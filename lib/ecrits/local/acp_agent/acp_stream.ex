defmodule Ecrits.Local.AcpAgent.AcpStream do
  @moduledoc """
  Drives one ACP turn over `ExMCP.ACP.Client` and yields normalized chat-rail
  events as a lazy `Stream`.

  This is the single, robust ex_mcp-based producer — it replaces the bespoke
  Codex app-server / Claude CLI drivers entirely. It:

    * can either start an `ExMCP.ACP.Client` for a one-off turn or drive an
      already-open durable client owned by `Ecrits.Local.AcpAgent.Session`;
    * creates or reuses a session, forwarding the `doc.*` MCP server(s) so the
      agent can discover and call them (`new_session(..., mcp_servers: ...)`);
    * issues the prompt and streams `session/update` notifications, mapping them
      to `%{type: :text_delta | :reasoning_delta | :tool_call_started |
      :tool_call_completed | :tool_call_failed, ...}`;
    * on cleanup, cancels the in-flight turn; one-off clients are disconnected,
      while durable clients stay alive for the next turn.
  """

  alias ExMCP.ACP.AdapterTransport
  alias ExMCP.ACP.Adapters.Claude
  alias ExMCP.ACP.Adapters.Codex
  alias ExMCP.ACP.Client
  require Logger

  # Total ceiling for one turn (the ExMCP `prompt` RPC stays open for the whole
  # turn — every tool call resolves through the session and the prompt completes
  # only at turn end, so this caps total wall-clock). Generous because a single
  # agent turn may make dozens of doc.* edits across a long document.
  @default_timeout 1_200_000
  # Inactivity window for the receive loop: a turn that keeps streaming session
  # updates (tool calls, text deltas) is making progress and must NOT be killed
  # just for being long — only a genuinely STALLED turn (no activity for this
  # long) fails. Reset on every session update. Bounded by the total ceiling.
  # 10 min: ACP surfaces only COMPLETED events, so a provider generating one
  # long tool call (e.g. a whole-slide ops batch when designing a pptx) is
  # silent-but-active the entire generation; 5 min killed real turns.
  @idle_timeout 600_000
  # The long idle window is only appropriate after ACP has proven the prompt is
  # alive. Before the first session/update, a wedged provider can otherwise leave
  # the rail spinning for the full idle window with no visible progress.
  @initial_activity_timeout 90_000

  @doc """
  Returns a `Stream` of normalized chat-rail events for one turn.

  `turn` is `%{input, workspace_root}` and may carry `:provider_session_id` —
  the provider session/thread id from a PRIOR turn of this conversation. When
  present, the turn RESUMES that provider session
  (`session/load`) so the agent keeps cross-turn memory, instead of minting a
  brand-new one (`session/new`). The resolved provider session id is emitted as
  the FIRST stream event (`%{type: :provider_session, provider_session_id: id}`)
  so the long-lived `Session` can persist it for the next turn.

  `opts` carries adapter config (`:cwd`, `:model`, `:approval_policy`,
  `:sandbox`, `:mcp_servers`, …).
  """
  @spec turn_stream(module(), map(), keyword()) :: Enumerable.t()
  def turn_stream(exmcp_adapter, turn, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Stream.resource(
      fn -> start_session(exmcp_adapter, turn, opts, timeout) end,
      &next_event/1,
      &cleanup/1
    )
  end

  @doc false
  def update_state, do: %{saw_text?: false, tool_titles: %{}}

  @doc false
  def map_session_update(update, state) when is_map(state) do
    update
    |> map_update(ensure_update_state(state))
  end

  @doc false
  def open_client_session(exmcp_adapter, turn, opts, event_listener \\ self()) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cwd = working_dir(turn, opts)
    adapter_opts = exmcp_adapter_opts(exmcp_adapter, cwd, opts)

    client_opts = [
      transport_mod: AdapterTransport,
      adapter: exmcp_adapter,
      adapter_opts: adapter_opts,
      event_listener: event_listener
    ]

    started_at = System.monotonic_time(:millisecond)

    case Client.start_link(client_opts) do
      {:ok, client} ->
        case open_provider_session_for_client(client, cwd, turn, opts, timeout) do
          {:ok, session_id} ->
            log_acp_timing("session_open", started_at,
              status: "ok",
              resumed: is_binary(prior_provider_session_id(turn)),
              mcp_servers: length(mcp_servers_param(Keyword.get(opts, :mcp_servers)))
            )

            {:ok, %{client: client, session_id: session_id, cwd: cwd}}

          {:error, _reason} = error ->
            log_acp_timing("session_open", started_at, status: "error")
            _ = safe_disconnect(client)
            error

          other ->
            log_acp_timing("session_open", started_at, status: "unexpected")
            _ = safe_disconnect(client)
            {:error, {:unexpected_session_open, other}}
        end

      {:error, _reason} = error ->
        log_acp_timing("session_open", started_at, status: "error")
        error
    end
  end

  # ── start ──────────────────────────────────────────────────────────

  defp start_session(exmcp_adapter, turn, opts, timeout) do
    case reusable_client(opts) do
      {:ok, client, session_id} ->
        log_acp_timing("session_reuse", System.monotonic_time(:millisecond),
          status: "ok",
          mcp_servers: length(mcp_servers_param(Keyword.get(opts, :mcp_servers)))
        )

        start_prompt_with_session(client, session_id, turn, opts, timeout, true)

      :none ->
        start_new_session(exmcp_adapter, turn, opts, timeout)
    end
  end

  defp start_new_session(exmcp_adapter, turn, opts, timeout) do
    event_listener = Keyword.get(opts, :event_listener, self())

    case open_client_session(exmcp_adapter, turn, opts, event_listener) do
      {:ok, %{client: client, session_id: session_id}} ->
        persist_client? = Keyword.get(opts, :persist_client?, false)
        if persist_client?, do: Process.unlink(client)

        start_prompt_with_session(
          client,
          session_id,
          turn,
          opts,
          timeout,
          persist_client?,
          pending_start_events(
            client,
            session_id,
            persist_client?,
            Keyword.get(opts, :acp_client_key)
          )
        )

      {:error, reason} ->
        raise "ex_mcp ACP session open failed: #{inspect(reason)}"
    end
  end

  defp reusable_client(opts) do
    client = Keyword.get(opts, :client)
    session_id = Keyword.get(opts, :session_id)

    if is_pid(client) and Process.alive?(client) and is_binary(session_id) and session_id != "" do
      {:ok, client, session_id}
    else
      :none
    end
  end

  defp open_provider_session_for_client(client, cwd, turn, opts, timeout) do
    mcp_servers = mcp_servers_param(Keyword.get(opts, :mcp_servers))
    prior_session_id = prior_provider_session_id(turn)

    open_provider_session(client, cwd, prior_session_id, timeout, mcp_servers)
  end

  defp pending_start_events(client, session_id, true, client_key) when not is_nil(client_key) do
    [
      %{
        type: :acp_client_ready,
        client: client,
        provider_session_id: session_id,
        acp_client_key: client_key
      },
      %{type: :provider_session, provider_session_id: session_id}
    ]
  end

  defp pending_start_events(_client, session_id, _persist_client?, _client_key) do
    [%{type: :provider_session, provider_session_id: session_id}]
  end

  defp start_prompt_with_session(
         client,
         session_id,
         turn,
         opts,
         timeout,
         persist_client?,
         pending_events \\ nil
       ) do
    input = build_prompt(turn, opts)

    pending_events =
      pending_events || [%{type: :provider_session, provider_session_id: session_id}]

    %{
      client: client,
      session_id: session_id,
      pending_events: pending_events,
      prompt_input: input,
      prompt_timeout: timeout,
      prompt_task: nil,
      idle: initial_activity_timeout(timeout, opts),
      active_idle: min(timeout, @idle_timeout),
      deadline: deadline(initial_activity_timeout(timeout, opts)),
      prompt_started_at: nil,
      first_activity_logged?: false,
      saw_text?: false,
      done?: false,
      persist_client?: persist_client?,
      tool_titles: %{}
    }
  end

  # Resume the prior provider session when we have one AND the agent advertises
  # resume support; otherwise create a fresh session. `load_session` maps (for
  # codex) to the `thread/resume` request with the remembered `threadId`, which
  # rejoins the prior rollout and is what gives the agent cross-turn memory. We
  # keep the id WE asked to resume if the agent's response omits it.
  defp open_provider_session(client, cwd, prior_session_id, timeout, mcp_servers)
       when is_binary(prior_session_id) and prior_session_id != "" do
    if resume_supported?(client) do
      case Client.load_session(client, prior_session_id, cwd,
             timeout: timeout,
             mcp_servers: mcp_servers
           ) do
        {:ok, %{"sessionId" => session_id}} when is_binary(session_id) and session_id != "" ->
          {:ok, session_id}

        {:ok, _other} ->
          {:ok, prior_session_id}

        {:error, _reason} ->
          # Resume failed (e.g. the provider dropped the thread) — fall back to a
          # fresh session so the turn still runs, just without prior memory.
          new_provider_session(client, cwd, timeout, mcp_servers)
      end
    else
      new_provider_session(client, cwd, timeout, mcp_servers)
    end
  end

  defp open_provider_session(client, cwd, _prior_session_id, timeout, mcp_servers) do
    new_provider_session(client, cwd, timeout, mcp_servers)
  end

  defp new_provider_session(client, cwd, timeout, mcp_servers) do
    case Client.new_session(client, cwd, timeout: timeout, mcp_servers: mcp_servers) do
      {:ok, %{"sessionId" => session_id}} -> {:ok, session_id}
      other -> other
    end
  end

  defp resume_supported?(client) do
    case Client.agent_capabilities(client) do
      {:ok, caps} when is_map(caps) ->
        truthy?(caps["loadSession"]) or
          truthy?(get_in(caps, ["sessionCapabilities", "resume"]))

      _ ->
        false
    end
  catch
    _, _ -> false
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  defp prior_provider_session_id(turn) do
    case Map.get(turn, :provider_session_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # ACP `session/new` carries mcpServers as a list of server descriptors. We pass
  # the same descriptor through; the (vendored) Codex/Claude adapters also read
  # it from adapter_opts to inject the provider launch config.
  defp mcp_servers_param(servers) when is_list(servers), do: servers
  defp mcp_servers_param(_servers), do: []

  # ── stream ──────────────────────────────────────────────────────────

  # Emit the provider session id first (before any provider output) so the
  # `Session` persists it and the next turn can resume this conversation.
  defp next_event(%{pending_events: [event | rest]} = state) do
    {[event], %{state | pending_events: rest}}
  end

  defp next_event(%{done?: true} = state), do: {:halt, state}

  defp next_event(state) do
    state = ensure_prompt_started(state)
    %{prompt_task: task, session_id: session_id, deadline: deadline} = state

    receive do
      # Graceful turn cancel: halt the stream so `Stream.resource` runs `cleanup/1`,
      # which issues the ACP cancel and disconnects the client cleanly (terminating
      # the provider subprocess via `terminate/2` — the SAME teardown a normal turn
      # completion uses). This must NOT be a `Process.exit(task, :kill)` from the
      # Session: a brutal kill skips `cleanup/1`, propagates an untrappable `:kill`
      # to the linked `ExMCP.ACP.Client`, and tears the subprocess down mid-flush so
      # the next turn cannot resume the conversation.
      :acp_cancel_turn ->
        {:halt, %{state | done?: true}}

      {:acp_session_update, ^session_id, update} ->
        # Activity — the turn is progressing; push the idle deadline forward so a
        # long-but-active turn (many doc.* edits) is never killed mid-stream.
        state = mark_activity(state, update)

        case map_update(update, state) do
          {:event, event, state} -> {[event], state}
          {:skip, state} -> next_event(state)
          {:error, message, state} -> fail_turn(state, message)
        end

      {:acp_session_update, _other, _update} ->
        next_event(state)

      {:acp_stream_activity, update} ->
        # Durable Session processes ACP updates in its own GenServer so UI tool
        # rows cannot race prompt completion. It forwards a lightweight heartbeat
        # here so the stream task's stall detector observes the same progress.
        state = mark_activity(state, update)
        next_event(state)

      {ref, prompt_result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        handle_prompt_result(prompt_result, state)

      {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
        fail_turn(state, "ex_mcp ACP prompt task exited: #{inspect(reason)}")
    after
      remaining(deadline) ->
        fail_turn(state, "ex_mcp ACP turn stalled: no activity for #{state.idle}ms")
    end
  end

  defp ensure_prompt_started(%{prompt_task: %Task{}} = state), do: state

  defp ensure_prompt_started(
         %{client: client, session_id: session_id, prompt_input: input, prompt_timeout: timeout} =
           state
       ) do
    prompt_task =
      Task.async(fn -> Client.prompt(client, session_id, input, timeout: timeout) end)

    %{state | prompt_task: prompt_task, prompt_started_at: System.monotonic_time(:millisecond)}
  end

  defp handle_prompt_result({:ok, result}, state) do
    log_acp_timing("prompt_complete", Map.get(state, :prompt_started_at),
      status: stop_reason(result) || "ok"
    )

    case stop_reason(result) do
      reason when reason in ["cancelled", "canceled"] ->
        {:halt, %{state | done?: true}}

      "error" ->
        fail_turn(state, "ex_mcp ACP turn errored: #{inspect(result)}")

      _ ->
        case result_text(result, state) do
          text when is_binary(text) and text != "" ->
            {[%{type: :text_delta, delta: text, source: :prompt_result}], %{state | done?: true}}

          _ ->
            {:halt, %{state | done?: true}}
        end
    end
  end

  defp handle_prompt_result({:error, reason}, state) do
    log_acp_timing("prompt_complete", Map.get(state, :prompt_started_at), status: "error")
    fail_turn(state, "ex_mcp ACP prompt failed: #{inspect(reason)}")
  end

  defp maybe_log_first_activity(%{first_activity_logged?: true} = state, _update), do: state

  defp maybe_log_first_activity(state, update) do
    log_acp_timing("first_activity", Map.get(state, :prompt_started_at),
      status: Map.get(update, "sessionUpdate") || "unknown"
    )

    %{state | first_activity_logged?: true}
  end

  defp mark_activity(state, update) do
    state = maybe_log_first_activity(state, update)
    idle = Map.get(state, :active_idle, state.idle)

    %{state | idle: idle, deadline: deadline(idle)}
  end

  defp initial_activity_timeout(timeout, opts) do
    configured = Keyword.get(opts, :initial_activity_timeout, @initial_activity_timeout)

    timeout
    |> min(@idle_timeout)
    |> min(configured)
  end

  defp log_acp_timing(_event, nil, _fields), do: :ok

  defp log_acp_timing(event, started_at, fields) do
    duration_ms = System.monotonic_time(:millisecond) - started_at
    fields = Keyword.put(fields, :duration_ms, duration_ms)

    Logger.debug(fn ->
      rendered =
        fields
        |> Enum.map(fn {key, value} -> "#{key}=#{inspect(value)}" end)
        |> Enum.join(" ")

      "[acp_stream] #{event} #{rendered}"
    end)
  end

  defp result_text(result, %{saw_text?: false}) when is_map(result), do: result["text"]
  defp result_text(_result, _state), do: nil

  defp cleanup(%{client: client, session_id: session_id, prompt_task: task} = state) do
    _ = if session_id && not Map.get(state, :done?, false), do: safe_cancel(client, session_id)

    _ = if task, do: Task.shutdown(task, :brutal_kill)
    _ = unless Map.get(state, :persist_client?, false), do: safe_disconnect(client)
    :ok
  end

  defp cleanup(_state), do: :ok

  defp safe_cancel(client, session_id) do
    Client.cancel(client, session_id)
  catch
    _, _ -> :ok
  end

  defp safe_disconnect(client) do
    if Process.alive?(client), do: GenServer.stop(client, :normal, 2_000)
  catch
    _, _ -> :ok
  end

  defp fail_turn(state, message) do
    cleanup(state)
    raise message
  end

  # ── session/update -> normalized event ─────────────────────────────

  # A `final: true` agent_message_chunk carries the WHOLE message text, not an
  # incremental delta. The Codex adapter re-emits it after the streamed deltas
  # (`ExMCP.ACP.Adapters.Codex.handle_item_completed/2`); appending it again
  # would double the reply ("Hi there?Hi there?"). When deltas were already
  # streamed (`saw_text?`), the full text is built — drop the terminal chunk.
  # When NO deltas were seen (a provider that only sends a final message), emit
  # it as the sole text. This mirrors the `saw_text?` guard on the
  # `turn/completed` result text (see `result_text/2`). The Claude adapter never
  # sets `final`, so this branch never affects it.
  defp map_update(
         %{"sessionUpdate" => "agent_message_chunk", "final" => true} = update,
         %{saw_text?: saw_text?} = state
       ) do
    case update_text(update) do
      text when is_binary(text) and text != "" and not saw_text? ->
        {:event, %{type: :text_delta, delta: text}, %{state | saw_text?: true}}

      _ ->
        {:skip, state}
    end
  end

  defp map_update(%{"sessionUpdate" => "agent_message_chunk"} = update, state) do
    case update_text(update) do
      text when is_binary(text) and text != "" ->
        {:event, %{type: :text_delta, delta: text}, %{state | saw_text?: true}}

      _ ->
        {:skip, state}
    end
  end

  defp map_update(%{"sessionUpdate" => "agent_thought_chunk"} = update, state) do
    case update_text(update) do
      text when is_binary(text) and text != "" ->
        {:event, %{type: :reasoning_delta, delta: text}, state}

      _ ->
        {:skip, state}
    end
  end

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

      _other ->
        {:skip, state}
    end
  end

  defp map_update(%{"sessionUpdate" => "error"} = update, state) do
    {:error, "ex_mcp ACP error: #{inspect(update["content"])}", state}
  end

  defp map_update(_update, state), do: {:skip, state}

  defp ensure_update_state(state) do
    state
    |> Map.put_new(:saw_text?, false)
    |> Map.put_new(:tool_titles, %{})
  end

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

  # ── adapter_opts ────────────────────────────────────────────────────

  defp exmcp_adapter_opts(Codex, cwd, opts) do
    [cwd: cwd]
    |> maybe_put(:model, Keyword.get(opts, :model))
    |> maybe_put(:approvalPolicy, codex_approval_policy(Keyword.get(opts, :approval_policy)))
    |> maybe_put(:sandbox, Keyword.get(opts, :sandbox))
    |> maybe_put(:mcp_servers, present_list(Keyword.get(opts, :mcp_servers)))
  end

  defp exmcp_adapter_opts(Claude, cwd, opts) do
    [cwd: cwd]
    |> maybe_put(:model, Keyword.get(opts, :model))
    |> maybe_put(
      :max_thinking_tokens,
      claude_thinking_budget(Keyword.get(opts, :reasoning_effort))
    )
    |> maybe_put(:mcp_servers, present_list(Keyword.get(opts, :mcp_servers)))
  end

  # Any other ex_mcp ACP adapter (e.g. a test fake) gets the raw adapter_opts so
  # it can read `:script`/`:wait_for`/`:test_pid`/`:echo_opts` etc.
  defp exmcp_adapter_opts(_other, cwd, opts) do
    Keyword.put(opts, :cwd, cwd)
  end

  # Map the rail's Claude effort tier onto the thinking-token budget the Claude
  # adapter forwards to the CLI as `--max-thinking-tokens` (a flag the `claude`
  # binary still accepts). The adapter does NOT forward `--effort`, so the budget
  # is how the chosen tier actually reaches the model. "ultracode" is the top
  # tier; it ALSO injects the `ultrathink` workflow keyword into the prompt
  # (see build_prompt/claude_ultracode?) for Claude's most exhaustive run.
  defp claude_thinking_budget("low"), do: 4_000
  defp claude_thinking_budget("medium"), do: 10_000
  defp claude_thinking_budget("high"), do: 21_333
  defp claude_thinking_budget("xhigh"), do: 31_999
  defp claude_thinking_budget("ultracode"), do: 60_000
  defp claude_thinking_budget(_effort), do: nil

  defp claude_ultracode?(opts), do: Keyword.get(opts, :reasoning_effort) == "ultracode"

  defp codex_approval_policy(nil), do: nil
  defp codex_approval_policy(:never), do: "never"
  defp codex_approval_policy(:on_request), do: "on-request"
  defp codex_approval_policy(:on_write), do: "on-request"
  defp codex_approval_policy(:always), do: "on-request"
  defp codex_approval_policy(:on_failure), do: "on-failure"
  # The access controls store these as snake_case STRINGS ("on_write"); codex
  # only accepts the kebab-case vocabulary — an unknown value silently falls
  # back to the user's own ~/.codex default policy, which is how a "read-only"
  # rail session could end up running under whatever the CLI default was.
  defp codex_approval_policy("on_write"), do: "on-request"
  defp codex_approval_policy("on_request"), do: "on-request"
  defp codex_approval_policy("always"), do: "on-request"
  defp codex_approval_policy("on_failure"), do: "on-failure"
  defp codex_approval_policy(other) when is_binary(other), do: other
  defp codex_approval_policy(_other), do: nil

  # ── misc ────────────────────────────────────────────────────────────

  defp working_dir(turn, opts) do
    cond do
      is_binary(Keyword.get(opts, :cwd)) and File.dir?(Keyword.fetch!(opts, :cwd)) ->
        Keyword.fetch!(opts, :cwd)

      is_binary(turn.workspace_root) and Path.type(turn.workspace_root) == :absolute and
          File.dir?(turn.workspace_root) ->
        turn.workspace_root

      true ->
        File.cwd!()
    end
  end

  # Prepend a concise, provider-agnostic developer instruction so the agent knows
  # the currently-open document is read/editable ONLY through the document MCP
  # tools — not by shelling out to hwp5proc / LibreOffice / file readers. Without
  # this, codex (gpt-5.5) tends to ignore them and try shell tooling, or it reads
  # but never follows through to the edit.
  #
  # CRITICAL — two confirmed failure modes this preamble defends against (verified
  # live against codex gpt-5.5 via ~/.codex/logs_2.sqlite):
  #
  # 1. Tool naming: the MCP server registers dotted names (`doc.context`). Keep
  #    the prompt aligned with that contract so the model uses the doc MCP tools
  #    it is actually handed, instead of searching for stale underscore aliases.
  #
  # 2. Deferred MCP tools: with many MCP servers connected (the user's global
  #    codex servers + our `doc`), codex does NOT inject every MCP tool into the
  #    request — it defers them behind a tool-search / `list_mcp_resources`
  #    discovery layer. The doc server connects and lists 12 tools
  #    (`tool_count=12` in connection_manager) yet none appear in the request's
  #    tools array. The earlier preamble FORBADE `tool_search`/`list_mcp_*`, so the
  #    model never surfaced the deferred doc tools and declared them missing. The
  #    fix REQUIRES the model to use discovery to load the `doc` tools first.
  # `turn.input` arrives already normalized by `Session` (a bare string for the
  # legacy path, OR a validated multi-modal block list — Phase 5). Map it onto the
  # ACP prompt content shape via `Ecrits.Local.AcpAgent.Prompt`: a string input
  # yields `preamble <> string` (UNCHANGED — `ExMCP.ACP.Client` auto-wraps it as
  # one text block, exactly as before); a block list yields a leading preamble
  # text block followed by one ACP block per input block.
  defp build_prompt(turn, opts) do
    Ecrits.Local.AcpAgent.Prompt.to_acp_content(turn.input, doc_preamble(opts))
  end

  # When the rail's top "ultracode" tier is selected (Claude only), append the
  # `ultrathink` workflow keyword. The Claude CLI recognizes this literal keyword
  # in the turn text — it injects a system message ("The user included the keyword
  # 'ultrathink', requesting deeper reasoning on this turn") that raises the
  # thinking budget for the turn. Verified present in claude 2.1.153's binary
  # (`workflow_keyword_request`). This is the real, supported way to engage the
  # most exhaustive reasoning per turn; there is NO `ultracode`/`--ultracode` flag.
  defp ultracode_keyword(opts) do
    if claude_ultracode?(opts) do
      "\n\n[System] ultrathink\n"
    else
      ""
    end
  end

  # Kept lean ON PURPOSE — this rides EVERY turn. Only the live-verified
  # defenses stay (dot/underscore tool naming, deferred-MCP discovery, the
  # no-shell rule + render-view exception, save/read-only/no-fabrication, the
  # caveman voice). The current document handle is now an MCP contract:
  # doc.context.current_document, not prompt-embedded path text.
  defp doc_preamble(opts) do
    status = Ecrits.Fuse.DocMount.status()
    vfs_mounted? = Keyword.get(opts, :doc_vfs_mounted, status.enabled?)

    cond do
      status.enabled? and vfs_mounted? ->
        mounted_vfs_preamble(status, opts)

      status.enabled? ->
        unmounted_vfs_preamble(status, opts)

      fs_vfs_expected?(status) ->
        blocked_vfs_preamble(status, opts)

      true ->
        legacy_doc_preamble(opts)
    end
  end

  defp unmounted_vfs_preamble(status, opts) do
    """
    [System] Doc VFS backend is available, but this workspace is not mounted right now:
    #{status.message}

    Do not claim `.ecrits/mount/<name>.jsonl` exists until `doc.open_doc` returns
    a non-null `mounted_at`. Do not use `.md`, and do not shell-read the raw
    binary document. For this/current/open document, call `doc.open_doc`; if it
    returns `mounted_at: null`, report the `mount_status` / `mount_error` blocker
    instead of editing. Only after `mounted_at` is non-null should you read/edit
    the mounted JSONL file with shell tools.

    Voice: caveman. Short answer, no filler; report result/blockers only.
    """ <> ultracode_keyword(opts)
  end

  defp fs_vfs_expected?(%{backend: :fskit, reason: reason})
       when reason in [
              :fskit_extension_disabled,
              :fskit_extension_not_registered,
              :fskit_extension_unsigned
            ],
       do: true

  defp fs_vfs_expected?(_status), do: false

  defp blocked_vfs_preamble(status, opts) do
    settings_line =
      if is_binary(status.settings_url) and status.settings_url != "" do
        "Settings URL: #{status.settings_url}\n"
      else
        ""
      end

    """
    [System] FSKit/VFS is configured but not mountable right now:
    #{status.message}
    #{settings_line}
    Do not claim `.ecrits/mount/<name>.jsonl` exists until `doc.open_doc` returns
    a non-null `mounted_at`. Do not use `.md`. Use the normal doc MCP tools for
    this turn unless the user enables FSKit first; `doc.open_doc` will report the
    same `mount_status` blocker.

    """ <> legacy_doc_preamble(opts)
  end

  # Mounted VFS mode: documents are FILES. Only doc.open_doc is advertised as an MCP
  # tool; read/find/edit happen with native shell tools over the projected IR file.
  # This matches the MCPServer tool gate (both key on `DocMount.enabled?()`), so
  # the agent is never told about a tool it can't call.
  defp mounted_vfs_preamble(status, opts) do
    """
    [System] #{doc_vfs_backend_mode_label(status)} mode: documents are EDITABLE FILES, not opaque binaries.
    The ONLY MCP tool to call is `doc.open_doc {path}` (mount a document into
    the VFS). There is NO doc.read / doc.find / doc.context / doc.edit /
    doc.set / doc.save — do EVERYTHING ELSE
    with your native shell/file tools over the mounted file.
    NEVER type `doc.open_doc` in the shell; it is an MCP tool call, not a command.
    If `doc.open_doc` is not immediately visible as a callable MCP tool, use
    resource/tool discovery only to surface `doc.open_doc`, then call
    `doc.open_doc`. Do not use discovery as a substitute for editing the mounted
    file. Do not call `doc.close_doc` in normal edit turns, even if a cached tool
    list shows it; closing removes the projected file before verification.

    Workflow:
    1. First action for this/current/open-document file work: call
       `doc.open_doc {path}` (path = the workspace document name). It mounts the doc
      and returns a `.ecrits/mount/<name>.jsonl` path under the workspace root.
      The JSONL file itself is IR-only; it does NOT contain `mounted_at`,
      `mount_status`, or other tool metadata. If the MCP tool is hidden but the
      mounted file already exists at `.ecrits/mount/<name>.jsonl`, use that
      path as the VFS target. Never treat a missing `mounted_at` field inside
      the JSONL as a blocker. Keep the document open through edit and
      verification; do not use `doc.close_doc` as cleanup.
      NEVER create, copy, or edit a JSONL projection anywhere else. A file like
      `/tmp/<name>.jsonl`, `<workspace>/<name>.jsonl`, or any scratch/staged JSONL
      outside `.ecrits/mount/` is fake and does NOT route to the document. If
      `.ecrits/mount/<name>.jsonl` is missing after `doc.open_doc`, stop and
      report that exact blocker; do not invent a fallback JSONL file.
    2. That file is the document's IR as one compact nested JSON value, not
       Markdown and not a flat positional stream:
       `[ [ [ payload_node, ... ], ... ], ... ]`
       means `sections -> paragraphs -> payload nodes`.
       Positional HWPX refs are NOT payload fields here: do not add
       `{"ref":[0,385,0]}` or invent any positional ref. The nested list position
       is the positional address. Rich non-positional refs may appear only when
       they carry semantic addressing from the backend. READ with `cat`/`sed -n`;
       FIND with `grep -n`/`rg` over it. For "this/current/open document", it is
       the one the user is viewing — `doc.open_doc` it, then operate on its file.
       Interpret normal placement words directly in this nested structure:
       "below/after the table" means find the relevant `"type":"table"` payload
       and insert the new payload immediately after that table payload in the
       same paragraph list. Do not create a new section/paragraph wrapper unless
       the user explicitly asks for a structural paragraph change and the VFS
       supports that change.
    3. EDIT existing payloads by changing fields IN PLACE with a shell command,
       keeping each existing node's `"type"` unchanged. Keep existing payload
       order stable unless you are intentionally inserting or deleting one
       supported native payload.
      For whole-file rewrites, create the temp file inside the same
      `.ecrits/mount/` directory, validate the temp with `jq -c . "$tmp"`,
      then rename it over the target only if JSON validation succeeds. Do NOT
      use `mktemp`, `dd`, or any temp path outside the mount. Example:
       `tmp=".ecrits/mount/<name>.jsonl.tmp"; jq -c '...' "$target" > "$tmp" && jq -c . "$tmp" >/dev/null && mv "$tmp" "$target"`
       This keeps the write on the VFS `create`/`write`/`rename` path.
       To CREATE a native table, insert one new payload object at the desired
       nested-list position inside an existing paragraph list (the innermost
       array of payload nodes), not as a metadata object, standalone object, new
       section wrapper, or new paragraph wrapper:
       `{"type":"table","cells":[["H1","H2"],["A","B"]],"header":true}`
       Do not invent `"ref"` for that new table. `rows`/`cols` are optional and
       otherwise derived from `cells`.
       To CREATE a native picture, insert one new payload object at the desired
       nested-list position inside an existing paragraph list (the innermost
       array of payload nodes), not as a metadata object, standalone object, new
       section wrapper, or new paragraph wrapper:
       `{"type":"picture","src":"/abs/img.png"}`
       ecrits chooses a readable default size from the image aspect; add
       `width`/`height` only when intentionally resizing in HWPUNIT. Do not put
       `x`/`y` on a newly inserted picture unless you explicitly set
       `"treatAsChar": false`; otherwise new pictures are inline at the nested
       position. Move an existing picture by editing that payload's `x`, `y`,
       and `treatAsChar` fields in place; resize by editing `width`/`height`.
       Delete a picture by removing that picture payload from its paragraph list.
       To put a new picture inside a table cell, find the target `"type":"cell"`
       payload and insert the picture payload immediately AFTER that cell payload
       in the same paragraph list. Do not edit/reuse an existing picture payload
       and do not invent `"ref"`; the preceding cell payload is the anchor.
       If the user asks for an image from the internet, download it to a normal
       workspace file first and use that absolute local path as `src`; do not
       put remote URLs into the JSONL. Other add/remove/reorder/ref/type edits
       are structural and rejected in this VFS write-back.
       Structural inserts are one-shot. After adding one requested table or
      picture payload, write once, re-read the mounted JSONL once, and stop when
      the requested table marker exists or the picture appears at the intended
      nested position. For table-cell pictures, that means a `"type":"picture"`
      node immediately after the target cell payload, normally with
      `ref.cellPath` after write-back. `src` is only embed input and may
      normalize away after write-back; do not insert another copy just because
      `src` normalized away. Repeated insertion is a failed edit.
       `"text"` changes route as scoped text edits; other payload node field
       changes route through the native property setter when the backend supports
       them. Unsupported/derived fields fail loudly. The write routes onto the
       live document and auto-saves — there is no doc.save.
    4. Verify with shell exactly once (re-`grep` the mount file). Do not reopen
       editor previews or poll `/local/document-bytes` to verify a VFS write.

    Voice: caveman. Short answer, no filler; report result/blockers only.
    Read-only questions: cat/grep and answer, do not edit. No fabrication.
    """ <> ultracode_keyword(opts)
  end

  defp doc_vfs_backend_mode_label(%{backend: :fskit}), do: "FSKit/VFS"
  defp doc_vfs_backend_mode_label(%{backend: :fuse}), do: "FUSE/VFS"

  defp legacy_doc_preamble(opts) do
    """
    [System] Use doc MCP tools for documents; never shell-read the RAW binary doc
    files (.hwp/.docx/.pptx/.xlsx are not text). EXCEPTION: only if `doc.open_doc`
    returns a non-null `mounted_at`, read/edit that mounted `.jsonl` IR file
    under `.ecrits/mount/` directly; it routes to the document.
    For "this/current/open document", call `doc.context` first and use
    `current_document.document` as the `document` param. Tool names are dotted.
    Read tools: `doc.context`, `doc.list`, `doc.open`, `doc.find`, `doc.read`,
    `doc.get`, `doc.render`. Write/output tools, ONLY when the user explicitly
    asks to modify/create/save/export: `doc.create`, `doc.edit`, `doc.set`,
    `doc.save`. Do not search for underscore names like `doc_edit` when
    `doc.edit` is available. The `document` param accepts ids/paths returned by
    doc.context/doc.list. ONE exception: `doc.render` returns PNG paths — VIEW
    them with your native image tool to check your work; that is expected.

    Read/inspect/summarize/extract/check questions are read-only. For them, do
    not call `doc.create`, `doc.edit`, `doc.set`, or `doc.save`; answer from
    `doc.context`/`doc.find`/`doc.read` and stop.

    Voice: caveman. Short answer, no filler; report result/blockers only.

    Read-only current doc: `doc.context` -> `doc.find` -> `doc.read {ref}`. Stop
    after answering. Never create a destination document for a read-only prompt.
    Write: `doc.edit` (structure/text, batch via ops:[...]), `doc.set`
    (formatting); empty cell -> insert_text, non-empty cell -> set_cell.
    Existing HWP paragraphs are structural records: to divide one paragraph, use
    `doc.edit` op `split` at paragraph offsets; do NOT use `replace_text` with
    newlines. If splitting one original paragraph several times, apply offsets
    from largest to smallest.

    New output document, ONLY when user explicitly asks to create/export/save/put
    into another document: FIRST call `doc.create` with the destination
    path/kind; `doc.open` never creates a file. Use the returned `document` id
    for all writes and save that id. If the new doc is derived from the
    current/open doc, read the source as needed, then still call `doc.create` for
    the destination before writing. Do not claim a new document exists unless
    `doc.create` and `doc.save` both succeeded. Authoring pptx/docx? Follow the
    doc server instructions' design guide; template clones: replace content in
    place, don't rebuild. Any edit/create/set MUST end with `doc.save` before
    saying done. Read-only refusal = stop/report. No fabrication.
    """ <> ultracode_keyword(opts)
  end

  defp present_list(list) when is_list(list) and list != [], do: list
  defp present_list(_other), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
