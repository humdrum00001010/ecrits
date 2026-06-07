defmodule EcritsWeb.Local.AgentChatLive do
  @moduledoc """
  The workspace chat-rail, extracted from `EcritsWeb.Local.WorkspaceLive` into
  its own `live_render`ed child LiveView (Phase 4 of the AgentLive/Session
  migration). It runs in its own process, isolated from the document shell, and
  owns the WHOLE chat thread:

    * the title / status / refresh controls,
    * the streamed message thread (user / agent prose / tool-call + reasoning
      rows, with the per-token client-side appends),
    * the error banner,
    * the message composer (textarea + send/stop), via a colocated `.ChatInput`
      hook (copied from `EcritsWeb.Live.Studio.Components.ChatRail`).

  ## How it binds to the durable agent (refresh-survival, P1)

  The parent `WorkspaceLive` is the AUTHORITY that starts + seeds the durable
  per-path foreground agent (it holds the provider/model/access selection and
  the open document, so only it can seed correctly). This child is a pure
  OBSERVER: it never starts an agent. On mount it polls
  `Ecrits.Workspace.Session.foreground_ws/1` (read-only, never starts anything)
  until the shell has bound the agent, then `subscribe/1`s to the agent's PubSub
  topic and `snapshot/1`s its transcript + status + title. A browser refresh
  re-mounts this child → re-polls → re-subscribes → repaints the durable
  transcript, exactly as the inline rail did before the extraction.

  The provider/model/reasoning/access selectors, the document-import upload and
  the provider-config modal stay in `WorkspaceLive`: they are URL-param-driven
  workspace settings (and a child LiveView cannot `push_patch` the top-level
  URL) and a document-pane concern, so they remain with the shell. This child
  applies NONE of them; it only renders + drives the chat thread.
  """

  use EcritsWeb, :live_view

  alias Ecrits.Workspace.Session, as: WorkspaceSession
  alias EcritsWeb.Live.Studio.Components.ChatRail

  # Debounce interval for re-rendering the streaming agent message body as
  # formatted markdown (raw client-side appends give instant sub-debounce
  # feedback; the tick re-renders the accumulated buffer through MDEx).
  @local_agent_text_flush_ms 120
  # Poll interval while waiting for the document shell to start + seed the
  # durable foreground agent (we never start it ourselves).
  @agent_sync_interval_ms 150

  @impl true
  def mount(_params, session, socket) do
    workspace_path = session["workspace_path"]

    {:ok,
     socket
     |> assign(:workspace_path, workspace_path)
     |> assign(:workspace_session, nil)
     # NAMED capture (not an anon closure): a stream `dom_id` resolver stored on
     # the long-lived LiveView. A remote capture `&__MODULE__.fun/1` is resolved
     # by name at call time and survives dev hot-reloads, unlike an anonymous
     # `& &1.dom_id` compiled into this module (which goes stale on recompile).
     |> stream_configure(:local_agent_items, dom_id: &__MODULE__.local_agent_item_dom_id/1)
     |> stream(:local_agent_items, [])
     |> assign(:local_agent_session_id, nil)
     |> assign(:local_agent_status, :starting)
     |> assign(:local_agent_error, nil)
     |> assign(:local_agent_turn_id, nil)
     # Count of mid-turn sends still queued behind the running turn (Phase 5
     # FIFO queue). Drives the "N 대기" pending indicator; decremented as each
     # queued turn drains.
     |> assign(:local_agent_pending, 0)
     |> assign(:local_agent_text, "")
     |> assign(:local_agent_text_segment, 0)
     |> assign(:local_agent_text_flush_ref, nil)
     |> assign(:local_agent_active_tools, %{})
     |> assign(:local_agent_reasoning_text, "")
     # Tracks whether reasoning text is being appended contiguously (codex glues
     # reasoning items with no separator); we insert a paragraph break when a new
     # item resumes after a non-reasoning event.
     |> assign(:local_agent_reasoning_open?, false)
     |> assign(:local_agent_title, default_local_agent_title())
     |> assign(:local_agent_title_user_edited?, false)
     |> assign(:local_agent_title_form, local_agent_title_form())
     |> assign(:local_agent_form, local_agent_form())
     |> maybe_schedule_agent_sync()}
  end

  # ── chat events ────────────────────────────────────────────────────

  @impl true
  def handle_event(
        "update_local_agent_title",
        %{"local_agent_title" => %{"title" => title}},
        socket
      ) do
    # Persist the rename on the durable foreground agent so it survives a refresh
    # (and pins the auto-title). No-op before the agent is bound.
    if w = ws(socket), do: WorkspaceSession.rename(w, title)

    {:noreply,
     socket
     |> assign(:local_agent_title_user_edited?, true)
     |> assign_local_agent_title(title)}
  end

  def handle_event("refresh_local_agent", _params, socket) do
    {:noreply, restart_local_agent_session(socket)}
  end

  # The composer sends via the colocated `.ChatInput` hook (pushEvent), so the
  # payload is a flat `%{"message" => ...}` (no nested form params).
  def handle_event("send_local_agent", %{"message" => message}, socket) do
    handle_send(socket, message)
  end

  def handle_event("send_local_agent", %{"agent" => %{"message" => message}}, socket) do
    handle_send(socket, message)
  end

  def handle_event("cancel_local_agent", _params, socket) do
    turn_id = socket.assigns.local_agent_turn_id

    if ws(socket) && turn_id do
      case WorkspaceSession.cancel(ws(socket), turn_id) do
        {:ok, _turn} ->
          partial = socket.assigns.local_agent_text
          segment = socket.assigns.local_agent_text_segment

          {:noreply,
           socket
           |> assign(:local_agent_status, :cancelled)
           |> assign(:local_agent_turn_id, nil)
           |> assign(:local_agent_text, "")
           |> finalize_cancelled_agent_text(turn_id, partial, segment)
           |> finalize_dangling_tools("Turn cancelled.")}

        {:error, reason} ->
          {:noreply, assign(socket, :local_agent_error, local_agent_error(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  defp handle_send(socket, message) do
    message = String.trim(message || "")

    cond do
      # Re-Enter gesture (Phase 5 FIFO queue): an empty Enter while a message is
      # queued FLUSHES the head — cancel the in-flight turn and run the next
      # queued message NOW instead of waiting for the running turn to finish.
      message == "" and socket.assigns.local_agent_pending > 0 ->
        flush_local_agent_queue(socket)

      message == "" ->
        {:noreply, assign(socket, :local_agent_form, local_agent_form())}

      is_nil(socket.assigns.local_agent_session_id) ->
        {:noreply, assign(socket, :local_agent_error, "Agent session is not ready.")}

      # A turn is in flight (or a message is already queued): ENQUEUE this send
      # behind the running turn rather than cancelling it (Phase 5). It drains in
      # order when the running turn finishes.
      socket.assigns.local_agent_status == :running or socket.assigns.local_agent_pending > 0 ->
        enqueue_local_agent_turn(socket, message)

      true ->
        send_local_agent_turn(socket, message)
    end
  end

  # Enqueue a mid-turn send: record the user bubble immediately (so the user sees
  # their message), bump the pending count, and let the durable agent drain it
  # when the running turn terminates. The placeholders (reasoning / assistant
  # bubble) are rendered later, when the queued turn actually drains (its
  # `turn_started` event arrives with `local_agent_turn_id` nil).
  defp enqueue_local_agent_turn(socket, message) do
    case WorkspaceSession.send_turn(ws(socket), message) do
      {:ok, %{id: queued_id}} ->
        {:noreply,
         socket
         |> stream_insert(:local_agent_items, agent_user_item(queued_id, message))
         |> assign(:local_agent_pending, socket.assigns.local_agent_pending + 1)
         |> assign(:local_agent_error, nil)
         |> assign(:local_agent_form, local_agent_form())}

      {:error, reason} ->
        {:noreply, assign(socket, :local_agent_error, local_agent_error(reason))}
    end
  end

  defp flush_local_agent_queue(socket) do
    case WorkspaceSession.flush_queue(ws(socket)) do
      {:ok, _turn} ->
        {:noreply, assign(socket, :local_agent_form, local_agent_form())}

      {:error, :empty_queue} ->
        {:noreply, assign(socket, :local_agent_pending, 0)}

      {:error, reason} ->
        {:noreply, assign(socket, :local_agent_error, local_agent_error(reason))}
    end
  end

  # ── streaming + lifecycle ──────────────────────────────────────────

  @impl true
  # Poll for the shell-started foreground agent. Until it exists we stay
  # :starting; once bound we subscribe + snapshot ONCE, then stop polling.
  def handle_info(:sync_agent, socket) do
    {:noreply, sync_agent(socket)}
  end

  def handle_info({:local_agent_event, %{session_id: session_id} = event}, socket)
      when session_id == socket.assigns.local_agent_session_id do
    # Close the contiguous-reasoning run on any non-reasoning event so the NEXT
    # reasoning delta starts a fresh paragraph (codex glues reasoning items).
    socket =
      case event do
        %{type: :reasoning_delta} -> socket
        _ -> assign(socket, :local_agent_reasoning_open?, false)
      end

    {:noreply, apply_local_agent_event(socket, event)}
  end

  def handle_info({:local_agent_event, _event}, socket), do: {:noreply, socket}

  # Debounced re-render of the in-flight streaming agent message: re-renders the
  # accumulated buffer through `markdown_body`/MDEx so LiveView pushes formatted
  # HTML that replaces the raw client-side appends.
  def handle_info({:flush_local_agent_text, ref}, socket) do
    if socket.assigns.local_agent_text_flush_ref == ref do
      {:noreply, flush_local_agent_text(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── agent binding (observer; never starts the agent) ───────────────

  defp maybe_schedule_agent_sync(socket) do
    if connected?(socket) and is_binary(socket.assigns.workspace_path) do
      send(self(), :sync_agent)
      socket
    else
      socket
    end
  end

  defp sync_agent(%{assigns: %{local_agent_session_id: id}} = socket) when is_binary(id),
    do: socket

  defp sync_agent(socket) do
    case safe_foreground_ws(socket.assigns.workspace_path) do
      %{agent_id: agent_id} = ws when is_binary(agent_id) ->
        :ok = WorkspaceSession.subscribe(ws)
        snapshot = WorkspaceSession.snapshot(ws)

        socket
        |> assign(:workspace_session, ws)
        |> assign(:local_agent_session_id, agent_id)
        |> assign(:local_agent_error, nil)
        |> assign(:local_agent_status, snapshot.status)
        # Restore the pending-queue count after a refresh (Phase 5). A snapshot
        # from a pre-Phase-5 agent has no `:pending` key → default 0.
        |> assign(:local_agent_pending, Map.get(snapshot, :pending, 0))
        |> maybe_restore_agent_title(snapshot.title)
        |> stream(:local_agent_items, [], reset: true)
        # codex `thread/resume` restores MEMORY but does NOT re-stream past
        # messages, so without this the re-attached pane is blank. Repaint the
        # prior bubbles from the durable transcript.
        |> replay_local_agent_transcript(snapshot.transcript)

      _ ->
        # Shell hasn't started + seeded the foreground agent yet; poll again.
        Process.send_after(self(), :sync_agent, @agent_sync_interval_ms)
        socket
    end
  end

  defp safe_foreground_ws(path) when is_binary(path) and path != "" do
    WorkspaceSession.foreground_ws(path)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp safe_foreground_ws(_path), do: nil

  # The workspace Session handle (delegates send/cancel/rename to the foreground
  # agent), or nil before the agent is bound.
  defp ws(%{assigns: %{workspace_session: %{} = ws}}), do: ws
  defp ws(_socket), do: nil

  # Restore the chat header from the durable agent's retained title (after a
  # refresh). A brand-new agent has no title yet (keep the "New Chat" default).
  defp maybe_restore_agent_title(socket, title) when is_binary(title) and title != "" do
    socket
    |> assign(:local_agent_title_user_edited?, true)
    |> assign_local_agent_title(title)
  end

  defp maybe_restore_agent_title(socket, _title), do: socket

  # Repaint the chat pane from the durable agent's display-only transcript (used
  # after a browser refresh re-binds the foreground agent). Each completed turn
  # was stored as %{turn_id, user, agent}; re-stream one user + one agent bubble
  # per turn using the SAME dom-id scheme live turns use (so a later live turn
  # with the same id reconciles rather than duplicating).
  defp replay_local_agent_transcript(socket, turns) when is_list(turns) do
    Enum.reduce(turns, socket, fn turn, acc ->
      acc
      |> maybe_stream_transcript_user(turn)
      |> maybe_stream_transcript_agent(turn)
    end)
  end

  defp replay_local_agent_transcript(socket, _turns), do: socket

  defp maybe_stream_transcript_user(socket, %{turn_id: turn_id, user: user})
       when is_binary(user) and user != "" do
    stream_insert(socket, :local_agent_items, agent_user_item(turn_id, user))
  end

  defp maybe_stream_transcript_user(socket, _turn), do: socket

  defp maybe_stream_transcript_agent(socket, %{turn_id: turn_id, agent: agent})
       when is_binary(agent) and agent != "" do
    stream_insert(socket, :local_agent_items, agent_assistant_item(turn_id, agent, :sent))
  end

  defp maybe_stream_transcript_agent(socket, _turn), do: socket

  # Re-sync the chat-rail to the durable foreground agent. The path-keyed Session
  # owns the agent, so "refresh chat" just clears the pane locally and repaints
  # from the (now possibly empty) live transcript — it does NOT tear down the
  # agent (no provider-thread loss).
  defp restart_local_agent_session(socket) do
    _ = maybe_cancel_active_local_agent(socket)

    socket
    |> assign(:local_agent_session_id, nil)
    |> assign(:local_agent_turn_id, nil)
    |> assign(:local_agent_text, "")
    |> assign(:local_agent_text_segment, 0)
    |> assign(:local_agent_reasoning_text, "")
    |> assign(:local_agent_title_user_edited?, false)
    |> assign_local_agent_title(default_local_agent_title())
    |> assign(:local_agent_form, local_agent_form())
    |> stream(:local_agent_items, [], reset: true)
    |> sync_agent()
  end

  defp maybe_cancel_active_local_agent(%{
         assigns: %{workspace_session: %{} = ws, local_agent_turn_id: turn_id}
       })
       when is_binary(turn_id) do
    _ = WorkspaceSession.cancel(ws, turn_id)
    :ok
  end

  defp maybe_cancel_active_local_agent(_socket), do: :ok

  defp send_local_agent_turn(socket, message) do
    case WorkspaceSession.send_turn(ws(socket), message) do
      {:ok, %{id: turn_id}} ->
        {:noreply,
         socket
         |> stream_insert(:local_agent_items, agent_user_item(turn_id, message))
         |> stream_insert(:local_agent_items, agent_reasoning_item(turn_id, "", :pending))
         |> stream_insert(:local_agent_items, agent_assistant_item(turn_id, "", :running, 0))
         |> assign(:local_agent_turn_id, turn_id)
         |> assign(:local_agent_text, "")
         |> assign(:local_agent_text_segment, 0)
         |> assign(:local_agent_reasoning_text, "")
         |> assign(:local_agent_status, :running)
         |> assign(:local_agent_error, nil)
         |> assign(:local_agent_form, local_agent_form())}

      {:error, reason} ->
        {:noreply, assign(socket, :local_agent_error, local_agent_error(reason))}
    end
  end

  # A mid-turn send was enqueued behind the running turn (Phase 5). The agent is
  # the source of truth for the pending count; sync it from the event so a flush
  # / drain elsewhere never drifts the indicator.
  defp apply_local_agent_event(socket, %{type: :turn_queued, pending: pending})
       when is_integer(pending) do
    assign(socket, :local_agent_pending, pending)
  end

  # `send_local_agent_turn/2` already set `local_agent_turn_id` (and :running)
  # from the synchronous send_turn reply, which carries the SAME id this event
  # echoes. So a turn_started whose id != the current turn is stale and must be
  # ignored; the catch-all clause drops the rest.
  defp apply_local_agent_event(
         %{assigns: %{local_agent_turn_id: turn_id}} = socket,
         %{type: :turn_started, turn_id: turn_id}
       ) do
    socket
    |> assign(:local_agent_turn_id, turn_id)
    |> assign(:local_agent_status, :running)
  end

  # A QUEUED turn just drained (Phase 5): `local_agent_turn_id` was nil (the prior
  # turn cleared it) and this is a fresh id. The user bubble was already rendered
  # when the message was enqueued; render the reasoning + assistant placeholders
  # now (the synchronous send path renders them for a non-queued turn, so the
  # adopt path renders them for a drained one), reset the per-turn buffers, and
  # decrement the pending count.
  defp apply_local_agent_event(
         %{assigns: %{local_agent_turn_id: nil}} = socket,
         %{type: :turn_started, turn_id: turn_id}
       )
       when is_binary(turn_id) do
    socket
    |> assign(:local_agent_turn_id, turn_id)
    |> assign(:local_agent_status, :running)
    |> assign(:local_agent_text, "")
    |> assign(:local_agent_text_segment, 0)
    |> assign(:local_agent_reasoning_text, "")
    |> assign(:local_agent_pending, max(socket.assigns.local_agent_pending - 1, 0))
    |> stream_insert(:local_agent_items, agent_reasoning_item(turn_id, "", :pending))
    |> stream_insert(:local_agent_items, agent_assistant_item(turn_id, "", :running, 0))
  end

  defp apply_local_agent_event(socket, %{type: type, title: title})
       when type in [:title_generated, :title_updated, :thread_title] and is_binary(title) do
    if socket.assigns.local_agent_title_user_edited? do
      socket
    else
      assign_local_agent_title(socket, title)
    end
  end

  defp apply_local_agent_event(
         %{assigns: %{local_agent_turn_id: turn_id}} = socket,
         %{type: :text_delta, turn_id: turn_id, delta: delta}
       )
       when is_binary(delta) do
    text = socket.assigns.local_agent_text <> delta
    segment = socket.assigns.local_agent_text_segment

    socket
    |> assign(:local_agent_text, text)
    |> push_event("local_agent_text_append", %{
      message_id: agent_assistant_dom_id(turn_id, segment),
      piece: String.replace(delta, ~r/\n{2,}/, "\n")
    })
    |> schedule_local_agent_text_flush()
  end

  defp apply_local_agent_event(
         %{assigns: %{local_agent_turn_id: turn_id}} = socket,
         %{type: :reasoning_delta, turn_id: turn_id, delta: delta}
       )
       when is_binary(delta) do
    prev = socket.assigns.local_agent_reasoning_text

    # New reasoning item resuming after a tool call / other event: separate it
    # from the previous item with a paragraph break. Contiguous deltas within one
    # item append raw.
    piece =
      if socket.assigns[:local_agent_reasoning_open?] or prev == "",
        do: delta,
        else: "\n\n" <> delta

    socket
    |> assign(:local_agent_reasoning_text, prev <> piece)
    |> assign(:local_agent_reasoning_open?, true)
    |> push_event("local_agent_reasoning_append", %{
      message_id: agent_reasoning_dom_id(turn_id),
      piece: piece
    })
  end

  defp apply_local_agent_event(socket, %{
         type: :tool_call_started,
         tool_call_id: tool_call_id,
         name: name,
         arguments: arguments
       }) do
    socket
    |> close_local_agent_text_segment()
    |> maybe_remove_empty_agent_placeholder()
    |> update(:local_agent_active_tools, &Map.put(&1 || %{}, tool_call_id, name))
    |> stream_insert(
      :local_agent_items,
      agent_tool_item(tool_call_id, name, :running, agent_tool_payload(arguments))
    )
  end

  defp apply_local_agent_event(socket, %{
         type: :tool_call_completed,
         tool_call_id: tool_call_id,
         name: name,
         result: result
       }) do
    socket
    |> update(:local_agent_active_tools, &Map.delete(&1 || %{}, tool_call_id))
    |> stream_insert(
      :local_agent_items,
      agent_tool_item(tool_call_id, name, :completed, agent_tool_payload(result))
    )
  end

  defp apply_local_agent_event(socket, %{
         type: :tool_call_failed,
         tool_call_id: tool_call_id,
         name: name,
         reason: reason
       }) do
    socket
    |> update(:local_agent_active_tools, &Map.delete(&1 || %{}, tool_call_id))
    |> stream_insert(:local_agent_items, agent_tool_item(tool_call_id, name, :failed, reason))
  end

  defp apply_local_agent_event(socket, %{
         type: :tool_approval_required,
         tool_call_id: tool_call_id,
         name: name,
         arguments: arguments
       }) do
    stream_insert(
      socket |> maybe_remove_empty_agent_placeholder(),
      :local_agent_items,
      agent_tool_item(tool_call_id, name, :approval_required, agent_tool_payload(arguments))
    )
  end

  defp apply_local_agent_event(
         %{assigns: %{local_agent_turn_id: turn_id}} = socket,
         %{type: :turn_completed, turn_id: turn_id}
       ) do
    # Flush ONLY the still-pending text segment (text streamed AFTER the last
    # tool call). Every earlier segment was already emitted at its tool boundary
    # by close_local_agent_text_segment/1. Use the per-segment buffer (which
    # resets at each tool boundary) rather than the session's CUMULATIVE turn
    # text, which would overwrite the final bubble with the whole turn.
    pending = socket.assigns.local_agent_text

    socket
    |> cancel_local_agent_text_flush()
    |> assign(:local_agent_turn_id, nil)
    |> assign(:local_agent_text, "")
    |> assign(:local_agent_status, :idle)
    |> maybe_remove_empty_reasoning(turn_id)
    |> assign(:local_agent_reasoning_text, "")
    |> maybe_stream_final_agent_text(turn_id, pending)
    |> finalize_dangling_tools("Turn ended before the tool finished.")
  end

  defp apply_local_agent_event(
         %{assigns: %{local_agent_turn_id: turn_id}} = socket,
         %{type: :turn_failed, turn_id: turn_id, reason: reason}
       ) do
    socket
    |> cancel_local_agent_text_flush()
    |> assign(:local_agent_turn_id, nil)
    |> assign(:local_agent_text, "")
    |> assign(:local_agent_status, :failed)
    |> assign(:local_agent_error, local_agent_error(reason))
    |> maybe_remove_empty_reasoning(turn_id)
    |> assign(:local_agent_reasoning_text, "")
    |> stream_insert(:local_agent_items, agent_assistant_item(turn_id, "Agent failed.", :failed))
    |> finalize_dangling_tools("Turn failed.")
  end

  defp apply_local_agent_event(%{assigns: %{local_agent_turn_id: turn_id}} = socket, %{
         type: :turn_cancelled,
         turn_id: turn_id
       }) do
    partial = socket.assigns.local_agent_text
    segment = socket.assigns.local_agent_text_segment

    socket
    |> cancel_local_agent_text_flush()
    |> assign(:local_agent_turn_id, nil)
    |> assign(:local_agent_text, "")
    |> assign(:local_agent_status, :cancelled)
    |> maybe_remove_empty_reasoning(turn_id)
    |> assign(:local_agent_reasoning_text, "")
    |> finalize_cancelled_agent_text(turn_id, partial, segment)
    |> finalize_dangling_tools("Turn cancelled.")
  end

  defp apply_local_agent_event(socket, %{type: :turn_cancelled}), do: socket
  defp apply_local_agent_event(socket, _event), do: socket

  # ── render ─────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="local-agent-chat"
      data-component="chat-rail-thread"
      data-session-id={@local_agent_session_id || ""}
      data-agent-status={to_string(@local_agent_status)}
      class="flex min-h-0 flex-1 flex-col overflow-visible"
    >
      <div
        data-role="chat-rail-controls"
        class="flex shrink-0 items-center justify-between gap-1.5 border-b border-base-300 bg-base-200/95 px-1.5 py-0.5"
      >
        <div
          id="local-agent-title"
          data-role="chat-thread-title"
          title={@local_agent_title}
          class="flex min-w-0 flex-1 items-center gap-1.5 text-sm font-semibold leading-5 text-base-content"
        >
          <.form
            for={@local_agent_title_form}
            id="local-agent-title-form"
            phx-change="update_local_agent_title"
            data-role="chat-thread-title-form"
            class="min-w-0 flex-1"
          >
            <input
              id="local-agent-title-label"
              name={@local_agent_title_form[:title].name}
              value={@local_agent_title}
              type="text"
              autocomplete="off"
              maxlength="120"
              aria-label="Chat title"
              data-role="chat-thread-title-label"
              class="block h-6 w-full min-w-0 truncate rounded-sm border border-transparent bg-transparent px-1 py-0 text-sm font-semibold leading-6 text-base-content outline-none transition-colors placeholder:text-transparent hover:border-base-content/15 focus:border-base-content/35 focus:bg-base-100 focus:outline-none"
            />
          </.form>
        </div>
        <span
          id="local-agent-status"
          data-role="local-agent-status"
          aria-live="polite"
          class="sr-only"
        >
          {agent_status_label(@local_agent_status)}
        </span>
        <span
          :if={@local_agent_pending > 0}
          id="local-agent-pending"
          data-role="local-agent-pending"
          data-pending={@local_agent_pending}
          aria-live="polite"
          title="Queued messages waiting for the current turn"
          class="inline-flex h-5 shrink-0 items-center rounded-full border border-base-content/20 bg-base-100 px-2 text-[11px] font-medium text-base-content/70"
        >
          {@local_agent_pending} 대기
        </span>
        <button
          id="local-mobile-open-document"
          type="button"
          data-role="mobile-open-document"
          aria-controls="local-editor-shell local-agent-sidebar"
          aria-pressed="false"
          class="inline-flex h-7 shrink-0 items-center gap-1 rounded border border-base-300 bg-base-100 px-2 text-xs text-base-content/70 transition-colors hover:border-base-content/25 hover:text-base-content lg:hidden"
        >
          <.icon name="hero-document-text" class="size-3.5" />
          <span>Document</span>
        </button>
        <button
          id="local-agent-refresh"
          type="button"
          phx-click="refresh_local_agent"
          class="inline-flex size-7 shrink-0 items-center justify-center rounded text-base-content/55 hover:bg-base-100 hover:text-base-content disabled:pointer-events-none disabled:opacity-45"
          aria-label="Refresh agent chat"
          disabled={@local_agent_status == :starting}
        >
          <.icon name="hero-arrow-path" class="size-4" />
        </button>
      </div>

      <div data-role="chat-rail-body" class="flex min-h-0 flex-1 flex-col overflow-visible">
        <div
          id="local-agent-thread"
          phx-update="stream"
          data-role="chat-stream"
          class="flex min-h-0 flex-1 flex-col items-stretch gap-3 overflow-x-hidden overflow-y-auto px-4 py-3"
        >
          <article
            :for={{dom_id, item} <- @streams.local_agent_items}
            id={dom_id}
            data-role={agent_item_data_role(item)}
            data-chat-role="chat-message"
            data-message-role={agent_item_role(item)}
            data-message-status={agent_item_status(item)}
            class={agent_item_class(item)}
          >
            <%= case agent_item_role(item) do %>
              <% "tool" -> %>
                <div
                  data-role="operation-block"
                  class="min-w-0 px-3 py-1 text-[12px] text-base-content/60"
                >
                  <button
                    id={"#{dom_id}-toggle"}
                    type="button"
                    aria-expanded="false"
                    aria-controls={"#{dom_id}-details"}
                    phx-click={
                      JS.toggle_attribute({"hidden", "hidden"}, to: "##{dom_id}-details")
                      |> JS.toggle_attribute({"aria-expanded", "true", "false"})
                    }
                    class="flex w-full min-w-0 items-center gap-1.5 text-left hover:text-base-content"
                  >
                    <.icon name="hero-wrench-screwdriver" class="size-3.5 shrink-0" />
                    <span class="shrink-0">Tool:</span>
                    <span class="min-w-0 truncate font-mono">{agent_item_title(item)}</span>
                    <span class="ml-auto shrink-0 text-[11px] text-base-content/45">
                      {agent_item_status_label(item)}
                    </span>
                    <.icon name="hero-chevron-down" class="size-3 shrink-0 text-base-content/45" />
                  </button>
                  <div
                    id={"#{dom_id}-details"}
                    data-role="operation-details"
                    hidden
                    class="mt-1 border-l border-base-300 pl-3"
                  >
                    <pre class="whitespace-pre-wrap break-words font-mono text-[11px] leading-relaxed text-base-content/55">{agent_item_body(item)}</pre>
                  </div>
                </div>
              <% "thinking" -> %>
                <div
                  data-role="operation-block"
                  class="min-w-0 px-3 py-1 text-[12px] text-base-content/60"
                >
                  <button
                    id={"#{dom_id}-toggle"}
                    type="button"
                    aria-expanded="false"
                    aria-controls={"#{dom_id}-details"}
                    phx-click={
                      JS.toggle_attribute({"hidden", "hidden"}, to: "##{dom_id}-details")
                      |> JS.toggle_attribute({"aria-expanded", "true", "false"})
                    }
                    class="flex w-full min-w-0 items-center gap-1.5 text-left hover:text-base-content"
                  >
                    <.icon name="hero-light-bulb" class="size-3.5 shrink-0" />
                    <span class="shrink-0">Thinking:</span>
                    <span
                      data-role="agent-reasoning-text"
                      data-message-id={dom_id}
                      class="min-w-0 truncate"
                    >
                      {agent_item_body(item)}
                    </span>
                    <.icon
                      name="hero-chevron-down"
                      class="ml-auto size-3 shrink-0 text-base-content/45"
                    />
                  </button>
                  <div
                    id={"#{dom_id}-details"}
                    data-role="operation-details"
                    hidden
                    class="mt-1 border-l border-base-300 pl-3"
                  >
                    <pre class="whitespace-pre-wrap break-words text-[11px] leading-relaxed text-base-content/55"><span
                        data-role="agent-reasoning-details-text"
                        data-message-id={dom_id}
                      >{agent_item_body(item)}</span></pre>
                  </div>
                </div>
              <% "user" -> %>
                <div
                  data-role="chat-message-body"
                  class="min-w-0 w-full border border-base-content/10 bg-base-300/50 px-3 py-1.5 text-[13px] leading-snug whitespace-normal break-words text-base-content/95 shadow-[inset_0_1px_3px_rgba(0,0,0,0.10)]"
                >
                  <ChatRail.markdown_body
                    body={agent_item_body(item)}
                    paragraph_role="chat-md-paragraph"
                  />
                </div>
              <% _ -> %>
                <div
                  data-role="agent-text"
                  data-message-id={dom_id}
                  aria-busy={agent_item_status(item) == "running"}
                  class="block min-w-0 px-3 py-1 text-[14px] leading-relaxed text-justify break-words text-base-content"
                >
                  <div data-role="agent-text-body" data-message-id={dom_id}>
                    <ChatRail.markdown_body
                      body={agent_item_body(item)}
                      paragraph_role="agent-paragraph"
                    />
                  </div>
                  <span
                    :if={agent_item_loading?(item)}
                    id={"#{dom_id}-loading"}
                    phx-update="ignore"
                    data-role="agent-loading"
                    role="status"
                    aria-label="Agent responding"
                    class="ml-1 inline-flex h-4 translate-y-[0.125rem] items-end gap-0.5 align-baseline text-base-content/45"
                  >
                    <span
                      aria-hidden="true"
                      style="animation-delay:-0.36s"
                      class="size-1 rounded-full bg-current chat-typing-dot"
                    >
                    </span>
                    <span
                      aria-hidden="true"
                      style="animation-delay:-0.18s"
                      class="size-1 rounded-full bg-current chat-typing-dot"
                    >
                    </span>
                    <span aria-hidden="true" class="size-1 rounded-full bg-current chat-typing-dot">
                    </span>
                  </span>
                </div>
            <% end %>
          </article>
        </div>

        <p
          :if={@local_agent_error}
          id="local-agent-error"
          class="mx-3 mb-3 rounded border border-error/25 bg-error/10 px-3 py-2 text-sm text-error"
        >
          {@local_agent_error}
        </p>

        <div class="shrink-0 border-t border-base-300 bg-base-200 px-3 py-2">
          <div class="rounded border border-base-300 bg-base-100 transition-colors focus-within:border-base-content/40">
            <%!-- No `phx-submit` here — the colocated `.ChatInput` hook is the
                 single source of truth for sending (pushEvent). A native submit
                 would also trip the parent grid hook's capture-phase submit
                 guard, whose `agentSubmitPending` flag only clears on the PARENT
                 LiveView's `updated()` — which no longer fires for a chat send
                 now that the composer lives in this child. So we send via the
                 hook and never emit a native submit. --%>
            <form
              id="local-agent-form"
              phx-hook=".ChatInput"
              data-role="chat-form"
              autocomplete="off"
            >
              <input
                id="local-agent-input"
                name="message"
                type="text"
                autocomplete="off"
                data-role="chat-textarea"
                disabled={@local_agent_status in [:offline, :starting]}
                placeholder={agent_input_placeholder(@local_agent_status)}
                class="block h-8 w-full border-0 bg-transparent px-3 py-1 text-[13px] leading-snug text-base-content outline-none placeholder:text-base-content/35 focus:outline-none focus:ring-0 disabled:cursor-not-allowed disabled:text-base-content/40"
              />
              <div class="flex items-center justify-end gap-1 px-2 pb-1.5 pt-0.5">
                <button
                  :if={@local_agent_status == :running}
                  id="local-agent-stop"
                  type="button"
                  phx-click="cancel_local_agent"
                  data-role="chat-stop"
                  data-action="stop"
                  class="inline-flex size-6 items-center justify-center rounded bg-base-content text-base-100 transition-colors hover:bg-base-content/80"
                  aria-label="Stop agent turn"
                >
                  <.icon name="hero-stop" class="size-3.5" />
                  <span class="sr-only">Stop</span>
                </button>
                <button
                  :if={@local_agent_status != :running}
                  id="local-agent-submit"
                  type="button"
                  data-role="chat-send"
                  data-action="send"
                  disabled={@local_agent_status in [:offline, :starting]}
                  class="inline-flex size-6 items-center justify-center rounded text-base-content/45 transition-colors hover:text-base-content disabled:cursor-not-allowed disabled:opacity-35"
                  aria-label="Send"
                >
                  <.icon name="hero-paper-airplane" class="size-3.5" />
                  <span class="sr-only">Send</span>
                </button>
              </div>
            </form>
          </div>
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatInput">
        export default {
          mounted() {
            this.form = this.el

            // Resolve the live input each call — morphdom may swap the node
            // across patches, so a cached ref can go stale.
            const input = () => this.form.querySelector('[data-role="chat-textarea"]')

            this.send = (e) => {
              if (e) e.preventDefault()
              const el = input()
              if (!el) return
              const value = el.value
              if (!value || !value.trim()) return
              this.pushEvent("send_local_agent", { message: value })
              el.value = ""
              // Keep focus on the input so the keyboard never hides mid-thread.
              el.focus({ preventScroll: true })
            }

            // Event delegation on the stable <form> node — robust against
            // morphdom replacing the button or input subtree (listeners on
            // direct refs would silently break after a patch).
            this.onFormKeydown = (e) => {
              if (e.target.matches('[data-role="chat-textarea"]')
                  && e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                this.send(e)
              }
            }

            // Send on pointerdown (with preventDefault to keep input focus so
            // the mobile keyboard stays open), de-duped against the click.
            this.onFormPointerDown = (e) => {
              const btn = e.target.closest('[data-role="chat-send"]')
              if (!btn || !this.form.contains(btn)) return
              e.preventDefault()
              if (e.type === "mousedown" && this._sendPressSent) return
              this._sendPressSent = true
              clearTimeout(this._sendPressTimer)
              this._sendPressTimer = setTimeout(() => { this._sendPressSent = false }, 400)
              this.send(e)
            }

            this.onFormClick = (e) => {
              const btn = e.target.closest('[data-role="chat-send"]')
              if (!btn || !this.form.contains(btn)) return
              if (this._sendPressSent) {
                e.preventDefault()
                this._sendPressSent = false
                return
              }
              this.send(e)
            }

            // Belt-and-braces: if anything ever fires a native submit, send via
            // the hook and swallow it (no double user bubble).
            this.onFormSubmit = (e) => this.send(e)

            this.form.addEventListener("keydown", this.onFormKeydown)
            this.form.addEventListener("pointerdown", this.onFormPointerDown)
            this.form.addEventListener("mousedown", this.onFormPointerDown)
            this.form.addEventListener("click", this.onFormClick)
            this.form.addEventListener("submit", this.onFormSubmit)
          },
          destroyed() {
            clearTimeout(this._sendPressTimer)
            if (!this.form) return
            this.form.removeEventListener("keydown", this.onFormKeydown)
            this.form.removeEventListener("pointerdown", this.onFormPointerDown)
            this.form.removeEventListener("mousedown", this.onFormPointerDown)
            this.form.removeEventListener("click", this.onFormClick)
            this.form.removeEventListener("submit", this.onFormSubmit)
          }
        }
      </script>
    </div>
    """
  end

  # ── streaming text buffer helpers ──────────────────────────────────

  defp close_local_agent_text_segment(socket) do
    socket = cancel_local_agent_text_flush(socket)

    case socket.assigns.local_agent_text do
      text when is_binary(text) and text != "" ->
        turn_id = socket.assigns.local_agent_turn_id
        segment = socket.assigns.local_agent_text_segment

        socket
        |> stream_insert(:local_agent_items, agent_assistant_item(turn_id, text, :sent, segment))
        |> assign(:local_agent_text, "")
        |> assign(:local_agent_text_segment, segment + 1)

      _empty ->
        socket
    end
  end

  # Coalesces streaming text deltas into a single debounced re-render. A
  # monotonic ref guards a flush that fires after the buffer was already
  # finalized (tool boundary / turn completion). Only one timer is outstanding;
  # while it is pending, new deltas extend the buffer and it renders the latest.
  defp schedule_local_agent_text_flush(socket) do
    if socket.assigns.local_agent_text_flush_ref do
      socket
    else
      ref = make_ref()
      Process.send_after(self(), {:flush_local_agent_text, ref}, @local_agent_text_flush_ms)
      assign(socket, :local_agent_text_flush_ref, ref)
    end
  end

  defp flush_local_agent_text(socket) do
    socket = assign(socket, :local_agent_text_flush_ref, nil)

    case socket.assigns.local_agent_text do
      text when is_binary(text) and text != "" ->
        turn_id = socket.assigns.local_agent_turn_id
        segment = socket.assigns.local_agent_text_segment

        stream_insert(
          socket,
          :local_agent_items,
          agent_assistant_item(turn_id, text, :running, segment)
        )

      _empty ->
        socket
    end
  end

  defp cancel_local_agent_text_flush(socket) do
    assign(socket, :local_agent_text_flush_ref, nil)
  end

  defp maybe_remove_empty_reasoning(socket, turn_id) do
    case socket.assigns.local_agent_reasoning_text do
      "" -> stream_delete(socket, :local_agent_items, agent_reasoning_item(turn_id, "", :pending))
      _text -> socket
    end
  end

  defp maybe_remove_empty_agent_placeholder(socket) do
    case socket.assigns.local_agent_text do
      "" ->
        stream_delete(
          socket,
          :local_agent_items,
          agent_assistant_item(
            socket.assigns.local_agent_turn_id,
            "",
            :running,
            socket.assigns.local_agent_text_segment
          )
        )

      _text ->
        socket
    end
  end

  defp maybe_stream_final_agent_text(socket, turn_id, text) when is_binary(text) and text != "" do
    stream_insert(
      socket,
      :local_agent_items,
      agent_assistant_item(turn_id, text, :sent, socket.assigns.local_agent_text_segment)
    )
  end

  defp maybe_stream_final_agent_text(socket, _turn_id, _text), do: socket

  # On cancel, keep what the agent already streamed (finalize the in-flight
  # bubble with the accumulated partial, in place). Do NOT emit a "Cancelled."
  # placeholder; if nothing was streamed yet, drop the empty running bubble.
  defp finalize_cancelled_agent_text(socket, turn_id, partial_text, segment) do
    if is_binary(partial_text) and partial_text != "" do
      stream_insert(
        socket,
        :local_agent_items,
        agent_assistant_item(turn_id, partial_text, :sent, segment)
      )
    else
      stream_delete(
        socket,
        :local_agent_items,
        agent_assistant_item(turn_id, "", :running, segment)
      )
    end
  end

  defp agent_tool_payload(payload) when is_binary(payload), do: payload

  defp agent_tool_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(payload, pretty: true)
    end
  end

  # A turn can end (complete/fail/cancel/die) while a tool_call is still
  # mid-flight — that tool_call never gets its terminal event, so its rail row
  # would be stuck on "running" forever. On every turn terminal, flip any
  # still-tracked in-flight tool_calls to :failed.
  defp finalize_dangling_tools(socket, reason) do
    active = socket.assigns[:local_agent_active_tools] || %{}

    socket =
      Enum.reduce(active, socket, fn {tool_call_id, name}, acc ->
        stream_insert(
          acc,
          :local_agent_items,
          agent_tool_item(tool_call_id, name, :failed, reason)
        )
      end)

    assign(socket, :local_agent_active_tools, %{})
  end

  # ── stream item builders ───────────────────────────────────────────

  defp agent_user_item(turn_id, body) do
    %{dom_id: "local-agent-user-#{turn_id}", role: :user, status: :sent, body: body}
  end

  defp agent_assistant_item(turn_id, body, status, segment \\ 0) do
    %{dom_id: agent_assistant_dom_id(turn_id, segment), role: :agent, status: status, body: body}
  end

  defp agent_reasoning_item(turn_id, body, status) do
    %{
      dom_id: agent_reasoning_dom_id(turn_id),
      role: :thinking,
      status: status,
      title: "Thinking",
      body: body
    }
  end

  defp agent_tool_item(tool_call_id, name, status, body) do
    %{
      dom_id: "local-agent-tool-#{tool_call_id}",
      role: :tool,
      title: name,
      status: status,
      body: body || ""
    }
  end

  defp agent_assistant_dom_id(turn_id, segment), do: "local-agent-assistant-#{turn_id}-#{segment}"
  defp agent_reasoning_dom_id(turn_id), do: "local-agent-thinking-#{turn_id}"

  # Stream dom_id resolver — PUBLIC so it can be captured as `&__MODULE__.../1` in
  # stream_configure (mount/3). Named captures survive dev hot-reloads, unlike
  # anonymous closures compiled into this module.
  @doc false
  def local_agent_item_dom_id(%{dom_id: dom_id}), do: dom_id

  # ── stream item view extractors ────────────────────────────────────

  defp agent_item_data_role(%{role: :tool}), do: "local-agent-tool"
  defp agent_item_data_role(%{role: :thinking}), do: "local-agent-thinking"
  defp agent_item_data_role(_item), do: "local-agent-message"

  defp agent_item_role(%{role: role}), do: to_string(role)
  defp agent_item_role(_item), do: "agent"

  defp agent_item_status(%{status: status}), do: to_string(status)
  defp agent_item_status(_item), do: "idle"

  # The bouncing-dots indicator renders ONLY while the assistant placeholder is
  # in-flight (`running`) AND has no body yet. Once the first token lands the
  # debounced re-render carries a body, so the guard drops the span (matching the
  # client hook's `agent-loading` removal) — without it morphdom re-creates the
  # animated node ~every 120ms and the dots visibly freeze.
  defp agent_item_loading?(item) do
    agent_item_status(item) == "running" and agent_item_body(item) == ""
  end

  defp agent_item_title(%{title: title}) when is_binary(title), do: title
  defp agent_item_title(_item), do: "Tool"

  defp agent_item_body(%{body: body}) when is_binary(body), do: body
  defp agent_item_body(_item), do: ""

  defp agent_item_status_label(%{status: :approval_required}), do: "Needs approval"

  defp agent_item_status_label(%{status: status}),
    do: status |> to_string() |> String.replace("_", " ")

  defp agent_item_status_label(_item), do: ""

  defp agent_item_class(%{role: :user}) do
    "group/message relative flex min-w-0 w-full flex-col items-stretch gap-0.5 self-end"
  end

  defp agent_item_class(%{role: :tool}) do
    "group/message relative flex min-w-0 w-full flex-col items-stretch gap-0.5"
  end

  defp agent_item_class(%{role: :thinking, status: :pending}) do
    "hidden"
  end

  defp agent_item_class(%{role: :system}) do
    "group/message relative flex min-w-0 w-full flex-col items-stretch gap-0.5 text-base-content/65"
  end

  defp agent_item_class(_item) do
    "group/message relative flex min-w-0 w-full flex-col items-stretch gap-0.5 self-start"
  end

  # ── status / placeholder labels ────────────────────────────────────

  defp agent_status_label(:offline), do: "Offline"
  defp agent_status_label(:starting), do: "Starting"
  defp agent_status_label(:running), do: "Running"
  defp agent_status_label(:cancelled), do: "Cancelled"
  defp agent_status_label(:failed), do: "Failed"
  defp agent_status_label(_status), do: "Idle"

  defp agent_input_placeholder(:offline), do: "Agent unavailable"
  defp agent_input_placeholder(:starting), do: "Starting agent"
  defp agent_input_placeholder(_status), do: "Ask about this workspace"

  # ── forms / title ──────────────────────────────────────────────────

  defp local_agent_form(params \\ %{"message" => ""}) do
    to_form(params, as: :agent)
  end

  defp local_agent_title_form(title \\ default_local_agent_title()) do
    to_form(%{"title" => local_agent_title(title)}, as: :local_agent_title)
  end

  defp assign_local_agent_title(socket, title) do
    title = local_agent_title(title)

    socket
    |> assign(:local_agent_title, title)
    |> assign(:local_agent_title_form, local_agent_title_form(title))
  end

  defp local_agent_title(title) when is_binary(title) do
    title |> String.trim() |> String.slice(0, 120)
  end

  defp local_agent_title(_title), do: ""

  defp default_local_agent_title, do: "New Chat"

  # ── error mapping ──────────────────────────────────────────────────

  defp local_agent_error({:codex_executable_missing, candidates}) do
    "Codex ACP unavailable. Install one of: #{Enum.join(candidates, ", ")}."
  end

  defp local_agent_error({:claude_executable_missing, candidates}) do
    "Claude unavailable. Install one of: #{Enum.join(candidates, ", ")}."
  end

  defp local_agent_error("{:codex_executable_missing" <> _reason) do
    "Codex ACP unavailable. Install codex-acp or codex, then refresh agent chat."
  end

  defp local_agent_error("{:claude_executable_missing" <> _reason) do
    "Claude unavailable. Install and authenticate Claude CLI, then refresh agent chat."
  end

  defp local_agent_error("{:unsupported_provider, \"fake\"" <> _reason) do
    "Selected provider is disabled. Choose Codex or Claude."
  end

  defp local_agent_error(:acp_unavailable) do
    "Local agent runtime unavailable. Refresh the workspace."
  end

  # ExMCP.ACP adapter failures arrive as inspected strings; map the common
  # provider-startup failures onto the same friendly guidance.
  defp local_agent_error(reason) when is_binary(reason) do
    cond do
      acp_codex_unavailable?(reason) ->
        "Codex ACP unavailable. Install codex, then refresh agent chat."

      acp_claude_unavailable?(reason) ->
        "Claude unavailable. Install and authenticate Claude CLI, then refresh agent chat."

      true ->
        reason
    end
  end

  defp local_agent_error(reason), do: inspect(reason)

  defp acp_codex_unavailable?(reason) do
    (String.contains?(reason, "executable_not_found") or
       String.contains?(reason, "ex_mcp ACP session start failed")) and
      String.contains?(reason, "codex")
  end

  defp acp_claude_unavailable?(reason) do
    (String.contains?(reason, "executable_not_found") or
       String.contains?(reason, "ex_mcp ACP session start failed")) and
      String.contains?(reason, "claude")
  end
end
