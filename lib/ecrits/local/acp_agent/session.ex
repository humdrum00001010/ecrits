defmodule Ecrits.Local.AcpAgent.Session do
  @moduledoc """
  One local chat-agent session, driven directly by `ExMCP.ACP.Client`.

  This is the *sole* chat-agent producer: there is no bespoke provider driver or
  safety-net fallback. The GenServer owns one ACP client per turn, selecting the
  concrete ex_mcp ACP adapter per provider (`ExMCP.ACP.Adapters.Codex` /
  `Claude`), translates the agent's streamed `session/update` notifications into
  the normalized chat-rail events, and broadcasts them on
  `local_agent:<session_id>` (the contract the workspace LiveView consumes).

  The session passes the `doc.*` MCP server to `new_session(..., mcp_servers:)`
  so the agent (codex AND claude, over ACP) discovers and calls those tools; the
  resulting `tool_call` / `tool_call_update` updates render in the chat-rail
  tool_call block.

  ## Per-turn lifecycle

      start ExMCP.ACP.Client -> new_session(cwd, mcp_servers)
        -> prompt (async, blocking on the client) -> session/update* (streamed)
        -> prompt result (stopReason) -> disconnect client

  Cancellation kills the streaming task; its `Stream.resource` cleanup issues the
  ACP cancel (`turn/interrupt` for codex) and disconnects the client, which
  terminates the agent subprocess.
  """

  use GenServer

  alias Ecrits.Context
  alias Ecrits.Local.AcpAgent.AcpStream
  alias Ecrits.Local.AcpAgent.Prompt

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
  Set the chat title explicitly (a user rename). Marks the title user-edited so
  the first-prompt auto-title never overrides it afterwards, and broadcasts a
  `:thread_title` event so every attached LiveView updates its header.
  """
  def rename(pid, title) when is_pid(pid) and is_binary(title),
    do: GenServer.call(pid, {:rename, title})

  @doc """
  Lightweight, display-only transcript of completed turns for repaint after a
  browser refresh. The conversation itself stays provider-owned (codex resumes it
  via `provider_session_id`); this is only the prior `user`/`agent` text bubbles
  so the chat pane is not blank on re-attach. A list (oldest first) of
  `%{turn_id, user, agent}` where each text field may be `nil`/empty.
  """
  def transcript(pid) when is_pid(pid), do: GenServer.call(pid, :transcript)

  def transcript(id) when is_binary(id) do
    case whereis(id) do
      pid when is_pid(pid) -> transcript(pid)
      nil -> []
    end
  end

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
       document_id: Keyword.get(opts, :document_id),
       # The agent's ACTIVE doc for the doc.* MCP tools: the `Ecrits.Doc.Pool`
       # document id (`d_<kind>_<hash>`) of the doc this agent is bound to —
       # distinct from `document_id` (the LiveView Document id used as provider
       # prompt context). `doc.context` returns THIS (per-agent, not the global
       # `Pool.active`); `doc.open`/`doc.edit` honour ownership against it. The
       # workspace LiveView sets it from `register_pool_document` and follows doc
       # switches live via `update_options`. nil until a doc is bound.
       pool_document_id: Keyword.get(opts, :pool_document_id),
       mcp_servers: Keyword.get(opts, :mcp_servers, []),
       # The provider's session/thread id, captured on turn 1 and RESUMED on
       # turns 2+ so the conversation keeps cross-turn memory. `nil` until the
       # first turn establishes it.
       provider_session_id: nil,
       current: nil,
       # FIFO queue of messages received WHILE a turn was in flight (Phase 5). A
       # mid-turn send ENQUEUES instead of cancelling the running turn; the head
       # drains automatically when the running turn reaches a terminal state. A
       # re-Enter (`flush_queue/2`) on a queued message cancels the current turn
       # and runs the head immediately. Each entry: %{turn_id, input}.
       queue: [],
       # Display-only transcript of COMPLETED turns (oldest first), so a browser
       # refresh can repaint the prior bubbles. codex `thread/resume` restores the
       # agent's memory but does NOT re-stream past messages, so without this the
       # re-attached pane is blank. Each entry: %{turn_id, user, agent}.
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
    {:reply,
     %{
       active_doc: state.pool_document_id,
       agent_id: state.id,
       workspace_root: state.workspace_root
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

  def handle_call(:transcript, _from, state) do
    {:reply, Enum.reverse(state.transcript), state}
  end

  def handle_call({:update_options, new_opts}, _from, state) do
    # The active document is per-turn context, NOT a reason to recreate the
    # session — switching the document in the workspace must preserve the
    # conversation (mirrors the access/reasoning live-update path). When the
    # caller passes a `:document_id` (LiveView Document id, provider prompt
    # context) and/or `:pool_document_id` (the Pool doc id the doc.* tools target),
    # follow them on the live session so the next turn's doc.* tools operate on
    # what the user is now viewing.
    {document_id, new_opts} = Keyword.pop(new_opts, :document_id, state.document_id)
    {pool_document_id, adapter_opts} =
      Keyword.pop(new_opts, :pool_document_id, state.pool_document_id)

    merged = Keyword.merge(state.adapter_opts, adapter_opts)

    {:reply, :ok,
     %{state | adapter_opts: merged, document_id: document_id, pool_document_id: pool_document_id}}
  end

  def handle_call({:send_turn, ctx, raw_input, _opts}, _from, state) do
    cond do
      not authorized?(ctx, state) ->
        {:reply, {:error, :forbidden}, state}

      true ->
        # Normalize the input at the boundary (Phase 5 multi-modal seam): a bare
        # string stays a bare string (the byte-for-byte-unchanged legacy path), a
        # block list is validated. A malformed multi-modal send fails fast here.
        case Prompt.normalize(raw_input) do
          {:ok, input} -> start_turn(input, ensure_queue(state))
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
        # the conversation it anchors) alive. We ask the per-turn task to halt its
        # `AcpStream` gracefully (`:acp_cancel_turn`) so the stream's `cleanup/1`
        # runs the SAME teardown a normal turn completion uses — ACP cancel + clean
        # client disconnect, which lets the provider subprocess flush its rollout so
        # the NEXT turn resumes the same conversation. A brutal `Process.exit(task,
        # :kill)` would skip that cleanup and tear the subprocess down mid-write,
        # losing the conversation. A bounded fallback still hard-kills a task that
        # refuses to wind down, so cancel can never hang.
        cancelled_turn_id = state.current.turn_id
        cancelled_current = state.current

        if state.current.task_pid do
          send(state.current.task_pid, :acp_cancel_turn)
          Process.send_after(self(), {:force_kill_turn, state.current.task_pid}, @cancel_grace_ms)
        end

        state =
          state
          |> record_transcript_turn(cancelled_current)
          |> emit(%{type: :turn_cancelled, turn_id: cancelled_turn_id})
          |> Map.put(:current, nil)
          |> drain_queue()

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
        # so the conversation can resume, record it, then drain the queue head.
        state =
          case state.current do
            %{turn_id: cancelled_turn_id} = current ->
              if current.task_pid do
                send(current.task_pid, :acp_cancel_turn)
                Process.send_after(self(), {:force_kill_turn, current.task_pid}, @cancel_grace_ms)
              end

              state
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

  @impl true
  # The provider session id must be captured even if the turn was just cancelled
  # (so the conversation can still resume) — store it regardless of `current`.
  def handle_info({:turn_event, turn_id, %{type: :provider_session} = event}, state) do
    {:noreply, handle_turn_event(state, turn_id, event)}
  end

  def handle_info({:turn_event, turn_id, event}, state) do
    with %{turn_id: ^turn_id} <- state.current do
      {:noreply, handle_turn_event(state, turn_id, event)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:turn_done, turn_id}, state) do
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
    if is_pid(task_pid) and Process.alive?(task_pid), do: Process.exit(task_pid, :kill)
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

  def handle_info(_msg, state), do: {:noreply, state}

  # Pop the FIFO queue head (if any) and launch it as the next turn. Called on
  # every turn terminal (done/failed/cancelled/crash) — so a mid-turn send that
  # was enqueued runs as soon as the running turn finishes, in send order. A
  # no-op when no turn is in flight is impossible here: callers clear `current`
  # to nil before draining, so the head always launches into an idle session.
  defp drain_queue(%{current: nil, queue: [next | rest]} = state) do
    {_turn_id, state} = launch_turn(next.input, %{state | queue: rest})
    state
  end

  defp drain_queue(state), do: state

  # ── send-turn helpers (FIFO queue) ─────────────────────────────────

  # Backfill the Phase 5 `:queue` key onto a Session GenServer hot-reloaded from
  # before this phase (the live :4000 server recompiles in place, not restarts),
  # so the first send into an upgraded process never crashes on a missing key.
  defp ensure_queue(state), do: Map.put_new(state, :queue, [])

  defp start_turn(input, %{current: current} = state) when current != nil do
    # A turn is already in flight — ENQUEUE rather than cancel (Phase 5 FIFO
    # queue). The pending message drains when the running turn reaches a terminal
    # state. A re-Enter on a queued message flushes it (see `:flush_queue`).
    queued = %{turn_id: Ecto.UUID.generate(), input: input}
    state = %{state | queue: state.queue ++ [queued]}

    state =
      emit(state, %{type: :turn_queued, turn_id: queued.turn_id, pending: length(state.queue)})

    {:reply, {:ok, %{id: queued.turn_id, session_id: state.id, status: :queued}}, state}
  end

  defp start_turn(input, state) do
    {turn_id, state} = launch_turn(input, state)
    {:reply, {:ok, %{id: turn_id, session_id: state.id, status: :running}}, state}
  end

  # Spawn the per-turn streaming task and record it as the current turn. Shared by
  # a fresh send and by draining the FIFO queue on a turn terminal.
  defp launch_turn(input, state) do
    turn_id = Ecto.UUID.generate()
    parent = self()

    task =
      Task.async(fn ->
        run_turn(parent, turn_id, input, state)
      end)

    Process.unlink(task.pid)

    state = %{
      state
      | current: %{
          turn_id: turn_id,
          task_ref: task.ref,
          task_pid: task.pid,
          text: "",
          input: input
        }
    }

    state = emit(state, %{type: :turn_started, turn_id: turn_id, input: input})
    state = maybe_emit_thread_title(state, input)

    {turn_id, state}
  end

  # ── turn streaming (in a Task) ─────────────────────────────────────

  defp run_turn(parent, turn_id, input, state) do
    stream =
      AcpStream.turn_stream(
        state.exmcp_adapter,
        %{
          input: input,
          workspace_root: state.workspace_root,
          document_id: state.document_id,
          # Resume the conversation's provider session on turns 2+ (nil on turn 1)
          # so the agent keeps cross-turn memory.
          provider_session_id: state.provider_session_id
        },
        Keyword.put(state.adapter_opts, :mcp_servers, state.mcp_servers)
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
  defp handle_turn_event(state, _turn_id, %{type: :provider_session, provider_session_id: id})
       when is_binary(id) and id != "" do
    %{state | provider_session_id: id}
  end

  defp handle_turn_event(state, turn_id, %{type: :text_delta, delta: delta})
       when is_binary(delta) do
    current = %{state.current | text: (state.current.text || "") <> delta}

    state
    |> Map.put(:current, current)
    |> emit(%{type: :text_delta, turn_id: turn_id, delta: delta})
  end

  defp handle_turn_event(state, turn_id, %{type: :reasoning_delta, delta: delta})
       when is_binary(delta) do
    emit(state, %{type: :reasoning_delta, turn_id: turn_id, delta: delta})
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_started} = event) do
    emit(state, %{
      type: :tool_call_started,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      arguments: Map.get(event, :arguments, %{})
    })
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_completed} = event) do
    emit(state, %{
      type: :tool_call_completed,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      result: Map.get(event, :result, %{})
    })
  end

  defp handle_turn_event(state, turn_id, %{type: :tool_call_failed} = event) do
    emit(state, %{
      type: :tool_call_failed,
      turn_id: turn_id,
      tool_call_id: event.tool_call_id,
      name: event.name,
      reason: Map.get(event, :reason, "")
    })
  end

  defp handle_turn_event(state, _turn_id, _event), do: state

  # ── helpers ────────────────────────────────────────────────────────

  # Append a finished turn to the display-only transcript (newest-prepended;
  # `transcript/1` reverses to oldest-first). Skips an empty turn (no user text
  # and no agent text) so a no-op turn never leaves a blank pair on repaint.
  defp record_transcript_turn(state, current) do
    # The transcript bubble shows the typed text regardless of input modality
    # (string sugar OR a multi-modal block list), so derive the display text.
    user = Prompt.display_text(current[:input])
    agent = current[:text]

    if blank?(user) and blank?(agent) do
      state
    else
      entry = %{turn_id: current.turn_id, user: user, agent: agent}
      %{state | transcript: [entry | state.transcript]}
    end
  end

  defp blank?(nil), do: true
  defp blank?(text) when is_binary(text), do: String.trim(text) == ""
  defp blank?(_), do: false

  defp public_snapshot(state) do
    %{
      id: state.id,
      owner_id: state.owner_id,
      provider: state.provider,
      document_id: state.document_id,
      workspace_root: state.workspace_root,
      current_turn: state.current && %{id: state.current.turn_id, status: :running}
    }
  end

  # Display-only snapshot for chat-rail repaint after a refresh.
  defp agent_snapshot_payload(state) do
    %{
      transcript: Enum.reverse(state.transcript),
      status: status(state),
      title: state.title,
      # Number of mid-turn sends still queued (Phase 5), so a refresh can repaint
      # the "N 대기" pending state.
      pending: length(state.queue)
    }
  end

  defp status(%{current: nil}), do: :idle
  defp status(_state), do: :running

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
