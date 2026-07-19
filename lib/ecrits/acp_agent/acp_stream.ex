defmodule Ecrits.AcpAgent.AcpStream do
  @moduledoc """
  Drives one ACP turn over `ExMCP.ACP.Client` and yields normalized chat-rail
  events as a lazy `Stream`.

  This is the single, robust ex_mcp-based producer — it replaces the bespoke
  Codex app-server / Claude CLI drivers entirely. It:

    * can either start an `ExMCP.ACP.Client` for a one-off turn or drive an
      already-open durable client owned by `Ecrits.AcpAgent.Session`;
    * creates or reuses a session, forwarding the `doc.*` MCP server(s) so the
      agent can discover and call them (`new_session(..., mcp_servers: ...)`);
    * issues the prompt and streams `session/update` notifications, mapping them
      to `%{type: :text_delta | :reasoning_delta | :file_operation_started |
      :file_operation_completed | :file_operation_failed | :tool_call_started |
      :tool_call_completed | :tool_call_failed, ...}`;
    * on cleanup, cancels the in-flight turn; one-off clients are disconnected,
      while durable clients stay alive for the next turn.
  """

  alias ExMCP.ACP.AdapterTransport
  alias ExMCP.ACP.Adapters.Claude
  alias ExMCP.ACP.Adapters.Codex
  alias ExMCP.ACP.Client
  alias Ecrits.AcpAgent.CodexAdapter
  alias Ecrits.AcpAgent.CodexHome
  alias Ecrits.AcpAgent.Content
  alias Ecrits.AcpAgent.WorkspaceFileHandler
  alias Ecrits.Prompt
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
  @mcp_startup_timeout 15_000
  @file_operation_names ~w(read_text_file search_text_file edit_text_file)
  @file_operation_reason_max_chars 1_000

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
  def update_state,
    do: %{
      saw_text?: false,
      tool_titles: %{},
      tool_kinds: %{},
      file_operation_ids: MapSet.new(),
      file_operation_started_ids: MapSet.new(),
      file_operations: %{},
      edit_payloads: %{},
      edit_paths: %{}
    }

  @doc false
  def map_session_update(update, state) when is_map(state) do
    update
    |> map_update(ensure_update_state(state))
  end

  @doc false
  def file_operation_name?(name), do: name in @file_operation_names

  @doc false
  def open_client_session(exmcp_adapter, turn, opts, event_listener \\ self()) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cwd = working_dir(turn, opts)
    started_at = System.monotonic_time(:millisecond)

    case adapter_isolation(exmcp_adapter, turn, opts) do
      {:ok, isolation} ->
        adapter_opts = exmcp_adapter_opts(exmcp_adapter, cwd, opts) ++ isolation.adapter_opts

        client_opts =
          [
            transport_mod: AdapterTransport,
            adapter: exmcp_adapter,
            adapter_opts: adapter_opts,
            event_listener: event_listener
          ]
          |> file_handler_client_opts(exmcp_adapter, turn, opts, cwd)

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
                isolation.cleanup.()
                error

              other ->
                log_acp_timing("session_open", started_at, status: "unexpected")
                _ = safe_disconnect(client)
                isolation.cleanup.()
                {:error, {:unexpected_session_open, other}}
            end

          {:error, _reason} = error ->
            log_acp_timing("session_open", started_at, status: "error")
            isolation.cleanup.()
            error
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
        case await_configured_mcp_startup(exmcp_adapter, session_id, turn, opts) do
          :ok ->
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
            _ = safe_disconnect(client)
            raise "ex_mcp ACP MCP startup failed: #{inspect(reason)}"
        end

      {:error, reason} ->
        raise "ex_mcp ACP session open failed: #{inspect(reason)}"
    end
  end

  @doc false
  def await_mcp_startup(session_id, server_names, timeout)
      when is_binary(session_id) and is_list(server_names) and is_integer(timeout) do
    pending = server_names |> Enum.filter(&is_binary/1) |> MapSet.new()
    await_mcp_startup_loop(session_id, pending, deadline(timeout))
  end

  defp await_configured_mcp_startup(CodexAdapter, session_id, turn, opts) do
    names = mcp_server_names(Keyword.get(opts, :mcp_servers))

    if document_lane?(turn, opts) and names != [] do
      await_mcp_startup(
        session_id,
        names,
        Keyword.get(opts, :mcp_startup_timeout, @mcp_startup_timeout)
      )
    else
      :ok
    end
  end

  defp await_configured_mcp_startup(_adapter, _session_id, _turn, _opts), do: :ok

  defp await_mcp_startup_loop(session_id, pending, deadline) do
    if MapSet.size(pending) == 0 do
      :ok
    else
      receive do
        {:acp_stream_activity, update} ->
          handle_mcp_startup_update(session_id, pending, deadline, update)

        {:acp_session_update, ^session_id, update} ->
          handle_mcp_startup_update(session_id, pending, deadline, update)
      after
        remaining(deadline) -> {:error, {:mcp_startup_timeout, MapSet.to_list(pending)}}
      end
    end
  end

  defp handle_mcp_startup_update(
         session_id,
         pending,
         deadline,
         %{
           "sessionUpdate" => "mcp_server_startup",
           "serverName" => name,
           "status" => "ready"
         }
       ) do
    await_mcp_startup_loop(session_id, MapSet.delete(pending, name), deadline)
  end

  defp handle_mcp_startup_update(
         session_id,
         pending,
         deadline,
         %{
           "sessionUpdate" => "mcp_server_startup",
           "serverName" => name,
           "status" => status
         } = update
       )
       when status in ["failed", "error"] do
    if MapSet.member?(pending, name),
      do: {:error, {:mcp_server_unavailable, name, update["error"]}},
      else: await_mcp_startup_loop(session_id, pending, deadline)
  end

  defp handle_mcp_startup_update(session_id, pending, deadline, _update),
    do: await_mcp_startup_loop(session_id, pending, deadline)

  defp mcp_server_names(servers) when is_list(servers) do
    servers
    |> Enum.map(fn
      %{"name" => name} -> name
      %{name: name} -> name
      _ -> nil
    end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp mcp_server_names(_servers), do: []

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

  defp map_update(%{"sessionUpdate" => "file_operation"} = update, state) do
    file_operation_id = file_operation_id(update)
    operation = file_operation_name(update)

    state = track_file_operation(state, file_operation_id, operation, update)

    cond do
      not file_operation_call?(state, file_operation_id) ->
        {:skip, state}

      file_operation_started?(state, file_operation_id) ->
        {:skip, state}

      true ->
        state = mark_file_operation_started(state, file_operation_id)

        {:event,
         file_operation_event(
           :file_operation_started,
           file_operation_id,
           :running,
           update,
           state
         ), state}
    end
  end

  defp map_update(%{"sessionUpdate" => "file_operation_update"} = update, state) do
    file_operation_id = file_operation_id(update)
    operation = file_operation_name(update)
    state = track_file_operation(state, file_operation_id, operation, update)

    if file_operation_call?(state, file_operation_id) do
      case file_operation_status(update) do
        "completed" ->
          {:event,
           file_operation_event(
             :file_operation_completed,
             file_operation_id,
             :completed,
             update,
             state
           ), state}

        "failed" ->
          {:event,
           file_operation_event(
             :file_operation_failed,
             file_operation_id,
             :failed,
             update,
             state
           )
           |> Map.put(:reason, tool_failure_reason(update)), state}

        _non_terminal ->
          if file_operation_started?(state, file_operation_id) do
            {:skip, state}
          else
            state = mark_file_operation_started(state, file_operation_id)

            {:event,
             file_operation_event(
               :file_operation_started,
               file_operation_id,
               :running,
               update,
               state
             ), state}
          end
      end
    else
      {:skip, state}
    end
  end

  defp map_update(%{"sessionUpdate" => "tool_call"} = update, state) do
    tool_call_id = tool_call_id(update)
    name = tool_name(update)
    kind = tool_kind(update)

    state =
      state
      |> put_in([:tool_kinds, tool_call_id], kind)
      |> maybe_put_tool_title(tool_call_id, name)
      |> track_file_operation(tool_call_id, name, update)

    cond do
      file_operation_call?(state, tool_call_id) ->
        if file_operation_started?(state, tool_call_id) do
          {:skip, state}
        else
          state = mark_file_operation_started(state, tool_call_id)

          {:event,
           file_operation_event(
             :file_operation_started,
             tool_call_id,
             :running,
             update,
             state
           ), state}
        end

      kind == "edit" ->
        map_edit_update(update, tool_call_id, state)

      tool_name?(name) ->
        {:event,
         %{
           type: :tool_call_started,
           tool_call_id: tool_call_id,
           name: name,
           kind: kind,
           arguments: tool_arguments(update)
         }, state}

      true ->
        {:skip, state}
    end
  end

  defp map_update(%{"sessionUpdate" => "tool_call_update"} = update, state) do
    tool_call_id = tool_call_id(update)
    reported_name = tool_name(update)
    cached_name = Map.get(state.tool_titles, tool_call_id)
    name = reported_name || cached_name
    kind = tool_kind(update) || Map.get(state.tool_kinds, tool_call_id)

    state =
      state
      |> put_in([:tool_kinds, tool_call_id], kind)
      |> track_file_operation(tool_call_id, cached_name, update)
      |> track_file_operation(tool_call_id, reported_name, update)

    cond do
      file_operation_call?(state, tool_call_id) ->
        case file_operation_status(update) do
          "completed" ->
            {:event,
             file_operation_event(
               :file_operation_completed,
               tool_call_id,
               :completed,
               update,
               state
             ), state}

          "failed" ->
            {:event,
             file_operation_event(
               :file_operation_failed,
               tool_call_id,
               :failed,
               update,
               state
             )
             |> Map.put(:reason, tool_failure_reason(update)), state}

          _non_terminal ->
            if file_operation_started?(state, tool_call_id) do
              {:skip, state}
            else
              state = mark_file_operation_started(state, tool_call_id)

              {:event,
               file_operation_event(
                 :file_operation_started,
                 tool_call_id,
                 :running,
                 update,
                 state
               ), state}
            end
        end

      kind == "edit" ->
        map_edit_update(update, tool_call_id, state)

      true ->
        case Map.get(update, "status") do
          "completed" when is_binary(name) and name != "" ->
            {:event,
             %{
               type: :tool_call_completed,
               tool_call_id: tool_call_id,
               name: name,
               kind: kind,
               result: tool_output(update)
             }, state}

          "failed" when is_binary(name) and name != "" ->
            {:event,
             %{
               type: :tool_call_failed,
               tool_call_id: tool_call_id,
               name: name,
               kind: kind,
               reason: tool_failure_reason(update)
             }, state}

          status when status not in ["completed", "failed"] ->
            # A non-terminal update for a call we have not seen is its START: the
            # Claude adapter's first report of a tool_use block is a
            # `tool_call_update` (pending/in_progress) with no prior `tool_call`.
            # Without this the call would only surface at completion — after the
            # UI already parked the reply bubble above it — and the terminal
            # update carries no toolName, so the row would fall back to "tool".
            cond do
              Map.has_key?(state.tool_titles, tool_call_id) ->
                {:skip, state}

              tool_name?(name) ->
                state = put_in(state.tool_titles[tool_call_id], name)

                {:event,
                 %{
                   type: :tool_call_started,
                   tool_call_id: tool_call_id,
                   name: name,
                   kind: kind,
                   arguments: tool_arguments(update)
                 }, state}

              true ->
                {:skip, state}
            end

          _terminal_without_identity ->
            {:skip, state}
        end
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
    |> Map.put_new(:tool_kinds, %{})
    |> Map.put_new(:file_operation_ids, MapSet.new())
    |> Map.put_new(:file_operation_started_ids, MapSet.new())
    |> Map.put_new(:file_operations, %{})
    |> Map.put_new(:edit_payloads, %{})
    |> Map.put_new(:edit_paths, %{})
  end

  defp map_edit_update(update, tool_call_id, state) do
    path = edit_path(update) || Map.get(state.edit_paths, tool_call_id)
    delta = edit_delta(update)
    state = if is_binary(path), do: put_in(state.edit_paths[tool_call_id], path), else: state

    cond do
      not (is_binary(delta) and delta != "") ->
        {:skip, state}

      Map.get(state.edit_payloads, tool_call_id) == delta ->
        {:skip, state}

      true ->
        state = put_in(state.edit_payloads[tool_call_id], delta)

        {:event, %{type: :edit_delta, edit_id: tool_call_id, path: path, delta: delta}, state}
    end
  end

  defp tool_kind(update) do
    case Map.get(update, "kind") do
      kind when is_binary(kind) -> String.downcase(kind)
      _ -> nil
    end
  end

  defp edit_path(update) do
    input = edit_input(update)

    input["path"] ||
      update
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.find_value(fn
        %{"type" => "diff", "path" => path} when is_binary(path) -> path
        _ -> nil
      end)
  end

  defp edit_delta(update) do
    input = edit_input(update)

    input["diff"] || input["newText"] ||
      update
      |> Map.get("content", [])
      |> List.wrap()
      |> Enum.find_value(fn
        %{"type" => "diff"} = diff -> diff["newText"] || diff["diff"]
        _ -> nil
      end)
  end

  defp edit_input(update) do
    case Map.get(update, "rawInput") || Map.get(update, "input") do
      input when is_map(input) -> input
      _ -> %{}
    end
  end

  defp update_text(%{"content" => %{"text" => text}}), do: text
  defp update_text(%{"content" => text}) when is_binary(text), do: text
  defp update_text(_update), do: nil

  defp tool_call_id(update) do
    Map.get(update, "toolCallId") || Map.get(update, "id") || Ecto.UUID.generate()
  end

  defp tool_name(update) do
    Map.get(update, "toolName") || Map.get(update, "title")
  end

  defp tool_name?(name), do: is_binary(name) and String.trim(name) != ""

  defp maybe_put_tool_title(state, tool_call_id, name) do
    if tool_name?(name),
      do: put_in(state.tool_titles[tool_call_id], name),
      else: state
  end

  defp track_file_operation(state, file_operation_id, name, update) do
    previous = Map.get(state.file_operations, file_operation_id, %{})
    operation = Map.get(previous, :operation) || recognized_file_operation(name)

    if is_binary(operation) do
      arguments = tool_arguments(update)
      kind = tool_kind(update)

      metadata =
        previous
        |> Map.put(:operation, operation)
        |> put_present(
          :path,
          Map.get(update, "path") || Map.get(update, :path) ||
            argument_value(arguments, "path")
        )
        |> put_present(
          :query,
          Map.get(update, "query") || Map.get(update, :query) ||
            argument_value(arguments, "query")
        )

      state
      |> maybe_put_tool_title(file_operation_id, operation)
      |> maybe_put_tool_kind(file_operation_id, kind)
      |> update_in([:file_operation_ids], &MapSet.put(&1, file_operation_id))
      |> put_in([:file_operations, file_operation_id], metadata)
    else
      state
    end
  end

  defp recognized_file_operation(name) do
    if file_operation_name?(name), do: name
  end

  defp maybe_put_tool_kind(state, _file_operation_id, nil), do: state

  defp maybe_put_tool_kind(state, file_operation_id, kind) do
    put_in(state.tool_kinds[file_operation_id], kind)
  end

  defp file_operation_call?(state, file_operation_id) do
    MapSet.member?(state.file_operation_ids, file_operation_id)
  end

  defp file_operation_started?(state, file_operation_id) do
    MapSet.member?(state.file_operation_started_ids, file_operation_id)
  end

  defp mark_file_operation_started(state, file_operation_id) do
    update_in(state.file_operation_started_ids, &MapSet.put(&1, file_operation_id))
  end

  defp file_operation_event(type, file_operation_id, status, update, state) do
    metadata = Map.get(state.file_operations, file_operation_id, %{})

    %{
      type: type,
      file_operation_id: file_operation_id,
      tool_call_id: file_operation_id,
      operation: Map.get(metadata, :operation),
      path: Map.get(metadata, :path),
      query: Map.get(metadata, :query),
      kind: tool_kind(update) || Map.get(state.tool_kinds, file_operation_id),
      status: status
    }
  end

  defp file_operation_id(update) do
    Map.get(update, "fileOperationId") || tool_call_id(update)
  end

  defp file_operation_name(update) do
    Map.get(update, "operation") || tool_name(update)
  end

  defp file_operation_status(%{"success" => false}), do: "failed"
  defp file_operation_status(update), do: Map.get(update, "status")

  defp argument_value(arguments, key) do
    Map.get(arguments, key) || Map.get(arguments, String.to_existing_atom(key))
  end

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

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
    update
    |> Map.get("reason")
    |> case do
      reason when is_binary(reason) and reason != "" ->
        reason

      _ ->
        Map.get(update, "error") ||
          extract_content_text(Map.get(update, "content")) ||
          inspect(Map.get(update, "rawOutput") || "")
    end
    |> truncate_file_operation_reason()
  end

  defp truncate_file_operation_reason(reason) when is_binary(reason) do
    if String.length(reason) <= @file_operation_reason_max_chars do
      reason
    else
      String.slice(reason, 0, @file_operation_reason_max_chars) <> "..."
    end
  end

  defp truncate_file_operation_reason(reason), do: inspect(reason)

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

  defp exmcp_adapter_opts(adapter, cwd, opts) when adapter in [Codex, CodexAdapter] do
    [cwd: cwd]
    |> maybe_put(:model, Keyword.get(opts, :model))
    |> maybe_put(:approvalPolicy, codex_approval_policy(Keyword.get(opts, :approval_policy)))
    |> maybe_put(:sandbox, Keyword.get(opts, :sandbox))
    # Ecrits embeds Codex inside a document workspace. It must not inherit or
    # generate personal Codex memories, which would otherwise become hidden
    # authoring guidance for an ACP turn.
    |> Keyword.put(:disable_memories, true)
    # Only Ecrits' per-agent document MCP endpoint can receive unattended
    # write elicitation in full-workspace mode. Shell/file escalations and
    # every other MCP server stay denied by the adapter.
    |> Keyword.put(:auto_approve_mcp_servers, ["doc"])
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

  defp adapter_isolation(adapter, turn, opts) when adapter in [Codex, CodexAdapter] do
    with {:ok, isolation} <-
           CodexHome.prepare(
             sandbox: Keyword.get(opts, :sandbox),
             document_lane?: document_lane?(turn, opts),
             workspace_root: turn[:workspace_root],
             # Key the isolated home by conversation so a restarted session
             # reuses it: codex stores thread rollouts inside CODEX_HOME, and
             # thread/resume only restores memory when they outlive the
             # session process.
             conversation_id: get_in(turn, [:expected_identity, :agent_id])
           ) do
      {:ok,
       %{
         adapter_opts: CodexHome.adapter_opts(isolation),
         cleanup: fn ->
           if Map.get(isolation, :ephemeral?, true), do: CodexHome.cleanup(isolation)
         end
       }}
    end
  end

  defp adapter_isolation(_adapter, _turn, _opts),
    do: {:ok, %{adapter_opts: [], cleanup: fn -> :ok end}}

  defp file_handler_client_opts(client_opts, adapter, turn, opts, cwd)
       when adapter in [Codex, CodexAdapter] do
    read_only? = not acp_write_authorized?(opts)

    # Ask mode is write-capable in intent but gated per-op: the handler needs
    # to distinguish it from Read only so a refused write can tell the agent
    # to request the user's approval in chat rather than presenting a silent
    # read-only wall (board #459 — Ask lanes used to auto-reject with no path
    # forward).
    ask? =
      read_only? and Keyword.get(opts, :sandbox) == "workspace-write" and
        Keyword.get(opts, :approval_policy) in [:on_write, "on_write"]

    client_opts
    |> Keyword.put(:handler, WorkspaceFileHandler)
    |> Keyword.put(
      :handler_opts,
      workspace_root: turn[:workspace_root] || cwd,
      document_path: turn[:document_path],
      session_pid: turn[:session_pid],
      expected_identity: turn[:expected_identity],
      read_only?: read_only?,
      ask?: ask?
    )
    # These describe the handler's protocol surface, not the current user's
    # authority. WorkspaceFileHandler remains the source of truth for explicit
    # Full-workspace authority, active-document ownership, and conditional-write
    # decisions. Ask mode stays read-only until it has a real approval round-trip.
    # Keeping the dynamic tool set stable lets a Codex thread survive access/doc
    # changes.
    |> Keyword.put(
      :capabilities,
      %{"fs" => %{"readTextFile" => true, "writeTextFile" => true}}
    )
  end

  defp file_handler_client_opts(client_opts, _adapter, _turn, _opts, _cwd), do: client_opts

  defp document_lane?(turn, _opts) do
    is_binary(turn[:document_path]) and turn[:document_path] != ""
  end

  # Full-workspace authority arrives in the turn opts as BOTH approval_policy
  # "never" and permission_mode "dontAsk" (AgentConfig.Access). Accept either,
  # so a plumbing drift that loses one field cannot silently downgrade a
  # Full-workspace rail to a write-refusing handler (2026-07-19 take17: turn 1
  # was denied with zero writes while the chip read Full workspace; the
  # follow-up turn on the same rail wrote fine — see board #459). A turn
  # carrying neither signal stays fail-closed read-only.
  @doc false
  def acp_write_authorized?(opts) do
    Keyword.get(opts, :sandbox) == "workspace-write" and
      (Keyword.get(opts, :approval_policy) in [:never, "never"] or
         Keyword.get(opts, :permission_mode) == "dontAsk")
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

  # `Content` encodes a normalized turn; `Prompt` owns every agent-visible
  # instruction. A bare string remains the legacy `preamble <> string` shape,
  # while block input becomes a leading preamble block plus content blocks.
  defp build_prompt(turn, opts) do
    Content.to_acp_content(turn.input, Prompt.acp_preamble(opts))
  end

  defp present_list(list) when is_list(list) and list != [], do: list
  defp present_list(_other), do: nil

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
