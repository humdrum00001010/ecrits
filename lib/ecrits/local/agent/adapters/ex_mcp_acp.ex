defmodule Ecrits.Local.Agent.Adapters.ExMCPACP do
  @moduledoc """
  Local agent adapter backed by `ExMCP.ACP` (the maintained, multi-provider ACP
  stack shipped with ex_mcp).

  This adapter drives `ExMCP.ACP.Client` over the `ExMCP.ACP.AdapterTransport`,
  selecting a concrete ACP agent adapter (`ExMCP.ACP.Adapters.Codex` or
  `ExMCP.ACP.Adapters.Claude`) per provider. It translates the agent's streamed
  `session/update` notifications into the normalized event maps that
  `Ecrits.Local.Agent.Session` already understands, so the chat-rail UI/event
  contract is unchanged — only the producer is swapped.

  ## Lifecycle (per turn)

      start_client -> new_session -> prompt (blocking)
                                  -> session/update* (streamed)
                                  -> prompt result (stopReason)
                                  -> close_session / disconnect

  Cancellation is driven by `Session` killing the streaming task: the
  `Stream.resource/3` cleanup disconnects the client, which terminates the agent
  subprocess (parity with the previous Codex app-server adapter, which closed
  the port on cleanup). The ACP `Client.cancel/2` (`turn/interrupt` for Codex)
  is also issued best-effort on cleanup while a prompt is still in flight.
  """

  @behaviour Ecrits.Local.Agent.Adapter

  require Logger

  alias ExMCP.ACP.AdapterTransport
  alias ExMCP.ACP.Adapters.Claude
  alias ExMCP.ACP.Adapters.Codex
  alias ExMCP.ACP.Client

  @default_timeout 300_000

  @impl true
  def stream_turn(turn, opts \\ []) do
    with {:ok, exmcp_adapter} <- resolve_exmcp_adapter(opts) do
      {:ok, turn_stream(exmcp_adapter, turn, opts)}
    end
  end

  # ── Provider/adapter selection ───────────────────────────────────

  defp resolve_exmcp_adapter(opts) do
    case Keyword.get(opts, :exmcp_adapter) || provider_to_adapter(Keyword.get(opts, :provider)) do
      mod when mod in [Codex, Claude] -> {:ok, mod}
      "codex" -> {:ok, Codex}
      "claude" -> {:ok, Claude}
      _other -> {:ok, Codex}
    end
  end

  defp provider_to_adapter("codex"), do: Codex
  defp provider_to_adapter(:codex), do: Codex
  defp provider_to_adapter("claude"), do: Claude
  defp provider_to_adapter(:claude), do: Claude
  defp provider_to_adapter(%{key: key}), do: provider_to_adapter(key)
  defp provider_to_adapter(%{id: id}), do: provider_to_adapter(id)
  defp provider_to_adapter(_other), do: nil

  # ── Streaming ────────────────────────────────────────────────────

  defp turn_stream(exmcp_adapter, turn, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Stream.resource(
      fn -> start_session(exmcp_adapter, turn, opts, timeout) end,
      &next_event/1,
      &cleanup/1
    )
  end

  defp start_session(exmcp_adapter, turn, opts, timeout) do
    cwd = working_dir(turn, opts)
    adapter_opts = exmcp_adapter_opts(exmcp_adapter, cwd, opts)

    client_opts = [
      transport_mod: AdapterTransport,
      adapter: exmcp_adapter,
      adapter_opts: adapter_opts,
      event_listener: self()
    ]

    case Client.start_link(client_opts) do
      {:ok, client} ->
        start_session_with_client(client, cwd, turn, timeout)

      {:error, reason} ->
        raise "ex_mcp ACP session start failed: #{inspect(reason)}"
    end
  end

  defp start_session_with_client(client, cwd, turn, timeout) do
    case Client.new_session(client, cwd, timeout: timeout) do
      {:ok, %{"sessionId" => session_id}} ->
        input = input_text(turn.input)

        prompt_task =
          Task.async(fn ->
            Client.prompt(client, session_id, input, timeout: timeout)
          end)

        %{
          client: client,
          session_id: session_id,
          prompt_task: prompt_task,
          deadline: deadline(timeout),
          saw_text?: false,
          done?: false,
          tool_titles: %{}
        }

      {:ok, other} ->
        _ = safe_disconnect(client)
        raise "ex_mcp ACP new_session returned unexpected result: #{inspect(other)}"

      {:error, reason} ->
        _ = safe_disconnect(client)
        raise "ex_mcp ACP session start failed: #{inspect(reason)}"
    end
  end

  defp next_event(%{done?: true} = state), do: {:halt, state}

  defp next_event(state) do
    %{prompt_task: task, session_id: session_id, deadline: deadline} = state

    receive do
      {:acp_session_update, ^session_id, update} ->
        case map_update(update, state) do
          {:event, event, state} -> {[event], state}
          {:skip, state} -> next_event(state)
        end

      {:acp_session_update, _other_session, _update} ->
        next_event(state)

      {ref, prompt_result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        handle_prompt_result(prompt_result, state)

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        fail_turn(state, "ex_mcp ACP prompt task exited: #{inspect(reason)}")
    after
      remaining(deadline) ->
        fail_turn(state, "ex_mcp ACP timeout during turn")
    end
  end

  defp handle_prompt_result({:ok, result}, state) do
    case stop_reason(result) do
      reason when reason in ["cancelled", "canceled"] ->
        {:halt, %{state | done?: true}}

      "error" ->
        fail_turn(state, "ex_mcp ACP turn errored: #{inspect(result)}")

      _ ->
        # Fall back to the final result text if no agent_message_chunk deltas
        # were streamed (some agents only return text in the prompt result).
        case result_text(result, state) do
          text when is_binary(text) and text != "" ->
            {[%{type: :text_delta, delta: text}], %{state | done?: true}}

          _ ->
            {:halt, %{state | done?: true}}
        end
    end
  end

  defp handle_prompt_result({:error, reason}, state) do
    fail_turn(state, "ex_mcp ACP prompt failed: #{inspect(reason)}")
  end

  defp result_text(result, %{saw_text?: false}) when is_map(result), do: result["text"]
  defp result_text(_result, _state), do: nil

  defp cleanup(%{client: client, session_id: session_id, prompt_task: task}) do
    _ = if session_id, do: safe_cancel(client, session_id)
    _ = if task, do: Task.shutdown(task, :brutal_kill)
    _ = safe_disconnect(client)
    :ok
  end

  defp cleanup(_state), do: :ok

  defp safe_cancel(client, session_id) do
    Client.cancel(client, session_id)
  catch
    _, _ -> :ok
  end

  defp safe_disconnect(client) do
    if Process.alive?(client) do
      GenServer.stop(client, :normal, 2_000)
    end
  catch
    _, _ -> :ok
  end

  defp fail_turn(state, message) do
    cleanup(state)
    raise message
  end

  # ── session/update -> ecrits event mapping ───────────────────────

  # Agent answer text.
  defp map_update(%{"sessionUpdate" => "agent_message_chunk"} = update, state) do
    case update_text(update) do
      text when is_binary(text) and text != "" ->
        {:event, %{type: :text_delta, delta: text}, %{state | saw_text?: true}}

      _ ->
        {:skip, state}
    end
  end

  # Agent reasoning / thinking.
  defp map_update(%{"sessionUpdate" => "agent_thought_chunk"} = update, state) do
    case update_text(update) do
      text when is_binary(text) and text != "" ->
        {:event, %{type: :reasoning_delta, delta: text}, state}

      _ ->
        {:skip, state}
    end
  end

  # Tool call started / pending / in progress.
  defp map_update(%{"sessionUpdate" => "tool_call"} = update, state) do
    tool_call_id = tool_call_id(update)
    name = tool_name(update)
    state = put_in(state.tool_titles[tool_call_id], name)

    {:event,
     %{
       type: :tool_call_started,
       tool_call_id: tool_call_id,
       name: name,
       arguments: tool_arguments(update)
     }, state}
  end

  # Tool call progress / completion / failure.
  defp map_update(%{"sessionUpdate" => "tool_call_update"} = update, state) do
    tool_call_id = tool_call_id(update)
    name = tool_name(update) || Map.get(state.tool_titles, tool_call_id)

    case Map.get(update, "status") do
      "completed" ->
        {:event,
         %{
           type: :tool_call_completed,
           tool_call_id: tool_call_id,
           name: name,
           result: tool_output(update)
         }, state}

      "failed" ->
        {:event,
         %{
           type: :tool_call_failed,
           tool_call_id: tool_call_id,
           name: name,
           reason: tool_failure_reason(update)
         }, state}

      status when status in [nil, "in_progress", "pending"] ->
        # Intermediate output deltas — fold into the running tool call rather
        # than emitting a new started event.
        {:skip, state}

      _other ->
        {:skip, state}
    end
  end

  defp map_update(%{"sessionUpdate" => "error"} = update, state) do
    fail_turn(state, "ex_mcp ACP error: #{inspect(update["content"])}")
  end

  defp map_update(_update, state), do: {:skip, state}

  defp update_text(%{"content" => %{"text" => text}}), do: text
  defp update_text(%{"content" => text}) when is_binary(text), do: text
  defp update_text(_update), do: nil

  defp tool_call_id(update) do
    Map.get(update, "toolCallId") || Map.get(update, "id") || Ecto.UUID.generate()
  end

  defp tool_name(update) do
    Map.get(update, "toolName") || Map.get(update, "title") || Map.get(update, "kind")
  end

  defp tool_arguments(update) do
    case Map.get(update, "rawInput") || Map.get(update, "input") do
      args when is_map(args) -> args
      _ -> %{}
    end
  end

  defp tool_output(update) do
    Map.get(update, "rawOutput") || extract_content_text(Map.get(update, "content")) || %{}
  end

  defp tool_failure_reason(update) do
    extract_content_text(Map.get(update, "content")) ||
      inspect(Map.get(update, "rawOutput") || "")
  end

  defp extract_content_text(content) when is_list(content) do
    content
    |> Enum.map(&content_item_text/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  defp extract_content_text(content) when is_binary(content), do: content
  defp extract_content_text(_content), do: nil

  defp content_item_text(%{"content" => %{"text" => text}}), do: text
  defp content_item_text(%{"text" => text}) when is_binary(text), do: text
  defp content_item_text(%{"newText" => text}) when is_binary(text), do: text
  defp content_item_text(_item), do: nil

  defp stop_reason(result) when is_map(result), do: result["stopReason"]
  defp stop_reason(_result), do: nil

  # ── ex_mcp adapter_opts ───────────────────────────────────────────

  defp exmcp_adapter_opts(Codex, cwd, opts) do
    [cwd: cwd]
    |> maybe_put(:model, Keyword.get(opts, :model))
    |> maybe_put(:approvalPolicy, codex_approval_policy(Keyword.get(opts, :approval_policy)))
    |> maybe_put(:sandbox, Keyword.get(opts, :sandbox))
  end

  defp exmcp_adapter_opts(Claude, cwd, opts) do
    [cwd: cwd]
    |> maybe_put(:model, Keyword.get(opts, :model))
  end

  defp codex_approval_policy(nil), do: nil
  defp codex_approval_policy(:never), do: "never"
  defp codex_approval_policy(:on_request), do: "on-request"
  defp codex_approval_policy(:on_write), do: "on-request"
  defp codex_approval_policy(:always), do: "on-request"
  defp codex_approval_policy(:on_failure), do: "on-failure"
  defp codex_approval_policy(other) when is_binary(other), do: other
  defp codex_approval_policy(_other), do: nil

  # ── helpers ───────────────────────────────────────────────────────

  defp working_dir(turn, opts) do
    cond do
      is_binary(Keyword.get(opts, :cwd)) and File.dir?(Keyword.fetch!(opts, :cwd)) ->
        Keyword.fetch!(opts, :cwd)

      is_binary(turn.workspace_root) and Path.type(turn.workspace_root) == :absolute and
          File.dir?(turn.workspace_root) ->
        turn.workspace_root

      is_binary(turn.document_id) and Path.type(turn.document_id) == :absolute and
          File.dir?(turn.document_id) ->
        turn.document_id

      true ->
        File.cwd!()
    end
  end

  defp input_text(input) when is_binary(input), do: input
  defp input_text(%{content: content}) when is_binary(content), do: content
  defp input_text(%{"content" => content}) when is_binary(content), do: content
  defp input_text(input), do: inspect(input)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
