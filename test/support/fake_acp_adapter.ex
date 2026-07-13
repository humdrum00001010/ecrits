defmodule EcritsWeb.FakeAcpAdapter do
  @moduledoc """
  A *test-only* `ExMCP.ACP.Adapter` that drives a scripted turn through the real
  ex_mcp ACP stack (no provider subprocess). This is NOT a bespoke chat-agent
  producer — it is an ex_mcp adapter (the framework's own extension point), used
  to exercise the chat-rail LiveView rendering deterministically.

  Driven via `adapter_opts`:

    * `:script` — list of normalized turn events to replay, in order. Each entry
      is `{:text_delta, str}` / `{:reasoning_delta, str}` or a map like
      `%{type: :tool_call_completed, id: ..., name: ..., result: ...}`.
    * `:wait_for` / `:test_pid` — block the turn until `:test_pid` sends the
      `:wait_for` message (after announcing `{:local_agent_adapter_waiting, self}`),
      so cancellation/concurrency can be tested.
    * `:echo_opts` — when true, the final text echoes the prompt input.
  """

  @behaviour ExMCP.ACP.Adapter

  @impl true
  def init(opts), do: {:ok, %{opts: opts, session_id: "fake-session"}}

  @impl true
  def command(_opts), do: :one_shot

  @impl true
  def capabilities do
    # Advertise resume/load so `ExMCP.ACP.Client.load_session/4`'s capability gate
    # passes — mirrors the real Codex adapter (`loadSession: true`, resume), which
    # is what the cross-turn-memory fix relies on.
    %{
      "loadSession" => true,
      "sessionCapabilities" => %{"resume" => %{}}
    }
  end

  # ── session lifecycle (cross-turn memory) ───────────────────────────
  #
  # The chat `Session` persists the provider session id and RESUMES it on turns
  # 2+ (`session/load`) instead of minting a fresh one (`session/new`) each turn.
  # Report each call to `:test_pid` (when `report_session_lifecycle: true`) so a
  # test can assert turn 2 resumes the SAME id rather than creating a new thread.
  #
  # On `session/new` we mint a stable id and tell the bridge to use it via
  # `{:session_id, id}`, so the id the client stores matches the one we report.
  # On `session/load` we echo back the `sessionId` the client passed (codex does
  # the same: `thread/start` with the remembered `threadId`).
  @impl true
  def translate_outbound(%{"method" => "session/new"}, state) do
    session_id = "fake-thread-" <> Integer.to_string(System.unique_integer([:positive]))
    report_session(state, :new, session_id)
    {:ok, {:session_id, session_id}, %{state | session_id: session_id}}
  end

  def translate_outbound(%{"method" => method, "params" => params}, state)
      when method in ["session/load", "session/resume"] do
    session_id = params["sessionId"] || state.session_id
    report_session(state, :load, session_id)
    {:ok, {:session_id, session_id}, %{state | session_id: session_id}}
  end

  def translate_outbound(%{"method" => "session/prompt", "id" => id, "params" => params}, state) do
    opts = state.opts
    # Use the session id the client/bridge actually assigned (the bridge
    # synthesizes one for `:one_shot` adapters) so the streamed session/update
    # notifications match the session the caller is listening on.
    session_id = params["sessionId"] || state.session_id
    prompt = extract_prompt_text(params["prompt"])
    report_prompt(state, session_id, prompt)

    cmd_fn = fn ->
      maybe_block(opts)

      messages =
        case Keyword.get(opts, :fail_with) do
          nil ->
            script_messages(opts, session_id, prompt) ++
              [prompt_result(id, session_id, opts, prompt)]

          reason ->
            # Surface as an ACP prompt error so the turn fails the same way a real
            # provider-launch failure would (e.g. missing executable).
            [
              %{
                "jsonrpc" => "2.0",
                "id" => id,
                "error" => %{"code" => -32_000, "message" => to_string(reason)}
              }
            ]
        end

      # One-shot messages are pushed straight to the transport outbox (no
      # encoding step in the bridge), so they must already be JSON strings.
      {:ok, Enum.map(messages, &Jason.encode!/1)}
    end

    {:one_shot, cmd_fn, state}
  end

  def translate_outbound(_msg, state), do: {:ok, :skip, state}

  @impl true
  def translate_inbound(_line, state), do: {:skip, state}

  # ── scripted messages ──────────────────────────────────────────────

  defp maybe_block(opts) do
    case {Keyword.get(opts, :wait_for), Keyword.get(opts, :test_pid)} do
      {nil, _} ->
        :ok

      {message, test_pid} when is_pid(test_pid) ->
        send(test_pid, {:local_agent_adapter_waiting, self()})

        receive do
          ^message -> :ok
        after
          5_000 -> :ok
        end

      _ ->
        :ok
    end
  end

  defp script_messages(opts, session_id, _prompt) do
    opts
    |> Keyword.get(:script, [])
    |> Enum.map(&to_session_update(&1, session_id))
  end

  defp to_session_update({:text_delta, text}, session_id) do
    session_update(session_id, %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => text}
    })
  end

  # Mirrors the real Codex adapter's terminal emit: after the streamed deltas,
  # the provider re-sends the WHOLE message text once as a `final: true`
  # `agent_message_chunk` (see `ExMCP.ACP.Adapters.Codex.handle_item_completed/2`
  # for `agentMessage`). The consumer must treat this as a no-op when it already
  # streamed the deltas, otherwise the reply is appended twice.
  defp to_session_update({:final_message, text}, session_id) do
    session_update(session_id, %{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => text},
      "final" => true
    })
  end

  defp to_session_update({:reasoning_delta, text}, session_id),
    do: to_session_update(%{type: :reasoning_delta, delta: text}, session_id)

  defp to_session_update(%{type: :reasoning_delta, delta: text}, session_id) do
    session_update(session_id, %{
      "sessionUpdate" => "agent_thought_chunk",
      "content" => %{"type" => "text", "text" => text}
    })
  end

  defp to_session_update(%{type: :text_delta, delta: text}, session_id),
    do: to_session_update({:text_delta, text}, session_id)

  defp to_session_update(%{type: :tool_call_completed} = event, session_id) do
    session_update(session_id, %{
      "sessionUpdate" => "tool_call_update",
      "status" => "completed",
      "toolCallId" => event[:id],
      "toolName" => event[:name],
      "rawOutput" => event[:result]
    })
  end

  defp to_session_update(%{type: :tool_call_failed} = event, session_id) do
    session_update(session_id, %{
      "sessionUpdate" => "tool_call_update",
      "status" => "failed",
      "toolCallId" => event[:id],
      "toolName" => event[:name],
      "content" => [
        %{"type" => "content", "content" => %{"type" => "text", "text" => event[:reason] || ""}}
      ]
    })
  end

  defp to_session_update(%{type: :tool_call_started} = event, session_id) do
    session_update(session_id, %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => event[:id],
      "toolName" => event[:name],
      "rawInput" => event[:arguments] || %{}
    })
  end

  # Mirrors the vendored Claude adapter's FIRST report of a tool_use block: a
  # `tool_call_update` with a non-terminal status and no prior `tool_call`
  # (the terminal update then arrives without a toolName — script a
  # `:tool_call_completed` entry without `:name` to match).
  defp to_session_update(%{type: :tool_call_in_progress} = event, session_id) do
    session_update(session_id, %{
      "sessionUpdate" => "tool_call_update",
      "status" => "in_progress",
      "toolCallId" => event[:id],
      "toolName" => event[:name],
      "input" => event[:arguments] || %{}
    })
  end

  defp prompt_result(id, session_id, opts, prompt) do
    text = if Keyword.get(opts, :echo_opts), do: echo_text(opts, prompt), else: final_text(opts)

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{"stopReason" => "end_turn", "text" => text, "sessionId" => session_id}
    }
  end

  # Echoes the prompt plus the adapter_opts that the workspace inline option
  # selectors forward through to the ACP adapter (model/reasoning/sandbox/...),
  # so the LiveView's option-forwarding path stays under test.
  defp echo_text(opts, prompt) do
    "Test response: #{prompt}" <>
      opt_line(opts, :model, "model") <>
      opt_line(opts, :reasoning_effort, "reasoning") <>
      opt_line(opts, :approval_policy, "approval") <>
      opt_line(opts, :sandbox, "sandbox") <>
      opt_line(opts, :permission_mode, "permission")
  end

  defp opt_line(opts, key, label) do
    case Keyword.get(opts, key) do
      nil -> ""
      value -> "\n#{label}=#{value}"
    end
  end

  defp final_text(opts) do
    opts
    |> Keyword.get(:script, [])
    |> Enum.reduce("", fn
      {:text_delta, text}, acc -> acc <> text
      %{type: :text_delta, delta: text}, acc -> acc <> text
      _other, acc -> acc
    end)
  end

  defp session_update(session_id, update) do
    %{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => session_id, "update" => update}
    }
  end

  defp report_session(state, method, session_id) do
    opts = state.opts

    if Keyword.get(opts, :report_session_lifecycle) do
      case Keyword.get(opts, :test_pid) do
        pid when is_pid(pid) -> send(pid, {:fake_acp_session, method, session_id})
        _ -> :ok
      end
    end

    :ok
  end

  defp report_prompt(state, session_id, prompt) do
    opts = state.opts

    if Keyword.get(opts, :report_prompts) do
      case Keyword.get(opts, :test_pid) do
        pid when is_pid(pid) -> send(pid, {:fake_acp_prompt, session_id, prompt})
        _ -> :ok
      end
    end

    :ok
  end

  defp extract_prompt_text(nil), do: ""
  defp extract_prompt_text(text) when is_binary(text), do: text

  defp extract_prompt_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", &(&1["text"] || ""))
  end
end
