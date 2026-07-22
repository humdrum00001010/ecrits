defmodule Ecrits.AcpAgent.Session do
  @moduledoc """
  One local chat-agent session, driven directly by `ExMCP.ACP.Client`.

  This is the *sole* chat-agent producer: there is no bespoke provider driver or
  safety-net fallback. The GenServer owns a durable ACP client while turn-launch
  options remain compatible, selecting the concrete ex_mcp ACP adapter per
  provider (`ExMCP.ACP.Adapters.Codex` / `Claude`), translates the agent's
  streamed `session/update` notifications into the normalized chat-rail events,
  and broadcasts them on
  `agent:<session_id>` (the contract the workspace LiveView consumes).

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

  ## Session contract

  This is the concrete `Ecrits.Agent.SessionContract` implementation: generic
  transcript / queue / title / topic mechanics live here, while `AcpStream`
  owns the ACP-provider-specific turn driver. It is not a Phoenix LiveView.
  """

  use GenServer

  @behaviour Ecrits.Agent.SessionContract

  alias Ecrits.Agent
  alias Ecrits.Agent.DurableState
  alias Ecrits.Context
  alias Ecrits.AcpAgent.AcpStream
  alias Ecrits.AcpAgent.Content
  alias ExMCP.ACP.Client

  @registry Ecrits.AcpAgent.SessionRegistry
  @pubsub Ecrits.PubSub

  # Grace window for a cancelled turn's task to wind down its `AcpStream` cleanly
  # (issue the ACP cancel + disconnect the client) before we hard-kill it. The
  # stream's own `safe_disconnect/1` waits up to 2s on `GenServer.stop`, so allow
  # a little more so the graceful path normally wins.
  @cancel_grace_ms 5_000
  @edit_preview_max 5_000
  @dangling_file_operation_reason "Turn ended before the file operation finished."
  @persisted_adapter_opt_keys [
    :model,
    :reasoning_effort,
    :sandbox,
    :permission_mode,
    :approval_policy,
    :access_control
  ]

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
          instance_id: String.t(),
          workspace_root: String.t() | nil,
          turn_id: String.t() | nil
        }
  def tool_context(pid) when is_pid(pid), do: GenServer.call(pid, :tool_context)

  @doc "Fetch this live turn's durable mounted-document tool sequence."
  @spec doc_vfs_sequence(pid(), String.t()) :: {:ok, map() | nil} | {:error, :turn_mismatch}
  def doc_vfs_sequence(pid, turn_id) when is_pid(pid) and is_binary(turn_id),
    do: GenServer.call(pid, {:doc_vfs_sequence, turn_id})

  @doc "Replace this live turn's durable mounted-document tool sequence."
  @spec put_doc_vfs_sequence(pid(), String.t(), map()) :: :ok | {:error, :turn_mismatch}
  def put_doc_vfs_sequence(pid, turn_id, sequence)
      when is_pid(pid) and is_binary(turn_id) and is_map(sequence),
      do: GenServer.call(pid, {:put_doc_vfs_sequence, turn_id, sequence})

  @impl true
  def send_turn(pid, ctx, input, opts \\ []),
    do: GenServer.call(pid, {:send_turn, ctx, input, opts})

  @doc """
  Re-Enter on a queued message (Phase 5 FIFO queue): cancel the in-flight turn
  and promote the queue head after that turn's workspace finalization ack.
  `{:error, :empty_queue}` when nothing is queued.
  """
  @impl true
  def flush_queue(pid, ctx) do
    with_current_turn_lock(pid, fn _turn_id -> GenServer.call(pid, {:flush_queue, ctx}) end)
  end

  @impl true
  def cancel(pid, ctx, turn_id \\ nil) do
    with_requested_turn_lock(pid, turn_id, fn locked_turn_id ->
      requested_turn_id = locked_turn_id || :no_current_turn
      GenServer.call(pid, {:cancel, ctx, requested_turn_id})
    end)
  end

  @doc false
  def prepare_restart(pid, workspace_root) when is_pid(pid) and is_binary(workspace_root) do
    with_current_turn_lock(pid, fn _turn_id ->
      GenServer.call(pid, {:prepare_restart, workspace_root})
    end)
  end

  @doc false
  def with_turn_commit(pid, identity, fun)
      when is_pid(pid) and is_map(identity) and is_function(fun, 0) do
    case Map.get(identity, :turn_id) do
      turn_id when is_binary(turn_id) and turn_id != "" ->
        :global.trans(turn_commit_lock(pid, turn_id), fn ->
          if current_turn_identity?(pid, identity), do: fun.(), else: {:error, :turn_invalidated}
        end)

      _missing ->
        {:error, :incomplete_turn_identity}
    end
  end

  @doc false
  def reconcile_workspace(pid, workspace_root) when is_pid(pid) and is_binary(workspace_root),
    do: GenServer.call(pid, {:reconcile_workspace, workspace_root})

  @doc """
  Display-only snapshot for the workspace Session / chat-rail repaint after a
  browser refresh: `%{transcript, status, title}`. The transcript is the prior
  user/agent text bubbles (oldest-first); status is `:idle`/`:running`; title is
  the derived/renamed chat title. The conversation itself stays provider-owned
  (codex `thread/resume`), so this is purely the visible history + header.
  """
  @impl true
  def agent_snapshot(pid) when is_pid(pid), do: GenServer.call(pid, :agent_snapshot)

  @doc false
  @spec durable_snapshot(pid()) :: map()
  def durable_snapshot(pid) when is_pid(pid), do: GenServer.call(pid, :durable_snapshot)

  @doc "The current chat title (nil/empty when no first-prompt title yet)."
  @impl true
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
  @impl true
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

  @impl true
  def topic(id), do: "agent:" <> id

  # ── GenServer ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    id = Keyword.fetch!(opts, :id)
    restored = cast_durable_restore(Keyword.get(opts, :durable_restore), id)
    adapter_opts = merge_restored_adapter_opts(Keyword.get(opts, :adapter_opts, []), restored)
    transcript = restored_transcript(restored)
    title = Map.get(restored, :title)

    {:ok,
     %{
       id: id,
       # A durable agent id survives provider restarts, but this GenServer does
       # not. Every emitted event carries this immutable process incarnation so
       # attached rails can reject delayed events from the process it replaced.
       instance_id: Ecto.UUID.generate(),
       # One process-owned cursor orders every PubSub event against snapshots.
       # A joining rail can replay the snapshot and discard already-covered
       # queued events without guessing from timestamps or event contents.
       event_seq: 0,
       owner_id: owner_id(Keyword.get(opts, :ctx)),
       provider: Keyword.get(opts, :provider),
       exmcp_adapter: Keyword.fetch!(opts, :exmcp_adapter),
       adapter_opts: adapter_opts,
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
       provider_session_id: Map.get(restored, :provider_session_id),
       # Chronological transcript rows the CURRENT provider thread has never
       # seen (it was created mid-conversation or the old thread was lost).
       # While > 0 the next prompt carries a one-time bounded recap of those
       # rows so cross-turn references keep working after a thread change.
       thread_covers_from: Map.get(restored, :thread_covers_from) || 0,
       acp_client: nil,
       acp_client_key: nil,
       acp_client_ref: nil,
       current: nil,
       # Explicit cancellation is a two-stage terminal path. The cancelled
       # turn's task must be observed dead before workspace finalization can
       # begin, otherwise its late cleanup can race the next turn's edits. The
       # fence retains the exact task monitor and requested post-finalization
       # queue mode until that DOWN arrives.
       cancellation_fence: nil,
       # A terminal turn is not fully closed until the workspace coordinator
       # acknowledges the exact {agent, process instance, turn} finalization.
       # While this barrier is present every new send remains in the FIFO.
       terminal_finalization: nil,
       # Natural completion/failure cannot mutate `current` from this GenServer
       # while a document commit owns the per-turn global lock: the commit may
       # call back into `tool_context/1`, which would deadlock if this process
       # waited for that lock. A short-lived external owner acquires the lock,
       # asks this process to apply the terminal state, releases it, and only
       # then permits workspace finalization / FIFO advancement.
       terminal_transition: nil,
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
       transcript: Enum.reverse(transcript),
       # Codex (unlike the `pi` adapter) never emits a session/thread title over
       # ACP, so a fresh conversation would stay "New Chat" forever. We derive a
       # title from the FIRST turn's prompt and emit it once; this flag gates that.
       title_emitted?: transcript != [] or not blank?(title),
       # The current chat title, RETAINED on the durable agent so a re-attach
       # (browser refresh) can recover it from `agent_snapshot/1` even though
       # codex never re-streams it. `nil` until the first prompt derives one (or a
       # user rename sets it). `title_user_edited?` pins a manual rename so the
       # first-prompt auto-title never clobbers it.
       title: title,
       title_user_edited?: Map.get(restored, :title_user_edited?, false)
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = state |> ensure_instance_id() |> ensure_event_seq()
    {:reply, {:ok, public_snapshot(state)}, state}
  end

  def handle_call(:agent_snapshot, _from, state) do
    state = state |> ensure_instance_id() |> ensure_event_seq() |> normalize_transcript()
    {:reply, agent_snapshot_payload(state), state}
  end

  def handle_call(:durable_snapshot, _from, state) do
    state = normalize_transcript(state)
    {:reply, durable_snapshot_payload(state), state}
  end

  def handle_call(:tool_context, _from, state) do
    state = ensure_instance_id(state)
    context = current_tool_context(state)

    {:reply,
     %{
       active_doc: context.pool_document_id,
       agent_id: state.id,
       instance_id: state.instance_id,
       workspace_root: state.workspace_root,
       # Map.get: tolerate pre-field state maps on hot-reloaded sessions.
       document_path: context.document_path,
       turn_id: state.current && state.current.turn_id,
       # Access modes map to sandbox: read-only → "read-only"; ask /
       # full-workspace → "workspace-write" (see workspace_live.ex
       # agent_access_control/1). So sandbox == "read-only" ⟺ the user
       # put this agent in read-only mode; the doc.* MCP tools (which run
       # server-side and bypass the CLI sandbox) consult this to gate writes.
       read_only: Keyword.get(state.adapter_opts, :sandbox) == "read-only"
     }, state}
  end

  def handle_call(:turn_lock_id, _from, state) do
    state = ensure_terminal_transition(state)

    turn_id =
      case state.current do
        %{turn_id: turn_id} -> turn_id
        nil -> state.terminal_transition && state.terminal_transition.turn_id
      end

    {:reply, turn_id, state}
  end

  def handle_call({:doc_vfs_sequence, turn_id}, _from, state) do
    case state.current do
      %{turn_id: ^turn_id} = current ->
        {:reply, {:ok, Map.get(current, :doc_vfs_sequence)}, state}

      _other ->
        {:reply, {:error, :turn_mismatch}, state}
    end
  end

  def handle_call({:put_doc_vfs_sequence, turn_id, sequence}, _from, state) do
    case state.current do
      %{turn_id: ^turn_id} = current ->
        {:reply, :ok, %{state | current: Map.put(current, :doc_vfs_sequence, sequence)}}

      _other ->
        {:reply, {:error, :turn_mismatch}, state}
    end
  end

  def handle_call(:title, _from, state) do
    {:reply, state.title, state}
  end

  def handle_call({:rename, title}, _from, state) do
    title = String.trim(title)
    state = %{state | title: title, title_user_edited?: true, title_emitted?: true}
    state = state |> emit(%{type: :thread_title, title: title}) |> persist_durable_state()
    {:reply, :ok, state}
  end

  def handle_call({:set_generated_title, title}, _from, state) do
    title = String.trim(title)

    state =
      if title == "" or Map.get(state, :title_user_edited?, false) do
        state
      else
        %{state | title: title, title_emitted?: true}
      end

    {:reply, :ok, persist_durable_state(state)}
  end

  def handle_call(:transcript, _from, state) do
    state = normalize_transcript(state)
    {:reply, Enum.reverse(state.transcript), state}
  end

  def handle_call({:append_transcript_item, item}, _from, state) when is_map(item) do
    state = state |> append_transcript_item_to_state(item) |> persist_durable_state_async()
    {:reply, :ok, state}
  end

  def handle_call({:update_options, new_opts}, _from, state) do
    # Access/reasoning/model changes are live defaults for future turns. Document
    # context is turn-scoped: each send carries document_path/pool_document_id
    # from the composer, so document switches cannot retarget an idle or running
    # agent through this live settings path.
    adapter_opts = Keyword.drop(new_opts, [:document_path, :pool_document_id])

    merged = Keyword.merge(state.adapter_opts, adapter_opts)

    {:reply, :ok, persist_durable_state(%{state | adapter_opts: merged})}
  end

  def handle_call({:send_turn, ctx, raw_input, opts}, from, state) do
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
        case Content.normalize(raw_input) do
          {:ok, input} ->
            state =
              state
              |> ensure_queue()
              |> ensure_cancellation_fence()
              |> ensure_terminal_finalization()
              |> ensure_terminal_transition()

            extras =
              state
              |> turn_extras(opts)
              |> Map.put(
                :workspace_registration_mode,
                workspace_registration_mode(state, from, opts)
              )

            start_turn(input, extras, state)

          {:error, reason} ->
            {:reply, {:error, {:invalid_input, reason}}, state}
        end
    end
  end

  def handle_call({:cancel, ctx, turn_id}, _from, state) do
    state =
      state
      |> ensure_queue()
      |> ensure_cancellation_fence()
      |> ensure_terminal_finalization()
      |> ensure_terminal_transition()

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

        state =
          state
          |> cancel_current_turn(cancelled_current, :hold)

        {:reply, {:ok, %{id: cancelled_turn_id, session_id: state.id, status: :cancelled}}, state}
    end
  end

  def handle_call({:prepare_restart, workspace_root}, _from, state) do
    state =
      state
      |> Map.put(:workspace_root, workspace_root)
      |> ensure_instance_id()
      |> ensure_queue()
      |> ensure_cancellation_fence()
      |> ensure_terminal_finalization()
      |> ensure_terminal_transition()

    cond do
      current = state.current ->
        key = {state.id, state.instance_id, current.turn_id}
        {:reply, {:pending, key}, cancel_current_turn(state, current, :hold)}

      transition = state.terminal_transition ->
        key = {state.id, state.instance_id, transition.turn_id}
        transition = %{transition | mode: :hold}
        {:reply, {:pending, key}, %{state | terminal_transition: transition}}

      fence = state.cancellation_fence ->
        key = {state.id, state.instance_id, fence.turn_id}
        {:reply, {:pending, key}, %{state | cancellation_fence: %{fence | mode: :hold}}}

      pending = state.terminal_finalization ->
        state = %{state | terminal_finalization: %{pending | mode: :hold}}
        {:reply, {:pending, pending.key}, renotify_terminal_finalization(state)}

      true ->
        {:reply, :ready, state}
    end
  end

  def handle_call({:reconcile_workspace, workspace_root}, _from, state) do
    state =
      state
      |> Map.put(:workspace_root, workspace_root)
      |> ensure_instance_id()
      |> ensure_cancellation_fence()
      |> ensure_terminal_finalization()
      |> ensure_terminal_transition()
      |> renotify_active_turn_owner()
      |> renotify_terminal_finalization()

    {:reply, :ok, state}
  end

  # Re-Enter on a queued message (Phase 5): cancel the in-flight turn and mark
  # the FIFO head to launch after the exact terminal-finalization ack. When no
  # terminal barrier is pending the head launches immediately.
  def handle_call({:flush_queue, ctx}, from, state) do
    state =
      state
      |> ensure_queue()
      |> ensure_cancellation_fence()
      |> ensure_terminal_finalization()
      |> ensure_terminal_transition()

    cond do
      not authorized?(ctx, state) ->
        {:reply, {:error, :forbidden}, state}

      state.queue == [] ->
        {:reply, {:error, :empty_queue}, state}

      true ->
        # Gracefully cancel the in-flight turn (same teardown as a normal cancel)
        # so the conversation can resume, record it, drop the durable client, then
        # drain the queue head on a fresh client only after finalization.
        state =
          case state.current do
            %{turn_id: _cancelled_turn_id} = current ->
              state
              |> cancel_current_turn(current, :drain)

            nil ->
              request_queue_drain(state, workspace_registration_mode(state, from))
          end

        {flushed, status} =
          case state.current do
            %{turn_id: turn_id} -> {turn_id, :running}
            nil -> {state.queue |> List.first() |> Map.fetch!(:turn_id), :queued}
          end

        {:reply, {:ok, %{id: flushed, session_id: state.id, status: status}}, state}
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

  # A send delegated by the Workspace Session cannot synchronously call that
  # same GenServer back while it is waiting for this handle_call reply. Erlang
  # signal ordering still makes the async registration durable before our reply
  # reaches Workspace. Direct callers use the synchronous path so a caller
  # cannot kill this Session and race a replacement attach ahead of ownership
  # registration.
  defp workspace_registration_mode(state, from),
    do: workspace_registration_mode(state, from, [])

  defp workspace_registration_mode(state, from, opts) when is_list(opts) do
    case Keyword.get(opts, :workspace_registration_mode) do
      mode when mode in [:sync, :async] -> mode
      _other -> workspace_registration_mode_from_caller(state, from)
    end
  end

  defp workspace_registration_mode_from_caller(state, {caller, _tag}) when is_pid(caller) do
    if Ecrits.Workspace.Session.whereis(state.workspace_root) == caller,
      do: :async,
      else: :sync
  end

  defp workspace_registration_mode_from_caller(_state, _from), do: :sync

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
      {:noreply, begin_terminal_transition(state, current, :completed)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:turn_failed, turn_id, reason}, state) do
    with %{turn_id: ^turn_id} = current <- state.current do
      {:noreply, begin_terminal_transition(state, current, {:failed, reason, :close})}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:terminal_turn_lock_acquired, token, lock_pid}, state)
      when is_reference(token) and is_pid(lock_pid) do
    state = ensure_terminal_transition(state)

    case state.terminal_transition do
      %{token: ^token, lock_pid: ^lock_pid, phase: :waiting} = transition ->
        case apply_terminal_transition(state, transition) do
          {:ok, state} ->
            transition = %{transition | phase: :applied}
            send(lock_pid, {:terminal_turn_state_applied, token, :applied})
            {:noreply, %{state | terminal_transition: transition}}

          :stale ->
            transition = %{transition | phase: :discarded}
            send(lock_pid, {:terminal_turn_state_applied, token, :discarded})
            {:noreply, %{state | terminal_transition: transition}}
        end

      _duplicate_or_stale ->
        {:noreply, state}
    end
  end

  def handle_info({:terminal_turn_lock_released, token, lock_pid, result}, state)
      when is_reference(token) and is_pid(lock_pid) do
    state = ensure_terminal_transition(state)

    case state.terminal_transition do
      %{token: ^token, lock_pid: ^lock_pid, phase: :applied} = transition
      when result == :applied ->
        {:noreply, finish_released_terminal_transition(state, transition)}

      %{token: ^token, lock_pid: ^lock_pid, phase: :discarded}
      when result == :discarded ->
        {:noreply, %{state | terminal_transition: nil}}

      %{token: ^token, lock_pid: ^lock_pid, phase: :waiting} ->
        {:noreply, restart_terminal_transition_lock(state)}

      _duplicate_or_stale ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:guarded_turn_worker_started, turn_id, guardian_pid, worker_pid},
        state
      )
      when is_binary(turn_id) and is_pid(guardian_pid) and is_pid(worker_pid) do
    cond do
      match?(%{turn_id: ^turn_id, task_pid: ^guardian_pid}, state.current) ->
        worker_ref = Process.monitor(worker_pid)

        current =
          state.current
          |> Map.put(:worker_pid, worker_pid)
          |> Map.put(:worker_ref, worker_ref)

        {:noreply, %{state | current: current}}

      match?(
        %{turn_id: ^turn_id, task_pid: ^guardian_pid},
        Map.get(state, :cancellation_fence)
      ) ->
        worker_ref = Process.monitor(worker_pid)
        send(guardian_pid, :acp_cancel_turn)

        fence =
          state.cancellation_fence
          |> Map.put(:worker_pid, worker_pid)
          |> Map.put(:worker_ref, worker_ref)
          |> Map.put(:worker_down?, false)

        {:noreply, %{state | cancellation_fence: fence}}

      true ->
        {:noreply, state}
    end
  end

  # Bounded fallback for a cancelled turn: if the exact fenced task is still
  # alive after the grace window, hard-kill only that task. In particular this
  # handler must never close `state.acp_client`: after the fence clears that
  # field may belong to a newer turn.
  def handle_info({:force_kill_turn, token, task_pid}, state) do
    state = ensure_cancellation_fence(state)

    case state.cancellation_fence do
      %{token: ^token, task_pid: ^task_pid} = fence ->
        if is_pid(task_pid) and Process.alive?(task_pid), do: Process.exit(task_pid, :kill)

        case Map.get(fence, :worker_pid) do
          worker_pid when is_pid(worker_pid) ->
            if Process.alive?(worker_pid), do: Process.exit(worker_pid, :kill)

          _missing ->
            :ok
        end

        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  # A live process can receive the old two-element timeout after a hot code
  # reload. Preserve that cleanup without touching the durable client, whose
  # ownership may already have advanced to another turn.
  def handle_info({:force_kill_turn, task_pid}, state) do
    if is_pid(task_pid) and Process.alive?(task_pid), do: Process.exit(task_pid, :kill)
    {:noreply, state}
  end

  # `Task.async/1` sends its result immediately before the monitor DOWN. While a
  # cancellation fence owns that monitor, retain it and wait for DOWN: receiving
  # the result is not yet proof that the task is dead.
  def handle_info(
        {ref, _result},
        %{cancellation_fence: %{task_ref: ref}} = state
      )
      when is_reference(ref) do
    {:noreply, state}
  end

  def handle_info({ref, _result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info(
        {:workspace_turn_finalization_ack, {agent_id, instance_id, turn_id}, _summary},
        state
      ) do
    state = ensure_terminal_finalization(state)

    case state.terminal_finalization do
      %{key: {^agent_id, ^instance_id, ^turn_id}, mode: mode} ->
        state = %{state | terminal_finalization: nil}
        {:noreply, if(mode == :drain, do: drain_queue(state), else: state)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{current: %{task_ref: ref} = current} = state
      )
      when reason != :normal do
    {:noreply, begin_terminal_transition(state, current, {:failed, reason, :cancel_and_close})}
  end

  def handle_info(
        {:DOWN, ref, :process, lock_pid, _reason},
        %{terminal_transition: %{lock_ref: ref, lock_pid: lock_pid} = transition} = state
      ) do
    case transition.phase do
      :applied ->
        # A process monitor is delivered only after its global lock is gone, so
        # an applied transition can safely continue even when the helper died
        # before it sent the explicit release message.
        {:noreply, finish_released_terminal_transition(state, transition)}

      :discarded ->
        {:noreply, %{state | terminal_transition: nil}}

      :waiting ->
        {:noreply, restart_terminal_transition_lock(state)}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, task_pid, _reason},
        %{cancellation_fence: %{task_ref: ref, task_pid: task_pid}} = state
      ) do
    fence = %{state.cancellation_fence | task_down?: true}
    {:noreply, maybe_finish_cancelled_turn(%{state | cancellation_fence: fence})}
  end

  def handle_info(
        {:DOWN, ref, :process, worker_pid, _reason},
        %{cancellation_fence: %{worker_ref: ref, worker_pid: worker_pid}} = state
      ) do
    fence = %{state.cancellation_fence | worker_down?: true}
    {:noreply, maybe_finish_cancelled_turn(%{state | cancellation_fence: fence})}
  end

  def handle_info(
        {:DOWN, ref, :process, worker_pid, reason},
        %{current: %{worker_ref: ref, worker_pid: worker_pid} = current} = state
      ) do
    if reason == :normal do
      current = current |> Map.delete(:worker_ref) |> Map.put(:worker_down?, true)
      {:noreply, %{state | current: current}}
    else
      failure = {:turn_worker_exit, reason}

      {:noreply, begin_terminal_transition(state, current, {:failed, failure, :cancel_and_close})}
    end
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

  defp begin_terminal_transition(state, current, outcome) do
    state = ensure_terminal_transition(state)

    case state.terminal_transition do
      nil ->
        transition = %{
          token: make_ref(),
          turn_id: current.turn_id,
          outcome: outcome,
          mode: :drain,
          previous_input: current.input,
          phase: :waiting,
          lock_pid: nil,
          lock_ref: nil
        }

        start_terminal_transition_lock(%{state | terminal_transition: transition})

      %{turn_id: turn_id} when turn_id == current.turn_id ->
        # `turn_failed`, guardian DOWN, and worker DOWN may all describe the
        # same terminal edge. The first mailbox-ordered edge owns it.
        state

      _other_turn ->
        state
    end
  end

  defp start_terminal_transition_lock(%{terminal_transition: transition} = state) do
    session = self()

    {lock_pid, lock_ref} =
      spawn_monitor(fn ->
        run_terminal_transition_lock(session, transition.token, transition.turn_id)
      end)

    transition = %{
      transition
      | lock_pid: lock_pid,
        lock_ref: lock_ref,
        phase: :waiting
    }

    %{state | terminal_transition: transition}
  end

  defp restart_terminal_transition_lock(%{terminal_transition: transition} = state) do
    if is_reference(transition.lock_ref), do: Process.demonitor(transition.lock_ref, [:flush])
    start_terminal_transition_lock(state)
  end

  defp run_terminal_transition_lock(session, token, turn_id) do
    session_ref = Process.monitor(session)

    result =
      try do
        :global.trans(turn_commit_lock(session, turn_id), fn ->
          send(session, {:terminal_turn_lock_acquired, token, self()})

          receive do
            {:terminal_turn_state_applied, ^token, result}
            when result in [:applied, :discarded] ->
              result

            {:DOWN, ^session_ref, :process, ^session, _reason} ->
              :session_down
          end
        end)
      catch
        kind, reason -> exit({:terminal_turn_lock_failed, kind, reason})
      end

    Process.demonitor(session_ref, [:flush])

    if result != :session_down do
      send(session, {:terminal_turn_lock_released, token, self(), result})
    end
  end

  defp apply_terminal_transition(state, %{turn_id: turn_id, outcome: outcome}) do
    case state.current do
      %{turn_id: ^turn_id} = current ->
        state =
          case outcome do
            :completed ->
              state
              |> clear_seeded_thread_gap(current)
              |> record_transcript_turn(current)
              |> emit(%{type: :turn_completed, turn_id: turn_id, text: current.text})

            {:failed, reason, :close} ->
              state
              |> close_acp_client()
              |> record_transcript_turn(current)
              |> emit(%{type: :turn_failed, turn_id: turn_id, reason: inspect(reason)})

            {:failed, reason, :cancel_and_close} ->
              state
              |> cancel_acp_client_turn()
              |> close_acp_client()
              |> record_transcript_turn(current)
              |> emit(%{type: :turn_failed, turn_id: turn_id, reason: inspect(reason)})
          end

        {:ok, Map.put(state, :current, nil)}

      _stale ->
        :stale
    end
  end

  defp finish_released_terminal_transition(state, transition) do
    if is_reference(transition.lock_ref), do: Process.demonitor(transition.lock_ref, [:flush])

    state
    |> Map.put(:terminal_transition, nil)
    |> persist_durable_state()
    |> begin_terminal_finalization(
      transition.turn_id,
      transition.mode,
      transition.previous_input
    )
  end

  defp cancel_waiting_terminal_transition(state, turn_id) do
    state = ensure_terminal_transition(state)

    case state.terminal_transition do
      %{turn_id: ^turn_id, phase: :waiting, lock_pid: lock_pid, lock_ref: lock_ref} ->
        if is_reference(lock_ref), do: Process.demonitor(lock_ref, [:flush])
        if is_pid(lock_pid), do: Process.exit(lock_pid, :kill)
        %{state | terminal_transition: nil}

      _none_or_already_applied ->
        state
    end
  end

  defp cancel_current_turn(state, current, mode) when mode in [:drain, :hold] do
    # This function is reached only through public APIs that own the same turn
    # lock. If a natural terminal message recorded a waiting helper first, that
    # helper cannot concurrently own the lock and is safe to retire here.
    state = cancel_waiting_terminal_transition(state, current.turn_id)
    task_pid = Map.get(current, :task_pid)
    worker_pid = Map.get(current, :worker_pid)

    if is_pid(task_pid), do: send(task_pid, :acp_cancel_turn)

    state =
      state
      |> cancel_acp_client_turn()
      |> close_acp_client()
      |> record_transcript_turn(current)
      |> emit(%{type: :turn_cancelled, turn_id: current.turn_id})
      |> Map.put(:current, nil)

    task_alive? = is_pid(task_pid) and Process.alive?(task_pid)
    worker_alive? = is_pid(worker_pid) and Process.alive?(worker_pid)

    if task_alive? or worker_alive? do
      task_ref =
        cond do
          not task_alive? -> nil
          is_reference(Map.get(current, :task_ref)) -> current.task_ref
          true -> Process.monitor(task_pid)
        end

      worker_ref =
        cond do
          not worker_alive? -> nil
          is_reference(Map.get(current, :worker_ref)) -> current.worker_ref
          true -> Process.monitor(worker_pid)
        end

      token = make_ref()

      timer_ref =
        Process.send_after(
          self(),
          {:force_kill_turn, token, task_pid},
          turn_cancel_grace_ms(state)
        )

      %{
        state
        | cancellation_fence: %{
            token: token,
            task_pid: task_pid,
            task_ref: task_ref,
            task_down?: not task_alive?,
            worker_pid: worker_pid,
            worker_ref: worker_ref,
            worker_down?: not worker_alive?,
            timer_ref: timer_ref,
            turn_id: current.turn_id,
            mode: mode,
            previous_input: current.input
          }
      }
    else
      state
      |> maybe_demonitor_turn_task(current)
      |> begin_terminal_finalization(current.turn_id, mode, current.input)
    end
  end

  defp finish_cancelled_turn(state) do
    state = ensure_cancellation_fence(state)

    case state.cancellation_fence do
      %{turn_id: turn_id, mode: mode, previous_input: previous_input} = fence ->
        cancel_cancellation_timer(fence)

        state
        |> Map.put(:cancellation_fence, nil)
        |> begin_terminal_finalization(turn_id, mode, previous_input)

      nil ->
        state
    end
  end

  defp maybe_finish_cancelled_turn(state) do
    case state.cancellation_fence do
      %{task_down?: true, worker_down?: true} -> finish_cancelled_turn(state)
      _pending -> state
    end
  end

  defp cancel_cancellation_timer(%{timer_ref: timer_ref}) when is_reference(timer_ref) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

  defp cancel_cancellation_timer(_fence), do: :ok

  defp turn_cancel_grace_ms(state) do
    case Keyword.get(state.adapter_opts, :turn_cancel_grace_ms, @cancel_grace_ms) do
      grace_ms when is_integer(grace_ms) and grace_ms >= 0 -> grace_ms
      _invalid -> @cancel_grace_ms
    end
  end

  defp maybe_demonitor_turn_task(state, %{task_ref: ref}) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state
  end

  defp maybe_demonitor_turn_task(state, _current), do: state

  defp begin_terminal_finalization(state, turn_id, mode, previous_input)
       when mode in [:drain, :hold] do
    state = ensure_terminal_finalization(state)

    identity = %{
      agent_id: state.id,
      instance_id: state.instance_id,
      turn_id: turn_id
    }

    key = {identity.agent_id, identity.instance_id, identity.turn_id}

    case Ecrits.Workspace.Session.notify_turn_terminal(state.workspace_root, identity, self()) do
      :pending ->
        %{
          state
          | terminal_finalization: %{
              key: key,
              mode: mode,
              previous_input: previous_input
            }
        }

      :no_workspace ->
        if mode == :drain, do: drain_queue(state), else: state
    end
  end

  defp renotify_terminal_finalization(%{terminal_finalization: %{key: key}} = state) do
    case key do
      {agent_id, instance_id, turn_id}
      when is_binary(agent_id) and is_binary(instance_id) and is_binary(turn_id) ->
        _ =
          Ecrits.Workspace.Session.notify_turn_terminal(
            state.workspace_root,
            %{agent_id: agent_id, instance_id: instance_id, turn_id: turn_id},
            self()
          )

        state

      _invalid_key ->
        state
    end
  end

  defp renotify_terminal_finalization(state), do: state

  defp renotify_active_turn_owner(%{current: %{turn_id: turn_id, task_pid: task_pid}} = state)
       when is_binary(turn_id) and turn_id != "" and is_pid(task_pid) do
    _ =
      Ecrits.Workspace.Session.notify_turn_started(
        state.workspace_root,
        %{agent_id: state.id, instance_id: state.instance_id, turn_id: turn_id},
        self(),
        task_pid,
        :async
      )

    state
  end

  defp renotify_active_turn_owner(state), do: state

  defp request_queue_drain(
         %{cancellation_fence: pending} = state,
         _workspace_registration_mode
       )
       when pending != nil do
    %{state | cancellation_fence: Map.put(pending, :mode, :drain)}
  end

  defp request_queue_drain(
         %{terminal_transition: pending} = state,
         _workspace_registration_mode
       )
       when pending != nil do
    %{state | terminal_transition: Map.put(pending, :mode, :drain)}
  end

  defp request_queue_drain(
         %{terminal_finalization: nil} = state,
         workspace_registration_mode
       ),
       do: drain_queue(state, workspace_registration_mode)

  defp request_queue_drain(
         %{terminal_finalization: pending} = state,
         _workspace_registration_mode
       ) do
    %{state | terminal_finalization: Map.put(pending, :mode, :drain)}
  end

  # Pop the FIFO queue head (if any) and launch it as the next turn. Called on
  # automatic terminal paths (done/failed/crash) and explicit flush, so a normal
  # user cancel can stop the current chat without sending queued follow-ups.
  # Callers clear `current` to nil before draining, so the head launches into an
  # idle session.
  defp drain_queue(state, workspace_registration_mode \\ :sync)

  defp drain_queue(
         %{current: nil, queue: [next | rest]} = state,
         workspace_registration_mode
       ) do
    {:ok, _turn_id, state} =
      launch_turn(
        queued_provider_input(next),
        %{state | queue: rest},
        next.turn_id,
        Map.get(next, :display) || next.input,
        Map.get(next, :picks, []),
        Map.get(next, :context),
        workspace_registration_mode
      )

    state
  end

  defp drain_queue(state, _workspace_registration_mode), do: state

  # ── send-turn helpers (FIFO queue) ─────────────────────────────────

  # Backfill the Phase 5 `:queue` key onto a Session GenServer hot-reloaded from
  # before this phase (the live :4000 server recompiles in place, not restarts),
  # so the first send into an upgraded process never crashes on a missing key.
  defp ensure_queue(state), do: Map.put_new(state, :queue, [])

  defp ensure_cancellation_fence(state),
    do: Map.put_new(state, :cancellation_fence, nil)

  defp ensure_terminal_finalization(state),
    do: Map.put_new(state, :terminal_finalization, nil)

  defp ensure_terminal_transition(state),
    do: Map.put_new(state, :terminal_transition, nil)

  defp start_turn(input, extras, %{current: current} = state) when current != nil do
    enqueue_turn(state, input, extras)
  end

  defp start_turn(input, extras, %{cancellation_fence: pending} = state)
       when pending != nil do
    enqueue_turn(state, input, extras)
  end

  defp start_turn(input, extras, %{terminal_finalization: pending} = state)
       when pending != nil do
    enqueue_turn(state, input, extras)
  end

  defp start_turn(input, extras, %{terminal_transition: pending} = state)
       when pending != nil do
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
        extras.context,
        Map.get(extras, :workspace_registration_mode, :sync)
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
  defp launch_turn(
         input,
         state,
         turn_id,
         display_input,
         picks,
         context,
         workspace_registration_mode
       ) do
    display_input = display_input || input
    {input, recap_covered} = maybe_prepend_thread_recap(state, input)
    parent = self()

    state =
      state
      |> apply_turn_context(context)
      |> ensure_acp_client_fields()

    client_key = acp_client_key(state)
    state = maybe_drop_incompatible_acp_client(state, client_key)

    launch_token = make_ref()

    # The guardian stays linked to the provider worker (so an untrappable kill
    # of either the Session or guardian cannot orphan document-writing work),
    # while monitoring this Session explicitly so ordinary owner death also
    # tears the worker down before Workspace finalization begins.
    task =
      Task.async(fn ->
        run_guarded_turn(
          parent,
          launch_token,
          turn_id,
          input,
          state,
          client_key
        )
      end)

    Process.unlink(task.pid)

    identity = %{agent_id: state.id, instance_id: state.instance_id, turn_id: turn_id}

    _ =
      Ecrits.Workspace.Session.notify_turn_started(
        state.workspace_root,
        identity,
        self(),
        task.pid,
        workspace_registration_mode
      )

    send(task.pid, {:launch_agent_turn, launch_token})

    state = %{
      state
      | current: %{
          turn_id: turn_id,
          task_ref: task.ref,
          task_pid: task.pid,
          text: "",
          pending_text: "",
          text_segment: 0,
          pending_reasoning: "",
          reasoning_segment: 0,
          edit_preview: nil,
          acp_update_state: AcpStream.update_state(),
          doc_vfs_sequence: nil,
          items: [],
          input: display_input,
          provider_input: input,
          recap_covered: recap_covered,
          picks: picks,
          context: turn_context(state, [])
        }
    }

    state =
      emit(state, %{type: :turn_started, turn_id: turn_id, input: display_input, picks: picks})

    state = maybe_emit_thread_title(state, display_input)

    {:ok, turn_id, state}
  end

  defp run_guarded_turn(parent, launch_token, turn_id, input, state, client_key) do
    Process.flag(:trap_exit, true)
    parent_ref = Process.monitor(parent)
    key = {state.id, state.instance_id, turn_id}
    cancel_grace_ms = turn_cancel_grace_ms(state)

    receive do
      {:launch_agent_turn, ^launch_token} ->
        guardian = self()
        worker_launch_token = make_ref()

        worker_pid =
          spawn_link(fn ->
            identity = %{agent_id: state.id, instance_id: state.instance_id, turn_id: turn_id}

            _ =
              Ecrits.Workspace.Session.notify_turn_worker_started(
                state.workspace_root,
                identity,
                guardian,
                self()
              )

            send(guardian, {:guarded_turn_worker_registered, self()})

            receive do
              {:launch_provider_worker, ^worker_launch_token} ->
                result = run_turn(parent, turn_id, input, state, client_key)
                send(guardian, {:guarded_turn_result, self(), result})

              :acp_cancel_turn ->
                :cancelled_before_launch
            end
          end)

        worker_ref = Process.monitor(worker_pid)

        await_guarded_worker_registration(
          parent,
          parent_ref,
          key,
          state.workspace_root,
          worker_pid,
          worker_ref,
          worker_launch_token,
          cancel_grace_ms
        )

      {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
        notify_guardian_stopped(state.workspace_root, key)
        :ok

      {:EXIT, _from, reason} ->
        exit(reason)
    end
  end

  defp await_guarded_worker_registration(
         parent,
         parent_ref,
         key,
         workspace_root,
         worker_pid,
         worker_ref,
         worker_launch_token,
         cancel_grace_ms
       ) do
    receive do
      {:guarded_turn_worker_registered, ^worker_pid} ->
        send(parent, {:guarded_turn_worker_started, elem(key, 2), self(), worker_pid})
        send(worker_pid, {:launch_provider_worker, worker_launch_token})

        await_guarded_turn(
          parent,
          parent_ref,
          key,
          workspace_root,
          worker_pid,
          worker_ref,
          cancel_grace_ms
        )

      :acp_cancel_turn ->
        send(worker_pid, :acp_cancel_turn)

        await_guarded_worker_registration(
          parent,
          parent_ref,
          key,
          workspace_root,
          worker_pid,
          worker_ref,
          worker_launch_token,
          cancel_grace_ms
        )

      {:shutdown_agent_turn, ^key, reply_to} when is_pid(reply_to) ->
        stop_guarded_worker(worker_pid, worker_ref, cancel_grace_ms)
        send(reply_to, {:agent_turn_guardian_stopped, key, self()})
        :ok

      {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
        stop_guarded_worker(worker_pid, worker_ref, cancel_grace_ms)
        notify_guardian_stopped(workspace_root, key)
        :ok

      {:DOWN, ^worker_ref, :process, ^worker_pid, reason} ->
        Process.demonitor(parent_ref, [:flush])
        exit({:turn_worker_exit, reason})

      {:EXIT, ^worker_pid, :normal} ->
        await_guarded_worker_registration(
          parent,
          parent_ref,
          key,
          workspace_root,
          worker_pid,
          worker_ref,
          worker_launch_token,
          cancel_grace_ms
        )

      {:EXIT, ^worker_pid, reason} ->
        Process.demonitor(parent_ref, [:flush])
        exit({:turn_worker_exit, reason})

      {:EXIT, _from, reason} ->
        stop_guarded_worker(worker_pid, worker_ref, cancel_grace_ms)
        exit(reason)
    end
  end

  defp await_guarded_turn(
         parent,
         parent_ref,
         key,
         workspace_root,
         worker_pid,
         worker_ref,
         cancel_grace_ms
       ) do
    receive do
      {:guarded_turn_result, ^worker_pid, result} ->
        Process.demonitor(parent_ref, [:flush])
        Process.demonitor(worker_ref, [:flush])
        result

      {:acp_stream_activity, _update} = activity ->
        send(worker_pid, activity)

        await_guarded_turn(
          parent,
          parent_ref,
          key,
          workspace_root,
          worker_pid,
          worker_ref,
          cancel_grace_ms
        )

      :acp_cancel_turn ->
        send(worker_pid, :acp_cancel_turn)

        await_guarded_turn(
          parent,
          parent_ref,
          key,
          workspace_root,
          worker_pid,
          worker_ref,
          cancel_grace_ms
        )

      {:shutdown_agent_turn, ^key, reply_to} when is_pid(reply_to) ->
        stop_guarded_worker(worker_pid, worker_ref, cancel_grace_ms)
        send(reply_to, {:agent_turn_guardian_stopped, key, self()})
        :ok

      {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
        stop_guarded_worker(worker_pid, worker_ref, cancel_grace_ms)
        notify_guardian_stopped(workspace_root, key)
        :ok

      {:DOWN, ^worker_ref, :process, ^worker_pid, reason} ->
        Process.demonitor(parent_ref, [:flush])
        exit({:turn_worker_exit, reason})

      {:EXIT, ^worker_pid, :normal} ->
        await_guarded_turn(
          parent,
          parent_ref,
          key,
          workspace_root,
          worker_pid,
          worker_ref,
          cancel_grace_ms
        )

      {:EXIT, ^worker_pid, reason} ->
        Process.demonitor(parent_ref, [:flush])
        exit({:turn_worker_exit, reason})

      {:EXIT, _from, reason} ->
        stop_guarded_worker(worker_pid, worker_ref, cancel_grace_ms)
        exit(reason)
    end
  end

  defp stop_guarded_worker(worker_pid, worker_ref, cancel_grace_ms) do
    send(worker_pid, :acp_cancel_turn)

    receive do
      {:DOWN, ^worker_ref, :process, ^worker_pid, _reason} ->
        :ok

      {:EXIT, ^worker_pid, _reason} ->
        await_guarded_worker_down(worker_pid, worker_ref)
    after
      cancel_grace_ms ->
        Process.exit(worker_pid, :kill)
        await_guarded_worker_down(worker_pid, worker_ref)
    end
  end

  defp notify_guardian_stopped(workspace_root, key) do
    case Ecrits.Workspace.Session.whereis(workspace_root) do
      pid when is_pid(pid) -> send(pid, {:agent_turn_guardian_stopped, key, self()})
      nil -> :ok
    end
  end

  defp await_guarded_worker_down(worker_pid, worker_ref) do
    receive do
      {:DOWN, ^worker_ref, :process, ^worker_pid, _reason} -> :ok
      {:EXIT, ^worker_pid, _reason} -> await_guarded_worker_down(worker_pid, worker_ref)
    end
  end

  defp queue_previous_input(%{queue: queue, current: current} = state) do
    case List.last(queue) do
      %{input: input} ->
        input

      _ ->
        case current do
          %{input: input} ->
            input

          _ ->
            case Map.get(state, :cancellation_fence) do
              %{previous_input: input} ->
                input

              _ ->
                case Map.get(state, :terminal_transition) do
                  %{previous_input: input} ->
                    input

                  _ ->
                    case Map.get(state, :terminal_finalization) do
                      %{previous_input: input} -> input
                      _ -> ""
                    end
                end
            end
        end
    end
  end

  defp queued_provider_input(%{input: input, previous_input: previous_input}) do
    previous = previous_input |> Content.display_text() |> String.trim()
    addendum = input |> Content.display_text() |> String.trim()

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

      {:events, events, acp_update_state} ->
        state
        |> put_current_acp_update_state(acp_update_state)
        |> then(fn state ->
          Enum.reduce(events, state, fn event, state ->
            handle_turn_event(state, turn_id, event)
          end)
        end)

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
      state.mcp_servers,
      is_binary(Map.get(state, :document_path)) and Map.get(state, :document_path) != ""
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
          document_path: state.document_path,
          session_pid: parent,
          expected_identity: %{
            agent_id: state.id,
            instance_id: state.instance_id,
            turn_id: turn_id
          },
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

    persist_durable_state(%{
      mark_thread_change(state, id)
      | acp_client: client,
        acp_client_key: client_key,
        acp_client_ref: ref,
        provider_session_id: id
    })
  end

  defp handle_turn_event(state, _turn_id, %{type: :provider_session, provider_session_id: id})
       when is_binary(id) and id != "" do
    persist_durable_state(%{mark_thread_change(state, id) | provider_session_id: id})
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
    current =
      state.current
      |> flush_pending_text_item()
      |> Map.update(:pending_reasoning, delta, &((&1 || "") <> delta))

    state
    |> Map.put(:current, current)
    |> emit(%{
      type: :reasoning_delta,
      turn_id: turn_id,
      segment: Map.get(current, :reasoning_segment, 0),
      delta: delta
    })
  end

  defp handle_turn_event(state, turn_id, %{type: :edit_delta, delta: delta} = event)
       when is_binary(delta) do
    current =
      state.current
      |> flush_pending_items()
      |> retain_edit_preview(event, delta)

    state
    |> Map.put(:current, current)
    |> emit(%{
      type: :edit_delta,
      turn_id: turn_id,
      edit_id: Map.get(event, :edit_id),
      path: Map.get(event, :path),
      delta: delta
    })
  end

  defp handle_turn_event(state, turn_id, %{type: :file_change_snapshot} = event) do
    emit(state, %{
      type: :file_change_snapshot,
      turn_id: turn_id,
      phase: Map.get(event, :phase, :proposed),
      edit_id: Map.get(event, :edit_id),
      changes: Map.get(event, :changes, []),
      fingerprint: Map.get(event, :fingerprint)
    })
  end

  defp handle_turn_event(state, turn_id, %{type: :file_operation_started} = event) do
    current =
      state.current
      |> flush_pending_items()
      |> put_file_activity_item(event, :running)

    state
    |> emit(file_operation_event_payload(event, turn_id, :running))
    |> Map.put(:current, current)
  end

  defp handle_turn_event(state, turn_id, %{type: :file_operation_completed} = event) do
    current =
      state.current
      |> flush_pending_items()
      |> put_file_activity_item(event, :completed)

    state
    |> emit(file_operation_event_payload(event, turn_id, :completed))
    |> Map.put(:current, current)
  end

  defp handle_turn_event(state, turn_id, %{type: :file_operation_failed} = event) do
    current =
      state.current
      |> flush_pending_items()
      |> put_file_activity_item(event, :failed)

    state
    |> emit(file_operation_event_payload(event, turn_id, :failed))
    |> Map.put(:current, current)
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_started} = event) do
    current =
      state.current
      |> flush_pending_items()
      |> put_tool_item(
        event.tool_call_id,
        event.name,
        Map.get(event, :kind),
        :running,
        tool_payload(event.name, Map.get(event, :arguments, %{}))
      )
      |> put_tool_arguments(event.tool_call_id, Map.get(event, :arguments, %{}))

    emit(state, %{
      type: :tool_call_started,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      kind: Map.get(event, :kind),
      arguments: Map.get(event, :arguments, %{})
    })
    |> Map.put(:current, current)
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_completed} = event) do
    # Flush text here too: a provider that only reports terminal tool updates
    # (no started event) must still get [text-so-far, tool] item order.
    current =
      state.current
      |> flush_pending_items()
      |> put_tool_item(
        event.tool_call_id,
        event.name,
        Map.get(event, :kind),
        :completed,
        tool_payload(event.name, Map.get(event, :result, %{}))
      )

    emit(state, %{
      type: :tool_call_completed,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      kind: Map.get(event, :kind),
      result: Map.get(event, :result, %{})
    })
    |> Map.put(:current, current)
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_failed} = event) do
    current =
      state.current
      |> flush_pending_items()
      |> put_tool_item(
        event.tool_call_id,
        event.name,
        Map.get(event, :kind),
        :failed,
        Map.get(event, :reason, "")
      )

    emit(state, %{
      type: :tool_call_failed,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      kind: Map.get(event, :kind),
      reason: Map.get(event, :reason, "")
    })
    |> Map.put(:current, current)
  end

  defp handle_turn_event(state, _turn_id, _event), do: state

  defp retain_edit_preview(current, event, delta) when is_map(current) do
    edit_id = Map.get(event, :edit_id)
    path = Map.get(event, :path)
    previous = Map.get(current, :edit_preview)

    preview =
      if same_edit_preview?(previous, edit_id, path) do
        previous
        |> Map.put(:edit_id, edit_id || Map.get(previous, :edit_id))
        |> Map.put(:path, path || Map.get(previous, :path))
        |> Map.put(:text, edit_preview_text_append(Map.get(previous, :text), delta))
        |> Map.put(:delta_count, Map.get(previous, :delta_count, 0) + 1)
      else
        %{
          edit_id: edit_id,
          path: path,
          text: edit_preview_text_append("", delta),
          delta_count: 1
        }
      end

    Map.put(current, :edit_preview, preview)
  end

  defp same_edit_preview?(previous, edit_id, path) when is_map(previous) do
    previous_edit_id = Map.get(previous, :edit_id)
    previous_path = Map.get(previous, :path)

    not (different_preview_identity?(previous_edit_id, edit_id) or
           different_preview_identity?(previous_path, path))
  end

  defp same_edit_preview?(_previous, _edit_id, _path), do: false

  defp different_preview_identity?(left, right)
       when is_binary(left) and left != "" and is_binary(right) and right != "",
       do: left != right

  defp different_preview_identity?(_left, _right), do: false

  defp edit_preview_text_append(text, delta) do
    text = (text || "") <> delta

    if String.length(text) <= @edit_preview_max do
      text
    else
      start = String.length(text) - @edit_preview_max
      "..." <> String.slice(text, start, @edit_preview_max)
    end
  end

  defp append_text_delta(state, turn_id, delta) do
    current =
      state.current
      |> flush_pending_reasoning_item()
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
  # A DIFFERENT provider session id than the remembered one means the old
  # thread was not resumed: every transcript row so far is invisible to the
  # new thread. Record how far the gap reaches so the next prompt seeds it.
  # (If THIS turn already carried a recap, the completed-turn transition
  # clears the gap again — the rows reached the new thread via the recap.)
  # `thread_covers_from` reads/writes go through Map.get/Map.put: a Session
  # hot-reloaded across the upgrade still carries a state map WITHOUT the key,
  # and dot access crashed the live session mid-send (2026-07-19 :dbg trace).
  defp mark_thread_change(state, id) do
    prior = state.provider_session_id
    rows = length(state.transcript)

    if is_binary(prior) and prior != "" and prior != id and rows > 0 do
      Map.put(state, :thread_covers_from, max(thread_covers_from(state), rows))
    else
      state
    end
  end

  defp clear_seeded_thread_gap(state, current) do
    if Map.get(current, :recap_covered, 0) > 0 do
      Map.put(state, :thread_covers_from, 0)
    else
      state
    end
  end

  defp thread_covers_from(state), do: Map.get(state, :thread_covers_from, 0)

  # Seed a thread gap: rows before `thread_covers_from` exist only in the
  # durable transcript — the provider thread never saw them. Prepend a bounded
  # recap once, ahead of the user's message, so references like "retry that
  # command" survive a thread change. Fires when a gap is recorded OR when
  # there is no resumable thread at all but restored rows exist.
  @thread_recap_budget 4_000

  defp maybe_prepend_thread_recap(state, input) when is_binary(input) do
    rows = length(state.transcript)
    gap = thread_covers_from(state)

    covered =
      cond do
        gap > 0 -> min(gap, rows)
        no_resumable_thread?(state) and rows > 0 -> rows
        true -> 0
      end

    if covered > 0 do
      chronological = state.transcript |> Enum.reverse() |> Enum.take(covered)
      {thread_recap(chronological) <> input, covered}
    else
      {input, 0}
    end
  end

  defp maybe_prepend_thread_recap(_state, input), do: {input, 0}

  defp no_resumable_thread?(state),
    do: not (is_binary(state.provider_session_id) and state.provider_session_id != "")

  defp thread_recap(dialogs) do
    {lines, omitted} =
      dialogs
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn dialog, {acc, omitted} ->
        line = recap_dialog(dialog)

        if IO.iodata_length([line | acc]) > @thread_recap_budget and acc != [] do
          {acc, omitted + 1}
        else
          {[line | acc], omitted}
        end
      end)

    omitted_note = if omitted > 0, do: "(#{omitted} earlier turns omitted)\n", else: ""

    """
    <conversation-recap>
    Earlier turns of THIS conversation. The current session thread started mid-conversation and has not seen them. Treat them as history that already happened — do not re-execute anything from the recap.
    #{omitted_note}#{IO.iodata_to_binary(lines)}</conversation-recap>

    """
  end

  defp recap_dialog(%Agent.Dialog{} = dialog) do
    # Tool lines get a larger budget than prose: a truncated shell command or
    # op payload cannot be retried, and "run that command again" across a
    # thread change is the recap's whole reason to exist.
    tool_lines =
      dialog.items
      |> Enum.filter(&(is_map(&1) and is_binary(Map.get(&1, :name))))
      |> Enum.map(fn item ->
        "  [tool #{recap_trim(item.name, 1_500)}] #{recap_trim(Map.get(item, :input), 1_500)}\n"
      end)

    [
      "[user] #{recap_trim(dialog.user)}\n",
      tool_lines,
      "[agent] #{recap_trim(dialog.agent)}\n"
    ]
  end

  defp recap_trim(value, limit \\ 400)

  defp recap_trim(value, limit) when is_binary(value) do
    if String.length(value) > limit, do: String.slice(value, 0, limit) <> "…", else: value
  end

  defp recap_trim(_value, _limit), do: ""

  defp record_transcript_turn(state, current) do
    # The transcript bubble shows the typed text regardless of input modality
    # (string sugar OR a multi-modal block list), so derive the display text.
    user = Content.display_text(current[:input])
    agent = current[:text]

    items = transcript_items(current, user, agent)

    if blank?(user) and blank?(agent) and items == [] do
      state
    else
      entry =
        Agent.new_dialog!(%{turn_id: current.turn_id, user: user, agent: agent, items: items})

      %{state | transcript: [entry | state.transcript]}
    end
  end

  defp transcript_items(current, user, agent) do
    current = flush_pending_items(current)

    items =
      current
      |> Map.get(:items, [])
      |> normalize_file_activity_items()
      |> Enum.map(&terminalize_running_file_activity/1)

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

  defp flush_pending_reasoning_item(current) when is_map(current) do
    pending = Map.get(current, :pending_reasoning, "")

    if blank?(pending) do
      current
    else
      segment = Map.get(current, :reasoning_segment, 0)

      current
      |> Map.update(:items, [reasoning_item(pending, segment)], fn items ->
        items ++ [reasoning_item(pending, segment)]
      end)
      |> Map.put(:pending_reasoning, "")
      |> Map.put(:reasoning_segment, segment + 1)
    end
  end

  defp flush_pending_items(current) when is_map(current) do
    current
    |> flush_pending_text_item()
    |> flush_pending_reasoning_item()
  end

  defp reasoning_item(body, segment) do
    %{role: :thinking, body: body, status: :sent, segment: segment}
  end

  defp maybe_append_agent_item(items, text, segment) do
    if blank?(text) do
      items
    else
      items ++ [%{role: :agent, body: text, status: :sent, segment: segment}]
    end
  end

  defp append_transcript_item_to_state(state, item) do
    item_turn_id = transcript_item_turn_id(item)
    current = Map.get(state, :current)

    cond do
      is_map(current) and
          (is_nil(item_turn_id) or Map.get(current, :turn_id) == item_turn_id) ->
        append_transcript_item_to_current(state, item)

      is_binary(item_turn_id) ->
        append_transcript_item_to_turn(state, item, item_turn_id)

      Map.get(state, :transcript, []) != [] ->
        append_transcript_item_to_latest(state, item)

      true ->
        append_transcript_item_as_dialog(state, item, nil)
    end
  end

  defp append_transcript_item_to_current(%{current: current} = state, item) do
    current = flush_pending_items(current)

    items =
      Agent.upsert_dialog_item(
        Map.get(current, :items, []),
        item,
        Map.get(current, :id) || Map.get(current, :turn_id)
      )

    %{state | current: Map.put(current, :items, items)}
  end

  defp append_transcript_item_to_turn(state, item, turn_id) do
    {transcript, found?} =
      Enum.map_reduce(state.transcript, false, fn dialog, found? ->
        if not found? and dialog_turn_id(dialog) == turn_id do
          {Agent.append_dialog_item(dialog, item), true}
        else
          {dialog, found?}
        end
      end)

    if found? do
      %{state | transcript: transcript}
    else
      append_transcript_item_as_dialog(state, item, turn_id)
    end
  end

  defp append_transcript_item_to_latest(%{transcript: [latest | rest]} = state, item) do
    latest = Agent.append_dialog_item(latest, item)
    %{state | transcript: [latest | rest]}
  end

  defp append_transcript_item_as_dialog(state, item, turn_id) do
    turn_id =
      turn_id || transcript_item_turn_id(item) ||
        "display-#{System.unique_integer([:positive, :monotonic])}"

    entry = Agent.new_dialog!(%{turn_id: turn_id, user: "", agent: "", items: [item]})
    %{state | transcript: [entry | state.transcript]}
  end

  defp transcript_item_turn_id(item) when is_map(item) do
    case Map.get(item, :turn_id) || Map.get(item, "turn_id") do
      turn_id when is_binary(turn_id) and turn_id != "" -> turn_id
      _other -> nil
    end
  end

  defp dialog_turn_id(dialog) when is_map(dialog),
    do: Map.get(dialog, :turn_id) || Map.get(dialog, "turn_id")

  defp normalize_transcript(state) do
    Map.update!(state, :transcript, fn transcript ->
      transcript
      |> Agent.normalize_dialogs!()
      |> Enum.map(fn dialog ->
        items =
          dialog.items
          |> normalize_file_activity_items()
          |> Enum.map(&terminalize_running_file_activity/1)

        Agent.new_dialog!(%{dialog | items: items})
      end)
    end)
  end

  defp normalize_file_activity_item(item) when is_map(item) do
    operation = item_field(item, :operation) || item_field(item, :name)

    if file_activity_item?(item) do
      file_operation_id = file_activity_id(item)
      input = file_activity_input(item)
      path = item_field(item, :path) || item_field(input, :path)
      query = item_field(item, :query) || item_field(input, :query)
      reason = file_activity_failure_reason(item)

      item
      |> Map.put(:role, :file_activity)
      |> Map.put(:file_operation_id, file_operation_id)
      |> Map.put(:tool_call_id, file_operation_id)
      |> Map.put(:operation, operation)
      |> Map.put(:name, operation)
      |> put_file_activity_value(:path, path)
      |> put_file_activity_value(:query, query)
      |> put_file_activity_value(:reason, reason)
      |> maybe_put_file_activity_failure_body(reason)
    else
      item
    end
  end

  defp normalize_file_activity_item(item), do: item

  defp normalize_file_activity_items(items) when is_list(items) do
    Enum.reduce(items, [], fn raw_item, normalized_items ->
      item = normalize_file_activity_item(raw_item)
      file_operation_id = if(file_activity_item?(item), do: file_activity_id(item))

      if is_nil(file_operation_id) do
        normalized_items ++ [item]
      else
        case Enum.find_index(normalized_items, fn existing ->
               file_activity_item?(existing) and file_activity_id(existing) == file_operation_id
             end) do
          nil ->
            normalized_items ++ [item]

          index ->
            previous = Enum.at(normalized_items, index)
            List.replace_at(normalized_items, index, merge_file_activity_items(previous, item))
        end
      end
    end)
  end

  defp merge_file_activity_items(previous, current) do
    merged =
      Map.merge(previous, current, fn _key, previous_value, current_value ->
        if present_file_activity_value?(current_value),
          do: current_value,
          else: previous_value
      end)

    if terminal_file_activity_status?(item_field(previous, :status)) and
         not terminal_file_activity_status?(item_field(current, :status)) do
      merged
      |> Map.put(:status, item_field(previous, :status))
      |> put_file_activity_value(:reason, item_field(previous, :reason))
      |> put_file_activity_value(:body, item_field(previous, :body))
      |> put_file_activity_value(:output, item_field(previous, :output))
    else
      merged
    end
  end

  defp terminalize_running_file_activity(item) when is_map(item) do
    if file_activity_item?(item) and
         item_field(item, :status) in [:pending, "pending", :running, "running"] do
      item
      |> normalize_file_activity_item()
      |> Map.put(:status, :failed)
      |> Map.put(:reason, @dangling_file_operation_reason)
      |> Map.put(:body, @dangling_file_operation_reason)
    else
      item
    end
  end

  defp terminalize_running_file_activity(item), do: item

  defp file_activity_input(item) do
    [:arguments, :args, :input]
    |> Enum.find_value(%{}, fn key ->
      case decode_file_activity_map(item_field(item, key)) do
        map when map != %{} -> map
        _ -> nil
      end
    end)
  end

  defp decode_file_activity_map(value) when is_map(value), do: value

  defp decode_file_activity_map(value) when is_binary(value) do
    value = String.trim(value)

    with {:error, _reason} <- Jason.decode(value),
         [input] <-
           Regex.run(~r/(?:^|\n)Input:\n(.*?)(?:\n\nOutput:|\z)/s, value, capture: :all_but_first),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(String.trim(input)) do
      decoded
    else
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{}
    end
  end

  defp decode_file_activity_map(_value), do: %{}

  defp file_activity_failure_reason(item) do
    if item_field(item, :status) in [:failed, "failed"] do
      item_field(item, :reason) ||
        file_activity_text(item_field(item, :output)) ||
        file_activity_body_output(item_field(item, :body)) ||
        file_activity_text(item_field(item, :body))
    end
  end

  defp file_activity_body_output(body) when is_binary(body) do
    case Regex.run(~r/(?:^|\n)Output:\n(.*)\z/s, body, capture: :all_but_first) do
      [output] -> file_activity_text(output)
      _ -> nil
    end
  end

  defp file_activity_body_output(_body), do: nil

  defp file_activity_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp file_activity_text(value) when is_map(value) or is_list(value),
    do: Jason.encode!(value)

  defp file_activity_text(nil), do: nil
  defp file_activity_text(value), do: inspect(value)

  defp maybe_put_file_activity_failure_body(item, nil), do: item

  defp maybe_put_file_activity_failure_body(item, reason) do
    put_file_activity_value(item, :body, reason)
  end

  defp put_file_activity_value(item, _key, value) when value in [nil, ""], do: item
  defp put_file_activity_value(item, key, value), do: Map.put(item, key, value)

  defp present_file_activity_value?(value), do: value not in [nil, "", [], %{}]

  defp terminal_file_activity_status?(status),
    do: status in [:completed, "completed", :failed, "failed", :cancelled, "cancelled"]

  defp file_activity_item?(item) when is_map(item) do
    role = item_field(item, :role)
    operation = item_field(item, :operation) || item_field(item, :name)

    role in [:file_activity, "file_activity"] or
      (role in [:tool, "tool"] and AcpStream.file_operation_name?(operation))
  end

  defp file_activity_item?(_item), do: false

  defp file_activity_id(item) do
    item_field(item, :file_operation_id) || item_field(item, :tool_call_id)
  end

  defp item_field(item, key) when is_map(item),
    do: Map.get(item, key, Map.get(item, Atom.to_string(key)))

  defp put_file_activity_item(current, event, status) when is_map(current) do
    file_operation_id =
      Map.get(event, :file_operation_id) || Map.get(event, :tool_call_id) ||
        "file-operation-" <> Integer.to_string(System.unique_integer([:positive]))

    previous =
      current
      |> Map.get(:items, [])
      |> Enum.find(fn item ->
        file_activity_item?(item) and file_activity_id(item) == file_operation_id
      end)

    operation = Map.get(event, :operation) || (previous && item_field(previous, :operation))

    item = %{
      role: :file_activity,
      file_operation_id: file_operation_id,
      tool_call_id: file_operation_id,
      operation: operation,
      name: operation,
      path: Map.get(event, :path) || (previous && item_field(previous, :path)),
      query: Map.get(event, :query) || (previous && item_field(previous, :query)),
      kind: Map.get(event, :kind) || (previous && item_field(previous, :kind)),
      status: status,
      reason: if(status == :failed, do: Map.get(event, :reason, ""), else: nil),
      body: if(status == :failed, do: Map.get(event, :reason, ""), else: nil)
    }

    items = Map.get(current, :items, [])

    items =
      if previous do
        Enum.map(items, fn existing ->
          if file_activity_item?(existing) and file_activity_id(existing) == file_operation_id,
            do: item,
            else: existing
        end)
      else
        items ++ [item]
      end

    Map.put(current, :items, items)
  end

  defp file_operation_event_payload(event, turn_id, status) do
    event
    |> Map.put(:turn_id, turn_id)
    |> Map.put(:status, status)
  end

  defp put_tool_item(current, tool_call_id, name, kind, status, body) when is_map(current) do
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
      kind: kind || (previous && Map.get(previous, :kind)),
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

  # Raw arguments are needed only while a tool is in flight so a sibling rail
  # joining mid-turn can complete the same doc.edit preview when the terminal
  # event arrives. `put_tool_item/6` drops this field on terminal updates, and
  # the durable transcript normalizer never persists it.
  defp put_tool_arguments(current, tool_call_id, arguments)
       when is_map(current) and not is_nil(tool_call_id) do
    Map.update(current, :items, [], fn items ->
      Enum.map(items, fn
        %{tool_call_id: ^tool_call_id} = item -> Map.put(item, :arguments, arguments)
        item -> item
      end)
    end)
  end

  defp put_tool_arguments(current, _tool_call_id, _arguments), do: current

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

  defp with_requested_turn_lock(pid, nil, fun), do: with_current_turn_lock(pid, fun)

  defp with_requested_turn_lock(pid, turn_id, fun)
       when is_pid(pid) and is_binary(turn_id) and is_function(fun, 1) do
    :global.trans(turn_commit_lock(pid, turn_id), fn -> fun.(turn_id) end)
  end

  defp with_current_turn_lock(pid, fun) when is_pid(pid) and is_function(fun, 1) do
    case current_turn_id(pid) do
      turn_id when is_binary(turn_id) and turn_id != "" ->
        result =
          :global.trans(turn_commit_lock(pid, turn_id), fn ->
            if current_turn_id(pid) == turn_id, do: fun.(turn_id), else: :retry_turn_lock
          end)

        if result == :retry_turn_lock, do: with_current_turn_lock(pid, fun), else: result

      _no_current_turn ->
        fun.(nil)
    end
  end

  defp current_turn_id(pid) do
    GenServer.call(pid, :turn_lock_id)
  catch
    :exit, _reason -> nil
  end

  defp current_turn_identity?(pid, identity) do
    case tool_context(pid) do
      context when is_map(context) ->
        Enum.all?([:agent_id, :instance_id, :turn_id], fn key ->
          value = Map.get(identity, key)
          is_binary(value) and value != "" and Map.get(context, key) == value
        end)

      _context ->
        false
    end
  catch
    :exit, _reason -> false
  end

  defp turn_commit_lock(pid, turn_id),
    do: {{__MODULE__, :turn_commit, pid, turn_id}, self()}

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_), do: false

  defp public_snapshot(state) do
    %{
      id: state.id,
      instance_id: state.instance_id,
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
      instance_id: state.instance_id,
      event_seq: state.event_seq,
      transcript: Enum.reverse(state.transcript),
      status: status(state),
      title: state.title,
      title_user_edited?: Map.get(state, :title_user_edited?, false),
      # Provider is bound when this agent process starts; model is the canonical
      # option retained by that process. Same-tab sibling LiveViews use these
      # values when a provider restart reuses the durable agent id.
      provider: snapshot_provider_id(state.provider),
      model: Keyword.get(state.adapter_opts, :model),
      # Number of mid-turn sends still queued (Phase 5), so a refresh can repaint
      # the "N 대기" pending state.
      pending: length(state.queue),
      queued: Enum.map(state.queue, &queued_turn_payload/1),
      current_turn: current_turn_snapshot(state.current),
      # Stored adapter_opts so the LiveView can hydrate reasoning/access from
      # session on re-attach (instead of reading stale URL params).
      adapter_opts: state.adapter_opts
    }
  end

  defp durable_snapshot_payload(state) do
    %{
      id: state.id,
      instance_id: state.instance_id,
      provider_session_id: Map.get(state, :provider_session_id),
      thread_covers_from: Map.get(state, :thread_covers_from, 0),
      title: Map.get(state, :title),
      title_user_edited?: Map.get(state, :title_user_edited?, false),
      transcript: Enum.reverse(state.transcript),
      adapter_opts: state.adapter_opts |> Keyword.take(@persisted_adapter_opt_keys) |> Map.new()
    }
    |> DurableState.cast!()
    |> DurableState.dump()
  end

  defp persist_durable_state(%{workspace_root: workspace_root, id: id} = state)
       when is_binary(workspace_root) and workspace_root != "" and is_binary(id) and id != "" do
    _ =
      Ecrits.WorkspaceHandoff.put_agent_state(
        workspace_root,
        id,
        durable_snapshot_payload(normalize_transcript(state))
      )

    state
  rescue
    _error -> state
  catch
    :exit, _reason -> state
  end

  defp persist_durable_state(state), do: state

  defp persist_durable_state_async(%{workspace_root: workspace_root, id: id} = state)
       when is_binary(workspace_root) and workspace_root != "" and is_binary(id) and id != "" do
    _ =
      Ecrits.WorkspaceHandoff.put_agent_state_async(
        workspace_root,
        id,
        durable_snapshot_payload(normalize_transcript(state))
      )

    state
  rescue
    _error -> state
  catch
    :exit, _reason -> state
  end

  defp persist_durable_state_async(state), do: state

  defp cast_durable_restore(restore, expected_id) when is_map(restore) do
    case DurableState.cast(restore) do
      {:ok, %DurableState{id: ^expected_id} = state} -> DurableState.runtime_map(state)
      _invalid_or_mismatched -> %{}
    end
  end

  defp cast_durable_restore(_restore, _expected_id), do: %{}

  defp restored_transcript(%{transcript: transcript}) when is_list(transcript) do
    Enum.map(transcript, &Agent.load_dialog!/1)
  rescue
    _error -> []
  end

  defp restored_transcript(_restore), do: []

  defp merge_restored_adapter_opts(runtime_opts, %{adapter_opts: restored})
       when is_list(runtime_opts) and is_map(restored) do
    persisted =
      Enum.flat_map(@persisted_adapter_opt_keys, fn key ->
        case Map.fetch(restored, Atom.to_string(key)) do
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end)

    Keyword.merge(persisted, runtime_opts)
  end

  defp merge_restored_adapter_opts(runtime_opts, _restore), do: runtime_opts

  # This is a value snapshot of the current turn, not the mutable `current`
  # state map itself. Pending prose/reasoning remain separate from already
  # ordered items so a joining LiveView can render the current bytes and then
  # continue appending future deltas to the same segment ids.
  defp current_turn_snapshot(nil), do: nil

  defp current_turn_snapshot(current) when is_map(current) do
    input = Content.display_text(Map.get(current, :input))
    picks = Map.get(current, :picks, [])

    current_items =
      current
      |> Map.get(:items, [])
      |> normalize_file_activity_items()

    %{
      id: current.turn_id,
      turn_id: current.turn_id,
      status: :running,
      input: input,
      picks: picks,
      items:
        []
        |> maybe_append_user_item(input, picks)
        |> Kernel.++(Enum.map(current_items, &Map.delete(&1, :arguments))),
      pending_text: Map.get(current, :pending_text, ""),
      text_segment: Map.get(current, :text_segment, 0),
      pending_reasoning: Map.get(current, :pending_reasoning, ""),
      reasoning_segment: Map.get(current, :reasoning_segment, 0),
      edit_preview: current_edit_preview_snapshot(current),
      active_tools: current_active_tools(current_items)
    }
  end

  defp current_edit_preview_snapshot(current) do
    case Map.get(current, :edit_preview) do
      preview when is_map(preview) ->
        %{
          edit_id: Map.get(preview, :edit_id),
          path: Map.get(preview, :path),
          text: Map.get(preview, :text, ""),
          delta_count: Map.get(preview, :delta_count, 0)
        }

      _missing ->
        nil
    end
  end

  defp current_active_tools(items) do
    items
    |> Enum.filter(&(Map.get(&1, :role) == :tool and Map.get(&1, :status) == :running))
    |> Map.new(fn item ->
      tool_call_id = Map.get(item, :tool_call_id)

      {tool_call_id,
       %{
         name: Map.get(item, :name),
         kind: Map.get(item, :kind),
         input: Map.get(item, :input),
         args: Map.get(item, :arguments, %{})
       }}
    end)
  end

  defp status(%{current: nil}), do: :idle
  defp status(_state), do: :running

  defp snapshot_provider_id(%{id: id}) when is_binary(id), do: id
  defp snapshot_provider_id(provider) when is_binary(provider), do: provider
  defp snapshot_provider_id(_provider), do: nil

  defp queued_turn_payload(queued) do
    %{
      turn_id: queued.turn_id,
      input: queued_display_input(queued),
      picks: Map.get(queued, :picks, [])
    }
  end

  defp queued_display_input(%{display: display}) when is_binary(display), do: display

  defp queued_display_input(%{input: input}), do: Content.display_text(input)

  defp emit(state, event) do
    state = state |> ensure_instance_id() |> ensure_event_seq()
    event_seq = state.event_seq + 1
    state = Map.put(state, :event_seq, event_seq)

    event =
      event
      |> Map.put(:session_id, state.id)
      |> Map.put(:instance_id, state.instance_id)
      |> Map.put(:event_seq, event_seq)
      |> Map.put(
        :at,
        DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
      )

    Phoenix.PubSub.broadcast(@pubsub, topic(state.id), {:agent_event, event})
    maybe_persist_durable_event(state, event)
  end

  defp maybe_persist_durable_event(state, %{type: type})
       when type in [:thread_title, :turn_cancelled],
       do: persist_durable_state(state)

  defp maybe_persist_durable_event(state, %{type: type})
       when type in [:turn_completed, :turn_failed],
       do: persist_durable_state_async(state)

  defp maybe_persist_durable_event(state, _event), do: state

  # Tolerate a process that was started before this field was hot-loaded. The
  # first snapshot or event pins one token for the rest of that process life.
  defp ensure_instance_id(state) do
    case Map.get(state, :instance_id) do
      instance_id when is_binary(instance_id) and instance_id != "" -> state
      _missing -> Map.put(state, :instance_id, Ecto.UUID.generate())
    end
  end

  defp ensure_event_seq(state) do
    case Map.get(state, :event_seq) do
      event_seq when is_integer(event_seq) and event_seq >= 0 -> state
      _missing -> Map.put(state, :event_seq, 0)
    end
  end

  # Auto-title a fresh conversation from its first user message. Codex does not
  # emit a session/thread title over ACP (only the `pi` adapter does via
  # session_info_update), so without this a `New Chat` stays untitled. We emit a
  # `:thread_title` event ONCE, on the first turn; the LiveView applies it unless
  # the user has manually renamed the thread (agent_title_user_edited?).
  defp maybe_emit_thread_title(%{title_emitted?: true} = state, _input), do: state

  defp maybe_emit_thread_title(state, input) do
    # Derive from the display text so a multi-modal turn titles from its typed
    # text; a bare-string input passes through `display_text/1` unchanged.
    case derive_title(Content.display_text(input)) do
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
