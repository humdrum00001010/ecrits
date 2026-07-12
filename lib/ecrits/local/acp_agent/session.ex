defmodule Ecrits.Local.AcpAgent.Session do
  @moduledoc """
  One local chat-agent session, driven directly by `ExMCP.ACP.Client`.

  This is the *sole* chat-agent producer: there is no bespoke provider driver or
  safety-net fallback. The GenServer owns a durable ACP client while turn-launch
  options remain compatible, selecting the concrete ex_mcp ACP adapter per
  provider (`ExMCP.ACP.Adapters.Codex` / `Claude`), translates the agent's
  streamed `session/update` notifications into the normalized chat-rail events,
  and broadcasts them on
  `local_agent:<session_id>` (the contract the workspace LiveView consumes).

  The session passes the `doc.*` MCP server to `new_session(..., mcp_servers:)`
  so the agent (codex AND claude, over ACP) discovers and calls those tools; the
  resulting `tool_call` / `tool_call_update` updates render in the chat-rail
  tool_call block.

  ## Per-turn lifecycle

      ensure ExMCP.ACP.Client -> new_session/load_session(cwd, mcp_servers)
        -> prompt (async, blocking on the client) -> session/update* (streamed)
        -> prompt result (stopReason) -> keep client for compatible next turn

  Cancellation kills the streaming task; the Session also cancels and drops the
  durable client so the next turn resumes from the last provider session id on a
  fresh app-server process. Queued follow-ups are left queued on a normal cancel;
  only `flush_queue/2` promotes a queued turn immediately.

  ## AgentLive boundary (Phase 5)

  This is the concrete **AgentLive** — see `Ecrits.Agent.AgentLive` for the
  extraction-boundary contract (the generic transcript / queue / title / topic
  mechanics this module implements, vs. the ACP-provider-specific turn driver in
  `AcpStream`). A `use Ecrits.Agent.AgentLive` behaviour extraction is
  deliberately deferred to avoid restructuring this GenServer's live `handle_*`
  surface; this module already satisfies that contract function-for-function.
  """

  use GenServer

  alias Ecrits.Context
  alias Ecrits.Local.AcpAgent.AcpStream
  alias Ecrits.Local.AcpAgent.Prompt
  alias ExMCP.ACP.Client

  @registry Ecrits.Local.AcpAgent.SessionRegistry
  @pubsub Ecrits.PubSub

  # Grace window for a cancelled turn's task to wind down its `AcpStream` cleanly
  # (issue the ACP cancel + disconnect the client) before we hard-kill it. The
  # stream's own `safe_disconnect/1` waits up to 2s on `GenServer.stop`, so allow
  # a little more so the graceful path normally wins.
  @cancel_grace_ms 5_000

  # ── public API ────────────────────────────────────────────────────

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def via(id), do: {:via, Registry, {@registry, id}}

  def whereis(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def whereis(_id), do: nil

  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @doc """
  The agent's private doc.* tool context (design invariant 3 — "assigns ARE the
  MCP tool context"). Returns `%{active_doc, agent_id}` read from THIS agent's
  own state, so a `doc.*` call resolved to this agent via its MCP url operates on
  the document THIS agent is bound to (`state.pool_document_id`, the Pool doc id)
  — never a global `Pool.active`. `active_doc` is nil before any document is
  bound.
  """
  @spec tool_context(pid()) :: %{
          active_doc: String.t() | nil,
          agent_id: String.t(),
          workspace_root: String.t() | nil
        }
  def tool_context(pid) when is_pid(pid), do: GenServer.call(pid, :tool_context)

  def send_turn(pid, ctx, input, opts \\ []),
    do: GenServer.call(pid, {:send_turn, ctx, input, opts})

  @doc """
  Re-Enter on a queued message (Phase 5 FIFO queue): cancel the in-flight turn
  and run the queue head NOW instead of waiting for the running turn to finish.
  `{:error, :empty_queue}` when nothing is queued.
  """
  def flush_queue(pid, ctx), do: GenServer.call(pid, {:flush_queue, ctx})

  def cancel(pid, ctx, turn_id \\ nil), do: GenServer.call(pid, {:cancel, ctx, turn_id})

  @doc """
  Display-only snapshot for the workspace Session / chat-rail repaint after a
  browser refresh: `%{transcript, status, title}`. The transcript is the prior
  user/agent text bubbles (oldest-first); status is `:idle`/`:running`; title is
  the derived/renamed chat title. The conversation itself stays provider-owned
  (codex `thread/resume`), so this is purely the visible history + header.
  """
  def agent_snapshot(pid) when is_pid(pid), do: GenServer.call(pid, :agent_snapshot)

  @doc "The current chat title (nil/empty when no first-prompt title yet)."
  def title(pid) when is_pid(pid), do: GenServer.call(pid, :title)

  @doc """
  Persist an agent/provider-generated chat title without marking it as a user edit.

  The caller already received the title event, so this only updates the durable
  snapshot used by rail lists and re-attach.
  """
  def set_generated_title(pid, title) when is_pid(pid) and is_binary(title),
    do: GenServer.call(pid, {:set_generated_title, title})

  @doc """
  Set the chat title explicitly (a user rename). Marks the title user-edited so
  the first-prompt auto-title never overrides it afterwards, and broadcasts a
  `:thread_title` event so every attached LiveView updates its header.
  """
  def rename(pid, title) when is_pid(pid) and is_binary(title),
    do: GenServer.call(pid, {:rename, title})

  @doc """
  Lightweight, display-only transcript of completed turns for repaint after a
  browser refresh. The conversation itself stays provider-owned (codex resumes it
  via `provider_session_id`); this is only the visible prior chat rows so the
  chat pane is not blank on re-attach. A list (oldest first) of
  `%{turn_id, user, agent, items}` where `items` preserves user/tool/agent rows.
  """
  def transcript(pid) when is_pid(pid), do: GenServer.call(pid, :transcript)

  def transcript(id) when is_binary(id) do
    case whereis(id) do
      pid when is_pid(pid) -> transcript(pid)
      nil -> []
    end
  end

  @doc """
  Append a display-only item to the visible transcript without sending it to the
  ACP provider.

  Used for UI-side artifacts such as durable edit-preview cards that are caused
  by a tool/VFS write but are not themselves provider messages.
  """
  def append_transcript_item(pid, item) when is_pid(pid) and is_map(item),
    do: GenServer.call(pid, {:append_transcript_item, item})

  @doc """
  Updates this live session's turn parameters (access/approval mode, reasoning
  effort, same-provider model) WITHOUT recreating the session, so the chat
  conversation is preserved. The merged `adapter_opts` (and `mcp_servers`) are
  picked up by the next turn.

  This is the in-process equivalent of issuing `session/set_mode` /
  `session/set_config_option` on the ACP client: the ACP session + client are
  created fresh per turn (see `AcpStream`), so a "live" change is just the
  stored per-turn options the next turn starts from — which is exactly what the
  Codex/Claude ACP adapters do with those requests ("stored for next turn").
  """
  def update_options(pid, adapter_opts) when is_list(adapter_opts) do
    GenServer.call(pid, {:update_options, adapter_opts})
  end

  def topic(id), do: "local_agent:" <> id

  # ── GenServer ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       owner_id: owner_id(Keyword.get(opts, :ctx)),
       provider: Keyword.get(opts, :provider),
       exmcp_adapter: Keyword.fetch!(opts, :exmcp_adapter),
       adapter_opts: Keyword.get(opts, :adapter_opts, []),
       workspace_root: Keyword.get(opts, :workspace_root),
       # Workspace-relative path of the doc the user is viewing. This is exposed
       # through doc.context so "this document" turns get the handle from MCP
       # state rather than from prompt text.
       document_path: Keyword.get(opts, :document_path),
       # The agent's ACTIVE doc for the doc.* MCP tools: the `Ecrits.Doc.Pool`
       # document id (`d_<kind>_<hash>`) of the doc this agent is bound to.
       # `doc.context` returns THIS (per-agent, not the global `Pool.active`);
       # `doc.open`/`doc.edit` honour ownership against it. The workspace LiveView
       # seeds it on attach; actual sends freeze the current value per turn.
       # nil until a doc is bound.
       pool_document_id: Keyword.get(opts, :pool_document_id),
       mcp_servers: Keyword.get(opts, :mcp_servers, []),
       # The provider's session/thread id, captured on turn 1 and RESUMED on
       # turns 2+ so the conversation keeps cross-turn memory. `nil` until the
       # first turn establishes it.
       provider_session_id: nil,
       acp_client: nil,
       acp_client_key: nil,
       acp_client_ref: nil,
       current: nil,
       # FIFO queue of messages received WHILE a turn was in flight (Phase 5). A
       # mid-turn send ENQUEUES instead of cancelling the running turn; the head
       # drains automatically when the running turn reaches a terminal state. A
       # re-Enter (`flush_queue/2`) on a queued message cancels the current turn
       # and runs the head immediately. Each entry:
       # %{turn_id, input, previous_input}. `previous_input` lets a mid-turn
       # follow-up run as an addendum instead of a standalone newcomer prompt.
       queue: [],
       # Display-only transcript of COMPLETED turns (oldest first), so a browser
       # refresh can repaint the prior bubbles. codex `thread/resume` restores the
       # agent's memory but does NOT re-stream past messages, so without this the
       # re-attached pane is blank. Each entry: %{turn_id, user, agent, items}.
       transcript: [],
       # Codex (unlike the `pi` adapter) never emits a session/thread title over
       # ACP, so a fresh conversation would stay "New Chat" forever. We derive a
       # title from the FIRST turn's prompt and emit it once; this flag gates that.
       title_emitted?: false,
       # The current chat title, RETAINED on the durable agent so a re-attach
       # (browser refresh) can recover it from `agent_snapshot/1` even though
       # codex never re-streams it. `nil` until the first prompt derives one (or a
       # user rename sets it). `title_user_edited?` pins a manual rename so the
       # first-prompt auto-title never clobbers it.
       title: nil,
       title_user_edited?: false
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, public_snapshot(state)}, state}
  end

  def handle_call(:agent_snapshot, _from, state) do
    {:reply, agent_snapshot_payload(state), state}
  end

  def handle_call(:tool_context, _from, state) do
    context = current_tool_context(state)

    {:reply,
     %{
       active_doc: context.pool_document_id,
       agent_id: state.id,
       workspace_root: state.workspace_root,
       # Map.get: tolerate pre-field state maps on hot-reloaded sessions.
       document_path: context.document_path,
       # Access modes map to sandbox: read-only → "read-only"; ask /
       # full-workspace → "workspace-write" (see workspace_live.ex
       # local_agent_access_control/1). So sandbox == "read-only" ⟺ the user
       # put this agent in read-only mode; the doc.* MCP tools (which run
       # server-side and bypass the CLI sandbox) consult this to gate writes.
       read_only: Keyword.get(state.adapter_opts, :sandbox) == "read-only"
     }, state}
  end

  def handle_call(:title, _from, state) do
    {:reply, state.title, state}
  end

  def handle_call({:rename, title}, _from, state) do
    title = String.trim(title)
    state = %{state | title: title, title_user_edited?: true, title_emitted?: true}
    {:reply, :ok, emit(state, %{type: :thread_title, title: title})}
  end

  def handle_call({:set_generated_title, title}, _from, state) do
    title = String.trim(title)

    state =
      if title == "" or Map.get(state, :title_user_edited?, false) do
        state
      else
        %{state | title: title, title_emitted?: true}
      end

    {:reply, :ok, state}
  end

  def handle_call(:transcript, _from, state) do
    {:reply, Enum.reverse(state.transcript), state}
  end

  def handle_call({:append_transcript_item, item}, _from, state) when is_map(item) do
    {:reply, :ok, append_transcript_item_to_state(state, item)}
  end

  def handle_call({:update_options, new_opts}, _from, state) do
    # Access/reasoning/model changes are live defaults for future turns. Document
    # context is turn-scoped: each send carries document_path/pool_document_id
    # from the composer, so document switches cannot retarget an idle or running
    # agent through this live settings path.
    adapter_opts = Keyword.drop(new_opts, [:document_path, :pool_document_id])

    merged = Keyword.merge(state.adapter_opts, adapter_opts)

    {:reply, :ok, %{state | adapter_opts: merged}}
  end

  def handle_call({:send_turn, ctx, raw_input, opts}, _from, state) do
    cond do
      not authorized?(ctx, state) ->
        {:reply, {:error, :forbidden}, state}

      true ->
        # Turn-scoped options: the composer attaches its CURRENT access/model
        # options to every send, so the turn runs with what the UI showed at
        # send time — no dependence on a separate update_options round-trip
        # having landed first (the access-switch desync).
        state = merge_turn_adapter_opts(state, Keyword.get(opts, :adapter_opts))

        # Normalize the input at the boundary (Phase 5 multi-modal seam): a bare
        # string stays a bare string (the byte-for-byte-unchanged legacy path), a
        # block list is validated. A malformed multi-modal send fails fast here.
        case Prompt.normalize(raw_input) do
          {:ok, input} -> start_turn(input, turn_extras(state, opts), ensure_queue(state))
          {:error, reason} -> {:reply, {:error, {:invalid_input, reason}}, state}
        end
    end
  end

  def handle_call({:cancel, ctx, turn_id}, _from, state) do
    cond do
      not authorized?(ctx, state) ->
        {:reply, {:error, :forbidden}, state}

      state.current == nil ->
        {:reply, {:error, :no_current_turn}, state}

      not is_nil(turn_id) and state.current.turn_id != turn_id ->
        {:reply, {:error, :not_found}, state}

      true ->
        # Cancel ONLY the in-flight turn while keeping THIS Session GenServer (and
        # the conversation it anchors) alive. Drop the durable ACP client after
        # interrupting the active turn so the next turn resumes the remembered
        # provider session id through a fresh app-server process instead of sharing
        # a client that may still have a pending prompt call.
        cancelled_turn_id = state.current.turn_id
        cancelled_current = state.current

        if state.current.task_pid do
          send(state.current.task_pid, :acp_cancel_turn)
          Process.send_after(self(), {:force_kill_turn, state.current.task_pid}, @cancel_grace_ms)
        end

        state =
          state
          |> cancel_acp_client_turn()
          |> close_acp_client()
          |> record_transcript_turn(cancelled_current)
          |> emit(%{type: :turn_cancelled, turn_id: cancelled_turn_id})
          |> Map.put(:current, nil)

        {:reply, {:ok, %{id: cancelled_turn_id, session_id: state.id, status: :cancelled}}, state}
    end
  end

  # Re-Enter on a queued message (Phase 5): flush the FIFO head NOW by cancelling
  # the in-flight turn and launching the head immediately, instead of waiting for
  # the running turn to finish. No-op when the queue is empty. When no turn is in
  # flight the head simply launches.
  def handle_call({:flush_queue, ctx}, _from, state) do
    state = ensure_queue(state)

    cond do
      not authorized?(ctx, state) ->
        {:reply, {:error, :forbidden}, state}

      state.queue == [] ->
        {:reply, {:error, :empty_queue}, state}

      true ->
        # Gracefully cancel the in-flight turn (same teardown as a normal cancel)
        # so the conversation can resume, record it, drop the durable client, then
        # drain the queue head on a fresh app-server process.
        state =
          case state.current do
            %{turn_id: cancelled_turn_id} = current ->
              if current.task_pid do
                send(current.task_pid, :acp_cancel_turn)
                Process.send_after(self(), {:force_kill_turn, current.task_pid}, @cancel_grace_ms)
              end

              state
              |> cancel_acp_client_turn()
              |> close_acp_client()
              |> record_transcript_turn(current)
              |> emit(%{type: :turn_cancelled, turn_id: cancelled_turn_id})
              |> Map.put(:current, nil)

            nil ->
              state
          end
          |> drain_queue()

        flushed = state.current && state.current.turn_id
        {:reply, {:ok, %{id: flushed, session_id: state.id, status: :running}}, state}
    end
  end

  defp merge_turn_adapter_opts(state, adapter_opts)
       when is_list(adapter_opts) and adapter_opts != [] do
    %{state | adapter_opts: Keyword.merge(state.adapter_opts, adapter_opts)}
  end

  defp merge_turn_adapter_opts(state, _adapter_opts), do: state

  # Caller-provided display seam: `:display` is what the transcript bubble shows
  # (the typed text) when it differs from the provider input (e.g. the LiveView
  # appends the picked-element JSON block for the agent only); `:picks` are the
  # structured picked-element chips that ride along on the user transcript row.
  defp turn_extras(state, opts) do
    %{
      display: Keyword.get(opts, :display),
      picks: Keyword.get(opts, :picks) || [],
      context: turn_context(state, opts)
    }
  end

  @impl true
  # The durable ACP client is started with this Session as its event listener.
  # Map streaming updates directly in this GenServer. `Client.prompt/4` resolves
  # from a separate JSON-RPC response, so forwarding updates through the turn
  # task can race prompt completion and drop trailing tool/text updates.
  def handle_info({:acp_session_update, _session_id, update}, state) do
    state = forward_acp_stream_activity(state, update)
    {:noreply, handle_acp_session_update(state, update)}
  end

  # The ACP client/provider session id must be captured even if the turn was just
  # cancelled (so the conversation can still resume) — store it regardless of
  # `current`.
  def handle_info({:turn_event, turn_id, %{type: :acp_client_ready} = event}, state) do
    {:noreply, handle_turn_event(state, turn_id, event)}
  end

  def handle_info({:turn_event, turn_id, %{type: :provider_session} = event}, state) do
    {:noreply, handle_turn_event(state, turn_id, event)}
  end

  def handle_info(
        {:turn_event, turn_id, %{type: :text_delta, source: :prompt_result} = event},
        state
      ) do
    send(self(), {:finish_prompt_result_text, turn_id, event})
    {:noreply, state}
  end

  def handle_info({:finish_prompt_result_text, turn_id, event}, state) do
    with %{turn_id: ^turn_id} <- state.current do
      {:noreply, handle_turn_event(state, turn_id, event)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:turn_event, turn_id, event}, state) do
    with %{turn_id: ^turn_id} <- state.current do
      {:noreply, handle_turn_event(state, turn_id, event)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:turn_done, turn_id}, state) do
    send(self(), {:finish_turn_done, turn_id})
    {:noreply, state}
  end

  def handle_info({:finish_turn_done, turn_id}, state) do
    with %{turn_id: ^turn_id} = current <- state.current do
      state =
        state
        |> record_transcript_turn(current)
        |> emit(%{type: :turn_completed, turn_id: turn_id, text: current.text})
        |> Map.put(:current, nil)
        |> drain_queue()

      {:noreply, state}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:turn_failed, turn_id, reason}, state) do
    with %{turn_id: ^turn_id} = current <- state.current do
      state =
        state
        |> close_acp_client()
        |> record_transcript_turn(current)
        |> emit(%{type: :turn_failed, turn_id: turn_id, reason: inspect(reason)})
        |> Map.put(:current, nil)
        |> drain_queue()

      {:noreply, state}
    else
      _ -> {:noreply, state}
    end
  end

  # Bounded fallback for a cancelled turn: if the per-turn task is still alive
  # after the grace window (its `AcpStream` cleanup wedged), hard-kill it so it
  # cannot linger. By now `current` has already been cleared, so this never
  # affects a turn that started after the cancel.
  def handle_info({:force_kill_turn, task_pid}, state) do
    state =
      if is_pid(task_pid) and Process.alive?(task_pid) do
        Process.exit(task_pid, :kill)
        close_acp_client(state)
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current: %{task_ref: ref, turn_id: turn_id} = current} = state
      )
      when reason not in [:normal, :killed] do
    state =
      state
      |> record_transcript_turn(current)
      |> emit(%{type: :turn_failed, turn_id: turn_id, reason: inspect(reason)})
      |> Map.put(:current, nil)
      |> drain_queue()

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    state = ensure_acp_client_fields(state)

    if state.acp_client_ref == ref and state.acp_client == pid do
      {:noreply, clear_acp_client(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = close_acp_client(state)
    :ok
  end

  # Pop the FIFO queue head (if any) and launch it as the next turn. Called on
  # automatic terminal paths (done/failed/crash) and explicit flush, so a normal
  # user cancel can stop the current chat without sending queued follow-ups.
  # Callers clear `current` to nil before draining, so the head launches into an
  # idle session.
  defp drain_queue(%{current: nil, queue: [next | rest]} = state) do
    {:ok, _turn_id, state} =
      launch_turn(
        queued_provider_input(next),
        %{state | queue: rest},
        next.turn_id,
        Map.get(next, :display) || next.input,
        Map.get(next, :picks, []),
        Map.get(next, :context)
      )

    state
  end

  defp drain_queue(state), do: state

  # ── send-turn helpers (FIFO queue) ─────────────────────────────────

  # Backfill the Phase 5 `:queue` key onto a Session GenServer hot-reloaded from
  # before this phase (the live :4000 server recompiles in place, not restarts),
  # so the first send into an upgraded process never crashes on a missing key.
  defp ensure_queue(state), do: Map.put_new(state, :queue, [])

  defp start_turn(input, extras, %{current: current} = state) when current != nil do
    enqueue_turn(state, input, extras)
  end

  defp start_turn(input, extras, %{current: nil, queue: [_ | _]} = state) do
    enqueue_turn(state, input, extras)
  end

  defp start_turn(input, extras, state) do
    {:ok, turn_id, state} =
      launch_turn(
        input,
        state,
        Ecto.UUID.generate(),
        extras.display,
        extras.picks,
        extras.context
      )

    {:reply, {:ok, %{id: turn_id, session_id: state.id, status: :running}}, state}
  end

  defp enqueue_turn(state, input, extras) do
    # A turn is already in flight — ENQUEUE rather than cancel (Phase 5 FIFO
    # queue). If the active turn was stopped, preserve order by appending behind
    # the still-pending queue instead of launching ahead of it.
    queued = %{
      turn_id: Ecto.UUID.generate(),
      input: input,
      display: extras.display,
      picks: extras.picks,
      context: extras.context,
      previous_input: queue_previous_input(state)
    }

    state = %{state | queue: state.queue ++ [queued]}

    state =
      emit(
        state,
        queued_turn_payload(queued)
        |> Map.merge(%{type: :turn_queued, pending: length(state.queue)})
      )

    {:reply, {:ok, %{id: queued.turn_id, session_id: state.id, status: :queued}}, state}
  end

  # Spawn the per-turn streaming task and record it as the current turn. Shared by
  # a fresh send and by draining the FIFO queue on a turn terminal.
  defp launch_turn(input, state, turn_id, display_input, picks, context) do
    display_input = display_input || input
    parent = self()

    state =
      state
      |> apply_turn_context(context)
      |> ensure_acp_client_fields()

    client_key = acp_client_key(state)
    state = maybe_drop_incompatible_acp_client(state, client_key)

    task =
      Task.async(fn ->
        run_turn(parent, turn_id, input, state, client_key)
      end)

    Process.unlink(task.pid)

    state = %{
      state
      | current: %{
          turn_id: turn_id,
          task_ref: task.ref,
          task_pid: task.pid,
          text: "",
          pending_text: "",
          text_segment: 0,
          acp_update_state: AcpStream.update_state(),
          items: [],
          input: display_input,
          provider_input: input,
          picks: picks,
          context: turn_context(state, [])
        }
    }

    state =
      emit(state, %{type: :turn_started, turn_id: turn_id, input: display_input, picks: picks})

    state = maybe_emit_thread_title(state, display_input)

    {:ok, turn_id, state}
  end

  defp queue_previous_input(%{queue: queue, current: current}) do
    case List.last(queue) do
      %{input: input} -> input
      _ -> current.input
    end
  end

  defp queued_provider_input(%{input: input, previous_input: previous_input}) do
    previous = previous_input |> Prompt.display_text() |> String.trim()
    addendum = input |> Prompt.display_text() |> String.trim()

    if previous == "" or addendum == "" do
      input
    else
      continuation_text(previous, addendum, input)
    end
  end

  defp continuation_text(previous, addendum, input) when is_binary(input) do
    "Continue previous task.\nPrevious: #{previous}\nAddendum: #{addendum}"
  end

  defp continuation_text(previous, addendum, input) when is_list(input) do
    [%{type: :text, text: continuation_text(previous, addendum, "")} | input]
  end

  defp handle_acp_session_update(%{current: %{turn_id: turn_id} = current} = state, update) do
    acp_update_state = Map.get(current, :acp_update_state, AcpStream.update_state())

    case AcpStream.map_session_update(update, acp_update_state) do
      {:event, event, acp_update_state} ->
        state
        |> put_current_acp_update_state(acp_update_state)
        |> handle_turn_event(turn_id, event)

      {:skip, acp_update_state} ->
        put_current_acp_update_state(state, acp_update_state)

      {:error, message, acp_update_state} ->
        state = put_current_acp_update_state(state, acp_update_state)
        send(self(), {:turn_failed, turn_id, {:acp_error, message}})
        state
    end
  end

  defp handle_acp_session_update(state, _update), do: state

  defp forward_acp_stream_activity(%{current: %{task_pid: task_pid}} = state, update)
       when is_pid(task_pid) do
    send(task_pid, {:acp_stream_activity, update})
    state
  end

  defp forward_acp_stream_activity(state, _update), do: state

  defp put_current_acp_update_state(%{current: current} = state, acp_update_state)
       when is_map(current) do
    %{state | current: Map.put(current, :acp_update_state, acp_update_state)}
  end

  # ── durable ACP client ────────────────────────────────────────────────

  defp acp_turn_opts(state) do
    Keyword.put(state.adapter_opts, :mcp_servers, state.mcp_servers)
  end

  defp maybe_put_reusable_client(opts, state) do
    state = ensure_acp_client_fields(state)

    if is_pid(state.acp_client) and Process.alive?(state.acp_client) and
         is_binary(state.provider_session_id) and state.provider_session_id != "" do
      opts
      |> Keyword.put(:client, state.acp_client)
      |> Keyword.put(:session_id, state.provider_session_id)
    else
      opts
    end
  end

  defp ensure_acp_client_fields(state) do
    state
    |> Map.put_new(:acp_client, nil)
    |> Map.put_new(:acp_client_key, nil)
    |> Map.put_new(:acp_client_ref, nil)
  end

  defp maybe_drop_incompatible_acp_client(state, client_key) do
    state = ensure_acp_client_fields(state)
    client = state.acp_client

    cond do
      not is_pid(client) ->
        clear_acp_client(state)

      not Process.alive?(client) ->
        clear_acp_client(state)

      state.acp_client_key != client_key ->
        close_acp_client(state)

      not (is_binary(state.provider_session_id) and state.provider_session_id != "") ->
        close_acp_client(state)

      true ->
        state
    end
  end

  defp acp_client_key(state) do
    {
      state.exmcp_adapter,
      normalize_keyword(state.adapter_opts),
      state.mcp_servers
    }
  end

  defp normalize_keyword(opts) when is_list(opts) do
    Enum.sort_by(opts, fn {key, _value} -> to_string(key) end)
  end

  defp normalize_keyword(_opts), do: []

  defp cancel_acp_client_turn(state) do
    state = ensure_acp_client_fields(state)

    if is_pid(state.acp_client) and is_binary(state.provider_session_id) and
         state.provider_session_id != "" do
      Client.cancel(state.acp_client, state.provider_session_id)
    end

    state
  catch
    _, _ -> state
  end

  defp close_acp_client(state) do
    state = ensure_acp_client_fields(state)

    if is_pid(state.acp_client) and Process.alive?(state.acp_client) do
      GenServer.stop(state.acp_client, :normal, 2_000)
    end

    clear_acp_client(state)
  catch
    _, _ -> clear_acp_client(state)
  end

  defp clear_acp_client(state) do
    state = ensure_acp_client_fields(state)

    if is_reference(state.acp_client_ref) do
      Process.demonitor(state.acp_client_ref, [:flush])
    end

    %{state | acp_client: nil, acp_client_key: nil, acp_client_ref: nil}
  end

  # ── turn streaming (in a Task) ─────────────────────────────────────

  defp run_turn(parent, turn_id, input, state, client_key) do
    stream =
      AcpStream.turn_stream(
        state.exmcp_adapter,
        %{
          input: input,
          workspace_root: state.workspace_root,
          # Resume the conversation's provider session on turns 2+ (nil on turn 1)
          # so the agent keeps cross-turn memory.
          provider_session_id: state.provider_session_id
        },
        state
        |> acp_turn_opts()
        |> Keyword.put(:persist_client?, true)
        |> Keyword.put(:event_listener, parent)
        |> Keyword.put(:acp_client_key, client_key)
        |> maybe_put_reusable_client(state)
      )

    Enum.each(stream, fn event -> send(parent, {:turn_event, turn_id, event}) end)
    send(parent, {:turn_done, turn_id})
  rescue
    e -> send(parent, {:turn_failed, turn_id, {:exception, Exception.message(e)}})
  end

  # ── event mapping -> chat-rail events ──────────────────────────────

  # The provider session/thread id for this conversation (emitted first by
  # `AcpStream`). Persist it on the long-lived Session so the NEXT turn resumes
  # the same provider session — this is what gives the agent cross-turn memory.
  # Not broadcast to the chat-rail (internal plumbing only).
  defp handle_turn_event(
         state,
         _turn_id,
         %{
           type: :acp_client_ready,
           client: client,
           provider_session_id: id,
           acp_client_key: client_key
         }
       )
       when is_pid(client) and is_binary(id) and id != "" do
    state = ensure_acp_client_fields(state)

    state =
      if is_pid(state.acp_client) and state.acp_client != client do
        close_acp_client(state)
      else
        state
      end

    ref = Process.monitor(client)

    %{
      state
      | acp_client: client,
        acp_client_key: client_key,
        acp_client_ref: ref,
        provider_session_id: id
    }
  end

  defp handle_turn_event(state, _turn_id, %{type: :provider_session, provider_session_id: id})
       when is_binary(id) and id != "" do
    %{state | provider_session_id: id}
  end

  defp handle_turn_event(
         state,
         turn_id,
         %{type: :text_delta, delta: delta, source: :prompt_result}
       )
       when is_binary(delta) do
    if Map.get(state.current, :acp_update_state, AcpStream.update_state()).saw_text? do
      state
    else
      append_text_delta(state, turn_id, delta)
    end
  end

  defp handle_turn_event(state, turn_id, %{type: :text_delta, delta: delta})
       when is_binary(delta) do
    append_text_delta(state, turn_id, delta)
  end

  defp handle_turn_event(state, turn_id, %{type: :reasoning_delta, delta: delta})
       when is_binary(delta) do
    emit(state, %{type: :reasoning_delta, turn_id: turn_id, delta: delta})
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_started} = event) do
    current =
      state.current
      |> flush_pending_text_item()
      |> put_tool_item(
        event.tool_call_id,
        event.name,
        :running,
        tool_payload(event.name, Map.get(event, :arguments, %{}))
      )

    emit(state, %{
      type: :tool_call_started,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      arguments: Map.get(event, :arguments, %{})
    })
    |> Map.put(:current, current)
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_completed} = event) do
    current =
      put_tool_item(
        state.current,
        event.tool_call_id,
        event.name,
        :completed,
        tool_payload(event.name, Map.get(event, :result, %{}))
      )

    emit(state, %{
      type: :tool_call_completed,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      result: Map.get(event, :result, %{})
    })
    |> Map.put(:current, current)
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_failed} = event) do
    current =
      put_tool_item(
        state.current,
        event.tool_call_id,
        event.name,
        :failed,
        Map.get(event, :reason, "")
      )

    emit(state, %{
      type: :tool_call_failed,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      reason: Map.get(event, :reason, "")
    })
    |> Map.put(:current, current)
  end

  defp handle_turn_event(state, _turn_id, _event), do: state

  defp append_text_delta(state, turn_id, delta) do
    current =
      state.current
      |> Map.update(:text, delta, &((&1 || "") <> delta))
      |> Map.update(:pending_text, delta, &((&1 || "") <> delta))

    state
    |> Map.put(:current, current)
    |> emit(%{type: :text_delta, turn_id: turn_id, delta: delta})
  end

  # ── helpers ────────────────────────────────────────────────────────

  # Append a finished turn to the display-only transcript (newest-prepended;
  # `transcript/1` reverses to oldest-first). Skips an empty turn (no user text
  # and no agent text) so a no-op turn never leaves a blank pair on repaint.
  defp record_transcript_turn(state, current) do
    # The transcript bubble shows the typed text regardless of input modality
    # (string sugar OR a multi-modal block list), so derive the display text.
    user = Prompt.display_text(current[:input])
    agent = current[:text]

    items = transcript_items(current, user, agent)

    if blank?(user) and blank?(agent) and items == [] do
      state
    else
      entry = %{turn_id: current.turn_id, user: user, agent: agent, items: items}
      %{state | transcript: [entry | state.transcript]}
    end
  end

  defp transcript_items(current, user, agent) do
    current = flush_pending_text_item(current)
    items = Map.get(current, :items, [])
    # Map.get: a session hot-reloaded mid-turn may hold a pre-picks current map.
    picks = Map.get(current, :picks, [])

    pending =
      if items == [] do
        agent
      else
        ""
      end

    []
    |> maybe_append_user_item(user, picks)
    |> Kernel.++(items)
    |> maybe_append_agent_item(pending, 0)
  end

  # A picks-only send has a blank typed text but must still keep its user row —
  # the chips ARE the message.
  defp maybe_append_user_item(items, user, picks) do
    cond do
      not blank?(user) and picks != [] -> items ++ [%{role: :user, body: user, picks: picks}]
      not blank?(user) -> items ++ [%{role: :user, body: user}]
      picks != [] -> items ++ [%{role: :user, body: "", picks: picks}]
      true -> items
    end
  end

  defp flush_pending_text_item(current) when is_map(current) do
    pending = Map.get(current, :pending_text, "")

    if blank?(pending) do
      current
    else
      segment = Map.get(current, :text_segment, 0)
      items = maybe_append_agent_item(Map.get(current, :items, []), pending, segment)

      current
      |> Map.put(:items, items)
      |> Map.put(:pending_text, "")
      |> Map.put(:text_segment, segment + 1)
    end
  end

  defp maybe_append_agent_item(items, text, segment) do
    if blank?(text) do
      items
    else
      items ++ [%{role: :agent, body: text, status: :sent, segment: segment}]
    end
  end

  defp append_transcript_item_to_state(%{current: %{items: items} = current} = state, item)
       when is_list(items) do
    %{state | current: Map.put(current, :items, items ++ [item])}
  end

  defp append_transcript_item_to_state(%{transcript: [latest | rest]} = state, item) do
    items = Map.get(latest, :items, []) ++ [item]
    %{state | transcript: [Map.put(latest, :items, items) | rest]}
  end

  defp append_transcript_item_to_state(state, item) do
    turn_id =
      item[:turn_id] || item["turn_id"] ||
        "display-#{System.unique_integer([:positive, :monotonic])}"

    entry = %{turn_id: turn_id, user: "", agent: "", items: [item]}
    %{state | transcript: [entry | state.transcript]}
  end

  defp put_tool_item(current, tool_call_id, name, status, body) when is_map(current) do
    tool_call_id =
      tool_call_id || "tool-" <> Integer.to_string(System.unique_integer([:positive]))

    previous =
      current
      |> Map.get(:items, [])
      |> Enum.find(&(Map.get(&1, :tool_call_id) == tool_call_id))

    {input, output, details} = tool_item_payloads(status, body, previous)

    item = %{
      role: :tool,
      tool_call_id: tool_call_id,
      name: name || "tool",
      status: status,
      input: input,
      output: output,
      body: details
    }

    items = Map.get(current, :items, [])

    items =
      if Enum.any?(items, &(Map.get(&1, :tool_call_id) == tool_call_id)) do
        Enum.map(items, fn
          %{tool_call_id: ^tool_call_id} -> item
          other -> other
        end)
      else
        items ++ [item]
      end

    Map.put(current, :items, items)
  end

  defp tool_payload(name, payload) do
    Ecrits.Doc.ToolPayloadSanitizer.encode_tool_payload(name, payload)
  end

  defp tool_item_payloads(status, body, previous) do
    body = body || ""

    case status do
      :running ->
        {body, nil, tool_io_body(body, nil)}

      :approval_required ->
        {body, nil, tool_io_body(body, nil)}

      :completed ->
        input = previous && Map.get(previous, :input)
        {input, body, tool_io_body(input, body)}

      :failed ->
        input = previous && Map.get(previous, :input)
        {input, body, tool_io_body(input, body)}

      _other ->
        {nil, body, body}
    end
  end

  defp tool_io_body(input, output) do
    parts =
      []
      |> maybe_tool_io_part("Input", input)
      |> maybe_tool_io_part("Output", output)

    case parts do
      [] -> ""
      _ -> Enum.join(parts, "\n\n")
    end
  end

  defp maybe_tool_io_part(parts, _label, nil), do: parts
  defp maybe_tool_io_part(parts, _label, ""), do: parts
  defp maybe_tool_io_part(parts, label, body), do: parts ++ ["#{label}:\n#{body}"]

  defp turn_context(state, opts) do
    %{
      document_path: turn_context_value(state, opts, :document_path),
      pool_document_id: turn_context_value(state, opts, :pool_document_id)
    }
  end

  defp turn_context_value(state, opts, key) do
    if is_list(opts) and Keyword.has_key?(opts, key) do
      Keyword.get(opts, key)
    else
      Map.get(state, key)
    end
  end

  defp apply_turn_context(state, nil), do: state

  defp apply_turn_context(state, %{
         document_path: document_path,
         pool_document_id: pool_document_id
       }) do
    state
    |> Map.put(:document_path, document_path)
    |> Map.put(:pool_document_id, pool_document_id)
  end

  defp current_tool_context(%{
         current: %{
           context:
             %{document_path: _document_path, pool_document_id: _pool_document_id} = context
         }
       }),
       do: context

  defp current_tool_context(state), do: turn_context(state, [])

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_), do: false

  defp public_snapshot(state) do
    %{
      id: state.id,
      owner_id: state.owner_id,
      provider: state.provider,
      workspace_root: state.workspace_root,
      # Last seeded/launched document path. In-flight tools use current.context;
      # Map.get tolerates pre-field hot-reload.
      document_path: Map.get(state, :document_path),
      current_turn: state.current && %{id: state.current.turn_id, status: :running}
    }
  end

  # Display-only snapshot for chat-rail repaint after a refresh.
  defp agent_snapshot_payload(state) do
    %{
      transcript: Enum.reverse(state.transcript),
      status: status(state),
      title: state.title,
      title_user_edited?: Map.get(state, :title_user_edited?, false),
      # Number of mid-turn sends still queued (Phase 5), so a refresh can repaint
      # the "N 대기" pending state.
      pending: length(state.queue),
      queued: Enum.map(state.queue, &queued_turn_payload/1),
      current_turn: state.current && %{id: state.current.turn_id, status: :running},
      # Stored adapter_opts so the LiveView can hydrate reasoning/access from
      # session on re-attach (instead of reading stale URL params).
      adapter_opts: state.adapter_opts
    }
  end

  defp status(%{current: nil}), do: :idle
  defp status(_state), do: :running

  defp queued_turn_payload(queued) do
    %{
      turn_id: queued.turn_id,
      input: queued_display_input(queued),
      picks: Map.get(queued, :picks, [])
    }
  end

  defp queued_display_input(%{display: display}) when is_binary(display), do: display

  defp queued_display_input(%{input: input}), do: Prompt.display_text(input)

  defp emit(state, event) do
    event =
      event
      |> Map.put(:session_id, state.id)
      |> Map.put(
        :at,
        DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
      )

    Phoenix.PubSub.broadcast(@pubsub, topic(state.id), {:local_agent_event, event})
    state
  end

  # Auto-title a fresh conversation from its first user message. Codex does not
  # emit a session/thread title over ACP (only the `pi` adapter does via
  # session_info_update), so without this a `New Chat` stays untitled. We emit a
  # `:thread_title` event ONCE, on the first turn; the LiveView applies it unless
  # the user has manually renamed the thread (local_agent_title_user_edited?).
  defp maybe_emit_thread_title(%{title_emitted?: true} = state, _input), do: state

  defp maybe_emit_thread_title(state, input) do
    # Derive from the display text so a multi-modal turn titles from its typed
    # text; a bare-string input passes through `display_text/1` unchanged.
    case derive_title(Prompt.display_text(input)) do
      title when is_binary(title) and title != "" ->
        # RETAIN the title on the durable agent (so a re-attach recovers it) AND
        # emit it once so attached LiveViews update their header.
        emit(%{state | title_emitted?: true, title: title}, %{type: :thread_title, title: title})

      _ ->
        %{state | title_emitted?: true}
    end
  end

  @title_max_chars 48

  # First non-empty line of the prompt, whitespace-collapsed and length-capped.
  defp derive_title(input) when is_binary(input) do
    input
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate_title()
  end

  defp derive_title(_input), do: ""

  defp truncate_title(""), do: ""

  defp truncate_title(text) do
    if String.length(text) > @title_max_chars do
      (text |> String.slice(0, @title_max_chars) |> String.trim_trailing()) <> "…"
    else
      text
    end
  end

  defp authorized?(ctx, %{owner_id: nil}), do: is_nil(owner_id(ctx))
  defp authorized?(ctx, %{owner_id: owner_id}), do: owner_id(ctx) == owner_id

  defp owner_id(%Context{user: %{id: id}}) when is_binary(id), do: id
  defp owner_id(_ctx), do: nil
end
