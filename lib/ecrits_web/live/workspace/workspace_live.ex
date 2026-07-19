defmodule EcritsWeb.Workspace.WorkspaceLive do
  @moduledoc """
  Local workspace shell.
  """

  use EcritsWeb, :live_view

  require Logger

  alias Ecrits.Agent
  alias Ecrits.Doc.Pool, as: DocPool
  alias Ecrits.Doc.Projection
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs
  alias Ecrits.AcpAgent, as: ACP
  alias Ecrits.Document
  alias Ecrits.Document.PreviewSnapshot
  alias Ecrits.Document.RhwpAdapter
  alias Ecrits.FileTree
  alias Ecrits.Path, as: WorkspacePath
  alias Ecrits.Prompt
  alias Ecrits.Workspace
  alias Ecrits.WorkspaceHandoff
  alias Ecrits.Workspace.Session, as: WorkspaceSession
  alias Ecrits.Workspace.Session.Document, as: SessionDocument
  alias EcritsWeb.Brand
  alias EcritsWeb.Components.WorkspaceFileTree
  alias Ecrits.DocumentElementPicker
  alias Ecrits.DocumentSearch
  alias Ecrits.EditorPreviewState
  alias Ecrits.EditorSurfaceState
  alias Ecrits.EditorToolbar
  alias Ecrits.AgentConfig
  alias Ecrits.AgentConfig.Access, as: AgentAccess
  alias Ecrits.AgentConfig.ModelCatalog, as: AgentModels
  alias Ecrits.MarkdownEditorState
  alias Ecrits.ScrollFollow
  alias Ecrits.WorkspaceLayout
  alias EcritsWeb.Live.Studio.Components.ChatRail
  alias EcritsWeb.Live.Studio.Components.EditorSurface
  alias EcritsWeb.Live.Studio.Components.Canvas.OfficeWasm
  alias EcritsWeb.Workspace.Adapter

  @document_upload_max_size 50_000_000
  @document_upload_accept ~w(.hwp .hwpx .doc .docx .xls .xlsx .ppt .pptx .rtf .md .markdown)
  @document_open_async :open_document
  @doc_vfs_mount_async :ensure_doc_vfs_mount
  # Debounce interval for re-rendering the streaming agent message body as
  # formatted markdown (raw client-side appends give instant sub-debounce
  # feedback; the tick re-renders the accumulated buffer through MDEx).
  @agent_text_flush_ms 120
  @agent_reasoning_flush_ms 120
  @agent_editor_preview_max 5_000
  @acp_file_operation_names ~w(read_text_file search_text_file edit_text_file)
  @doc_browser_finalize_timeout_ms 1_000
  @doc_browser_finalize_max_attempts 3
  @doc_browser_recovery_timeout_ms 5_000
  @doc_browser_recovery_max_attempts 3
  # Chat-rail document mirrors are expensive if they accumulate. Keep only the
  # newest direct-edit mirror alive; the mirror hook itself renders the edited
  # highlight pages instead of building a full page stack.
  # Idle window before a dirty viewed document is auto-saved. Each user/agent
  # edit (re)arms a per-document timer; when it fires and the doc is still dirty
  # we fire a canonical `doc.save` (the same path Ctrl/Cmd+S uses).
  @autosave_idle_ms 4_000
  @selectable_agent_provider_ids ~w(codex claude)
  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:live_session_id, live_session_id(session))
     |> assign(:chat_rail_tab_id, nil)
     # The durable per-workspace `Ecrits.Workspace.Session` (keyed by canonical
     # path) owns document routing. The active foreground chat agent is scoped by
     # the stable browser-tab id above, while the Phoenix session id groups recent
     # chats. `nil` until the first attach.
     |> assign(:workspace_session, nil)
     # NAMED captures (not anon closures): a stream `dom_id` resolver is stored on
     # the long-lived LiveView at mount. An anonymous `& &1.dom_id` is compiled
     # INTO this module, so a dev hot-reload that purges the old module version
     # while the LiveView is still alive turns it into a stale function reference
     # ("points to an old version of the code" -> BadFunctionError on the next
     # stream_insert). A remote capture `&__MODULE__.fun/1` is resolved by name at
     # call time and therefore survives recompiles.
     |> stream_configure(:hwp_pages, dom_id: &__MODULE__.hwp_page_dom_id/1)
     |> stream(:hwp_pages, [])
     |> stream_configure(:agent_items, dom_id: &__MODULE__.agent_item_dom_id/1)
     |> stream(:agent_items, [])
     # Markdown (.md/.markdown) editor: plain-text source + live MDEx preview.
     |> assign(:markdown_editor, MarkdownEditorState.new())
     |> assign(:markdown_preview_html, "")
     |> assign(:page_title, "Workspace")
     |> assign(:workspace, nil)
     |> assign(:workspace_path, nil)
     |> assign(:workspace_layout, WorkspaceLayout.new())
     |> assign(:chat_scroll_follow, ScrollFollow.new())
     |> assign(:file_tree, FileTree.new())
     |> assign(:active_document_path, nil)
     |> assign(:active_document, nil)
     |> assign(:active_document_viewport, nil)
     |> assign(:document_bytes_version, nil)
     |> assign(:open_documents, [])
     |> assign(:active_document_id, nil)
     |> assign(:document_element_picker, DocumentElementPicker.new())
     |> assign(:editor_toolbar, EditorToolbar.new())
     |> reset_document_search()
     |> assign(:pending_document_open_ref, nil)
     |> assign(:pending_document_path, nil)
     |> assign(:pool_document_id, nil)
     # Browser-backed agent edits (design §6.2): when the open HWP is registered
     # `:browser` in the Pool, the agent's doc.* edits route HERE. We push the op
     # to the WasmHwpEditor hook (authoritative WASM model) and relay its reply
     # back to the waiting MCP caller. `doc_browser_pending` maps a per-request
     # ref -> the caller pid so a hook reply finds its requester.
     |> assign(:doc_browser_pending, %{})
     # A successful vfs_write remains provisional after its request/reply
     # finishes. Keep its caller monitor alive until that same owner completes
     # vfs_commit/vfs_rollback, so death or turn cancellation cannot strand the
     # browser's pending transaction.
     |> assign(:doc_browser_vfs_leases, %{})
     # Unsaved-changes tracking (LiveView is the source of truth). A document id
     # is in `dirty_document_ids` once it is touched (user edit via
     # `rhwp.text.mutated`, or an agent doc.edit/doc.set routed through the browser
     # bridge) and removed once saved (Ctrl+S/auto-save, or an agent doc.save) —
     # so the tab dot reflects user AND agent ops uniformly. `autosave_timers`
     # holds the per-document debounce timer that fires a canonical save on idle.
     |> assign(:dirty_document_ids, MapSet.new())
     |> assign(:autosave_timers, %{})
     |> assign(:fs_watcher_pid, nil)
     # Document VFS (exfuse) toggle state. nil hides the header doc-VFS button on
     # non-workspace chrome; in the workspace it is always a boolean (shown).
     |> assign(:fuse_mode, false)
     # The doc_vfs:<root> PubSub topic this LV is subscribed to (direct-edit cards).
     |> assign(:doc_vfs_topic, nil)
     |> assign(:fs_refresh_timer, nil)
     |> assign(:workspace_fs_subscribed_paths, MapSet.new())
     # Subscribed-once flag for the agent-file-write PubSub topic
     # (`Ecrits.Doc.Tools.workspace_files_topic/0`): an agent doc.create-clone /
     # doc.save broadcasts the written path there, and we refresh the tree LIVE
     # (mid-turn) when the path is under this workspace's root.
     |> assign(:workspace_files_subscribed?, false)
     |> assign(:document_error, nil)
     |> assign(:document_status, :none)
     |> assign(:document_snapshot, nil)
     |> assign(:hwp_page_count, 0)
     |> assign(:hwp_stream_renderer, nil)
     |> assign(:hwp_stream_document_id, nil)
     |> assign(:hwp_stream_loading?, false)
     |> assign(:last_caret, nil)
     |> assign(:workspace_error, nil)
     # Each attached workspace LiveView renders the shared browser-tab rail
     # inline. `agent_session_id` is the currently bound durable
     # foreground-agent id; it gates the chat send path here.
     |> assign(:agent_session_id, nil)
     # Provider restarts deliberately reuse the durable agent id while replacing
     # its process. Track that process locally so every same-tab sibling can tell
     # a real restart from an ordinary same-instance metadata rebind.
     |> assign(:agent_process_pid, nil)
     |> assign(:agent_instance_id, nil)
     |> assign(:agent_event_seq, 0)
     |> assign(:agent_status, :starting)
     |> assign(:agent_error, nil)
     |> assign(:agent_turn_id, nil)
     # Count of mid-turn sends still queued behind the running turn (Phase 5 FIFO
     # queue). Drives the "N 대기" pending indicator; decremented as each queued
     # turn drains.
     |> assign(:agent_pending, 0)
     |> assign(:agent_queue, [])
     |> assign(:agent_queue_index, 0)
     |> assign(:agent_rail_key, nil)
     |> assign(:agent_rails, [])
     |> assign(:agent_rail_drawer_open?, false)
     |> assign(:agent_text, "")
     |> assign(:agent_text_segment, 0)
     |> assign(:agent_text_flush_ref, nil)
     |> assign(:agent_editor_preview, nil)
     |> assign(:agent_vfs_preview_item, nil)
     |> assign(:agent_vfs_preview_rollback_item, nil)
     |> assign(:agent_active_tools, %{})
     |> assign(:agent_active_file_operations, %{})
     |> assign(:agent_reasoning_text, "")
     |> assign(:agent_reasoning_segment, 0)
     |> assign(:agent_reasoning_flush_ref, nil)
     # Tracks whether reasoning text is being appended contiguously (codex glues
     # reasoning items with no separator); we insert a paragraph break when a new
     # item resumes after a non-reasoning event.
     |> assign(:agent_reasoning_open?, false)
     |> assign(:agent_title, default_agent_title())
     |> assign(:agent_title_user_edited?, false)
     |> assign(:agent_title_form, agent_title_form())
     |> assign(:agent_form, agent_form())
     |> assign(
       :agent,
       AgentConfig.new(%{
         provider: agent_provider_display(),
         provider_warning: nil,
         model: default_agent_model_id(default_provider_id()),
         reasoning_effort: default_reasoning_effort(),
         access: AgentAccess.resolve(default_access_control()),
         integrations: agent_integrations()
       })
     )
     |> assign(:agent_model_modal_open, false)
     |> assign(:agent_options_form, agent_options_form())
     |> allow_upload(:document_import,
       accept: @document_upload_accept,
       max_entries: 1,
       max_file_size: @document_upload_max_size,
       auto_upload: true,
       progress: &handle_document_import_upload/3
     )
     |> assign(:octet_stash, %{})
     |> subscribe_octet_sink()}
  end

  # General binary ingress (:octet): browser engines ship binaries over
  # `EcritsWeb.OctetChannel` (own socket; one binary frame per upload, the
  # push reply is the ack — no flow control on this local lane). The channel
  # broadcasts each committed binary to this LiveView's unguessable sink
  # topic; `handle_info({:octet_upload, ...})` stashes it and acks the
  # client. The sink id is rendered into the DOM for the client module to
  # join on.
  defp subscribe_octet_sink(socket) do
    {sink_id, :ok} = PhoenixOctet.Sink.subscribe(Ecrits.PubSub, connected?(socket))
    assign(socket, :octet_sink_id, sink_id)
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    case WorkspaceHandoff.fetch_workspace_path(socket.assigns.live_session_id) do
      {:ok, path} ->
        socket =
          socket
          |> mount_workspace(path)
          # Attach the durable per-path workspace Session and bind this browser tab's
          # foreground agent. A browser refresh replaces the LiveView pid but reuses
          # the stable tab id and selected rail.
          # The route query string is deliberately ignored; workspace/document/provider
          # state is owned by LiveView/session state, not by the URL.
          |> attach_workspace_session()

        {:noreply, socket}

      _missing_or_unavailable ->
        {:noreply, push_navigate(socket, to: ~p"/")}
    end
  end

  # The transition this provider/model selection implies, as a tag
  # `apply_agent_transition/2`
  # matches on:
  #   :restart_provider — a provider change (codex<->claude, or a cross-provider
  #       model pick) rebinds the ACP adapter, which can't be swapped on a live
  #       session, so an already-bound agent is killed + restarted. The first
  #       connected attach seeds the right provider directly (no restart).
  #   :live_options     — a same-provider model change applies live (preserves
  #       the conversation).
  #   :keep             — nothing agent-affecting changed.
  defp agent_transition(socket, provider, model) do
    cond do
      provider_change?(socket, provider) and agent_bound?(socket) and connected?(socket) ->
        :restart_provider

      model.id != socket.assigns.agent.model ->
        :live_options

      true ->
        :keep
    end
  end

  defp apply_agent_transition(socket, :restart_provider),
    do: restart_agent_for_provider(socket)

  defp apply_agent_transition(socket, :live_options),
    do: maybe_apply_live_agent_options(socket, true)

  defp apply_agent_transition(socket, :keep),
    do: maybe_apply_live_agent_options(socket, false)

  defp provider_change?(socket, provider),
    do: provider.key != socket.assigns.agent.provider.key

  defp agent_bound?(socket), do: is_binary(socket.assigns.agent_session_id)

  defp apply_agent_model(socket, %{id: model_id, provider: provider_id} = _model) do
    provider = agent_provider_display(provider_id)
    transition = agent_transition(socket, provider, %{id: model_id})

    socket
    |> put_agent(
      provider: provider,
      provider_warning: nil,
      model: model_id,
      integrations: agent_integrations()
    )
    |> apply_agent_transition(transition)
  end

  defp apply_agent_model(socket, _model), do: socket

  @impl true
  def handle_event("workspace.file_tree.toggle", _params, socket) do
    {:noreply, update(socket, :workspace_layout, &WorkspaceLayout.toggle_file_tree/1)}
  end

  # Browser-tab identity belongs to the workspace hook because sessionStorage is
  # browser-only state. Defer agent attachment until it arrives: a mounted hook
  # runs after the LiveSocket connects, and attaching before this event would
  # create an orphan foreground rail for the temporary connection.
  def handle_event("workspace.chat_rail.tab_ready", %{"id" => tab_id}, socket)
      when is_binary(tab_id) and tab_id != "" do
    socket =
      case socket.assigns.chat_rail_tab_id do
        nil ->
          socket
          |> assign(:chat_rail_tab_id, tab_id)
          |> attach_workspace_session()

        ^tab_id ->
          attach_workspace_session(socket)

        _different_tab ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("workspace.chat_rail.tab_ready", _params, socket), do: {:noreply, socket}

  def handle_event("workspace.editor_fullscreen.toggle", _params, socket) do
    {:noreply, update(socket, :workspace_layout, &WorkspaceLayout.toggle_editor_fullscreen/1)}
  end

  def handle_event("workspace.layout.resize.start", params, socket) do
    {:noreply, update(socket, :workspace_layout, &WorkspaceLayout.begin_resize(&1, params))}
  end

  def handle_event("workspace.layout.resize.move", params, socket) do
    {:noreply, update(socket, :workspace_layout, &WorkspaceLayout.resize(&1, params))}
  end

  def handle_event("workspace.layout.resize.finish", params, socket) do
    start_params =
      Map.put(params, "x", Map.get(params, "start_x", Map.get(params, "x")))

    layout =
      socket.assigns.workspace_layout
      |> WorkspaceLayout.begin_resize(start_params)
      |> WorkspaceLayout.resize(params)
      |> WorkspaceLayout.finish_resize()

    width =
      case Map.get(params, "panel", Map.get(params, :panel)) do
        panel when panel in ["file_tree", :file_tree] ->
          WorkspaceLayout.file_tree_render_width(layout)

        _panel ->
          layout.chat_rail_width
      end

    {:reply, %{width: width}, assign(socket, :workspace_layout, layout)}
  end

  def handle_event("chat.viewport.scrolled", params, socket) do
    {:noreply, update(socket, :chat_scroll_follow, &ScrollFollow.observe(&1, params))}
  end

  def handle_event("workspace.directory.toggle", %{"path" => path}, socket) do
    socket =
      socket
      |> update(:file_tree, &FileTree.toggle(&1, path))
      |> refresh_tree()

    {:noreply, socket}
  end

  def handle_event("workspace.file.select", %{"path" => path}, socket) do
    {:noreply, update(socket, :file_tree, &FileTree.select(&1, path))}
  end

  def handle_event("workspace.document.open", %{"path" => path}, socket) do
    {:noreply, schedule_document_open(socket, path)}
  end

  def handle_event("document.element_picker.toggle", _params, socket) do
    picker = DocumentElementPicker.toggle(socket.assigns.document_element_picker)

    socket =
      socket
      |> assign(:document_element_picker, picker)
      |> persist_document_element_picker_enabled(picker.enabled?)

    {:noreply, socket}
  end

  def handle_event("document.element_picker.pick.toggle", params, socket) do
    {:noreply,
     update(
       socket,
       :document_element_picker,
       &DocumentElementPicker.toggle_pick(&1, params)
     )}
  end

  def handle_event("document.element_picker.pick.remove", %{"key" => key}, socket) do
    {:noreply,
     update(
       socket,
       :document_element_picker,
       &DocumentElementPicker.remove_pick(&1, key)
     )}
  end

  def handle_event("document.element_picker.picks.clear", _params, socket) do
    {:noreply, update(socket, :document_element_picker, &DocumentElementPicker.clear/1)}
  end

  def handle_event("document.toolbar.command", %{"command" => command} = params, socket) do
    {:noreply, push_editor_toolbar_command(socket, command, params)}
  end

  def handle_event("document.toolbar.shortcut_pressed", params, socket) do
    case EditorToolbar.shortcut_command(params) do
      nil -> {:reply, %{handled: false}, socket}
      command -> {:reply, %{handled: true}, push_editor_toolbar_command(socket, command, %{})}
    end
  end

  def handle_event("document.toolbar.state_received", params, socket) do
    toolbar =
      EditorToolbar.put_engine_state(
        socket.assigns.editor_toolbar,
        params,
        active_document_id(socket)
      )

    {:noreply, assign(socket, :editor_toolbar, toolbar)}
  end

  def handle_event(
        "document.toolbar.font_size_changed",
        %{"editor_toolbar" => %{"size" => size}},
        socket
      ) do
    {:noreply, push_editor_toolbar_command(socket, "font-size-set", %{size: size})}
  end

  def handle_event(
        "document.toolbar.color_changed",
        %{"editor_toolbar" => %{"command" => command, "color" => color}},
        socket
      ) do
    {:noreply, push_editor_toolbar_command(socket, command, %{color: color})}
  end

  def handle_event("document.toolbar.image_selected", params, socket) do
    {:noreply, push_editor_toolbar_command(socket, "image", params)}
  end

  def handle_event("document.search.open", %{"document_id" => document_id}, socket) do
    with :ok <- verify_active_document(socket, document_id),
         true <- document_search_enabled?(socket) do
      search = DocumentSearch.open(socket.assigns.document_search, document_id)

      socket = assign(socket, :document_search, search)

      socket =
        if search.query == "" do
          socket
        else
          push_document_search_action(socket, "search")
        end

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "document.search.query_changed",
        %{"document_search" => %{"query" => query}},
        socket
      )
      when is_binary(query) do
    if socket.assigns.document_search.open? and document_search_enabled?(socket) do
      socket =
        socket
        |> put_document_search_query(query)
        |> push_document_search_action("search")

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("document.search.query_changed", _params, socket), do: {:noreply, socket}

  def handle_event("document.search.next", _params, socket) do
    {:noreply, maybe_push_document_search_action(socket, "next")}
  end

  def handle_event("document.search.previous", _params, socket) do
    {:noreply, maybe_push_document_search_action(socket, "prev")}
  end

  def handle_event("document.search.close", _params, socket) do
    search = socket.assigns.document_search

    if search.open? do
      socket =
        socket
        |> push_document_search_action("close")
        |> assign(:document_search, DocumentSearch.close(search))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event(
        "document.search.result_received",
        %{"document_id" => document_id, "query" => query} = params,
        socket
      ) do
    search = socket.assigns.document_search

    with :ok <- verify_active_document(socket, document_id),
         true <- search.open?,
         true <- search.document_id == document_id,
         true <- search.query == query do
      {:noreply, assign(socket, :document_search, DocumentSearch.put_result(search, params))}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("document.search.result_received", _params, socket), do: {:noreply, socket}

  def handle_event("workspace.document.activate", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.open_documents, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      %{path: path} ->
        {:noreply, schedule_document_open(socket, path)}
    end
  end

  def handle_event("workspace.document.close", %{"id" => id}, socket) do
    {:noreply, close_open_document_tab(socket, id)}
  end

  def handle_event("document.hwp.load", %{"document_id" => document_id}, socket) do
    with :ok <- verify_active_document(socket, document_id),
         {:ok, response} <- RhwpAdapter.load(document_id) do
      socket =
        socket
        |> assign(:active_document, document_summary(response))
        |> assign(:document_status, :loaded)
        |> assign(:document_error, nil)

      {:reply, load_reply(response), socket}
    else
      {:error, reason} ->
        {:reply, %{error: error_message(reason)},
         assign(socket, :document_error, error_message(reason))}
    end
  end

  def handle_event("document.content.changed", %{"documentId" => document_id} = params, socket) do
    with :ok <- verify_active_document(socket, document_id),
         {:ok, response} <- RhwpAdapter.record_mutation(document_id, params) do
      socket = socket |> mark_doc_dirty(document_id) |> arm_autosave(document_id)
      {:reply, %{ok: true, local: true, mutation: mutation_reply(response.mutation)}, socket}
    else
      {:error, reason} ->
        {:reply, %{error: error_message(reason)}, socket}
    end
  end

  def handle_event("document.content.changed", params, socket) do
    document_id = params["document_id"] || active_document_id(socket)

    with :ok <- verify_active_document(socket, document_id),
         {:ok, response} <- RhwpAdapter.record_mutation(document_id, params) do
      socket = socket |> mark_doc_dirty(document_id) |> arm_autosave(document_id)
      {:reply, %{ok: true, local: true, mutation: mutation_reply(response.mutation)}, socket}
    else
      {:error, reason} ->
        {:reply, %{error: error_message(reason)}, socket}
    end
  end

  # Reply from the WasmHwpEditor hook for an agent-routed browser op (see the
  # `{:doc_browser_request, ...}` handler). Relay the result to the MCP caller
  # that is blocked in `Ecrits.Doc.Tools.browser_call/4`.
  def handle_event(
        "document.engine.operation.replied",
        %{"request_id" => request_id} = params,
        socket
      ) do
    # Claim first even when the request was already cancelled. A timed-out
    # export may finish after its caller has gone away; leaving its octet in the
    # LiveView stash would retain the complete document binary indefinitely.
    {socket, params} = claim_octet(socket, params)

    case Map.get(socket.assigns.doc_browser_pending, request_id) do
      %{kind: :vfs_finalize, status: :waiting} = entry ->
        result = doc_browser_result(params)

        case result do
          {:ok, _result} ->
            release_doc_browser_entry_resources(entry)
            {:noreply, update(socket, :doc_browser_pending, &Map.delete(&1, request_id))}

          {:error, reason} ->
            {:noreply, retry_or_recover_doc_browser_finalize(socket, request_id, entry, reason)}
        end

      %{status: :waiting, from: from, ref: ref, verb: verb} = entry ->
        result = doc_browser_result(params)
        send(from, {:doc_browser_reply, ref, result})

        socket =
          socket
          |> put_doc_browser_pending(
            request_id,
            entry |> Map.put(:status, :replied) |> Map.put(:result, result)
          )
          |> apply_browser_op_dirty(verb, result)

        {:noreply, socket}

      %{status: :replied} ->
        {:noreply, socket}

      # Hot-code compatibility for requests created before the monitored
      # pending-entry handshake was loaded.
      {from, ref, verb} ->
        result = doc_browser_result(params)
        send(from, {:doc_browser_reply, ref, result})

        socket =
          socket
          |> update(:doc_browser_pending, &Map.delete(&1, request_id))
          |> apply_browser_op_dirty(verb, result)

        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  # Canonical-byte recovery is the fallback after the browser accepted a VFS
  # commit but did not acknowledge `vfs_finalize`. The reload is itself a
  # request/reply operation: removing the retained finalize transaction without
  # hearing that the replacement document loaded would leave the editor locked
  # indefinitely on fetch/constructor failures.
  def handle_event(
        "document.vfs.recovery.replied",
        %{"recovery_id" => recovery_id} = params,
        socket
      ) do
    case Map.get(socket.assigns.doc_browser_pending, recovery_id) do
      %{kind: :vfs_recovery, status: :waiting} = entry ->
        result = doc_browser_result(params)
        response_attempt = params["attempt"]

        case result do
          {:ok, _result} ->
            release_doc_browser_entry_resources(entry)
            {:noreply, update(socket, :doc_browser_pending, &Map.delete(&1, recovery_id))}

          {:error, reason} when response_attempt == entry.attempt ->
            {:noreply, retry_or_fail_doc_browser_recovery(socket, recovery_id, entry, reason)}

          # A failure from an earlier timed-out load must not consume the retry
          # currently in flight. A success from any attempt is accepted above,
          # since it proves canonical bytes replaced the provisional model.
          {:error, _stale_reason} ->
            {:noreply, socket}
        end

      _other ->
        {:noreply, socket}
    end
  end

  # Ctrl/Cmd+S over the editor shell. The `phx-key="s"` filter narrows the
  # window keydown to the "s" key; the modifier check guards against a bare "s"
  # keystroke triggering a save. NOTE: a save only fires when the keydown
  # payload carries `ctrlKey`/`metaKey` — see the second clause for plain "s".
  def handle_event("document.save.requested", %{"key" => key} = params, socket)
      when key in ["s", "S"] do
    if params["ctrlKey"] || params["metaKey"] do
      {:noreply, save_active_document(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("document.save.requested", _params, socket), do: {:noreply, socket}

  # Deadline-missed uploads confirm cancellation in two places: the channel
  # forgets the transfer (its "abort"), and this drops any binary that already
  # reached the stash so a late claim cannot resurrect it.
  def handle_event("octet:cancel", %{"id" => id}, socket) when is_binary(id) do
    {:reply, %{cancelled: true}, update(socket, :octet_stash, &Map.delete(&1, id))}
  end

  def handle_event("octet:cancel", _params, socket) do
    {:reply, %{cancelled: false}, socket}
  end

  def handle_event("document.snapshot.checkpoint", params, socket) do
    {socket, params} = claim_octet(socket, params)
    persist_rhwp_snapshot(:checkpoint, params, socket)
  end

  def handle_event("document.snapshot.save_requested", params, socket) do
    {socket, params} = claim_octet(socket, params)
    persist_rhwp_snapshot(:save, params, socket)
  end

  def handle_event("document.viewer.save_requested", params, socket) do
    {socket, params} = claim_octet(socket, params)
    persist_viewer_save(params, socket)
  end

  def handle_event("document.viewer.changed", %{"document_id" => document_id}, socket) do
    with :ok <- verify_active_document(socket, document_id) do
      {:noreply, socket |> mark_doc_dirty(document_id) |> arm_autosave(document_id)}
    else
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("document.viewer.changed", _params, socket), do: {:noreply, socket}

  # The editor hook reports whether it ACTUALLY holds the document model. Only
  # then does this LiveView claim browser authority for doc.* routing —
  # attaching at tab-open routed agent calls to editors that never loaded
  # (e.g. office WASM in a non-isolated context), producing document_not_loaded
  # finds and refused renders while the server arm sat idle and capable.
  def handle_event("document.viewer.ready", %{"document_id" => document_id}, socket) do
    with :ok <- verify_active_document(socket, document_id),
         doc_id when is_binary(doc_id) <- socket.assigns[:pool_document_id] do
      attach_session_viewer(socket, doc_id)
      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("document.viewer.ready", _params, socket), do: {:noreply, socket}

  def handle_event("document.viewer.failed", %{"document_id" => document_id}, socket) do
    with :ok <- verify_active_document(socket, document_id),
         doc_id when is_binary(doc_id) <- socket.assigns[:pool_document_id] do
      detach_session_viewer(socket, doc_id)
      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("document.viewer.failed", _params, socket), do: {:noreply, socket}

  def handle_event(
        "document.viewport.changed",
        %{"document_path" => document_path} = params,
        socket
      ) do
    if open_document_path?(socket, document_path) do
      viewport = %{
        scroll_top: scroll_coordinate(params["top"] || params["scroll_top"]),
        scroll_left: scroll_coordinate(params["left"] || params["scroll_left"])
      }

      if ws = ws(socket) do
        _ = WorkspaceSession.update_document_scroll(ws, document_path, viewport)
      end

      socket =
        if socket.assigns[:active_document_path] == document_path do
          assign(socket, :active_document_viewport, viewport)
        else
          socket
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("document.viewport.changed", _params, socket), do: {:noreply, socket}

  def handle_event(
        "document.markdown.source_changed",
        %{"markdown_editor" => %{"source" => source}},
        socket
      )
      when is_binary(source) do
    if markdown_document_active?(socket) do
      state = MarkdownEditorState.put_source(socket.assigns.markdown_editor, source)

      socket =
        socket
        |> assign(:markdown_editor, state)
        |> assign(:markdown_preview_html, EcritsWeb.Markdown.to_preview_html(state.source))
        |> mark_doc_dirty(active_document_id(socket))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("document.markdown.source_changed", _params, socket), do: {:noreply, socket}

  def handle_event("document.markdown.selection_changed", params, socket) do
    if markdown_document_active?(socket) do
      {:noreply, update(socket, :markdown_editor, &MarkdownEditorState.put_selection(&1, params))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("document.markdown.view_toggled", _params, socket) do
    {:noreply, update(socket, :markdown_editor, &MarkdownEditorState.toggle_view/1)}
  end

  def handle_event("document.markdown.save_requested", params, socket) do
    state =
      case params do
        %{"source" => source} when is_binary(source) ->
          MarkdownEditorState.put_source(socket.assigns.markdown_editor, source)

        _ ->
          socket.assigns.markdown_editor
      end

    with %{id: document_id} <- socket.assigns[:active_document],
         true <- markdown_document_active?(socket),
         {:ok, _document, _snapshot} <- Document.save(document_id, state.source) do
      {:noreply, assign(socket, :markdown_editor, MarkdownEditorState.mark_saved(state))}
    else
      {:error, reason} ->
        {:noreply, assign(socket, :document_error, error_message(reason))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("workspace.document_vfs.toggle", _params, socket) do
    path = socket.assigns[:workspace_path]

    socket =
      if is_binary(path) do
        mounted? =
          if socket.assigns.fuse_mode == true do
            _ = DocMount.teardown(path)
            DocMount.mounted?(path)
          else
            path
            |> DocMount.ensure()
            |> doc_vfs_mounted_after_ensure(path)
          end

        put_doc_vfs_mount_state(socket, path, mounted?)
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("workspace.tree.refresh", _params, socket) do
    {:noreply, refresh_tree(socket)}
  end

  def handle_event("agent.model_dialog.open", _params, socket) do
    {:noreply, assign(socket, :agent_model_modal_open, true)}
  end

  def handle_event("agent.model_dialog.close", _params, socket) do
    {:noreply, assign(socket, :agent_model_modal_open, false)}
  end

  def handle_event("agent.provider.select", params, socket) do
    provider = agent_provider_param(params)

    case AgentConfig.selectable_provider(provider, selectable_provider_ids()) do
      nil ->
        {:noreply, socket}

      provider_id when provider_id == socket.assigns.agent.provider.key ->
        {:noreply, assign(socket, :agent_model_modal_open, false)}

      provider_id ->
        model = agent_model(default_agent_model_id(provider_id))

        {:noreply,
         socket
         |> apply_agent_model(model)
         |> assign(:agent_model_modal_open, false)}
    end
  end

  def handle_event("agent.model.select", params, socket) do
    model_id =
      params["model"] ||
        params["value"] ||
        get_in(params, ["agent_model", "model"])

    case agent_model(model_id) do
      nil ->
        {:noreply, socket}

      model ->
        {:noreply, apply_agent_model(socket, model)}
    end
  end

  def handle_event("agent.option.select", params, socket) do
    case agent_option_param(params) do
      {"reasoning", value} ->
        select_agent_reasoning(value, socket)

      {"access", value} ->
        select_agent_access(value, socket)

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("agent.reasoning.select", %{"reasoning" => value}, socket) do
    select_agent_reasoning(value, socket)
  end

  def handle_event("agent.access.select", %{"access" => value}, socket) do
    select_agent_access(value, socket)
  end

  def handle_event("workspace.document.import.validate", _params, socket) do
    {:noreply, assign_document_upload_errors(socket)}
  end

  # ── inline chat events ─────────────────────────────────────────────

  def handle_event(
        "agent.title.change",
        %{"agent_title" => %{"title" => title}},
        socket
      ) do
    # Persist the rename on the durable foreground agent so it survives a refresh
    # (and pins the auto-title). No-op before the agent is bound.
    if w = ws(socket), do: WorkspaceSession.rename(w, title)

    {:noreply,
     socket
     |> assign(:agent_title_user_edited?, true)
     |> assign_agent_title(title)
     |> refresh_agent_rails()}
  end

  def handle_event("agent.conversation.create", _params, socket) do
    {:noreply, restart_agent_session(socket)}
  end

  def handle_event("agent.rail_picker.open", _params, socket) do
    {:noreply,
     socket
     |> assign(:agent_rail_drawer_open?, true)
     |> refresh_agent_rails()}
  end

  def handle_event("agent.rail_picker.close", _params, socket) do
    {:noreply, assign(socket, :agent_rail_drawer_open?, false)}
  end

  def handle_event("agent.rail.select", %{"rail-key" => rail_key}, socket)
      when is_binary(rail_key) and rail_key != "" do
    path = socket.assigns.workspace_path

    case safe_select_foreground(path, rail_key, agent_attach_settings(socket)) do
      {:ok, %{agent_id: agent_id} = ws} when is_binary(agent_id) ->
        {:noreply,
         socket
         |> bind_agent_subscription(agent_id)
         |> snapshot_agent(ws, agent_id)
         |> assign(:agent_rail_drawer_open?, false)
         |> refresh_agent_rails()}

      {:pending, _ws} ->
        {:noreply, assign(socket, :agent_rail_drawer_open?, false)}

      {:error, :foreground_transition_in_progress} ->
        {:noreply, assign(socket, :agent_rail_drawer_open?, false)}

      {:error, reason} ->
        {:noreply, assign(socket, :agent_error, agent_error(reason))}
    end
  end

  def handle_event("agent.rail.select", _params, socket), do: {:noreply, socket}

  def handle_event(
        "agent.message.submit_requested",
        %{"agent" => %{"message" => message}},
        socket
      ) do
    submit_agent_message(socket, message)
  end

  def handle_event("agent.message.submit_requested", %{"message" => message}, socket) do
    submit_agent_message(socket, message)
  end

  def handle_event("agent.turn.cancel", _params, socket) do
    turn_id = socket.assigns.agent_turn_id

    if ws(socket) && turn_id do
      case WorkspaceSession.cancel(ws(socket), turn_id) do
        {:ok, _turn} ->
          partial = socket.assigns.agent_text
          segment = socket.assigns.agent_text_segment

          {:noreply,
           socket
           |> close_agent_reasoning_segment()
           |> assign(:agent_status, :cancelled)
           |> assign(:agent_turn_id, nil)
           |> assign(:agent_text, "")
           |> finalize_inline_editor_preview(turn_id, :cancelled)
           |> finalize_cancelled_agent_text(turn_id, partial, segment)
           |> finalize_dangling_tools("Turn cancelled.")}

        {:error, reason} ->
          {:noreply, assign(socket, :agent_error, agent_error(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("agent.queue.previous", _params, socket) do
    {:noreply, update(socket, :agent_queue_index, &max((&1 || 0) - 1, 0))}
  end

  def handle_event("agent.queue.next", _params, socket) do
    max_index = max(length(socket.assigns.agent_queue) - 1, 0)
    {:noreply, update(socket, :agent_queue_index, &min((&1 || 0) + 1, max_index))}
  end

  def handle_event("agent.queue.flush", _params, socket) do
    flush_agent_queue(socket)
  end

  @impl true
  # Foreground-agent events for the rail currently bound to this LiveView drive
  # its inline transcript. Every sibling LiveView receives the same PubSub
  # terminal, so document persistence is claimed by Workspace.Session and runs
  # once outside the LiveViews; a separate workspace broadcast refreshes them.
  def handle_info(
        {:agent_event, %{session_id: session_id, instance_id: instance_id} = event},
        %{
          assigns: %{
            agent_session_id: session_id,
            agent_instance_id: instance_id
          }
        } = socket
      )
      when is_binary(instance_id) and instance_id != "" do
    if stale_agent_event?(socket, event) do
      {:noreply, socket}
    else
      socket = advance_agent_event_cursor(socket, event)

      # Close the contiguous-reasoning run on any non-reasoning event so the NEXT
      # reasoning delta starts a fresh paragraph (codex glues reasoning items).
      socket =
        case event do
          %{type: :reasoning_delta} -> socket
          _ -> assign(socket, :agent_reasoning_open?, false)
        end

      socket = apply_agent_event(socket, event)

      socket =
        case event do
          %{type: :turn_completed, turn_id: turn_id} ->
            finalize_agent_turn(socket, instance_id, turn_id)

          _ ->
            socket
        end

      {:noreply, socket}
    end
  end

  def handle_info({:agent_event, _event}, socket), do: {:noreply, socket}

  # A committed :octet upload arriving from `EcritsWeb.OctetChannel` via this
  # LiveView's sink topic. Stash under the client-chosen id until the event
  # that references it claims it (`claim_octet/2`); ack AFTER the stash write
  # so the client's next event is ordered behind it. The stash lives in
  # LiveView state, so unclaimed binaries die with the socket: no spool files,
  # no sweeper, no HTTP endpoint.
  def handle_info({:octet_upload, id, bytes}, socket)
      when is_binary(id) and is_binary(bytes) do
    socket =
      socket
      |> update(:octet_stash, &Map.put(&1, id, bytes))
      |> push_event("octet:ack", %{id: id, bytes: byte_size(bytes)})

    {:noreply, socket}
  end

  # Upload and cancel are serialized in the one channel process, so this
  # terminal cancellation arrives after any earlier upload delivery for the
  # same id — even when the client's LiveView `octet:cancel` event overtook
  # the PubSub delivery. Delete once more to make cancellation final.
  def handle_info({:octet_cancelled, id}, socket) when is_binary(id) do
    {:noreply, update(socket, :octet_stash, &Map.delete(&1, id))}
  end

  def handle_info({:workspace_foreground_rebound, %{path: path, agent_id: agent_id} = ws}, socket)
      when is_binary(path) and is_binary(agent_id) do
    if same_workspace_path?(socket.assigns.workspace_path, path) do
      {:noreply, bind_workspace_foreground(socket, ws, agent_id)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:workspace_foreground_transition_failed, reason}, socket) do
    {:noreply, assign(socket, :agent_error, agent_error(reason))}
  end

  def handle_info(
        {:workspace_turn_finalized,
         %{
           workspace_path: path,
           agent_id: agent_id,
           instance_id: instance_id,
           result: result
         }},
        socket
      )
      when is_binary(path) and is_binary(agent_id) and is_binary(instance_id) do
    if same_workspace_path?(socket.assigns.workspace_path, path) do
      socket =
        if socket.assigns.agent_session_id == agent_id and
             socket.assigns.agent_instance_id == instance_id do
          surface_turn_finalization(socket, result)
        else
          socket
        end

      {:noreply, refresh_tree(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:workspace_turn_finalized, %{workspace_path: path}}, socket)
      when is_binary(path) do
    if same_workspace_path?(socket.assigns.workspace_path, path) do
      {:noreply, refresh_tree(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:editor_preview_delta, payload}, socket) when is_map(payload) do
    {:noreply, push_event(socket, "document.preview.delta_received", payload)}
  end

  # Debounced re-render of the in-flight streaming agent message: re-renders the
  # accumulated buffer through `markdown_body`/MDEx so LiveView pushes formatted
  # HTML that replaces the raw client-side appends.
  def handle_info({:flush_agent_text, ref}, socket) do
    if socket.assigns.agent_text_flush_ref == ref do
      {:noreply, flush_agent_text(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:flush_agent_reasoning, ref}, socket) do
    if socket.assigns.agent_reasoning_flush_ref == ref do
      {:noreply, flush_agent_reasoning(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:rhwp_positional_index_request, request}, socket) do
    selected_document_id = active_document_id(socket)
    request_id = rhwp_request_value(request, ["request_id", :request_id])
    requested_document_id = rhwp_request_value(request, ["document_id", :document_id])
    text_events = rhwp_request_value(request, ["text_events", :text_events]) || []
    base_snapshot = rhwp_request_value(request, ["base_snapshot", :base_snapshot])
    document_id = requested_document_id || selected_document_id

    cond do
      not is_binary(request_id) or request_id == "" ->
        {:noreply, socket}

      not is_binary(selected_document_id) ->
        _ = ack_rhwp_snapshot_failed(request_id, document_id, :no_document)
        {:noreply, socket}

      is_binary(document_id) and document_id != selected_document_id ->
        _ = ack_rhwp_snapshot_failed(request_id, document_id, :document_mismatch)
        {:noreply, socket}

      true ->
        payload =
          %{
            request_id: request_id,
            document_id: selected_document_id,
            text_events: text_events
          }
          |> maybe_put_base_snapshot(base_snapshot)

        {:noreply, push_event(socket, "rhwp:positional_index.request", payload)}
    end
  end

  @impl true
  def handle_info({:open_document, ref, path}, socket) do
    if socket.assigns.pending_document_open_ref == ref and
         socket.assigns.pending_document_path == path do
      {:noreply, start_document_open(socket, ref, path)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:doc_viewer_state_request, from, ref, document_id}, socket) do
    result =
      if socket.assigns[:pool_document_id] == document_id do
        {:ok, %{dirty: viewer_document_dirty?(socket, document_id)}}
      else
        {:error, :document_mismatch}
      end

    send(from, {:doc_viewer_state_reply, ref, result})
    {:noreply, socket}
  end

  # Agent edit/read/find for the OPEN HWP, routed from `Ecrits.Doc.Tools` because
  # this document is `:browser`-backed in the Pool (its authority is the WASM
  # model in the viewer, not the server NIF). Push the verb to the WasmHwpEditor
  # hook and remember the caller so the hook's reply (a `document.engine.operation.replied`
  # client event) is relayed back to the waiting MCP process.
  def handle_info({:doc_browser_request, from, ref, verb, payload}, socket) do
    {:noreply, queue_doc_browser_request(socket, from, ref, verb, payload, nil)}
  end

  def handle_info(
        {:doc_browser_request, from, ref, verb, payload, expected_document_id},
        socket
      ) do
    {:noreply,
     queue_doc_browser_request(
       socket,
       from,
       ref,
       verb,
       payload,
       expected_document_id
     )}
  end

  # The bridge acknowledges a reply before returning it to its caller. Keeping
  # the entry until this acknowledgement closes the timeout/reply race: if the
  # caller's deadline wins, cancellation still has the original edit metadata
  # needed to roll back the browser transaction. For vfs_commit specifically,
  # this ACK is the irreversible boundary: only then do we release the owner
  # lease and ask the browser to discard its retained rollback snapshot.
  def handle_info({:doc_browser_request_completed, from, ref, ack_ref}, socket) do
    request_id = doc_browser_request_id(ref)

    case Map.get(socket.assigns.doc_browser_pending, request_id) do
      %{from: ^from, ref: ^ref, status: :replied} = entry ->
        socket = complete_doc_browser_pending(socket, request_id, entry)
        send(from, {:doc_browser_request_completion_ack, ack_ref, :ok})
        {:noreply, socket}

      _other ->
        send(
          from,
          {:doc_browser_request_completion_ack, ack_ref, {:error, :request_not_pending}}
        )

        {:noreply, socket}
    end
  end

  # Compatibility for in-process callers/tests created before the two-way
  # completion handshake. Production BrowserBridge calls use the four-tuple
  # above and do not return until this LiveView has crossed the commit boundary.
  def handle_info({:doc_browser_request_completed, from, ref}, socket) do
    request_id = doc_browser_request_id(ref)

    case Map.get(socket.assigns.doc_browser_pending, request_id) do
      %{from: ^from, ref: ^ref, status: :replied} = entry ->
        {:noreply, complete_doc_browser_pending(socket, request_id, entry)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info({:doc_browser_request_cancelled, from, ref, reason}, socket) do
    request_id = doc_browser_request_id(ref)

    case Map.get(socket.assigns.doc_browser_pending, request_id) do
      %{from: ^from, ref: ^ref} = entry ->
        {:noreply,
         cancel_doc_browser_pending(socket, request_id, entry,
           reason: {:bridge_cancelled, reason},
           reply?: false
         )}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info({:doc_browser_finalize_timeout, request_id, attempt}, socket) do
    case Map.get(socket.assigns.doc_browser_pending, request_id) do
      %{kind: :vfs_finalize, status: :waiting, attempt: ^attempt} = entry ->
        {:noreply, retry_or_recover_doc_browser_finalize(socket, request_id, entry, :timeout)}

      _other ->
        {:noreply, socket}
    end
  end

  def handle_info({:doc_browser_recovery_timeout, recovery_id, attempt}, socket) do
    case Map.get(socket.assigns.doc_browser_pending, recovery_id) do
      %{kind: :vfs_recovery, status: :waiting, attempt: ^attempt} = entry ->
        {:noreply, retry_or_fail_doc_browser_recovery(socket, recovery_id, entry, :timeout)}

      _other ->
        {:noreply, socket}
    end
  end

  # A tool process can be killed before its own timeout handler runs. Each
  # pending request therefore monitors its caller independently and uses the
  # same idempotent browser rollback path when that caller disappears.
  def handle_info({:DOWN, monitor_ref, :process, from, _reason}, socket) do
    if doc_browser_owner_monitor?(socket, monitor_ref, from) do
      {:noreply,
       cancel_doc_browser_owner(socket, from,
         reason: :caller_down,
         reply?: false
       )}
    else
      {:noreply, socket}
    end
  end

  # Debounced auto-save tick: the per-document timer fired. Drop it from the
  # timer map and, if the doc is still dirty, run a canonical save (the dot
  # clears via the `doc.save` browser_reply, verb `:save`).
  def handle_info({:autosave, id}, socket) do
    socket = update(socket, :autosave_timers, &Map.delete(&1, id))

    if MapSet.member?(socket.assigns.dirty_document_ids, id) do
      {:noreply, save_document(socket, id)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:document_saved, %Document{} = document, snapshot}, socket) do
    {:noreply, apply_document_snapshot(socket, :saved, document, snapshot)}
  end

  def handle_info({:document_checkpointed, %Document{} = document, snapshot}, socket) do
    {:noreply, apply_document_snapshot(socket, :checkpointed, document, snapshot)}
  end

  def handle_info({:workspace_fs_event, path}, socket) when is_binary(path) do
    if workspace_contains_path?(socket, path) and fs_relevant_path?(path) do
      {:noreply, schedule_tree_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:file_event, pid, :stop}, %{assigns: %{fs_watcher_pid: pid}} = socket) do
    {:noreply, assign(socket, :fs_watcher_pid, nil)}
  end

  # Stale per-LiveView watcher events from sockets that were hot-reloaded before
  # watcher ownership moved to `Workspace.Session` are ignored.
  def handle_info({:file_event, _pid, _payload}, socket), do: {:noreply, socket}

  def handle_info(:refresh_tree, socket) do
    socket =
      socket
      |> assign(:fs_refresh_timer, nil)
      |> refresh_tree()
      |> reconcile_open_documents()

    {:noreply, socket}
  end

  # An agent doc.create-clone / doc.save wrote a file (broadcast by
  # `Ecrits.Doc.Tools`). Refresh the tree the instant the write lands — but ONLY
  # when the file is under THIS workspace's root, so a write in some other open
  # workspace (or a scratch/temp path) never refreshes the wrong tree. Debounced
  # via the same timer the FS watcher uses, so a burst (clone-then-save, or a
  # batch save) collapses into one re-list.
  def handle_info({:workspace_file_written, path}, socket) when is_binary(path) do
    if workspace_contains_path?(socket, path) do
      {:noreply, schedule_tree_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  # A DIRECT edit of a mounted `.jsonl` was routed onto the document (doc VFS
  # write-back). Drop a file-viewer card in the chat rail showing where it landed.
  def handle_info({:vfs_doc_edited, info}, socket) when is_map(info) do
    info = ensure_vfs_preview_snapshot(socket, info)
    turn_id = vfs_doc_edit_turn_id(info)

    socket =
      socket
      |> maybe_route_vfs_doc_edit_preview(info, turn_id)
      |> resync_open_editor_after_vfs_edit(info)

    {:noreply, socket}
  end

  # A temp projection may have emitted a preview while its complete bytes were
  # being prepared. If the atomic rename is rejected, remove that provisional
  # card instead of presenting bytes that never became document truth.
  def handle_info({:vfs_doc_edit_rejected, info}, socket) when is_map(info) do
    socket =
      if vfs_doc_edit_preview_for_active_agent?(socket, info) do
        discard_rejected_vfs_preview(socket, info)
      else
        socket
      end

    {:noreply, socket}
  end

  defp stale_agent_event?(socket, %{event_seq: event_seq})
       when is_integer(event_seq) and event_seq >= 0 do
    event_seq <= (socket.assigns[:agent_event_seq] || 0)
  end

  # Compatibility for synthetic/older in-memory events. Real Session events
  # always carry a cursor; they are the only source involved in attach races.
  defp stale_agent_event?(_socket, _event), do: false

  defp advance_agent_event_cursor(socket, %{event_seq: event_seq})
       when is_integer(event_seq) and event_seq >= 0,
       do: assign(socket, :agent_event_seq, event_seq)

  defp advance_agent_event_cursor(socket, _event), do: socket

  defp maybe_route_vfs_doc_edit_preview(socket, info, turn_id) do
    if is_binary(turn_id) and turn_id != "" and
         vfs_doc_edit_preview_for_active_agent?(socket, info) do
      socket =
        socket
        |> split_agent_text_before_preview()
        |> maybe_persist_vfs_edit_preview(info, turn_id)

      if continuing_live_vfs_preview?(socket, info, turn_id) do
        socket
      else
        item = vfs_doc_edit_item(socket, info, turn_id)

        socket
        |> replace_live_vfs_editor_preview(item)
        |> maybe_stream_agent_item(item)
      end
    else
      socket
    end
  end

  defp continuing_live_vfs_preview?(socket, info, turn_id) do
    not vfs_edit_progress_complete?(info) and
      item_field(info, :preview_continuation) == true and
      is_nil(item_field(info, :preview_base_url)) and
      is_nil(item_field(info, :preview_snapshot)) and
      match?(
        %{role: :editor_preview, turn_id: ^turn_id},
        socket.assigns[:agent_vfs_preview_item]
      )
  end

  defp discard_rejected_vfs_preview(socket, info) do
    rejected_edit_id = item_field(info, :edit_id)
    rejected_turn_id = item_field(info, :turn_id)

    case socket.assigns[:agent_vfs_preview_item] do
      %{role: :editor_preview} = item ->
        matching_provisional? =
          provisional_vfs_preview?(item) and
            is_binary(rejected_edit_id) and rejected_edit_id != "" and
            item_field(item, :edit_id) == rejected_edit_id and
            is_binary(rejected_turn_id) and rejected_turn_id != "" and
            item_field(item, :turn_id) == rejected_turn_id

        if matching_provisional? do
          socket = stream_delete(socket, :agent_items, item)

          case socket.assigns[:agent_vfs_preview_rollback_item] do
            %{role: :editor_preview} = rollback_item ->
              socket
              |> stream_insert(:agent_items, rollback_item)
              |> assign(:agent_vfs_preview_item, rollback_item)
              |> assign(:agent_vfs_preview_rollback_item, nil)

            _other ->
              socket
              |> assign(:agent_vfs_preview_item, nil)
              |> assign(:agent_vfs_preview_rollback_item, nil)
          end
        else
          socket
        end

      _other ->
        socket
    end
  end

  defp vfs_doc_edit_preview_for_active_agent?(socket, info) do
    with turn_id when is_binary(turn_id) and turn_id != "" <- vfs_doc_edit_turn_id(info),
         agent_id when is_binary(agent_id) and agent_id != "" <- vfs_doc_edit_agent_id(info),
         instance_id when is_binary(instance_id) and instance_id != "" <-
           vfs_doc_edit_instance_id(info) do
      agent_id == socket.assigns[:agent_session_id] and
        instance_id == socket.assigns[:agent_instance_id] and
        known_agent_turn?(socket, agent_id, turn_id)
    else
      _other -> false
    end
  end

  defp known_agent_turn?(socket, agent_id, turn_id) do
    turn_id == socket.assigns[:agent_turn_id] or
      turn_id == item_field(socket.assigns[:agent_vfs_preview_item], :turn_id) or
      agent_snapshot_has_turn?(agent_id, turn_id)
  end

  defp agent_snapshot_has_turn?(agent_id, turn_id) do
    snapshot = ACP.agent_snapshot(agent_id)

    current_turn_id =
      snapshot
      |> Map.get(:current_turn)
      |> item_field(:turn_id)

    current_turn_id == turn_id or
      Enum.any?(Map.get(snapshot, :transcript, []), &(item_field(&1, :turn_id) == turn_id))
  rescue
    _error -> false
  catch
    :exit, _reason -> false
  end

  defp vfs_doc_edit_agent_id(info) when is_map(info) do
    item_field(info, :agent_id)
  end

  defp vfs_doc_edit_instance_id(info) when is_map(info),
    do: item_field(info, :instance_id)

  # A VFS write edits the SERVER document model + saves to disk. This function is
  # not the VFS write path; it only keeps an already-open browser viewer in sync
  # after the file-level write-back has committed. When write-back produced exact
  # semantic ops/sets, reuse the non-mirror browser hook (`document.engine.operation.command` ->
  # patch the WASM model -> repaint the affected page); that is a post-commit UI
  # resync layer, not the authoring route. (Match by PATH:
  # `hwp_stream_document_id` is the Document struct id "local-…", while the
  # write-back keys the Pool document id.)
  defp resync_open_editor_after_vfs_edit(socket, %{path: edited_abs} = info)
       when is_binary(edited_abs) do
    workspace_path = socket.assigns[:workspace_path]
    renderer = socket.assigns[:hwp_stream_renderer]
    open_id = socket.assigns[:hwp_stream_document_id]
    open_rel = socket.assigns[:active_document_path]
    ops = Map.get(info, :ops, [])
    sets = Map.get(info, :sets, [])

    cond do
      item_field(info, :preview_only) == true ->
        socket

      item_field(info, :browser_authority) == true ->
        socket

      renderer not in [:rhwp_wasm, :office_wasm] ->
        socket

      not (is_binary(workspace_path) and is_binary(open_rel)) ->
        socket

      canonical_path_for_compare(edited_abs) !=
          canonical_path_for_compare(Path.join(workspace_path, open_rel)) ->
        socket

      # Incremental live apply (the browser-arm path). request_id is synthetic —
      # there is no MCP waiter, so the editor's reply lands on an unknown id and
      # is harmlessly ignored by `document.engine.operation.replied`.
      renderer in [:rhwp_wasm, :office_wasm] and (ops != [] or sets != []) ->
        socket
        |> push_vfs_browser_edit(open_id, ops)
        |> push_vfs_browser_set(open_id, sets)

      # No semantic ops, or a structural edit that cannot be replayed: re-fetch
      # saved bytes.
      true ->
        version = System.unique_integer([:positive, :monotonic])
        socket = assign(socket, :document_bytes_version, version)

        case document_bytes_url(workspace_path, open_rel, version) do
          base when is_binary(base) ->
            event =
              if renderer == :rhwp_wasm,
                do: "document.hwp.load_command",
                else: "document.office.load_command"

            push_event(socket, event, %{url: base, document_id: open_id})

          _ ->
            socket
        end
    end
  end

  defp resync_open_editor_after_vfs_edit(socket, _info), do: socket

  defp push_vfs_browser_edit(socket, _document_id, []), do: socket

  defp push_vfs_browser_edit(socket, document_id, ops) do
    push_event(socket, "document.engine.operation.command", %{
      request_id: "vfs-" <> Integer.to_string(System.unique_integer([:positive, :monotonic])),
      document_id: document_id,
      verb: "edit",
      payload: %{ops: ops, resync: true}
    })
  end

  defp push_vfs_browser_set(socket, _document_id, []), do: socket

  defp push_vfs_browser_set(socket, document_id, sets) do
    push_event(socket, "document.engine.operation.command", %{
      request_id: "vfs-" <> Integer.to_string(System.unique_integer([:positive, :monotonic])),
      document_id: document_id,
      verb: "set",
      payload: %{sets: sets, resync: true}
    })
  end

  @impl true
  def handle_async(@doc_vfs_mount_async, {:ok, {path, result}}, socket) do
    {:noreply, apply_doc_vfs_mount_result(socket, path, result)}
  end

  def handle_async(@doc_vfs_mount_async, {:exit, reason}, socket) do
    Logger.warning("[DocMount] async ensure exited: #{inspect(reason)}")

    case socket.assigns[:workspace_path] do
      path when is_binary(path) ->
        {:noreply, put_doc_vfs_mount_state(socket, path, DocMount.mounted?(path))}

      _other ->
        {:noreply, assign(socket, :fuse_mode, false)}
    end
  end

  @impl true
  def handle_async(@document_open_async, {:ok, {ref, path, result}}, socket) do
    if socket.assigns.pending_document_open_ref == ref and
         socket.assigns.pending_document_path == path do
      {:noreply, apply_document_open_result(socket, path, result)}
    else
      {:noreply, socket}
    end
  end

  def handle_async(@document_open_async, {:exit, {:shutdown, :cancel}}, socket) do
    {:noreply, socket}
  end

  def handle_async(@document_open_async, {:exit, reason}, socket) do
    case socket.assigns.pending_document_path do
      path when is_binary(path) and path != "" ->
        {:noreply, apply_document_open_result(socket, path, {:error, reason})}

      _other ->
        {:noreply, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    _ = unsubscribe_hwp_stream(socket)
    _ = unregister_rhwp_materializer_editor(active_document_id(socket))
    _ = stop_fs_watcher(socket)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant="split">
      <div
        id="workspace-root"
        phx-hook=".ChatRailTabIdentity"
        data-octet-sink={@octet_sink_id}
        class="h-dvh min-h-0 min-w-[1024px] overflow-hidden bg-[var(--cs-bg)] text-[var(--cs-ink)]"
      >
        <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatRailTabIdentity">
          const chatRailTabStorageKey = "ecrits:chat-rail-tab-id"

          const chatRailTabId = () => {
            const freshId = () => globalThis.crypto.randomUUID()

            try {
              const storedId = globalThis.sessionStorage.getItem(chatRailTabStorageKey)

              if (storedId) return storedId

              const id = freshId()
              globalThis.sessionStorage.setItem(chatRailTabStorageKey, id)
              return id
            } catch (_error) {
              return freshId()
            }
          }

          const announceChatRailTab = hook => {
            hook.pushEvent("workspace.chat_rail.tab_ready", {id: chatRailTabId()})
          }

          export default {
            mounted() {
              announceChatRailTab(this)
            },

            reconnected() {
              announceChatRailTab(this)
            }
          }
        </script>

        <div
          :if={@workspace_error}
          id="workspace-error"
          class="mx-auto max-w-xl px-4 py-16"
        >
          <div class="rounded-md border border-error/25 bg-error/10 px-4 py-3 text-sm text-error">
            {@workspace_error}
          </div>
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm mt-4">Back</.link>
        </div>

        <div
          :if={!@workspace_error}
          id="workspace-grid"
          data-office-asset-version={OfficeWasm.office_asset_version()}
          data-workspace-layout={WorkspaceLayout.encode(@workspace_layout)}
          style={WorkspaceLayout.grid_style(@workspace_layout)}
          class={[
            "isolate grid h-full min-h-0 overflow-hidden",
            if(@workspace_layout.editor_fullscreen?,
              do: "grid-cols-[0_minmax(0,1fr)_0]",
              else:
                "grid-cols-[var(--workspace-file-tree-live-width,var(--workspace-file-tree-width,260px))_minmax(0,1fr)_var(--workspace-chat-rail-live-width,var(--workspace-chat-rail-width,340px))]"
            )
          ]}
        >
          <script :type={Phoenix.LiveView.ColocatedHook} name=".WorkspacePanelResize">
            const panelResizeModels = new WeakMap()

            const panelConfig = panel => panel === "file_tree" ? {
              cssVariable: "--workspace-file-tree-width",
              liveCssVariable: "--workspace-file-tree-live-width",
              direction: 1,
              minimum: 220,
              maximum: 520,
              oppositeId: "agent-sidebar"
            } : {
              cssVariable: "--workspace-chat-rail-width",
              liveCssVariable: "--workspace-chat-rail-live-width",
              direction: -1,
              minimum: 280,
              maximum: 720,
              oppositeId: "file-tree-panel"
            }

            const serverWidth = (grid, panel) => {
              try {
                const layout = JSON.parse(grid.dataset.workspaceLayout || "{}")
                const width = panel === "file_tree"
                  ? layout.fileTreeWidth
                  : layout.chatRailWidth
                return Number.isFinite(width) ? Math.round(width) : null
              } catch (_error) {
                return null
              }
            }

            const createPanelResizeModel = hook => {
              let drag = null

              const syncServerWidth = () => {
                if (drag) return
                const panel = hook.el.dataset.panel
                const config = panelConfig(panel)
                const grid = document.getElementById("workspace-grid")
                if (!grid) return
                const width = serverWidth(grid, panel)
                if (width !== null) grid.style.setProperty(config.cssVariable, `${width}px`)
                grid.style.removeProperty(config.liveCssVariable)
              }

              const applyLocalWidth = x => {
                if (!drag) return null
                const viewportWidth = Math.max(window.innerWidth, 1024)
                const oppositeWidth = document.getElementById(drag.config.oppositeId)
                  ?.getBoundingClientRect().width || 0
                const maximum = Math.max(
                  drag.config.minimum,
                  Math.min(drag.config.maximum, viewportWidth - oppositeWidth - 360)
                )
                const width = Math.round(Math.max(
                  drag.config.minimum,
                  Math.min(
                    maximum,
                    drag.startWidth + (x - drag.startX) * drag.config.direction
                  )
                ))
                drag.lastX = x
                drag.grid.style.setProperty(drag.config.liveCssVariable, `${width}px`)
                return width
              }

              const onPointerDown = event => {
                if (event.button !== 0 && event.pointerType !== "touch") return
                event.preventDefault()
                const panel = hook.el.dataset.panel
                const controlled = document.getElementById(hook.el.getAttribute("aria-controls"))
                const grid = document.getElementById("workspace-grid")
                if (!controlled || !grid) return
                drag = {
                  panel,
                  config: panelConfig(panel),
                  grid,
                  pointerId: event.pointerId,
                  startX: event.clientX,
                  lastX: event.clientX,
                  startWidth: Math.round(controlled.getBoundingClientRect().width)
                }
                hook.el.dataset.dragging = "true"
                hook.el.setPointerCapture(event.pointerId)
              }

              const onPointerMove = event => {
                if (!hook.el.hasPointerCapture(event.pointerId)) return
                event.preventDefault()
                applyLocalWidth(event.clientX)
              }

              const finishPointerResize = event => {
                const finishedDrag = drag
                if (!finishedDrag) return
                if (Number.isFinite(event.pointerId) && event.pointerId !== finishedDrag.pointerId) return
                const x = Number.isFinite(event.clientX) ? event.clientX : finishedDrag.lastX
                const width = applyLocalWidth(x)
                drag = null
                hook.el.dataset.dragging = "false"
                if (hook.el.hasPointerCapture(finishedDrag.pointerId)) {
                  hook.el.releasePointerCapture(finishedDrag.pointerId)
                }
                let settled = false
                const settle = reply => {
                  if (settled) return
                  settled = true
                  window.clearTimeout(finishedDrag.settleTimer)
                  const confirmedWidth = Number.isFinite(reply?.width)
                    ? Math.round(reply.width)
                    : serverWidth(finishedDrag.grid, finishedDrag.panel)
                  if (confirmedWidth !== null) {
                    finishedDrag.grid.style.setProperty(finishedDrag.config.cssVariable, `${confirmedWidth}px`)
                  }
                  finishedDrag.grid.style.removeProperty(finishedDrag.config.liveCssVariable)
                }
                finishedDrag.settleTimer = window.setTimeout(() => settle({width}), 1000)
                hook.pushEvent("workspace.layout.resize.finish", {
                  panel: finishedDrag.panel,
                  start_x: finishedDrag.startX,
                  x,
                  panel_width: finishedDrag.startWidth,
                  viewport_width: window.innerWidth
                }, settle)
              }

              const onLostPointerCapture = event => finishPointerResize(event)
              const onWindowPointerUp = event => finishPointerResize(event)
              const onWindowPointerCancel = event => finishPointerResize(event)

              return {
                mount() {
                  syncServerWidth()
                  hook.el.addEventListener("pointerdown", onPointerDown)
                  hook.el.addEventListener("pointermove", onPointerMove)
                  hook.el.addEventListener("pointerup", finishPointerResize)
                  hook.el.addEventListener("pointercancel", finishPointerResize)
                  hook.el.addEventListener("lostpointercapture", onLostPointerCapture)
                  window.addEventListener("pointerup", onWindowPointerUp)
                  window.addEventListener("pointercancel", onWindowPointerCancel)
                },
                updated: syncServerWidth,
                destroy() {
                  hook.el.removeEventListener("pointerdown", onPointerDown)
                  hook.el.removeEventListener("pointermove", onPointerMove)
                  hook.el.removeEventListener("pointerup", finishPointerResize)
                  hook.el.removeEventListener("pointercancel", finishPointerResize)
                  hook.el.removeEventListener("lostpointercapture", onLostPointerCapture)
                  window.removeEventListener("pointerup", onWindowPointerUp)
                  window.removeEventListener("pointercancel", onWindowPointerCancel)
                  if (drag) {
                    drag.grid.style.removeProperty(drag.config.liveCssVariable)
                    drag = null
                  }
                  syncServerWidth()
                }
              }
            }

            export default {
              mounted() {
                const model = createPanelResizeModel(this)
                panelResizeModels.set(this, model)
                model.mount()
              },
              updated() {
                panelResizeModels.get(this)?.updated()
              },
              destroyed() {
                panelResizeModels.get(this)?.destroy()
                panelResizeModels.delete(this)
              }
            }
          </script>
          <aside
            id="file-tree-panel"
            aria-label="Workspace files"
            data-component="repo-browser"
            data-file-tree-panel="true"
            data-collapsed={to_string(@workspace_layout.file_tree_collapsed?)}
            class={[
              "relative min-h-0 flex-col overflow-hidden border-r border-base-300 bg-base-100",
              if(@workspace_layout.editor_fullscreen?, do: "hidden", else: "flex")
            ]}
          >
            <div
              id="file-tree-content"
              data-role="file-tree-content"
              aria-hidden={to_string(@workspace_layout.file_tree_collapsed?)}
              class={[
                "min-h-0 flex-1 flex-col",
                if(@workspace_layout.file_tree_collapsed?, do: "hidden", else: "flex")
              ]}
            >
              <div
                data-role="repo-browser-header"
                data-action="collapse-file-tree"
                class="cursor-pointer border-b border-base-300 bg-base-100 transition-colors hover:bg-base-200/60"
              >
                <div class="flex h-11 items-center justify-between gap-2 px-3">
                  <div class="flex min-w-0 items-center gap-2">
                    <.link
                      navigate={~p"/"}
                      aria-label="Ecrits"
                      class="flex-none text-base-content/70 transition-colors hover:text-base-content"
                    >
                      <Brand.mark size="sm" />
                    </.link>
                    <h1 class="truncate text-sm font-semibold text-base-content">
                      {workspace_title(@workspace)}
                    </h1>
                  </div>
                  <button
                    id="file-tree-hide"
                    type="button"
                    phx-click="workspace.file_tree.toggle"
                    data-role="file-tree-hide"
                    aria-label="Hide file tree"
                    aria-controls="file-tree-content"
                    aria-expanded={to_string(not @workspace_layout.file_tree_collapsed?)}
                    class="inline-flex size-7 shrink-0 items-center justify-center rounded text-base-content/55 transition-colors hover:bg-base-200 hover:text-base-content focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content/35"
                  >
                    <.icon name="hero-chevron-left" class="size-4" />
                  </button>
                </div>
              </div>

              <div class="min-h-0 flex-1 overflow-auto">
                <WorkspaceFileTree.tree
                  id="file-tree"
                  state={@file_tree}
                />
              </div>
            </div>

            <div
              id="file-tree-restore"
              data-role="file-tree-restore"
              class={[
                "bg-base-100 px-1.5 py-1.5",
                if(@workspace_layout.file_tree_collapsed?, do: "block", else: "hidden")
              ]}
            >
              <button
                id="file-tree-show"
                type="button"
                phx-click="workspace.file_tree.toggle"
                data-role="file-tree-show"
                aria-label="Show file tree"
                aria-controls="file-tree-content"
                aria-expanded={to_string(not @workspace_layout.file_tree_collapsed?)}
                class="inline-flex size-7 items-center justify-center rounded text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content/35"
              >
                <.icon name="hero-chevron-right" class="size-4" />
              </button>
            </div>

            <button
              id="file-tree-resizer"
              type="button"
              phx-hook=".WorkspacePanelResize"
              data-panel="file_tree"
              data-role="file-tree-resizer"
              aria-label="Resize file tree"
              aria-controls="file-tree-panel"
              hidden={@workspace_layout.file_tree_collapsed?}
              data-dragging={
                to_string(
                  not is_nil(@workspace_layout.drag) and
                    @workspace_layout.drag.panel == :file_tree
                )
              }
              class={[
                "absolute -right-1 top-0 z-10 block h-full w-2 cursor-col-resize touch-none select-none",
                "focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content/35",
                "before:absolute before:left-1/2 before:top-0 before:h-full before:w-px before:-translate-x-1/2",
                "before:bg-base-300 before:transition-colors before:duration-150",
                "hover:before:bg-base-content/35 data-[dragging=true]:before:bg-base-content/35"
              ]}
            ></button>
          </aside>

          <section
            id="editor-shell"
            data-editor-shell="true"
            class="relative z-[var(--workspace-editor-z)] h-full min-h-0 min-w-0 overflow-hidden bg-[var(--cs-bg)]"
          >
            <EditorSurface.document
              :if={@active_document || @open_documents != []}
              shell_id="rhwp-shell"
              toolbar_id="rhwp-toolbar"
              frame_id="rhwp-editor-frame"
              state={
                EditorSurfaceState.new(%{
                  document: @active_document,
                  document_path: @active_document_path,
                  document_viewport: @active_document_viewport,
                  document_loading?: @document_status == :loading,
                  document_spec: @active_document && document_spec(@active_document),
                  canvas_id: @active_document && rhwp_dom_id(@active_document),
                  hwp_bytes_url:
                    @active_document &&
                      document_bytes_url(
                        @workspace_path,
                        @active_document.relative_path,
                        @document_bytes_version
                      ),
                  open_documents: @open_documents,
                  active_document_id: @active_document_id,
                  dirty_document_ids: @dirty_document_ids,
                  document_element_picker: @document_element_picker,
                  editor_toolbar: @editor_toolbar,
                  document_search: @document_search,
                  hwp_page_count: @hwp_page_count,
                  markdown_editor: @markdown_editor,
                  markdown_preview_html: @markdown_preview_html,
                  workspace_layout: @workspace_layout,
                  save_state:
                    @active_document &&
                      save_state(
                        @active_document,
                        @document_snapshot,
                        @document_status
                      )
                })
              }
              hwp_pages={@streams.hwp_pages}
            />
          </section>

          <aside
            id="agent-sidebar"
            data-default-visible="true"
            data-session-id={@agent_session_id || ""}
            data-agent-status={to_string(@agent_status)}
            data-component="chat-rail"
            data-chat-rail="true"
            data-provider-key={@agent.provider.key}
            class={[
              "relative z-[var(--workspace-agent-rail-z)] col-start-3 h-full min-h-0 flex-col overflow-visible border-l border-base-300 bg-base-200 text-base-content",
              if(@workspace_layout.editor_fullscreen?, do: "hidden", else: "flex")
            ]}
          >
            <button
              id="agent-rail-resizer"
              type="button"
              phx-hook=".WorkspacePanelResize"
              data-panel="chat_rail"
              data-role="chat-rail-resizer"
              aria-label="Resize chat rail"
              aria-controls="agent-sidebar"
              data-dragging={
                to_string(
                  not is_nil(@workspace_layout.drag) and
                    @workspace_layout.drag.panel == :chat_rail
                )
              }
              class={[
                "absolute -left-1 top-0 z-10 block h-full w-2 cursor-col-resize touch-none select-none",
                "focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content/35",
                "before:absolute before:left-1/2 before:top-0 before:h-full before:w-px before:-translate-x-1/2",
                "before:bg-base-300 before:transition-colors before:duration-150",
                "hover:before:bg-base-content/35 data-[dragging=true]:before:bg-base-content/35"
              ]}
            ></button>

            <p
              :if={@agent.provider_warning}
              id="agent-provider-warning"
              class="border-b border-warning/20 bg-warning/10 px-3 py-2 text-xs leading-5 text-warning"
            >
              {@agent.provider_warning}
            </p>

            <%!-- Each attached workspace LiveView renders the selected shared
                 browser-tab rail inline. The Session synchronizes create/select
                 rebinds across simultaneous processes for that tab. --%>
            <div
              data-role="chat-rail-controls"
              class="flex shrink-0 items-center justify-between gap-1.5 border-b border-base-300 bg-base-200/95 px-1.5 py-0.5"
            >
              <div
                id="agent-title"
                data-role="chat-thread-title"
                title={@agent_title}
                phx-click-away="agent.rail_picker.close"
                class="relative flex min-w-0 flex-1 items-center gap-1.5 text-sm font-semibold leading-5 text-base-content"
              >
                <.form
                  for={@agent_title_form}
                  id="agent-title-form"
                  phx-change="agent.title.change"
                  phx-submit="agent.title.change"
                  data-role="chat-thread-title-form"
                  class="min-w-0 flex-1"
                >
                  <input
                    id="agent-title-label"
                    name={@agent_title_form[:title].name}
                    value={@agent_title}
                    type="text"
                    autocomplete="off"
                    maxlength="120"
                    aria-label="Chat title"
                    data-role="chat-thread-title-label"
                    class="block h-6 w-full min-w-0 truncate rounded-sm border border-transparent bg-transparent px-1 py-0 text-sm font-semibold leading-6 text-base-content outline-none transition-colors placeholder:text-transparent hover:border-base-content/15 focus:border-base-content/35 focus:bg-base-100 focus:outline-none"
                  />
                </.form>

                <button
                  id="agent-rail-picker"
                  type="button"
                  phx-click={
                    if(@agent_rail_drawer_open?,
                      do: "agent.rail_picker.close",
                      else: "agent.rail_picker.open"
                    )
                  }
                  data-role="chat-rail-picker"
                  data-open={@agent_rail_drawer_open?}
                  data-state={if(@agent_rail_drawer_open?, do: "open", else: "closed")}
                  data-count={length(@agent_rails)}
                  aria-label="Select chat rail"
                  aria-expanded={@agent_rail_drawer_open?}
                  aria-controls="agent-rail-drawer"
                  class={[
                    "inline-flex h-7 shrink-0 items-center gap-1 rounded px-1.5 text-xs transition-colors",
                    @agent_rail_drawer_open? &&
                      "bg-base-100 text-base-content",
                    not @agent_rail_drawer_open? &&
                      "text-base-content/70 hover:bg-base-100 hover:text-base-content"
                  ]}
                >
                  <.icon name="hero-chat-bubble-left-right" class="size-4" />
                  <span
                    :if={length(@agent_rails) > 1}
                    data-role="chat-rail-count"
                    class="tabular-nums"
                  >
                    {length(@agent_rails)}
                  </span>
                </button>

                <div
                  id="agent-rail-drawer"
                  data-role="chat-rail-dropdown"
                  data-open={@agent_rail_drawer_open?}
                  data-state={if(@agent_rail_drawer_open?, do: "open", else: "closed")}
                  class={[
                    "absolute left-0 right-0 top-8 z-30 origin-top rounded border border-base-300 bg-base-100 p-1.5 shadow-sm",
                    "transition-opacity duration-75 ease-out",
                    @agent_rail_drawer_open? &&
                      "visible opacity-100",
                    not @agent_rail_drawer_open? &&
                      "invisible pointer-events-none opacity-0"
                  ]}
                >
                  <div class="flex items-center justify-between px-1.5 pb-1">
                    <p class="text-[11px] font-medium leading-4 text-base-content/70">
                      Recent chats
                    </p>
                    <p
                      :if={length(@agent_rails) > 1}
                      data-role="chat-rail-dropdown-count"
                      class="text-[10px] leading-4 text-base-content/45"
                    >
                      {length(@agent_rails)} rails
                    </p>
                  </div>

                  <div class="flex max-h-64 flex-col gap-0.5 overflow-y-auto">
                    <button
                      :for={rail <- @agent_rails}
                      id={"agent-rail-option-#{rail.agent_id}"}
                      type="button"
                      phx-click="agent.rail.select"
                      phx-value-rail-key={rail.rail_key}
                      data-role="chat-rail-option"
                      data-agent-id={rail.agent_id}
                      data-active={rail.active?}
                      class={[
                        "flex min-w-0 items-start gap-2 rounded px-2 py-2 text-left transition-colors",
                        rail.active? && "bg-base-200 text-base-content",
                        not rail.active? &&
                          "text-base-content/75 hover:bg-base-200 hover:text-base-content"
                      ]}
                    >
                      <span class="mt-0.5 inline-flex size-4 shrink-0 items-center justify-center text-base-content/45">
                        <.icon name="hero-chat-bubble-left" class="size-3.5" />
                      </span>
                      <span class="min-w-0 flex-1">
                        <span
                          data-role="chat-rail-option-title"
                          class="block truncate text-[13px] font-medium leading-4"
                        >
                          {agent_rail_title(rail)}
                        </span>
                        <span
                          data-role="chat-rail-option-meta"
                          class="mt-0.5 block truncate text-[11px] leading-4 text-base-content/50"
                        >
                          {agent_rail_meta(rail)}
                        </span>
                      </span>
                      <.icon
                        :if={rail.active?}
                        name="hero-check"
                        class="mt-0.5 size-3.5 shrink-0 text-base-content/60"
                      />
                    </button>
                    <p
                      :if={@agent_rails == []}
                      id="agent-rail-empty"
                      class="px-2 py-2 text-xs text-base-content/45"
                    >
                      No recent chats
                    </p>
                  </div>
                </div>
              </div>
              <span
                id="agent-status"
                data-role="agent-status"
                aria-live="polite"
                class="sr-only"
              >
                {agent_status_label(@agent_status)}
              </span>
              <span
                :if={@agent_pending > 0}
                id="agent-pending"
                data-role="agent-pending"
                data-pending={@agent_pending}
                aria-live="polite"
                title="Queued messages waiting for the current turn"
                class="inline-flex h-5 shrink-0 items-center rounded-full border border-base-content/20 bg-base-100 px-2 text-[11px] font-medium text-base-content/70"
              >
                {@agent_pending} 대기
              </span>
              <button
                id="agent-refresh"
                type="button"
                phx-click="agent.conversation.create"
                class="inline-flex size-7 shrink-0 items-center justify-center rounded text-base-content/55 hover:bg-base-100 hover:text-base-content disabled:pointer-events-none disabled:opacity-45"
                aria-label="New agent chat"
                disabled={@agent_status == :starting}
              >
                <.icon name="hero-arrow-path" class="size-4" />
              </button>
            </div>

            <div data-role="chat-rail-body" class="flex min-h-0 flex-1 flex-col overflow-visible">
              <div
                id="agent-thread"
                phx-update="stream"
                phx-hook=".StickToBottom"
                data-scroll-follow-state={ScrollFollow.encode(@chat_scroll_follow)}
                data-role="chat-stream"
                class="flex min-h-0 flex-1 flex-col items-stretch gap-3 overflow-x-hidden overflow-y-auto px-4 py-3"
              >
                <article
                  :for={{dom_id, item} <- @streams.agent_items}
                  id={dom_id}
                  data-role={agent_item_data_role(item)}
                  data-chat-role="chat-message"
                  data-message-role={agent_item_role(item)}
                  data-message-status={agent_item_status(item)}
                  class={agent_item_class(item)}
                >
                  <%= case agent_item_role(item) do %>
                    <% "file_activity" -> %>
                      <div
                        data-role="file-activity-row"
                        data-operation-kind={file_activity_kind(item)}
                        class="flex min-w-0 items-center gap-1.5 px-3 py-1 text-[12px] text-base-content/60"
                      >
                        <.icon
                          name={file_activity_icon(item)}
                          class="size-3.5 shrink-0"
                        />
                        <span class="shrink-0">{file_activity_label(item)}:</span>
                        <span
                          class="min-w-0 truncate font-mono"
                          title={file_activity_detail(item)}
                        >
                          {file_activity_detail(item)}
                        </span>
                        <span class="ml-auto shrink-0 text-[11px] text-base-content/70">
                          {agent_item_status_label(item)}
                        </span>
                      </div>
                    <% "tool" -> %>
                      <% render_files = agent_item_render_files(item) %>
                      <div
                        data-role="operation-block"
                        data-operation-kind={agent_item_operation_kind(item)}
                        class="min-w-0 px-3 py-1 text-[12px] text-base-content/60"
                      >
                        <details id={"#{dom_id}-disclosure"} class="group">
                          <summary
                            id={"#{dom_id}-toggle"}
                            aria-controls={"#{dom_id}-details"}
                            class="flex w-full min-w-0 cursor-pointer list-none items-center gap-1.5 text-left hover:text-base-content"
                          >
                            <.icon
                              name={agent_item_operation_icon(item)}
                              class="size-3.5 shrink-0"
                            />
                            <span class="shrink-0">{agent_item_operation_label(item)}:</span>
                            <span class="min-w-0 truncate font-mono">{agent_item_title(item)}</span>
                            <span class="ml-auto shrink-0 text-[11px] text-base-content/45">
                              {agent_item_status_label(item)}
                            </span>
                            <.icon
                              name="hero-chevron-down"
                              class="size-3 shrink-0 text-base-content/45 transition-transform duration-150 group-open:rotate-180"
                            />
                          </summary>
                          <div
                            id={"#{dom_id}-details"}
                            data-role="operation-details"
                            class="mt-1 border-l border-base-300 pl-3"
                          >
                            <pre class="whitespace-pre-wrap break-words font-mono text-[11px] leading-relaxed text-base-content/55">{agent_item_body(item)}</pre>
                          </div>
                        </details>
                        <%!-- doc.render chips show the rendered page itself —
                             the raw tool payload stays behind the toggle. --%>
                        <div
                          :if={render_files != []}
                          data-role="render-preview"
                          class="mt-1.5 flex flex-wrap gap-2"
                        >
                          <a
                            :for={file <- render_files}
                            href={"/render-preview?file=#{URI.encode_www_form(file)}"}
                            target="_blank"
                            rel="noopener"
                            title={Path.basename(file)}
                            class="block max-w-full overflow-hidden rounded border border-base-300 bg-white shadow-sm transition-shadow hover:shadow"
                          >
                            <img
                              src={"/render-preview?file=#{URI.encode_www_form(file)}"}
                              alt={"Rendered page " <> Path.basename(file)}
                              loading="lazy"
                              class="block max-h-48 w-auto"
                            />
                          </a>
                        </div>
                      </div>
                    <% "editor_preview" -> %>
                      <div data-role="editor-preview-card" class="min-w-0 w-full px-3 py-1.5">
                        <%= if agent_editor_preview_unavailable?(item) do %>
                          <div
                            data-role="editor-preview-unavailable"
                            role="status"
                            class="flex items-center gap-2 border border-base-300 bg-base-200/40 px-3 py-2 text-xs text-base-content/65"
                          >
                            <.icon
                              name="hero-exclamation-triangle"
                              class="size-4 shrink-0"
                            />
                            <span>Saved document preview is unavailable.</span>
                          </div>
                        <% else %>
                          <EditorSurface.embedded_document
                            id={"#{dom_id}-surface"}
                            state={agent_editor_preview_state(item)}
                          />
                        <% end %>
                      </div>
                    <% "thinking" -> %>
                      <details
                        id={"#{dom_id}-disclosure"}
                        data-role="operation-block"
                        data-operation-kind="thinking"
                        class="group min-w-0 px-3 py-1 text-[12px] text-base-content/60"
                      >
                        <summary
                          id={"#{dom_id}-toggle"}
                          aria-controls={"#{dom_id}-details"}
                          class="flex w-full min-w-0 cursor-pointer list-none items-center gap-1.5 text-left hover:text-base-content"
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
                            class="ml-auto size-3 shrink-0 text-base-content/45 transition-transform duration-150 group-open:rotate-180"
                          />
                        </summary>
                        <div
                          id={"#{dom_id}-details"}
                          data-role="operation-details"
                          class="mt-1 border-l border-base-300 pl-3"
                        >
                          <pre class="whitespace-pre-wrap break-words text-[11px] leading-relaxed text-base-content/55"><span
                              data-role="agent-reasoning-details-text"
                              data-message-id={dom_id}
                            >{agent_item_body(item)}</span></pre>
                        </div>
                      </details>
                    <% "user" -> %>
                      <div
                        data-role="chat-message-body"
                        class="min-w-0 w-full border border-base-content/10 bg-base-300/50 px-3 py-1.5 text-[13px] leading-snug whitespace-normal break-words text-base-content/95 shadow-[inset_0_1px_3px_rgba(0,0,0,0.10)]"
                      >
                        <% picks = agent_item_picks(item) %>
                        <div
                          :if={picks != []}
                          data-role="picked-element-chips"
                          class="mb-1 flex w-full min-w-0 flex-wrap gap-1"
                        >
                          <span
                            :for={pick <- picks}
                            data-role="picked-element-chip"
                            title={pick["ref"]}
                            class="inline-flex max-w-full min-w-0 items-center gap-1 rounded border border-base-content/15 bg-base-100/80 px-1.5 py-0.5 text-[11px] leading-4 text-base-content/75"
                          >
                            <.icon
                              name="hero-cursor-arrow-rays"
                              class="size-3 shrink-0 text-base-content/45"
                            />
                            <span class="shrink-0 font-medium text-base-content/55">
                              {pick["type"]}
                            </span>
                            <span :if={pick_chip_label(pick) != ""} class="min-w-0 truncate">
                              {pick_chip_label(pick)}
                            </span>
                          </span>
                        </div>
                        <ChatRail.markdown_body
                          body={agent_item_body(item)}
                          paragraph_role="chat-md-paragraph"
                        />
                      </div>
                    <% _ -> %>
                      <div
                        data-role="agent-text"
                        data-message-id={dom_id}
                        aria-busy={agent_item_loading?(item, @agent_editor_preview)}
                        class="block min-w-0 px-3 py-1 text-left text-[14px] leading-relaxed break-words text-base-content"
                      >
                        <div data-role="agent-text-body" data-message-id={dom_id}>
                          <ChatRail.markdown_body
                            body={agent_item_body(item)}
                            paragraph_role="agent-paragraph"
                          />
                        </div>
                        <span
                          :if={agent_item_loading?(item, @agent_editor_preview)}
                          id={"#{dom_id}-loading"}
                          phx-update="ignore"
                          data-role="agent-loading"
                          role="status"
                          aria-label="Agent responding"
                          class="ml-1 inline-flex h-4 translate-y-[0.125rem] items-end gap-0.5 align-baseline text-base-content/45"
                        >
                          <span
                            aria-hidden="true"
                            class="size-1 rounded-full bg-current motion-safe:animate-bounce [animation-delay:-240ms]"
                          ></span>
                          <span
                            aria-hidden="true"
                            class="size-1 rounded-full bg-current motion-safe:animate-bounce [animation-delay:-120ms]"
                          ></span>
                          <span
                            aria-hidden="true"
                            class="size-1 rounded-full bg-current motion-safe:animate-bounce"
                          ></span>
                        </span>
                      </div>
                  <% end %>
                </article>
              </div>

              <p
                :if={@agent_error}
                id="agent-error"
                class="mx-3 mb-3 rounded border border-error/25 bg-error/10 px-3 py-2 text-sm text-error"
              >
                {@agent_error}
              </p>

              <% queued_item =
                agent_queued_item(@agent_queue, @agent_queue_index) %>
              <div
                :if={queued_item}
                id="agent-queued-panel"
                data-role="queued-messages"
                data-queued-count={length(@agent_queue)}
                data-queued-index={@agent_queue_index + 1}
                class="mb-1.5 shrink-0 flex min-h-11 min-w-0 items-center gap-1.5 rounded border border-base-300 bg-base-100 px-1.5 py-1 text-xs text-base-content/70"
              >
                <button
                  id="agent-queued-prev"
                  type="button"
                  phx-click="agent.queue.previous"
                  disabled={@agent_queue_index <= 0}
                  aria-label="Previous queued message"
                  class="inline-flex size-5 shrink-0 items-center justify-center rounded-sm text-base-content/40 transition-colors hover:bg-base-200 hover:text-base-content disabled:pointer-events-none disabled:opacity-25"
                >
                  <.icon name="hero-chevron-left" class="size-3.5" />
                </button>
                <button
                  id="agent-queued-next"
                  type="button"
                  phx-click="agent.queue.next"
                  disabled={@agent_queue_index >= length(@agent_queue) - 1}
                  aria-label="Next queued message"
                  class="inline-flex size-5 shrink-0 items-center justify-center rounded-sm text-base-content/40 transition-colors hover:bg-base-200 hover:text-base-content disabled:pointer-events-none disabled:opacity-25"
                >
                  <.icon name="hero-chevron-right" class="size-3.5" />
                </button>
                <div
                  id="agent-queued-body"
                  data-role="queued-body"
                  class="min-w-0 flex-1"
                >
                  <p
                    id="agent-queued-title"
                    data-role="queued-count"
                    aria-label={"Queued message #{@agent_queue_index + 1} of #{length(@agent_queue)}"}
                    class="flex h-3 items-center gap-1 text-[10px] font-medium leading-3 text-base-content/45"
                  >
                    <span>Queue</span>
                    <span class="tabular-nums text-base-content/80">
                      {@agent_queue_index + 1}/{length(@agent_queue)}
                    </span>
                  </p>
                  <div
                    id="agent-queued-message"
                    data-role="queued-message"
                    data-turn-id={queued_item.turn_id}
                    class="min-w-0 truncate text-[13px] font-medium leading-4 text-base-content/90"
                    title={queued_item.body}
                  >
                    <% picks = queued_item.picks || [] %>
                    <span
                      :if={picks != []}
                      data-role="queued-picks-count"
                      class="mr-1 text-[11px] font-normal text-base-content/45"
                    >
                      +{length(picks)}
                    </span>
                    <span :if={queued_item.body != ""}>
                      {queued_item.body}
                    </span>
                    <span :if={queued_item.body == ""} class="text-base-content/55">
                      Selected elements
                    </span>
                  </div>
                </div>
                <button
                  id="agent-queued-flush"
                  type="button"
                  phx-click="agent.queue.flush"
                  title="Send queued"
                  aria-label="Send queued message"
                  class="inline-flex h-6 shrink-0 items-center gap-1 rounded-sm bg-base-content px-2 text-xs font-medium text-base-100 transition-colors hover:bg-base-content/85"
                >
                  <.icon name="hero-arrow-turn-down-left" class="size-3.5" />
                  <span>Send</span>
                </button>
              </div>

              <%!-- The composer box: the textarea + send/stop row AND the
                     embedded options row (model / 📎 attach / reasoning / access)
                     live in ONE bordered box, ChatGPT-style. The composer is a
                     native `phx-submit` form; the colocated `.ChatInput` hook adds
                     Enter-to-send while the button uses native form submission.
                     The options stay a SEPARATE sibling
                     form (`agent-provider-options`) so they never submit a
                     chat turn. --%>
              <div class="shrink-0 rounded border border-base-300 bg-base-100 transition-colors focus-within:border-base-content/40">
                <div
                  id="agent-picks"
                  data-role="composer-picks"
                  class="flex flex-wrap gap-1 px-2 pt-1.5 empty:hidden empty:p-0"
                >
                  <span
                    :for={pick <- @document_element_picker.picks}
                    data-role="composer-pick-chip"
                    title={pick.ref}
                    class="inline-flex max-w-full min-w-0 items-center gap-1 rounded border border-base-300 bg-base-200/70 px-1.5 py-0.5 text-[11px] leading-4 text-base-content/80"
                  >
                    <.icon
                      name="hero-cursor-arrow-rays"
                      class="size-3 shrink-0 text-base-content/45"
                    />
                    <span class="shrink-0 font-medium text-base-content/55">{pick.type}</span>
                    <span :if={pick.text != ""} class="min-w-0 truncate">{pick.text}</span>
                    <button
                      type="button"
                      phx-click="document.element_picker.pick.remove"
                      phx-value-key={DocumentElementPicker.pick_key(pick)}
                      data-role="composer-pick-remove"
                      aria-label="Remove selected element"
                      class="inline-flex size-3.5 shrink-0 items-center justify-center rounded text-base-content/45 transition-colors hover:bg-base-300 hover:text-base-content"
                    >
                      ×
                    </button>
                  </span>
                </div>
                <.form
                  for={@agent_form}
                  id="agent-form"
                  phx-submit="agent.message.submit_requested"
                  phx-hook=".ChatInput"
                  data-role="chat-form"
                >
                  <.input
                    field={@agent_form[:message]}
                    id="agent-input"
                    type="textarea"
                    rows="1"
                    autocomplete="off"
                    data-role="chat-textarea"
                    disabled={@agent_status in [:offline, :starting]}
                    placeholder={agent_input_placeholder(@agent_status)}
                    wrapper_class="m-0 p-0 gap-0"
                    label_class="m-0 block"
                    class="block max-h-40 min-h-7 w-full resize-none overflow-y-auto border-0 bg-transparent px-3 pt-1.5 pb-0.5 text-[13px] leading-snug text-base-content outline-none placeholder:text-base-content/35 focus:outline-none focus:ring-0 disabled:cursor-not-allowed disabled:text-base-content/40"
                  />
                  <div class="flex items-center justify-end gap-1 px-2 pb-1.5 pt-0">
                    <%!-- 📎 attach sits next to Send; its hidden file input stays
                           in the options form below (upload phx-change binding). --%>
                    <label
                      id="agent-upload"
                      data-role="chat-upload"
                      for={@uploads.document_import.ref}
                      class="inline-flex size-6 shrink-0 cursor-pointer items-center justify-center rounded text-base-content/45 transition-colors hover:text-base-content"
                      aria-label="Open local document"
                    >
                      <.icon name="hero-paper-clip" class="size-3.5" />
                    </label>
                    <button
                      :if={@agent_status == :running}
                      id="agent-submit"
                      type="submit"
                      phx-click="agent.turn.cancel"
                      data-role="chat-stop"
                      data-action="stop"
                      class="inline-flex size-6 items-center justify-center rounded bg-[color-mix(in_oklab,var(--cs-blue)_18%,transparent)] text-[var(--cs-blue)] transition-colors hover:bg-[color-mix(in_oklab,var(--cs-blue)_28%,transparent)]"
                      aria-label="Stop agent turn"
                    >
                      <.icon name="hero-stop" class="size-3.5" />
                      <span class="sr-only">Stop</span>
                    </button>
                    <button
                      :if={@agent_status != :running}
                      id="agent-submit"
                      type="submit"
                      data-role="chat-send"
                      data-action="send"
                      data-armed="false"
                      disabled={@agent_status in [:offline, :starting]}
                      class="inline-flex size-6 items-center justify-center rounded text-base-content/45 transition-colors hover:text-base-content data-[armed=true]:bg-[color-mix(in_oklab,var(--cs-blue)_18%,transparent)] data-[armed=true]:text-[var(--cs-blue)] data-[armed=true]:hover:bg-[color-mix(in_oklab,var(--cs-blue)_28%,transparent)] data-[armed=true]:hover:text-[var(--cs-blue)] disabled:cursor-not-allowed disabled:opacity-35"
                      aria-label="Send"
                    >
                      <.icon name="hero-paper-airplane" class="size-3.5" />
                      <span class="sr-only">Send</span>
                    </button>
                  </div>
                </.form>

                <.form
                  for={@agent_options_form}
                  id="agent-provider-options"
                  phx-change="workspace.document.import.validate"
                  data-role="provider-options"
                  data-selected-provider={@agent.provider.key}
                  data-selected-model={@agent.model}
                  data-selected-reasoning={@agent.reasoning_effort}
                  data-selected-access={@agent.access.id}
                  class="flex min-w-0 flex-wrap items-center gap-1 border-t border-base-300 px-2 py-1.5 text-[11px] leading-5 text-base-content/60"
                >
                  <div class="block min-w-0 shrink-0">
                    <span class="sr-only">Model</span>
                    <details
                      id="agent-model-select"
                      data-role="agent-model-select"
                      data-selected-provider={@agent.provider.key}
                      data-selected-model={@agent.model}
                      class="group relative inline-block min-w-0 max-w-32 align-top"
                    >
                      <summary class="inline-flex h-7 max-w-32 min-w-0 cursor-pointer list-none items-center justify-between gap-1 rounded border border-base-300 bg-base-100 px-1.5 text-left text-[11px] text-base-content transition-colors hover:border-base-content/25 marker:hidden">
                        <img
                          src={@agent.provider.favicon_src}
                          data-role="agent-model-provider-favicon"
                          aria-hidden="true"
                          alt=""
                          class="size-3.5 shrink-0 opacity-90 [filter:brightness(0)_invert(0.82)]"
                        />
                        <span class="min-w-0 truncate">
                          {agent_selected_model_label(@agent.model)}
                        </span>
                        <.icon
                          name="hero-chevron-down"
                          class="size-3 shrink-0 text-base-content/50"
                        />
                      </summary>
                      <div
                        data-role="agent-model-menu"
                        class="absolute bottom-8 left-0 z-40 max-h-[min(24rem,calc(100vh-8rem))] w-[min(17rem,calc(100vw-2rem))] max-w-[calc(var(--workspace-chat-rail-width,340px)-2rem)] overflow-y-auto rounded border border-base-300 bg-base-100 py-1 text-xs shadow-sm"
                      >
                        <button
                          :for={model <- agent_models_for_provider(@agent.provider.key)}
                          id={"agent-inline-model-#{model.id}"}
                          type="button"
                          phx-click={
                            JS.remove_attribute("open", to: "#agent-model-select")
                            |> JS.push("agent.model.select", value: %{model: model.id})
                          }
                          data-role="agent-model-option"
                          data-model={model.id}
                          data-provider={model.provider}
                          data-selected={to_string(@agent.model == model.id)}
                          title={model.description}
                          class={[
                            "flex w-full items-start justify-between gap-2 px-2 py-1.5 text-left transition-colors hover:bg-base-200/70",
                            if(@agent.model == model.id,
                              do: "text-base-content",
                              else: "text-base-content/70"
                            )
                          ]}
                        >
                          <span class="min-w-0 flex-1">
                            <span
                              data-role="agent-model-option-label"
                              class="block whitespace-normal break-words font-medium leading-snug"
                            >
                              {model.label}
                            </span>
                            <span
                              data-role="agent-model-option-description"
                              class="mt-0.5 block whitespace-normal break-words text-[11px] leading-snug text-base-content/50"
                            >
                              {model.description}
                            </span>
                          </span>
                          <.icon
                            :if={@agent.model == model.id}
                            name="hero-check"
                            class="size-3.5 shrink-0 text-base-content/65"
                          />
                        </button>
                        <div class="my-1 border-t border-base-300" />
                        <button
                          id="agent-go-to-provider"
                          type="button"
                          phx-click={
                            JS.remove_attribute("open", to: "#agent-model-select")
                            |> JS.push("agent.model_dialog.open")
                          }
                          data-role="agent-provider-config-open"
                          class="flex h-8 w-full items-center justify-between gap-2 px-2 text-left text-base-content/70 transition-colors hover:bg-base-200/70 hover:text-base-content"
                        >
                          <span class="whitespace-nowrap">Go to provider</span>
                          <.icon
                            name="hero-arrow-up-right"
                            class="size-3.5 shrink-0 text-base-content/45"
                          />
                        </button>
                      </div>
                    </details>
                  </div>
                  <%!-- Hidden file input for the 📎 upload. The visible label was
                         moved up next to Send, but this input must stay inside this
                         options form (it carries the upload's phx-change binding). --%>
                  <.live_file_input
                    upload={@uploads.document_import}
                    class="sr-only"
                    data-role="document-import-file-input"
                  />
                  <details
                    id="agent-reasoning-select"
                    data-role="provider-reasoning-select"
                    data-selected-reasoning={@agent.reasoning_effort}
                    class="group relative min-w-0 max-w-28"
                  >
                    <summary class="inline-flex h-6 min-w-0 max-w-28 cursor-pointer list-none items-center justify-between gap-1 rounded border border-base-300 bg-base-100 px-1.5 text-[11px] text-base-content transition-colors hover:border-base-content/25 marker:hidden">
                      <span class="min-w-0 truncate">
                        {agent_reasoning_short_label(@agent.reasoning_effort)}
                      </span>
                      <.icon
                        name="hero-chevron-down"
                        class="size-2.5 shrink-0 text-base-content/45"
                      />
                    </summary>
                    <div class="absolute bottom-7 right-0 z-40 w-52 rounded border border-base-300 bg-base-100 py-1 text-xs shadow-sm">
                      <button
                        :for={effort <- agent_reasoning_efforts(@agent.provider.key)}
                        id={"agent-inline-reasoning-#{effort}"}
                        type="button"
                        phx-click={
                          JS.remove_attribute("open", to: "#agent-reasoning-select")
                          |> JS.push("agent.reasoning.select", value: %{reasoning: effort})
                        }
                        data-role="provider-reasoning-option"
                        data-value={effort}
                        data-selected={to_string(@agent.reasoning_effort == effort)}
                        title={agent_reasoning_title(effort)}
                        class={[
                          "flex h-8 w-full items-center justify-between gap-2 px-2 text-left transition-colors hover:bg-base-200/70",
                          if(@agent.reasoning_effort == effort,
                            do: "text-base-content",
                            else: "text-base-content/70"
                          )
                        ]}
                      >
                        <span class="min-w-0 flex-1 truncate">
                          {agent_reasoning_label(effort)}
                        </span>
                        <.icon
                          :if={@agent.reasoning_effort == effort}
                          name="hero-check"
                          class="size-3.5 shrink-0 text-base-content/65"
                        />
                      </button>
                    </div>
                  </details>
                  <details
                    id="agent-access-select"
                    data-role="agent-access-control"
                    data-selected-access={@agent.access.id}
                    class="group relative min-w-0 max-w-36"
                  >
                    <summary class="inline-flex h-7 min-w-0 max-w-36 cursor-pointer list-none items-center justify-between gap-1 rounded border border-base-300 bg-base-100 px-1.5 text-xs text-base-content transition-colors hover:border-base-content/25 marker:hidden">
                      <span class="min-w-0 truncate">
                        {AgentAccess.resolve(@agent.access.id).label}
                      </span>
                      <.icon name="hero-chevron-down" class="size-3 shrink-0 text-base-content/45" />
                    </summary>
                    <div class="absolute bottom-8 right-0 z-20 w-40 rounded border border-base-300 bg-base-100 py-1 text-xs shadow-sm">
                      <button
                        :for={access <- agent_access_controls()}
                        id={"agent-inline-access-#{access.id}"}
                        type="button"
                        phx-click={
                          JS.remove_attribute("open", to: "#agent-access-select")
                          |> JS.push("agent.access.select", value: %{access: access.id})
                        }
                        data-role="agent-access-option"
                        data-access={access.id}
                        data-selected={to_string(@agent.access.id == access.id)}
                        title={access.title}
                        class={[
                          "flex h-8 w-full items-center justify-between gap-2 px-2 text-left transition-colors hover:bg-base-200/70",
                          if(@agent.access.id == access.id,
                            do: "text-base-content",
                            else: "text-base-content/70"
                          )
                        ]}
                      >
                        <span class="whitespace-nowrap">{access.label}</span>
                        <.icon
                          :if={@agent.access.id == access.id}
                          name="hero-check"
                          class="size-3.5 shrink-0 text-base-content/65"
                        />
                      </button>
                    </div>
                  </details>
                </.form>
              </div>
            </div>

            <div
              :if={@agent_model_modal_open}
              id="agent-model-modal"
              class="fixed inset-0 z-50"
              role="dialog"
              aria-modal="true"
              aria-labelledby="agent-model-modal-title"
              phx-window-keydown="agent.model_dialog.close"
              phx-key="Escape"
            >
              <div
                id="agent-model-modal-backdrop"
                class="absolute inset-0 bg-base-content/20"
                phx-click="agent.model_dialog.close"
              />
              <div class="relative mx-3 mt-20 max-w-[420px] rounded-md border border-base-300 bg-base-100 shadow-sm sm:mx-auto">
                <header class="flex h-10 items-center justify-between border-b border-base-300 px-3">
                  <h3
                    id="agent-model-modal-title"
                    class="text-sm font-semibold text-base-content"
                  >
                    Provider config
                  </h3>
                  <button
                    id="agent-model-modal-close"
                    type="button"
                    phx-click="agent.model_dialog.close"
                    aria-label="Close provider config"
                    class="inline-flex size-7 items-center justify-center rounded text-base-content/55 transition-colors hover:bg-base-200 hover:text-base-content focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content/35"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </header>
                <div class="divide-y divide-base-300 px-3 py-1">
                  <%= for provider <- agent_provider_details(@agent.integrations) do %>
                    <.link
                      :if={provider_setup_required?(provider)}
                      id={"agent-model-detail-#{provider.id}"}
                      href={agent_provider_setup_href(assigns, provider.id)}
                      target="_blank"
                      rel="noopener"
                      data-role="agent-provider-setup"
                      data-provider={provider.id}
                      data-selected={to_string(provider.id == @agent.provider.key)}
                      data-status={to_string(provider.status)}
                      aria-current={to_string(provider.id == @agent.provider.key)}
                      class={[
                        "flex w-full items-center justify-between gap-3 py-2 text-left text-sm transition-colors hover:bg-base-200/60 focus:outline-none focus-visible:ring-1 focus-visible:ring-base-content/25",
                        provider.id == @agent.provider.key && "text-base-content",
                        provider.id != @agent.provider.key && "text-base-content/75"
                      ]}
                    >
                      <div class="flex min-w-0 items-center gap-2">
                        <img
                          src={provider.favicon_src}
                          alt=""
                          class="size-4 shrink-0 opacity-90 [filter:brightness(0)_invert(0.82)]"
                        />
                        <div class="min-w-0">
                          <p class="truncate font-medium text-base-content">{provider.label}</p>
                          <p class="truncate text-xs text-base-content/55">{provider.runtime}</p>
                        </div>
                      </div>
                      <span class="flex shrink-0 items-center gap-1 text-xs text-base-content/60">
                        <span title={provider.detail}>{provider.status_label}</span>
                        <.icon name="hero-arrow-up-right" class="size-3 text-base-content/45" />
                      </span>
                    </.link>
                    <button
                      :if={!provider_setup_required?(provider)}
                      id={"agent-model-detail-#{provider.id}"}
                      type="button"
                      phx-click="agent.provider.select"
                      phx-value-provider={provider.id}
                      data-role="agent-provider-select"
                      data-provider={provider.id}
                      data-selected={to_string(provider.id == @agent.provider.key)}
                      data-status={to_string(provider.status)}
                      aria-pressed={to_string(provider.id == @agent.provider.key)}
                      class={[
                        "flex w-full items-center justify-between gap-3 py-2 text-left text-sm transition-colors hover:bg-base-200/60 focus:outline-none focus-visible:ring-1 focus-visible:ring-base-content/25",
                        provider.id == @agent.provider.key && "text-base-content",
                        provider.id != @agent.provider.key && "text-base-content/75"
                      ]}
                    >
                      <div class="flex min-w-0 items-center gap-2">
                        <img
                          src={provider.favicon_src}
                          alt=""
                          class="size-4 shrink-0 opacity-90 [filter:brightness(0)_invert(0.82)]"
                        />
                        <div class="min-w-0">
                          <p class="truncate font-medium text-base-content">{provider.label}</p>
                          <p class="truncate text-xs text-base-content/55">{provider.runtime}</p>
                        </div>
                      </div>
                      <p class="shrink-0 text-xs text-base-content/60" title={provider.detail}>
                        {provider.status_label}
                      </p>
                    </button>
                  <% end %>
                </div>
              </div>
            </div>

            <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatInput">
              export default {
                mounted() {
                  this.el.addEventListener("keydown", event => this.handleDomEvent(event))
                  this.el.addEventListener("input", event => this.handleDomEvent(event))
                  this.resizeInput()
                  this.syncSendArmed()
                },
                updated() {
                  this.resizeInput()
                  this.syncSendArmed()
                },
                handleDomEvent(event) {
                  if (event.type === "input") {
                    this.resizeInput()
                    this.syncSendArmed()
                    return
                  }

                  if (event.type === "keydown") {
                    const submit = event.target.matches('[data-role="chat-textarea"]')
                      && event.key === "Enter"
                      && !event.shiftKey
                      && !event.isComposing
                    if (!submit) return
                    event.preventDefault()
                    this.el.requestSubmit()
                  }
                },
                resizeInput() {
                  const input = this.el.querySelector('[data-role="chat-textarea"]')
                  if (!input || input.tagName !== "TEXTAREA") return
                  input.style.height = "auto"
                  input.style.height = `${Math.min(input.scrollHeight, 160)}px`
                },
                // Typed content arms the Send button (solid ink) without a
                // server round-trip per keystroke; the styles ride the
                // data-armed attribute on the button.
                syncSendArmed() {
                  const input = this.el.querySelector('[data-role="chat-textarea"]')
                  const send = this.el.querySelector('[data-role="chat-send"]')
                  if (!input || !send) return
                  send.dataset.armed = input.value.trim() === "" ? "false" : "true"
                }
              }
            </script>
            <%!-- Browser scroll measurements are facts sent to ScrollFollow;
                  the LiveView model owns whether the viewport remains pinned. --%>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".StickToBottom">
              export default {
                mounted() {
                  this.el.addEventListener("scroll", event => this.handleDomEvent(event), {passive: true})
                  this.handleEvent("agent.stream.text_appended", () => this.maybeScroll())
                  this.handleEvent("agent.stream.reasoning_appended", () => this.maybeScroll())
                  this.scrollToBottom()
                },

                updated() {
                  this.maybeScroll()
                },

                handleDomEvent(event) {
                  const distance = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
                  this.pushEvent("chat.viewport.scrolled", {distance})
                },

                maybeScroll() {
                  let state = {}
                  try { state = JSON.parse(this.el.dataset.scrollFollowState || "{}") }
                  catch (_error) {}
                  if (state.pinned === true) this.scrollToBottom()
                },

                scrollToBottom() {
                  // rAF so the just-inserted node's height is laid out before we
                  // measure scrollHeight — otherwise we'd scroll to a stale bottom.
                  requestAnimationFrame(() => {
                    this.el.scrollTop = this.el.scrollHeight
                  })
                },
              }
            </script>
          </aside>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp mount_workspace(socket, path) do
    root_path = socket.assigns.workspace_path

    if root_path == path and socket.assigns.workspace do
      assign(socket, :workspace_error, nil)
    else
      do_mount_workspace(socket, path)
    end
  end

  # Default-ON document VFS: when the workspace mounts (connected only), ensure
  # the exfuse projection mount in the background — `Exfuse.mount/3` blocks until
  # the mount settles, so we never stall the LiveView on it. The header toggle is
  # only true after the OS mount table says the mount is actually serving.
  # Teardown is owned by `Ecrits.Workspace.Session.terminate/2`. Idempotent across
  # tabs/refreshes.
  defp maybe_ensure_fuse_mount(socket) do
    path = socket.assigns[:workspace_path]

    if connected?(socket) and is_binary(path) and Ecrits.Fuse.DocMount.enabled?() do
      mounted? = DocMount.mounted?(path)
      socket = put_doc_vfs_mount_state(socket, path, mounted?)

      if mounted? do
        socket
      else
        start_async(socket, @doc_vfs_mount_async, fn ->
          {path, Ecrits.Fuse.DocMount.ensure(path)}
        end)
      end
    else
      socket
      |> assign(:fuse_mode, false)
      |> unsubscribe_doc_vfs()
      |> apply_vfs_write_policy()
    end
  end

  defp apply_doc_vfs_mount_result(socket, path, result) do
    mounted? = doc_vfs_mounted_after_ensure(result, path)

    unless mounted? or match?({:ok, _}, result) do
      Logger.warning("[DocMount] async ensure did not mount #{path}: #{inspect(result)}")
    end

    if socket.assigns[:workspace_path] == path do
      socket
      |> put_doc_vfs_mount_state(path, mounted?)
      |> maybe_apply_live_agent_options(true)
    else
      socket
    end
  end

  defp doc_vfs_mounted_after_ensure({:ok, _state}, _path), do: true
  defp doc_vfs_mounted_after_ensure(:disabled, _path), do: false
  defp doc_vfs_mounted_after_ensure(_result, path), do: DocMount.mounted?(path)

  defp put_doc_vfs_mount_state(socket, path, mounted?) do
    socket
    |> assign(:fuse_mode, mounted?)
    |> sync_doc_vfs_subscription(path, mounted?)
    |> apply_vfs_write_policy()
  end

  # The mounted `.jsonl` is writable ONLY when the workspace agent access is
  # "full-workspace" — a direct file write is the agent modifying the workspace,
  # so it honours the same gate as the MCP tools. Pushed to the VFS layer
  # (Ecrits.Fuse.OpenDocs) whenever the mount comes up or the access changes.
  defp apply_vfs_write_policy(socket) do
    path = socket.assigns[:workspace_path]
    if is_binary(path), do: Ecrits.Fuse.OpenDocs.set_writable(path, vfs_writable?(socket))
    socket
  end

  defp vfs_writable?(socket) do
    if socket.assigns[:fuse_mode] == true do
      case socket.assigns[:agent] do
        %{access: %{id: "full-workspace"}} -> true
        _ -> false
      end
    else
      false
    end
  end

  # Subscribe (once) to the workspace's doc-VFS edit broadcasts so a DIRECT file
  # edit of a mounted `.jsonl` (routed by Ecrits.Doc.Projection.write_back/3) shows a
  # card in the chat rail — the agent edits the file, not doc.edit.
  defp subscribe_doc_vfs(socket, root) do
    topic = "doc_vfs:" <> DocMount.canonical_root(root)

    cond do
      not connected?(socket) ->
        socket

      socket.assigns[:doc_vfs_topic] == topic ->
        socket

      true ->
        socket = unsubscribe_doc_vfs(socket)

        Phoenix.PubSub.subscribe(Ecrits.PubSub, topic)
        assign(socket, :doc_vfs_topic, topic)
    end
  end

  defp unsubscribe_doc_vfs(socket) do
    if connected?(socket) and is_binary(socket.assigns[:doc_vfs_topic]) do
      Phoenix.PubSub.unsubscribe(Ecrits.PubSub, socket.assigns.doc_vfs_topic)
    end

    assign(socket, :doc_vfs_topic, nil)
  end

  # Subscribe while the workspace owns the VFS feature, even during the short
  # interval before the asynchronous OS mount is observable. `doc.open_doc` can
  # make that same mount available from another process; tying the subscription
  # to a stale `mounted? == false` snapshot would then drop its edit preview.
  defp sync_doc_vfs_subscription(socket, root, _mounted?) when is_binary(root),
    do: subscribe_doc_vfs(socket, root)

  defp sync_doc_vfs_subscription(socket, _root, _mounted?), do: unsubscribe_doc_vfs(socket)

  defp vfs_doc_edit_turn_id(info) when is_map(info) do
    case item_field(info, :turn_id) do
      turn_id when is_binary(turn_id) and turn_id != "" -> turn_id
      _other -> nil
    end
  end

  # Projection attaches this at the final committed write boundary. The fallback
  # keeps synthetic/older VFS broadcasters safe without letting a later tab
  # switch turn their chat card into a view of mutable canonical bytes.
  defp ensure_vfs_preview_snapshot(socket, info) do
    cond do
      is_map(item_field(info, :preview_snapshot)) ->
        info

      not is_nil(item_field(info, :preview_snapshot_error)) ->
        info

      item_field(info, :preview_only) == true ->
        info

      not vfs_edit_progress_complete?(info) ->
        info

      true ->
        workspace_path = socket.assigns[:workspace_path]
        edited_abs = item_field(info, :path)

        with true <- is_binary(workspace_path) and is_binary(edited_abs),
             {:ok, relative_path} <- vfs_preview_relative_path(workspace_path, edited_abs),
             {:ok, args} <- Document.open_args(workspace_path, relative_path),
             document_id = Keyword.fetch!(args, :id),
             path = Keyword.fetch!(args, :path),
             {:ok, bytes} <- File.read(path),
             {:ok, snapshot} <- PreviewSnapshot.put(document_id, bytes) do
          Map.put(info, :preview_snapshot, snapshot)
        else
          {:error, reason} -> Map.put(info, :preview_snapshot_error, preview_error(reason))
          other -> Map.put(info, :preview_snapshot_error, preview_error(other))
        end
    end
  end

  defp preview_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp preview_error(reason), do: inspect(reason, limit: 8, printable_limit: 160)

  # The chat-rail view for a DIRECT file edit (write_back broadcast). Render the
  # saved document itself, including cold/replayed docs; the browser hook narrows
  # mirror rendering to the pages that contain the saved edit highlights.
  defp vfs_doc_edit_item(socket, info, turn_id) do
    vfs_editor_preview_item(socket, info, turn_id)
  end

  defp replace_live_vfs_editor_preview(socket, item) do
    previous = socket.assigns[:agent_vfs_preview_item]
    socket = remember_vfs_preview_rollback(socket, previous, item)

    socket =
      case {previous, item} do
        {%{role: :editor_preview, dom_id: dom_id}, %{role: :editor_preview, dom_id: dom_id}} ->
          socket

        {%{role: :editor_preview} = previous, _item} ->
          stream_delete(socket, :agent_items, previous)

        {_previous, _item} ->
          socket
      end

    case item do
      %{role: :editor_preview} -> assign(socket, :agent_vfs_preview_item, item)
      _other -> assign(socket, :agent_vfs_preview_item, nil)
    end
  end

  defp remember_vfs_preview_rollback(socket, previous, item) do
    cond do
      provisional_vfs_preview?(item) and stable_editor_preview?(previous) ->
        assign(socket, :agent_vfs_preview_rollback_item, previous)

      provisional_vfs_preview?(item) ->
        socket

      true ->
        assign(socket, :agent_vfs_preview_rollback_item, nil)
    end
  end

  defp provisional_vfs_preview?(item), do: item_field(item, :provisional) == true

  defp stable_editor_preview?(%{role: :editor_preview} = item),
    do: not provisional_vfs_preview?(item)

  defp stable_editor_preview?(_item), do: false

  defp maybe_stream_agent_item(socket, nil), do: socket
  defp maybe_stream_agent_item(socket, item), do: stream_insert(socket, :agent_items, item)

  defp vfs_editor_preview_item(socket, %{path: edited_abs} = info, turn_id)
       when is_binary(edited_abs) do
    workspace_path = socket.assigns[:workspace_path]

    with true <- is_binary(workspace_path),
         {:ok, %{document: document, relative_path: relative_path}} <-
           vfs_preview_document(socket, edited_abs),
         true <-
           Document.ehwp_format?(document.format) or Document.libreoffice_format?(document.format) or
             Document.markdown_format?(document.format) do
      highlights = vfs_preview_highlights(info)

      preview_snapshot =
        preview_snapshot_for_document(item_field(info, :preview_snapshot), document)

      document = pin_preview_document(document, preview_snapshot)

      committed_preview? =
        vfs_edit_progress_complete?(info) and item_field(info, :preview_only) != true

      preview_unavailable? = committed_preview? and not is_map(preview_snapshot)

      preview_steps = vfs_preview_steps(info)
      preview_base_url = item_field(info, :preview_base_url)

      snapshot_bytes_url =
        if is_map(preview_snapshot) do
          preview_snapshot_bytes_url(
            workspace_path,
            relative_path,
            document,
            preview_snapshot
          )
        end

      committed_playback? =
        committed_preview? and preview_steps != [] and is_binary(preview_base_url) and
          preview_base_url != "" and is_binary(snapshot_bytes_url)

      bytes_url =
        cond do
          preview_unavailable? ->
            nil

          committed_playback? ->
            preview_base_url

          is_binary(snapshot_bytes_url) ->
            snapshot_bytes_url

          true ->
            preview_base_url ||
              workspace_path
              |> document_bytes_url(relative_path)
              |> cache_bust_url()
        end

      state = %{
        turn_id: turn_id,
        edit_id: item_field(info, :edit_id) || turn_id,
        document_id: document.id,
        document: document,
        document_path: relative_path,
        document_spec: document_spec(document),
        canvas_id:
          "agent-editor-preview-#{dom_token(turn_id)}-#{dom_token(document.id)}-#{if(committed_preview?, do: "committed", else: "live")}-canvas",
        bytes_url: bytes_url,
        final_bytes_url: if(committed_playback?, do: snapshot_bytes_url, else: nil),
        text: "",
        delta_count: vfs_edit_change_count(info, 1),
        highlights: highlights,
        preview_steps:
          if((is_map(preview_snapshot) and not committed_playback?) or preview_unavailable?,
            do: [],
            else: preview_steps
          ),
        scroll: session_document_viewport(socket, relative_path),
        marker: info[:marker] || "",
        summary: vfs_edit_summary(info),
        preview_snapshot: preview_snapshot,
        preview_unavailable: preview_unavailable?,
        preview_error:
          if(preview_unavailable?,
            do: item_field(info, :preview_snapshot_error) || "snapshot_unavailable",
            else: nil
          ),
        provisional:
          item_field(info, :preview_only) == true or not vfs_edit_progress_complete?(info),
        status: if(vfs_edit_progress_complete?(info), do: :sent, else: :running)
      }

      agent_editor_preview_item(state)
    else
      _ -> nil
    end
  end

  defp vfs_editor_preview_item(_socket, _info, _turn_id), do: nil

  # A viewer-INDEPENDENT one-line summary of a VFS write-back (from the broadcast's
  # `sets`/`ops`), so the edit is visible in the rail even when the editor preview
  # can't render (e.g. the office WASM viewer is unavailable). Example:
  # "deck.pptx: 1 change — shape[title]: FillColor".
  defp vfs_edit_summary(info) do
    doc = info[:doc] || (is_binary(info[:path]) && Path.basename(info[:path])) || "document"

    details =
      Enum.map(List.wrap(info[:sets]), fn set ->
        ref = set["ref"] || set[:ref]

        props =
          (set["props"] || set[:props] || %{})
          |> strip_transient_preview_bytes()
          |> Map.keys()
          |> Enum.reject(&(&1 in ["kind", :kind]))

        String.trim("#{vfs_edit_short_ref(ref)}: #{Enum.join(props, ", ")}", ": ")
      end) ++
        Enum.map(List.wrap(info[:ops]), fn op -> to_string(op["op"] || op[:op] || "edit") end)

    details = Enum.reject(details, &(&1 in [nil, ""]))

    count = vfs_edit_change_count(info, length(details))
    unit = if(count == 1, do: "change", else: "changes")

    change_label =
      if item_field(info, :preview_only) == true do
        "previewing #{count} #{unit}"
      else
        "#{count} #{unit}"
      end

    suffix =
      case Enum.take(details, 2) do
        [] -> ""
        shown -> " — " <> Enum.join(shown, "; ")
      end

    "#{doc}: #{change_label}#{suffix}"
  end

  # `applied` and `delta_applied` count raw engine operations, while projection
  # progress counts logical edit groups. A replacement remains a delete+insert
  # pair in `ops`, but is one visible change in both the provisional and final
  # rail state.
  defp vfs_edit_change_count(info, fallback) when is_map(info) and is_integer(fallback) do
    progress_index = item_field(info, :progress_index)
    progress_total = item_field(info, :progress_total)

    candidates =
      if item_field(info, :preview_only) == true do
        [
          progress_total,
          item_field(info, :delta_applied),
          item_field(info, :applied),
          progress_index
        ]
      else
        [
          progress_index,
          item_field(info, :applied),
          item_field(info, :delta_applied),
          progress_total
        ]
      end

    Enum.find(candidates, &(is_integer(&1) and &1 > 0)) || max(fallback, 0)
  end

  # "page[page1]/shape[title]" -> "shape[title]"; sensible for short/nil refs.
  defp vfs_edit_short_ref(ref) when is_binary(ref) and ref != "",
    do: ref |> String.split("/") |> List.last()

  defp vfs_edit_short_ref(_ref), do: "node"

  defp vfs_preview_document(socket, edited_abs) do
    workspace_path = socket.assigns[:workspace_path]

    with true <- is_binary(workspace_path),
         {:ok, relative_path} <- vfs_preview_relative_path(workspace_path, edited_abs),
         {:ok, %Document{} = document} <-
           vfs_preview_document_for_relative_path(socket, workspace_path, relative_path) do
      {:ok, %{document: document, relative_path: relative_path}}
    else
      _ -> nil
    end
  end

  defp vfs_preview_document_for_relative_path(_socket, workspace_path, candidate_path) do
    Document.open(workspace_path, candidate_path)
  end

  defp vfs_preview_relative_path(workspace_path, edited_abs)
       when is_binary(workspace_path) and is_binary(edited_abs) do
    root = DocMount.canonical_root(workspace_path)
    edited_path = DocMount.canonical_root(edited_abs)
    relative_path = Path.relative_to(edited_path, root)

    cond do
      relative_path == edited_path -> {:error, :outside_workspace}
      relative_path == "." -> {:error, :workspace_root}
      String.starts_with?(relative_path, "..") -> {:error, :outside_workspace}
      true -> WorkspacePath.normalize(relative_path)
    end
  end

  defp vfs_preview_highlights(info) when is_map(info) do
    case item_field(info, :highlights) do
      highlights when is_list(highlights) -> highlights
      _ -> []
    end
  end

  defp vfs_preview_steps(info) when is_map(info) do
    case item_field(info, :preview_steps) do
      steps when is_list(steps) -> steps
      _ -> []
    end
  end

  defp vfs_preview_marker(info) when is_map(info) do
    case item_field(info, :marker) ||
           vfs_preview_marker_from_highlights(vfs_preview_highlights(info)) do
      marker when is_binary(marker) -> marker
      _ -> ""
    end
  end

  defp vfs_preview_marker_from_highlights(highlights) when is_list(highlights) do
    highlights
    |> Enum.find_value(fn
      %{"text" => text} when is_binary(text) and text != "" -> text
      %{text: text} when is_binary(text) and text != "" -> text
      %{"replacement" => text} when is_binary(text) and text != "" -> text
      %{replacement: text} when is_binary(text) and text != "" -> text
      _ -> nil
    end)
  end

  defp edit_preview_hash(highlights) when is_list(highlights) do
    highlights
    |> Enum.take(64)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
    |> String.slice(0, 32)
  rescue
    _ -> ""
  end

  defp cache_bust_url(url) when is_binary(url) do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> "v=" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end

  defp cache_bust_url(url), do: url

  defp maybe_persist_vfs_edit_preview(socket, info, turn_id) do
    if is_binary(turn_id) and turn_id != "" and vfs_edit_progress_complete?(info) do
      case socket.assigns[:agent_session_id] do
        session_id when is_binary(session_id) ->
          if item = vfs_edit_preview_transcript_item(socket, info, turn_id) do
            _ = ACP.append_transcript_item(session_id, item)
          end

          socket

        _ ->
          socket
      end
    else
      socket
    end
  end

  defp vfs_edit_progress_complete?(info) when is_map(info) do
    case {item_field(info, :progress_index), item_field(info, :progress_total)} do
      {index, total} when is_integer(index) and is_integer(total) and total >= 1 ->
        index >= 1 and index >= total

      _other ->
        true
    end
  end

  defp vfs_edit_progress_complete?(_info), do: true

  defp vfs_edit_preview_transcript_item(socket, %{path: edited_abs} = info, turn_id)
       when is_binary(edited_abs) and is_binary(turn_id) and turn_id != "" do
    workspace_path = socket.assigns[:workspace_path]
    highlights = vfs_preview_highlights(info)

    with true <- is_binary(workspace_path),
         {:ok, relative_path} <- vfs_preview_relative_path(workspace_path, edited_abs),
         {:ok, format} <- preview_document_format(info, relative_path),
         true <- Document.ehwp_format?(format) or Document.libreoffice_format?(format) do
      document_id = Document.id_for(Path.expand(workspace_path), relative_path)
      version = vfs_edit_preview_file_version(edited_abs)
      preview_ref = edit_preview_ref(highlights)
      edit_id = item_field(info, :edit_id) || turn_id
      hash = edit_preview_hash(highlights)

      preview_snapshot =
        preview_snapshot_for_document(
          item_field(info, :preview_snapshot),
          %Document{id: document_id}
        )

      preview_unavailable? = not is_map(preview_snapshot)
      snapshot_id = item_field(preview_snapshot, :id) || "unavailable"

      %{
        role: :edit_preview,
        status: :sent,
        turn_id: turn_id,
        edit_id: edit_id,
        doc: item_field(info, :doc) || Path.basename(relative_path),
        document_id: document_id,
        document_path: relative_path,
        backend: edit_preview_backend(format),
        format: format,
        applied: vfs_edit_change_count(info, 1),
        ops:
          persistable_preview_payload(
            item_field(info, :composition_ops) || item_field(info, :ops)
          ),
        sets: persistable_preview_payload(item_field(info, :sets)),
        highlights: persistable_preview_payload(highlights),
        ref: strip_transient_preview_bytes(preview_ref),
        scroll: session_document_viewport(socket, relative_path),
        marker: vfs_preview_marker(info),
        summary: vfs_edit_summary(info),
        hash: hash,
        version: version,
        preview_snapshot: strip_transient_preview_bytes(preview_snapshot),
        preview_unavailable: preview_unavailable?,
        preview_error:
          if(preview_unavailable?,
            do: item_field(info, :preview_snapshot_error) || "snapshot_unavailable",
            else: nil
          ),
        preview_identity: %{
          turn_id: turn_id,
          edit_id: edit_id,
          document_id: document_id,
          snapshot_id: snapshot_id
        },
        mode: "descriptor"
      }
    else
      _ -> nil
    end
  end

  defp vfs_edit_preview_transcript_item(_socket, _info, _turn_id), do: nil

  defp edit_preview_backend(format) do
    cond do
      Document.ehwp_format?(format) -> "ehwp"
      Document.libreoffice_format?(format) -> "libreofficex"
      true -> nil
    end
  end

  defp preview_document_format(info, relative_path) when is_map(info) do
    case item_field(info, :format) do
      format when is_binary(format) ->
        Document.normalize_format(format)

      format when is_atom(format) and not is_nil(format) ->
        Document.normalize_format(Atom.to_string(format))

      _ ->
        Document.detect_format(relative_path)
    end
  end

  defp previewable_document_format?(format) do
    Document.ehwp_format?(format) or Document.libreoffice_format?(format) or
      Document.markdown_format?(format)
  end

  defp vfs_edit_preview_file_version(path) when is_binary(path) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> %{byte_size: stat.size, mtime: stat.mtime}
      _ -> %{}
    end
  end

  defp transcript_edit_preview_item(socket, turn_id, item, _index) do
    document_path = item_field(item, :document_path) || item_field(item, :document)
    applied = item_field(item, :applied) |> preview_positive_int(1)
    workspace_path = socket.assigns[:workspace_path]

    with workspace_path when is_binary(workspace_path) and workspace_path != "" <- workspace_path,
         relative_path when is_binary(relative_path) and relative_path != "" <-
           document_path && to_string(document_path),
         {:ok, path} <- transcript_edit_preview_path(socket, relative_path),
         {:ok, relative_path} <- WorkspacePath.normalize(relative_path),
         {:ok, fallback_format} <- preview_document_format(item, relative_path),
         true <- previewable_document_format?(fallback_format) do
      workspace_path = Path.expand(workspace_path)
      document_id = Document.id_for(workspace_path, relative_path)
      dom_id = "agent-editor-preview-#{turn_id}-#{dom_token(document_id)}"

      {document, preview_snapshot, preview_error} =
        replay_preview_document(
          workspace_path,
          relative_path,
          path,
          document_id,
          fallback_format,
          item_field(item, :preview_snapshot)
        )

      preview_unavailable? = not is_map(preview_snapshot)

      state = %{
        # The committed VFS card already occupies this stable turn/document row.
        # Rebuilding it from its durable descriptor must update that row in
        # place, both live and on replay, instead of moving it to the stream tail.
        dom_id: dom_id,
        turn_id: turn_id,
        edit_id: item_field(item, :edit_id) || item_field(item, :hash) || turn_id,
        document_id: document.id,
        document: document,
        document_path: relative_path,
        document_spec: document_spec(document),
        canvas_id:
          "agent-editor-preview-#{dom_token(turn_id)}-#{dom_token(document_id)}-committed-canvas",
        bytes_url:
          if(is_map(preview_snapshot),
            do:
              preview_snapshot_bytes_url(
                workspace_path,
                relative_path,
                document,
                preview_snapshot
              ),
            else: nil
          ),
        text: "",
        delta_count: applied,
        highlights: vfs_preview_highlights(item),
        preview_steps: [],
        scroll: item_field(item, :scroll) || session_document_viewport(socket, relative_path),
        marker: vfs_preview_marker(item),
        summary: item_field(item, :summary) || "",
        preview_snapshot: preview_snapshot,
        preview_identity: item_field(item, :preview_identity),
        preview_unavailable: preview_unavailable?,
        preview_error:
          if(preview_unavailable?,
            do: item_field(item, :preview_error) || preview_error || "snapshot_unavailable",
            else: nil
          ),
        status: :sent
      }

      agent_editor_preview_item(state)
    else
      _ -> nil
    end
  end

  defp transcript_edit_preview_path(socket, relative_path) do
    root = socket.assigns[:workspace_path]

    with root when is_binary(root) and root != "" <- root,
         {:ok, rel} <- WorkspacePath.normalize(relative_path),
         {:ok, path} <- WorkspacePath.join(root, rel) do
      {:ok, path}
    else
      _ -> :error
    end
  end

  defp preview_snapshot_for_document(snapshot, %Document{id: document_id})
       when is_map(snapshot) do
    case fetch_preview_snapshot(snapshot, document_id) do
      {:ok, verified_snapshot, _bytes} -> verified_snapshot
      {:error, _reason} -> nil
    end
  end

  defp preview_snapshot_for_document(_snapshot, _document), do: nil

  defp fetch_preview_snapshot(snapshot, document_id)
       when is_map(snapshot) and is_binary(document_id) do
    snapshot_id = item_field(snapshot, :id)

    with ^document_id <- item_field(snapshot, :document_id),
         true <- PreviewSnapshot.valid_id?(snapshot_id),
         {:ok, bytes} <- PreviewSnapshot.fetch(document_id, snapshot_id) do
      {:ok,
       %{
         id: snapshot_id,
         document_id: document_id,
         byte_size: byte_size(bytes),
         sha256: Document.sha256(bytes)
       }, bytes}
    else
      false -> {:error, :invalid_snapshot_ref}
      nil -> {:error, :invalid_snapshot_ref}
      value when is_binary(value) -> {:error, :snapshot_document_mismatch}
      {:error, _reason} = error -> error
      _ -> {:error, :invalid_snapshot_ref}
    end
  end

  defp fetch_preview_snapshot(_snapshot, _document_id), do: {:error, :missing_snapshot}

  defp replay_preview_document(
         workspace_path,
         relative_path,
         path,
         document_id,
         fallback_format,
         snapshot
       ) do
    case fetch_preview_snapshot(snapshot, document_id) do
      {:ok, verified_snapshot, bytes} ->
        case Document.detect_format(relative_path, bytes) do
          {:ok, format} ->
            if previewable_document_format?(format) do
              args = [
                id: document_id,
                workspace_root: workspace_path,
                relative_path: relative_path,
                path: path,
                format: format
              ]

              {Document.build(args, bytes), verified_snapshot, nil}
            else
              {unavailable_preview_document(
                 workspace_path,
                 relative_path,
                 path,
                 document_id,
                 fallback_format
               ), nil, "unsupported_snapshot_format"}
            end

          {:error, reason} ->
            {unavailable_preview_document(
               workspace_path,
               relative_path,
               path,
               document_id,
               fallback_format
             ), nil, preview_error(reason)}
        end

      {:error, reason} ->
        {unavailable_preview_document(
           workspace_path,
           relative_path,
           path,
           document_id,
           fallback_format
         ), nil, preview_error(reason)}
    end
  end

  defp unavailable_preview_document(
         workspace_path,
         relative_path,
         path,
         document_id,
         format
       ) do
    %Document{
      id: document_id,
      workspace_root: workspace_path,
      relative_path: relative_path,
      path: path,
      format: format,
      byte_size: 0,
      sha256: "",
      metadata_dir: nil
    }
  end

  defp pin_preview_document(%Document{} = document, snapshot) when is_map(snapshot) do
    byte_size = item_field(snapshot, :byte_size)
    sha256 = item_field(snapshot, :sha256)

    if is_integer(byte_size) and byte_size >= 0 and is_binary(sha256) do
      %Document{document | byte_size: byte_size, sha256: sha256}
    else
      document
    end
  end

  defp pin_preview_document(document, _snapshot), do: document

  defp preview_positive_int(value, _default) when is_integer(value) and value >= 1, do: value

  defp preview_positive_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 1 -> int
      _ -> default
    end
  end

  defp preview_positive_int(_value, default), do: default

  defp persistable_preview_payload(value) do
    value
    |> List.wrap()
    |> Enum.map(&strip_transient_preview_bytes/1)
  end

  defp strip_transient_preview_bytes(%{} = map) do
    map
    |> Map.drop([
      "image_base64",
      :image_base64,
      "imageBase64",
      :imageBase64,
      "bins",
      :bins,
      "bytes",
      :bytes,
      "bytes_base64",
      :bytes_base64,
      "preview_base_url",
      :preview_base_url
    ])
    |> Map.new(fn {key, nested} -> {key, strip_transient_preview_bytes(nested)} end)
  end

  defp strip_transient_preview_bytes(list) when is_list(list),
    do: Enum.map(list, &strip_transient_preview_bytes/1)

  defp strip_transient_preview_bytes(value), do: value

  defp do_mount_workspace(socket, path) do
    case Adapter.mount(path) do
      {:ok, workspace} ->
        socket
        |> assign(:workspace, workspace)
        |> assign(:workspace_path, workspace_root_path(workspace))
        |> update(:file_tree, &FileTree.put_nodes(&1, Map.get(workspace, :tree, [])))
        |> assign(:workspace_error, nil)
        |> assign(:page_title, workspace_title(workspace))
        |> maybe_subscribe_workspace_fs_events()
        |> maybe_subscribe_workspace_files()
        |> maybe_ensure_fuse_mount()

      {:error, _reason} ->
        # Workspace failed to mount (bad / inaccessible path) — send the user
        # back to the folder picker ("/") rather than a dead-end error page.
        socket
        |> unsubscribe_hwp_stream()
        |> assign(:workspace_path, nil)
        |> assign(:active_document, nil)
        |> assign(:active_document_path, nil)
        |> clear_hwp_pages()
        |> push_navigate(to: ~p"/")
    end
  end

  defp schedule_document_open(%{assigns: %{workspace: nil}} = socket, _path), do: socket

  defp schedule_document_open(socket, path) do
    ref = make_ref()

    socket
    |> prepare_document_loading(path)
    |> assign(:pending_document_open_ref, ref)
    |> assign(:pending_document_path, path)
    |> start_document_open(ref, path)
  end

  defp start_document_open(socket, ref, path) do
    root = workspace_root_path(socket.assigns.workspace)

    start_async(socket, @document_open_async, fn ->
      {ref, path, Document.open(root, path)}
    end)
  end

  defp prepare_document_loading(socket, path) do
    previous_document_id = active_document_id(socket)
    _ = unregister_rhwp_materializer_editor(previous_document_id)

    socket
    |> reset_document_search()
    |> unsubscribe_hwp_stream()
    |> clear_pool_document()
    |> upsert_open_document_tab(path)
    |> update(:file_tree, &FileTree.select(&1, path))
    |> assign(:active_document_path, path)
    |> assign(:active_document, nil)
    |> assign(:active_document_viewport, session_document_viewport(socket, path))
    |> assign(:document_bytes_version, nil)
    |> assign(:document_status, :loading)
    |> assign(:document_snapshot, nil)
    |> assign(:document_error, nil)
    |> clear_hwp_pages()
  end

  # Open-or-focus tab tracking. The id is a deterministic token of the relative
  # path so re-opening the same file focuses the existing tab instead of adding
  # a duplicate. Tab order is preserved; a freshly opened file is appended.
  defp upsert_open_document_tab(socket, path) do
    id = tab_id(path)
    tabs = socket.assigns.open_documents

    tabs =
      if Enum.any?(tabs, &(&1.id == id)) do
        tabs
      else
        tabs ++ [%{id: id, name: Path.basename(path), path: path}]
      end

    socket
    |> assign(:open_documents, tabs)
    |> assign(:active_document_id, id)
  end

  defp maybe_restore_session_documents(
         %{assigns: %{open_documents: [], active_document_path: nil}} = socket,
         ws
       ) do
    snapshot = safe_document_snapshot(ws)
    documents = Map.get(snapshot, :documents, [])
    tabs = Enum.map(documents, &session_document_tab/1)
    active_document_path = Map.get(snapshot, :active_document_path)

    socket =
      socket
      |> restore_document_element_picker_enabled(snapshot)
      |> assign(:open_documents, tabs)

    if is_binary(active_document_path) and Enum.any?(tabs, &(&1.path == active_document_path)) do
      schedule_document_open(socket, active_document_path)
    else
      socket
    end
  end

  defp maybe_restore_session_documents(socket, ws) do
    restore_document_element_picker_enabled(socket, safe_document_snapshot(ws))
  end

  defp safe_document_snapshot(ws) do
    WorkspaceSession.document_snapshot(ws)
  rescue
    _ -> empty_document_snapshot()
  catch
    :exit, _ -> empty_document_snapshot()
  end

  defp empty_document_snapshot,
    do: %{documents: [], active_document_path: nil, document_element_picker_enabled?: false}

  defp restore_document_element_picker_enabled(socket, snapshot) do
    enabled? = Map.get(snapshot, :document_element_picker_enabled?, false)

    update(socket, :document_element_picker, fn picker ->
      DocumentElementPicker.put_enabled(picker, enabled?)
    end)
  end

  defp session_document_tab(%SessionDocument{path: path}) when is_binary(path) do
    %{id: tab_id(path), name: Path.basename(path), path: path}
  end

  defp session_document_tab(%{path: path}) when is_binary(path) do
    %{id: tab_id(path), name: Path.basename(path), path: path}
  end

  defp session_document_viewport(socket, path) when is_binary(path) do
    with %{} = ws <- ws(socket),
         %{documents: documents} <- safe_document_snapshot(ws),
         %SessionDocument{} = document <- Enum.find(documents, &(&1.path == path)) do
      document_viewport(document)
    else
      %{scroll_top: _top, scroll_left: _left} = document -> document_viewport(document)
      _ -> nil
    end
  end

  defp session_document_viewport(_socket, _path), do: nil

  defp persist_session_open_document(socket, %Document{} = document) do
    attrs = %{
      path: document.relative_path,
      id: document.id,
      pool_document_id: socket.assigns[:pool_document_id]
    }

    with %{} = ws <- ws(socket),
         {:ok, session_document} <- WorkspaceSession.open_document(ws, attrs) do
      assign(socket, :active_document_viewport, document_viewport(session_document))
    else
      _ ->
        assign(
          socket,
          :active_document_viewport,
          session_document_viewport(socket, document.relative_path)
        )
    end
  end

  defp persist_session_closed_document(socket, %{path: path}) when is_binary(path) do
    if ws = ws(socket) do
      _ = WorkspaceSession.close_document(ws, path)
    end

    socket
  end

  defp persist_session_closed_document(socket, _tab), do: socket

  defp persist_document_element_picker_enabled(socket, enabled?) do
    if ws = ws(socket) do
      _ = WorkspaceSession.set_document_element_picker_enabled(ws, enabled?)
    end

    socket
  end

  defp open_document_path?(socket, path) when is_binary(path) do
    Enum.any?(socket.assigns[:open_documents] || [], &(&1.path == path))
  end

  defp open_document_path?(_socket, _path), do: false

  defp document_viewport(%SessionDocument{} = document) do
    %{
      scroll_top: scroll_coordinate(document.scroll_top),
      scroll_left: scroll_coordinate(document.scroll_left)
    }
  end

  defp document_viewport(%{scroll_top: scroll_top, scroll_left: scroll_left}) do
    %{scroll_top: scroll_coordinate(scroll_top), scroll_left: scroll_coordinate(scroll_left)}
  end

  defp document_viewport(_document), do: %{scroll_top: 0, scroll_left: 0}

  defp scroll_coordinate(value) when is_integer(value) and value >= 0, do: value

  defp scroll_coordinate(value) when is_float(value) and value >= 0 do
    value |> Float.round() |> trunc()
  end

  defp scroll_coordinate(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} when integer >= 0 -> integer
      _ -> 0
    end
  end

  defp scroll_coordinate(_value), do: 0

  defp tab_id(path) do
    path = to_string(path)
    token = dom_token(path)

    if String.match?(path, ~r/[^\x00-\x7F]/u) do
      digest =
        :sha256
        |> :crypto.hash(path)
        |> binary_part(0, 6)
        |> Base.url_encode64(padding: false)

      "#{token}-#{digest}"
    else
      token
    end
  end

  # Drop a tab. When it was the active tab we tear down the live document
  # (stream + edit handle) and focus a neighbor; if it was the last tab we fall
  # back to the empty workspace state.
  defp close_open_document_tab(socket, id) do
    tabs = socket.assigns.open_documents

    case Enum.find_index(tabs, &(&1.id == id)) do
      nil ->
        socket

      index ->
        active? = socket.assigns.active_document_id == id
        closed_tab = Enum.at(tabs, index)
        remaining = List.delete_at(tabs, index)

        socket =
          socket
          |> assign(:open_documents, remaining)
          |> persist_session_closed_document(closed_tab)
          # A closed doc must never linger as dirty (and its auto-save timer
          # would otherwise fire against a doc with no open tab).
          |> mark_doc_clean(id)
          # Dispose the server office twin so its libreofficex session +
          # `.~lock.<file>#` are released — a detach-on-switch keeps the twin,
          # but an explicit close must let go of it.
          |> release_office_twin_on_close(closed_tab)

        socket =
          if active? do
            cancel_document_open(socket)
          else
            socket
          end

        cond do
          not active? ->
            socket

          remaining == [] ->
            socket
            |> tear_down_active_document()
            |> assign(:active_document_id, nil)
            |> update(:file_tree, &FileTree.select(&1, nil))

          true ->
            neighbor = Enum.at(remaining, min(index, length(remaining) - 1))

            schedule_document_open(socket, neighbor.path)
        end
    end
  end

  # Closing an OFFICE (docx/pptx/xlsx) tab must dispose its server Pool twin — else the
  # libreofficex UNO session lingers and its `.~lock.<file>#` is never released
  # (the user-reported "close of libre never works"; the twin then survives until
  # an LRU eviction that never comes with few docs open). A VIEWED office twin is
  # only a disk SHADOW — the browser WASM is the save authority — so disposing it
  # on close loses no edits. HWP twins keep their own twin-sync lifecycle.
  # Best-effort; keyed by absolute path exactly like `open_document_exists?/2`.
  defp release_office_twin_on_close(socket, %{path: rel_path}) when is_binary(rel_path) do
    ext = rel_path |> Path.extname() |> String.downcase()

    if connected?(socket) and ext in [".docx", ".pptx", ".ppt", ".xlsx"] do
      root = workspace_root_path(socket.assigns.workspace)

      with {:ok, rel} <- WorkspacePath.normalize(rel_path),
           {:ok, absolute} <- WorkspacePath.join(root, rel) do
        _ = DocPool.close_by_path(absolute)
      end
    end

    socket
  end

  defp release_office_twin_on_close(socket, _tab), do: socket

  # Close streams/handles for the currently active document, mirroring the
  # teardown that `maybe_open_document/2` performs on empty navigation.
  defp tear_down_active_document(socket) do
    previous_document_id = active_document_id(socket)
    _ = unregister_rhwp_materializer_editor(previous_document_id)

    socket
    |> reset_document_search()
    |> unsubscribe_hwp_stream()
    |> clear_pool_document()
    |> assign(:active_document_path, nil)
    |> assign(:active_document, nil)
    |> assign(:active_document_viewport, nil)
    |> assign(:document_bytes_version, nil)
    |> assign(:document_status, :none)
    |> assign(:document_snapshot, nil)
    |> assign(:document_error, nil)
    |> clear_hwp_pages()
  end

  defp cancel_document_open(socket) do
    socket
    |> cancel_async(@document_open_async)
    |> assign(:pending_document_open_ref, nil)
    |> assign(:pending_document_path, nil)
  end

  defp apply_document_open_result(socket, path, result) do
    previous_document_id = active_document_id(socket)

    case result do
      {:ok, %Document{} = document} ->
        if connected?(socket) do
          :ok = Document.subscribe(document.id)
          update_rhwp_materializer_editor(previous_document_id, document.id)
        end

        socket =
          socket
          |> update(:file_tree, &FileTree.select(&1, document.relative_path))
          |> assign(:active_document_path, document.relative_path)
          |> assign(:active_document, document_summary(document))
          |> assign(:pending_document_open_ref, nil)
          |> assign(:pending_document_path, nil)
          |> assign(:document_status, :opened)
          |> assign(:document_snapshot, nil)
          |> assign(:document_error, nil)
          |> register_pool_document(document)
          |> persist_session_open_document(document)
          |> render_document_pages(document)

        socket

      {:error, reason} ->
        _ = unregister_rhwp_materializer_editor(previous_document_id)

        socket
        |> clear_pool_document()
        |> unsubscribe_hwp_stream()
        |> update(:file_tree, &FileTree.select(&1, path))
        |> assign(:active_document_path, nil)
        |> assign(:active_document, nil)
        |> assign(:active_document_viewport, nil)
        |> assign(:document_bytes_version, nil)
        |> assign(:pending_document_open_ref, nil)
        |> assign(:pending_document_path, nil)
        |> assign(:document_status, :error)
        |> assign(:document_error, error_message(reason))
        |> clear_hwp_pages()
    end
  end

  # Register the freshly-opened workspace document in `Ecrits.Doc.Pool` and mark
  # it the ACTIVE document, so the chat agent's `doc.*` MCP tools (which operate
  # against the Pool) can see, read and edit the document the user is viewing.
  #
  # HWP/HWPX route to the browser-WASM model (this clause); a VIEWED office
  # docx/pptx ALSO routes to its browser-WASM model (separate clause below, O5b) —
  # a headless office doc (no viewer) falls back to the server libreofficex UNO
  # NIF. Other formats (Markdown) have no Pool backend yet, so we just clear any
  # stale active doc for them. The Pool keys by absolute path, so re-opening the
  # same file reuses the handle.
  defp register_pool_document(socket, %Document{path: path, format: format})
       when format in ["hwp", "hwpx"] do
    kind = String.to_existing_atom(format)

    case DocPool.open(path, kind: kind) do
      {:ok, doc_id} ->
        # NOTE: the Session viewer (browser authority for doc.* routing) is NOT
        # attached here. The editor hook pushes `document.viewer_ready`
        # once the WASM model has ACTUALLY loaded, and the handler attaches
        # then — a tab whose editor failed to load (e.g. office WASM in a
        # non-isolated context) must never capture routing; the doc stays
        # `:server`-backed so reads/renders keep working.
        socket
        |> cancel_all_doc_browser_pending()
        |> assign(:pool_document_id, doc_id)

      {:error, _reason} ->
        # Pool registration is best-effort: a backend open failure must not
        # break the viewer. The agent simply won't have a handle for this doc.
        clear_pool_document(socket)
    end
  end

  # Office formats (docx/pptx/xlsx) are viewed through the browser-WASM office model.
  # Do NOT cold-open the server LibreOffice/UNO twin while rendering that viewer:
  # the hook will claim browser authority via `document.viewer_ready`, and
  # headless `doc.open` still opens the server twin through DocPool directly.
  defp register_pool_document(socket, %Document{path: path, format: format})
       when format in ["docx", "pptx", "xlsx"] do
    kind = office_document_kind(format)
    doc_id = DocPool.document_id_for(path, kind)

    socket
    |> cancel_all_doc_browser_pending()
    |> assign(:pool_document_id, doc_id)
  end

  defp register_pool_document(socket, %Document{}), do: clear_pool_document(socket)

  defp office_document_kind("docx"), do: :docx
  defp office_document_kind("pptx"), do: :pptx
  defp office_document_kind("xlsx"), do: :xlsx

  # Register this connected LiveView as the Session viewer for `doc_id`, keyed by
  # the workspace path (the Session is the home of `viewers`). Best-effort: a
  # missing/erroring Session must never break the viewer render.
  defp attach_session_viewer(socket, doc_id) do
    case socket.assigns[:workspace_path] do
      path when is_binary(path) and path != "" ->
        _ = WorkspaceSession.attach_viewer(path, doc_id, self())
        :ok

      _ ->
        :ok
    end
  end

  # Relinquish this viewer's browser authority over the doc it registered. We
  # leave the Editor in the Pool (other sessions may share it); we only give up
  # the viewer claim in the workspace Session. Without the detach a closed/
  # navigated-away doc would stay `:browser`-backed by this (now stale) viewer, so
  # the agent's reads/edits for THAT doc would route to the browser and be
  # redirected to whatever is currently open — the multi-doc bug.
  defp clear_pool_document(%{assigns: %{pool_document_id: doc_id}} = socket)
       when is_binary(doc_id) do
    if connected?(socket), do: detach_session_viewer(socket, doc_id)

    socket
    |> cancel_all_doc_browser_pending()
    |> assign(:pool_document_id, nil)
  end

  defp clear_pool_document(socket) do
    socket
    |> cancel_all_doc_browser_pending()
    |> assign(:pool_document_id, nil)
  end

  defp detach_session_viewer(socket, doc_id) do
    case socket.assigns[:workspace_path] do
      path when is_binary(path) and path != "" ->
        _ = WorkspaceSession.detach_viewer(path, doc_id, self())
        :ok

      _ ->
        :ok
    end
  end

  # --- browser-backed agent edit bridge (design §6.2) ------------------------

  # Stable string id for a pending browser request (ref is not JSON-serialisable
  # for the client round-trip, so we key by an inspected ref string).
  defp doc_browser_request_id(ref), do: "dbr:" <> (:erlang.ref_to_list(ref) |> List.to_string())

  defp queue_doc_browser_request(
         socket,
         from,
         ref,
         verb,
         payload,
         expected_document_id
       ) do
    request_id = doc_browser_request_id(ref)
    document_id = active_document_id(socket)
    wire_payload = doc_browser_payload(payload, socket)
    routed_document_id = socket.assigns[:pool_document_id]

    if valid_doc_browser_route?(expected_document_id, routed_document_id) do
      entry = %{
        from: from,
        ref: ref,
        verb: verb,
        payload: wire_payload,
        document_id: document_id,
        expected_document_id: expected_document_id,
        identity: doc_browser_identity(payload),
        monitor_ref: Process.monitor(from),
        status: :waiting
      }

      socket
      |> put_doc_browser_pending(request_id, entry)
      |> push_event("document.engine.operation.command", %{
        request_id: request_id,
        document_id: document_id,
        verb: to_string(verb),
        payload: wire_payload
      })
    else
      send(
        from,
        {:doc_browser_reply, ref,
         {:error,
          {:document_mismatch, %{expected: expected_document_id, actual: routed_document_id}}}}
      )

      socket
    end
  end

  defp valid_doc_browser_route?(nil, _actual), do: true
  defp valid_doc_browser_route?(expected, actual), do: expected == actual

  defp put_doc_browser_pending(socket, request_id, entry) do
    assign(
      socket,
      :doc_browser_pending,
      Map.put(socket.assigns.doc_browser_pending, request_id, entry)
    )
  end

  defp complete_doc_browser_pending(socket, request_id, entry) do
    socket = update(socket, :doc_browser_pending, &Map.delete(&1, request_id))

    cond do
      entry.verb == :vfs_write and match?({:ok, _result}, entry.result) ->
        lease_doc_browser_write(socket, entry)

      entry.verb == :vfs_commit and match?({:ok, _result}, entry.result) ->
        release_doc_browser_entry_resources(entry)

        socket
        |> release_doc_browser_lease(entry)
        |> queue_doc_browser_finalize(entry)

      entry.verb == :vfs_rollback and match?({:ok, _result}, entry.result) ->
        release_doc_browser_entry_resources(entry)
        release_doc_browser_lease(socket, entry)

      true ->
        release_doc_browser_entry_resources(entry)
        socket
    end
  end

  defp queue_doc_browser_finalize(socket, entry) do
    edit_id = doc_browser_edit_id(entry.payload)

    if is_binary(edit_id) and edit_id != "" do
      request_id = "dbr-finalize:#{System.unique_integer([:positive, :monotonic])}"

      finalize_entry = %{
        # LiveView owns this cleanup request after the caller ACK. It has no
        # caller monitor and must never be converted back into a rollback by a
        # later turn/document teardown.
        kind: :vfs_finalize,
        verb: :vfs_finalize,
        payload: entry.payload,
        document_id: entry.document_id,
        expected_document_id: entry.expected_document_id,
        attempt: 1,
        status: :waiting
      }

      push_doc_browser_finalize_attempt(socket, request_id, finalize_entry)
    else
      socket
    end
  end

  defp push_doc_browser_finalize_attempt(socket, request_id, entry) do
    timer_ref =
      Process.send_after(
        self(),
        {:doc_browser_finalize_timeout, request_id, entry.attempt},
        @doc_browser_finalize_timeout_ms
      )

    entry = Map.put(entry, :timer_ref, timer_ref)

    socket
    |> put_doc_browser_pending(request_id, entry)
    |> push_event("document.engine.operation.command", %{
      request_id: request_id,
      document_id: entry.document_id,
      verb: "vfs_finalize",
      payload: entry.payload
    })
  end

  defp retry_or_recover_doc_browser_finalize(socket, request_id, entry, reason) do
    release_doc_browser_entry_resources(entry)

    if entry.attempt < @doc_browser_finalize_max_attempts and
         doc_browser_finalize_route_active?(socket, entry) do
      Logger.warning(
        "retrying browser VFS finalize attempt=#{entry.attempt + 1} reason=#{inspect(reason)}"
      )

      entry =
        entry
        |> Map.put(:attempt, entry.attempt + 1)
        |> Map.delete(:timer_ref)

      push_doc_browser_finalize_attempt(socket, request_id, entry)
    else
      recover_doc_browser_finalize(socket, request_id, entry, reason)
    end
  end

  defp doc_browser_finalize_route_active?(socket, entry) do
    entry.document_id == active_document_id(socket) and
      valid_doc_browser_route?(entry.expected_document_id, socket.assigns[:pool_document_id])
  end

  defp recover_doc_browser_finalize(socket, request_id, entry, reason) do
    Logger.error(
      "browser VFS finalize exhausted retries; reloading committed bytes reason=#{inspect(reason)}"
    )

    socket = update(socket, :doc_browser_pending, &Map.delete(&1, request_id))

    if doc_browser_finalize_route_active?(socket, entry) and
         socket.assigns[:hwp_stream_renderer] == :rhwp_wasm do
      recovery_id = "dbr-recovery:#{System.unique_integer([:positive, :monotonic])}"

      recovery_entry = %{
        # The commit completion ACK already crossed the irreversible boundary.
        # This server-owned request may retry or fail visibly, but teardown must
        # never convert it into a browser rollback.
        kind: :vfs_recovery,
        verb: :vfs_recovery,
        document_id: entry.document_id,
        expected_document_id: entry.expected_document_id,
        attempt: 1,
        status: :waiting,
        finalize_reason: reason
      }

      push_doc_browser_recovery_attempt(socket, recovery_id, recovery_entry)
    else
      socket
    end
  end

  defp push_doc_browser_recovery_attempt(socket, recovery_id, entry) do
    version = System.unique_integer([:positive, :monotonic])
    workspace_path = socket.assigns[:workspace_path]
    relative_path = socket.assigns[:active_document_path]

    case document_bytes_url(workspace_path, relative_path, version) do
      url when is_binary(url) ->
        timer_ref =
          Process.send_after(
            self(),
            {:doc_browser_recovery_timeout, recovery_id, entry.attempt},
            @doc_browser_recovery_timeout_ms
          )

        entry = Map.put(entry, :timer_ref, timer_ref)

        socket
        |> assign(:document_bytes_version, version)
        |> put_doc_browser_pending(recovery_id, entry)
        |> push_event("document.hwp.load_command", %{
          url: url,
          document_id: entry.document_id,
          force: true,
          vfs_recovery: true,
          vfs_recovery_id: recovery_id,
          vfs_recovery_attempt: entry.attempt
        })

      _missing_url ->
        fail_doc_browser_recovery(socket, recovery_id, entry, :missing_document_url)
    end
  end

  defp retry_or_fail_doc_browser_recovery(socket, recovery_id, entry, reason) do
    release_doc_browser_entry_resources(entry)

    if entry.attempt < @doc_browser_recovery_max_attempts and
         doc_browser_finalize_route_active?(socket, entry) do
      Logger.warning(
        "retrying browser canonical recovery attempt=#{entry.attempt + 1} reason=#{inspect(reason)}"
      )

      entry =
        entry
        |> Map.put(:attempt, entry.attempt + 1)
        |> Map.put(:last_reason, reason)
        |> Map.delete(:timer_ref)

      push_doc_browser_recovery_attempt(socket, recovery_id, entry)
    else
      fail_doc_browser_recovery(socket, recovery_id, entry, reason)
    end
  end

  defp fail_doc_browser_recovery(socket, recovery_id, entry, reason) do
    release_doc_browser_entry_resources(entry)

    Logger.error(
      "browser canonical recovery failed after commit attempt=#{entry.attempt} reason=#{inspect(reason)}"
    )

    failed_entry =
      entry
      |> Map.put(:status, :failed)
      |> Map.put(:last_reason, reason)
      |> Map.delete(:timer_ref)

    socket
    |> put_doc_browser_pending(recovery_id, failed_entry)
    |> assign(
      :document_error,
      "The edit was saved, but the browser could not reload the committed document."
    )
  end

  defp lease_doc_browser_write(socket, entry) do
    case doc_browser_edit_id(entry.payload) do
      edit_id when is_binary(edit_id) and edit_id != "" ->
        key = {edit_id, entry.from}
        lease = Map.drop(entry, [:ref, :result, :status])

        socket =
          case Map.get(socket.assigns.doc_browser_vfs_leases, key) do
            nil -> socket
            existing -> cancel_doc_browser_entries(socket, [], [{key, existing}], reply?: false)
          end

        assign(
          socket,
          :doc_browser_vfs_leases,
          Map.put(socket.assigns.doc_browser_vfs_leases, key, lease)
        )

      _missing ->
        release_doc_browser_entry_resources(entry)
        socket
    end
  end

  defp release_doc_browser_lease(socket, entry) do
    key = {doc_browser_edit_id(entry.payload), entry.from}

    case Map.pop(socket.assigns.doc_browser_vfs_leases, key) do
      {nil, _leases} ->
        socket

      {lease, leases} ->
        release_doc_browser_entry_resources(lease)
        assign(socket, :doc_browser_vfs_leases, leases)
    end
  end

  defp cancel_doc_browser_pending(socket, request_id, entry, opts) do
    lease_matches =
      if entry.verb in [:vfs_commit, :vfs_rollback] do
        key = {doc_browser_edit_id(entry.payload), entry.from}

        case Map.get(socket.assigns.doc_browser_vfs_leases, key) do
          nil -> []
          lease -> [{key, lease}]
        end
      else
        []
      end

    cancel_doc_browser_entries(socket, [{request_id, entry}], lease_matches, opts)
  end

  defp cancel_all_doc_browser_pending(socket) do
    cancel_doc_browser_entries(
      socket,
      Map.to_list(socket.assigns.doc_browser_pending),
      Map.to_list(socket.assigns.doc_browser_vfs_leases),
      reason: :document_changed,
      reply?: true
    )
  end

  defp cancel_doc_browser_owner(socket, from, opts) do
    pending =
      Enum.filter(socket.assigns.doc_browser_pending, fn {_id, entry} ->
        entry_owner?(entry, from)
      end)

    leases =
      Enum.filter(socket.assigns.doc_browser_vfs_leases, fn {_id, entry} ->
        entry_owner?(entry, from)
      end)

    cancel_doc_browser_entries(socket, pending, leases, opts)
  end

  defp cancel_doc_browser_identity(socket, identity, opts) do
    pending =
      Enum.filter(socket.assigns.doc_browser_pending, fn {_id, entry} ->
        entry_identity?(entry, identity)
      end)

    leases =
      Enum.filter(socket.assigns.doc_browser_vfs_leases, fn {_id, entry} ->
        entry_identity?(entry, identity)
      end)

    cancel_doc_browser_entries(socket, pending, leases, opts)
  end

  defp cancel_doc_browser_entries(socket, pending, leases, opts) do
    reason = Keyword.get(opts, :reason, :cancelled)

    if Keyword.get(opts, :reply?, false) do
      Enum.each(pending, fn
        {_request_id, %{from: from, ref: ref}} ->
          send(from, {:doc_browser_reply, ref, {:error, reason}})

        {_request_id, {from, ref, _verb}} ->
          send(from, {:doc_browser_reply, ref, {:error, reason}})

        _legacy ->
          :ok
      end)
    end

    Enum.each(pending ++ leases, fn {_key, entry} ->
      release_doc_browser_entry_resources(entry)
    end)

    pending_keys = Enum.map(pending, &elem(&1, 0))
    lease_keys = Enum.map(leases, &elem(&1, 0))

    socket
    |> assign(:doc_browser_pending, Map.drop(socket.assigns.doc_browser_pending, pending_keys))
    |> assign(
      :doc_browser_vfs_leases,
      Map.drop(socket.assigns.doc_browser_vfs_leases, lease_keys)
    )
    |> push_doc_browser_rollbacks(Enum.map(pending ++ leases, &elem(&1, 1)))
  end

  defp release_doc_browser_entry_resources(entry) when is_map(entry) do
    case entry[:monitor_ref] do
      monitor_ref when is_reference(monitor_ref) -> Process.demonitor(monitor_ref, [:flush])
      _other -> false
    end

    case entry[:timer_ref] do
      timer_ref when is_reference(timer_ref) -> Process.cancel_timer(timer_ref)
      _other -> false
    end

    :ok
  end

  defp release_doc_browser_entry_resources(_entry), do: false

  defp doc_browser_owner_monitor?(socket, monitor_ref, from) do
    Enum.any?(
      Map.values(socket.assigns.doc_browser_pending) ++
        Map.values(socket.assigns.doc_browser_vfs_leases),
      fn
        %{monitor_ref: ^monitor_ref, from: ^from} -> true
        _entry -> false
      end
    )
  end

  defp entry_owner?(%{from: from}, from), do: true
  defp entry_owner?(_entry, _from), do: false

  defp entry_identity?(%{identity: identity}, identity) when is_map(identity), do: true
  defp entry_identity?(_entry, _identity), do: false

  defp push_doc_browser_rollbacks(socket, entries) do
    entries
    |> Enum.flat_map(fn
      entry when is_map(entry) ->
        edit_id = doc_browser_edit_id(entry[:payload])

        # vfs_finalize is intentionally absent: the bridge completion ACK is
        # already the commit point, so teardown may abandon/reload cleanup but
        # must not roll the browser model back to the pre-commit snapshot.
        if entry[:verb] in [:vfs_write, :vfs_commit, :vfs_rollback] and is_binary(edit_id) and
             edit_id != "" do
          [{{entry[:document_id], edit_id}, entry}]
        else
          []
        end

      _legacy_entry ->
        []
    end)
    |> Map.new()
    |> Enum.reduce(socket, fn {{document_id, edit_id}, _entry}, socket ->
      push_event(socket, "document.engine.operation.command", %{
        request_id: "dbr-cancel:#{System.unique_integer([:positive, :monotonic])}",
        document_id: document_id,
        verb: "vfs_rollback",
        payload: %{edit_id: edit_id, document_id: document_id}
      })
    end)
  end

  defp doc_browser_edit_id(payload) when is_map(payload) do
    payload[:edit_id] || payload["edit_id"] || payload[:editId] || payload["editId"]
  end

  defp doc_browser_edit_id(_payload), do: nil

  defp doc_browser_identity(payload) when is_map(payload) do
    identity = %{
      agent_id: payload[:agent_id] || payload["agent_id"],
      instance_id: payload[:instance_id] || payload["instance_id"],
      turn_id: payload[:turn_id] || payload["turn_id"]
    }

    if Enum.all?(Map.values(identity), &(is_binary(&1) and &1 != "")), do: identity, else: nil
  end

  # Augment the verb payload with the doc id. Values cross the wire as JSON, so
  # keyword lists (e.g. doc.read's `opts`) are coerced into plain maps the client
  # (and Jason) can serialise.
  defp doc_browser_payload(payload, socket) do
    payload
    |> Map.put(:document_id, socket.assigns[:pool_document_id])
    |> Map.new(fn {k, v} -> {k, jsonable(v)} end)
  end

  defp jsonable(kw) when is_list(kw) do
    if Keyword.keyword?(kw), do: Map.new(kw, fn {k, v} -> {k, jsonable(v)} end), else: kw
  end

  defp jsonable(v), do: v

  # Decode the hook's reply params into a `{:ok, map}` / `{:error, reason}` the
  # MCP caller understands.
  defp doc_browser_result(%{"error" => error}) when is_binary(error), do: {:error, error}
  defp doc_browser_result(%{"result" => result}) when is_map(result), do: {:ok, result}
  defp doc_browser_result(%{"ok" => true} = params), do: {:ok, Map.delete(params, "request_id")}
  defp doc_browser_result(_params), do: {:error, "browser_apply_failed"}

  # Attach this LiveView to the durable per-workspace `Ecrits.Workspace.Session`
  # and bind the foreground agent selected by this browser tab. Simultaneous
  # LiveViews with the same stable tab id share that selection; a refresh reuses
  # it. The static (disconnected) render spawns nothing.
  defp attach_workspace_session(%{assigns: %{workspace_error: error}} = socket)
       when is_binary(error),
       do: socket

  defp attach_workspace_session(socket) do
    path = socket.assigns.workspace_path

    cond do
      not connected?(socket) ->
        socket

      not is_binary(socket.assigns.chat_rail_tab_id) ->
        socket

      not (is_binary(path) and path != "") ->
        socket

      true ->
        do_attach_workspace_session(socket, path)
    end
  end

  defp do_attach_workspace_session(socket, path) do
    case safe_attach_workspace_session(path, agent_attach_settings(socket)) do
      {:ok, %{agent_id: agent_id} = ws} when is_binary(agent_id) ->
        bind_workspace_foreground(socket, ws, agent_id)

      {:pending, _ws} ->
        socket

      {:error, reason, _ws} ->
        Logger.warning("workspace agent attach failed: #{inspect(reason)}")
        socket

      {:error, reason} ->
        Logger.warning("workspace agent attach failed: #{inspect(reason)}")
        socket
    end
  end

  # A same-agent rebind refreshes durable metadata without replaying over a live
  # stream. A provider restart keeps the same durable id but replaces the agent
  # process, so that path must repaint every sibling from the new empty snapshot.
  # A changed selection swaps PubSub topics and repaints as usual. Every
  # successful path clears any stale rail-selection error.
  defp bind_workspace_foreground(socket, ws, agent_id) do
    agent_pid = ACP.whereis(agent_id)

    cond do
      socket.assigns.agent_session_id != agent_id ->
        socket
        |> bind_agent_subscription(agent_id)
        |> assign(:workspace_session, ws)
        |> maybe_restore_session_documents(ws)
        |> snapshot_agent(ws, agent_id)

      agent_process_changed?(socket, agent_pid) ->
        socket
        |> assign(:workspace_session, ws)
        |> maybe_restore_session_documents(ws)
        |> snapshot_agent(ws, agent_id)

      true ->
        socket
        |> assign(:workspace_session, ws)
        |> assign(:agent_session_id, agent_id)
        |> assign(:agent_rail_key, Map.get(ws, :rail_key))
        |> assign(:agent_error, nil)
        |> maybe_restore_session_documents(ws)
        |> refresh_agent_rails()
        |> apply_vfs_write_policy()
    end
  end

  defp agent_process_changed?(socket, agent_pid) when is_pid(agent_pid) do
    Map.get(socket.assigns, :agent_process_pid) != agent_pid
  end

  defp agent_process_changed?(_socket, _agent_pid), do: false

  defp same_workspace_path?(left, right) when is_binary(left) and is_binary(right) do
    Path.expand(left) == Path.expand(right)
  end

  defp same_workspace_path?(_left, _right), do: false

  # Bind + repaint the inline chat from the foreground agent's display-only
  # snapshot (initial bind / selecting a recent rail). codex `thread/resume`
  # restores memory but does not re-stream past messages, so repaint the prior
  # bubbles from the durable transcript.
  defp snapshot_agent(socket, ws, agent_id) do
    snapshot = WorkspaceSession.snapshot(ws)
    stored_opts = Map.get(snapshot, :adapter_opts, [])

    socket
    |> cancel_agent_text_flush()
    |> cancel_agent_reasoning_flush()
    |> assign(:workspace_session, ws)
    |> assign(:agent_session_id, agent_id)
    |> assign(:agent_process_pid, ACP.whereis(agent_id))
    |> assign(:agent_instance_id, Map.get(snapshot, :instance_id))
    |> assign(:agent_event_seq, Map.get(snapshot, :event_seq, 0))
    |> assign(:agent_rail_key, Map.get(ws, :rail_key))
    |> assign(:agent_error, nil)
    |> assign(:agent_status, snapshot.status)
    |> assign(:agent_turn_id, snapshot_current_turn_id(snapshot))
    |> assign(:agent_text, "")
    |> assign(:agent_text_segment, 0)
    |> assign(:agent_editor_preview, nil)
    |> assign(:agent_vfs_preview_item, nil)
    |> assign(:agent_vfs_preview_rollback_item, nil)
    |> assign(:agent_reasoning_text, "")
    |> assign(:agent_reasoning_segment, 0)
    |> assign(:agent_reasoning_open?, false)
    |> assign(:agent_active_tools, %{})
    |> assign(:agent_active_file_operations, %{})
    # Restore the pending-queue count from the selected rail (Phase 5). A snapshot from a
    # pre-Phase-5 agent has no `:pending` key → default 0.
    |> assign(:agent_pending, Map.get(snapshot, :pending, 0))
    |> assign(:agent_queue, queued_items_from_snapshot(Map.get(snapshot, :queued, [])))
    |> assign(:agent_queue_index, 0)
    |> restore_agent_title(snapshot.title, Map.get(snapshot, :title_user_edited?, false))
    |> hydrate_agent_display_from_snapshot(snapshot)
    # Hydrate reasoning/access from the selected rail's stored adapter_opts — not
    # route params (which are deliberately ignored for these settings).
    |> hydrate_agent_options_from_session(stored_opts)
    |> apply_vfs_write_policy()
    |> stream(:agent_items, [], reset: true)
    |> replay_agent_transcript(snapshot.transcript)
    |> replay_agent_current(Map.get(snapshot, :current_turn))
    |> refresh_agent_rails()
  end

  defp snapshot_current_turn_id(%{current_turn: %{id: id}}) when is_binary(id), do: id
  defp snapshot_current_turn_id(%{current_turn: %{"id" => id}}) when is_binary(id), do: id
  defp snapshot_current_turn_id(_snapshot), do: nil

  defp hydrate_agent_display_from_snapshot(socket, snapshot) when is_map(snapshot) do
    stored_opts = Map.get(snapshot, :adapter_opts, [])
    provider_id = Map.get(snapshot, :provider)

    model_id =
      Map.get(snapshot, :model) || Keyword.get(stored_opts, :model) ||
        default_agent_model_id(provider_id)

    with provider_id when is_binary(provider_id) <-
           AgentConfig.allowed_provider(provider_id, allowed_provider_ids()),
         model_id when is_binary(model_id) <- model_id,
         %{provider: ^provider_id} <- agent_model(model_id) do
      put_agent(socket,
        provider: agent_provider_display(provider_id),
        provider_warning: nil,
        model: model_id,
        integrations: agent_integrations()
      )
    else
      _ -> socket
    end
  end

  # Settings the durable session OWNS and we hydrate back into the assigns on
  # attach. Each is resolved optimistically as `session_value || default` — read
  # from the session adapter_opts, falling back to the configured default when a
  # fresh agent has none yet — then assigned unconditionally (no per-option
  # branching). access_control is the stored id; a legacy/initial session that
  # only has `permission_mode` is mapped back through it before the default.
  defp hydrate_agent_options_from_session(socket, opts) when is_list(opts) do
    provider_key = socket.assigns.agent.provider.key

    reasoning =
      AgentConfig.reasoning_effort(
        opts[:reasoning_effort] || default_reasoning_effort(),
        agent_reasoning_efforts(provider_key)
      )

    access =
      opts[:access_control] || access_from_permission_mode(opts[:permission_mode]) ||
        default_access_control()

    socket
    |> put_agent(reasoning_effort: reasoning)
    |> put_agent_access(access)
  end

  defp hydrate_agent_options_from_session(socket, _), do: socket

  defp access_from_permission_mode("plan"), do: "read-only"
  defp access_from_permission_mode("dontAsk"), do: "full-workspace"
  defp access_from_permission_mode(_), do: nil

  # GENUINE restart of the foreground agent on a PROVIDER switch (codex<->claude,
  # or a cross-provider model selection). The ACP adapter is bound at the agent's
  # start and cannot be swapped on a running session, so we TERMINATE the current
  # agent and START a fresh one (new adapter + the now-updated provider/model/
  # access settings), then re-bind the LiveView to a genuinely-new, EMPTY session:
  #   * the path-keyed agent id is unchanged, so the LiveView's existing PubSub
  #     subscription to `agent:<id>` still routes the NEW agent's events —
  #     we must NOT re-subscribe (that would double-deliver every event); and
  #   * the transcript is CLEARED, title reset to "New Chat", queue/pending/turn/
  #     error cleared — no chat-log replay across providers.
  defp restart_agent_for_provider(socket) do
    path = socket.assigns.workspace_path

    case safe_restart_foreground(path, agent_attach_settings(socket)) do
      {:ok, %{agent_id: agent_id} = ws} when is_binary(agent_id) ->
        bind_fresh_agent_session(socket, ws, agent_id)

      {:pending, _ws} ->
        socket

      _ ->
        # Restart failed (provider CLI missing / infra down). Leave the existing
        # session bound and surface the warning rather than wiping the chat.
        socket
    end
  end

  # Tolerate the workspace-Session infra not being up (mirrors
  # safe_attach_workspace_session) so a provider switch degrades instead of
  # crashing the live process.
  defp safe_restart_foreground(path, settings) when is_binary(path) and path != "" do
    WorkspaceSession.restart_foreground(path, settings)
  rescue
    e -> {:error, {:session_unavailable, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  defp safe_restart_foreground(_path, _settings), do: {:error, :no_path}

  defp safe_new_foreground(path, settings) when is_binary(path) and path != "" do
    WorkspaceSession.new_foreground(path, settings)
  rescue
    e -> {:error, {:session_unavailable, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  defp safe_new_foreground(_path, _settings), do: {:error, :no_path}

  defp safe_select_foreground(path, rail_key, settings)
       when is_binary(path) and path != "" and is_binary(rail_key) and rail_key != "" do
    WorkspaceSession.select_foreground(path, rail_key, settings)
  rescue
    e -> {:error, {:session_unavailable, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  defp safe_select_foreground(_path, _rail_key, _settings), do: {:error, :not_found}

  defp refresh_agent_rails(%{assigns: %{workspace_session: %{} = ws}} = socket) do
    assign(socket, :agent_rails, safe_recent_foregrounds(ws))
  end

  defp refresh_agent_rails(socket), do: assign(socket, :agent_rails, [])

  defp safe_recent_foregrounds(ws) do
    WorkspaceSession.recent_foregrounds(ws)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp bind_fresh_agent_session(socket, ws, agent_id) do
    snapshot = ACP.agent_snapshot(agent_id)
    instance_id = Map.get(snapshot, :instance_id)

    socket
    |> cancel_agent_text_flush()
    |> cancel_agent_reasoning_flush()
    |> assign(:workspace_session, ws)
    |> assign(:agent_session_id, agent_id)
    |> assign(:agent_process_pid, ACP.whereis(agent_id))
    |> assign(:agent_instance_id, instance_id)
    |> assign(:agent_event_seq, Map.get(snapshot, :event_seq, 0))
    |> assign(:agent_rail_key, Map.get(ws, :rail_key))
    |> assign(:agent_error, nil)
    |> assign(:agent_status, :idle)
    |> assign(:agent_pending, 0)
    |> assign(:agent_queue, [])
    |> assign(:agent_queue_index, 0)
    |> assign(:agent_turn_id, nil)
    |> assign(:agent_text, "")
    |> assign(:agent_text_segment, 0)
    |> assign(:agent_editor_preview, nil)
    |> assign(:agent_vfs_preview_item, nil)
    |> assign(:agent_vfs_preview_rollback_item, nil)
    |> assign(:agent_reasoning_text, "")
    |> assign(:agent_reasoning_segment, 0)
    |> assign(:agent_reasoning_open?, false)
    |> assign(:agent_active_tools, %{})
    |> assign(:agent_active_file_operations, %{})
    |> assign(:agent_title_user_edited?, false)
    |> assign_agent_title(default_agent_title())
    |> assign(:agent_form, agent_form())
    |> stream(:agent_items, [], reset: true)
    |> refresh_agent_rails()
    |> push_event("agent.title.reset", %{title: default_agent_title()})
  end

  # Tolerate the workspace-Session supervision infra not being up yet (e.g. the
  # SessionSupervisor/Registry child was added to the tree but the server hasn't
  # been restarted to activate it). Degrade rather than crashing the mount.
  defp safe_attach_workspace_session(path, settings) do
    WorkspaceSession.attach(path, settings)
  rescue
    e -> {:error, {:session_unavailable, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:session_unavailable, reason}}
  end

  # Settings used to SEED the foreground agent on first attach. Same-pid attaches
  # re-use the active rail and apply live settings. Mirrors agent_session_opts
  # minus the explicit `:id` (the Session derives the id from path + rail key).
  defp agent_attach_settings(socket) do
    socket
    |> agent_session_opts()
    |> Keyword.put(:live_session_id, socket.assigns.live_session_id)
    |> Keyword.put(
      :chat_rail_id,
      Map.get(socket.assigns, :chat_rail_tab_id, socket.assigns.live_session_id)
    )
    |> Keyword.delete(:id)
  end

  defp live_session_id(session) when is_map(session) do
    case session["live_session_id"] || session[:live_session_id] do
      id when is_binary(id) and id != "" -> id
      _ -> Ecto.UUID.generate()
    end
  end

  defp live_session_id(_session), do: Ecto.UUID.generate()

  # Apply per-turn option changes (access/reasoning/model/provider) to the LIVE
  # foreground agent without recreating it, preserving the conversation. No agent
  # bound yet -> nothing to do (the first attach seeds these from the assigns).
  defp maybe_apply_live_agent_options(socket, false), do: socket

  defp maybe_apply_live_agent_options(
         %{assigns: %{workspace_session: %{} = ws}} = socket,
         true
       ) do
    workspace_path = workspace_root_path(socket.assigns.workspace || %{})

    _ =
      WorkspaceSession.update_options(
        ws,
        agent_adapter_opts(socket, workspace_path)
      )

    socket
  end

  defp maybe_apply_live_agent_options(socket, _changed?), do: socket

  defp finalize_agent_turn(
         %{assigns: %{workspace_session: %{} = ws}} = socket,
         instance_id,
         turn_id
       ) do
    case WorkspaceSession.finalize_turn(ws, turn_id, instance_id: instance_id) do
      {:ok, status} when status in [:started, :queued, :running] ->
        socket

      {:ok, {:completed, _summary}} ->
        # A late subscriber may receive the terminal after the one completion
        # broadcast. The work is already durable; it only needs a fresh tree.
        refresh_tree(socket)

      {:error, reason} ->
        Logger.warning("turn finalizer: could not claim #{turn_id}: #{inspect(reason)}")
        socket
    end
  end

  defp finalize_agent_turn(socket, _instance_id, _turn_id), do: socket

  defp surface_turn_finalization(socket, %{saved: paths}) when is_list(paths) do
    if paths == [], do: socket, else: after_auto_save(socket, paths)
  end

  defp surface_turn_finalization(socket, {:error, reason}) do
    Logger.warning("turn finalizer: terminal work failed: #{inspect(reason)}")
    socket
  end

  defp surface_turn_finalization(socket, _result), do: socket

  # The Session's single finalizer broadcasts the result to every LiveView. The
  # bound rail surfaces the save notice while all workspace views refresh once.
  defp after_auto_save(socket, paths) do
    put_flash(
      socket,
      :info,
      "Saved #{length(paths)} document#{if length(paths) == 1, do: "", else: "s"} the agent left unsaved."
    )
  end

  # Resolve a hook-supplied `octet_id` stash reference into the binary it names
  # before the params reach persistence or an agent reply. Agent-routed op
  # replies nest the saved fields under "result".
  defp claim_octet(socket, %{"octet_id" => id} = params) when is_binary(id) do
    {bytes, stash} = Map.pop(socket.assigns.octet_stash, id)
    socket = assign(socket, :octet_stash, stash)
    params = Map.delete(params, "octet_id")
    {socket, if(is_binary(bytes), do: Map.put(params, "bytes", bytes), else: params)}
  end

  defp claim_octet(socket, %{"result" => %{"octet_id" => _} = result} = params) do
    {socket, result} = claim_octet(socket, result)
    {socket, Map.put(params, "result", result)}
  end

  defp claim_octet(socket, params), do: {socket, params}

  defp handle_document_import_upload(:document_import, entry, socket) do
    if entry.done? do
      socket
      |> import_document_entry(entry)
      |> case do
        {:ok, socket} ->
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, :document_error, error_message(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  defp import_document_entry(%{assigns: %{workspace: nil}}, _entry),
    do: {:error, :workspace_not_mounted}

  defp import_document_entry(socket, entry) do
    root = workspace_root_path(socket.assigns.workspace)

    case consume_uploaded_entry(socket, entry, fn %{path: path} ->
           {:ok, import_document_file(root, path, entry.client_name)}
         end) do
      {:ok, relative_path} ->
        socket =
          socket
          |> assign(:document_error, nil)
          |> refresh_tree()
          |> schedule_document_open(relative_path)

        {:ok, socket}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_document_file(root, source_path, client_name) do
    with {:ok, relative_path} <- unique_import_path(root, client_name),
         {:ok, bytes} <- File.read(source_path),
         {:ok, _format} <- Document.detect_format(relative_path, bytes),
         :ok <- Workspace.write_file(root, relative_path, bytes) do
      {:ok, relative_path}
    end
  end

  defp unique_import_path(root, client_name) do
    with {:ok, base_name} <- import_base_name(client_name),
         {:ok, _format} <- Document.detect_format(base_name) do
      0..999
      |> Enum.reduce_while(nil, fn index, _acc ->
        candidate = import_candidate(base_name, index)

        case import_path_exists?(root, candidate) do
          {:ok, false} -> {:halt, {:ok, candidate}}
          {:ok, true} -> {:cont, nil}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        nil -> {:error, :import_name_conflict}
        result -> result
      end
    end
  end

  defp import_base_name(client_name) when is_binary(client_name) do
    client_name
    |> Path.basename()
    |> String.trim()
    |> case do
      value when value in ["", ".", ".."] -> {:error, :invalid_path}
      value -> {:ok, value}
    end
  end

  defp import_base_name(_client_name), do: {:error, :invalid_path}

  defp import_candidate(base_name, 0), do: base_name

  defp import_candidate(base_name, index) do
    extension = Path.extname(base_name)
    stem = Path.rootname(base_name)

    "#{stem}-#{index + 1}#{extension}"
  end

  defp import_path_exists?(root, relative_path) do
    with {:ok, path} <- WorkspacePath.join(root, relative_path) do
      {:ok, File.exists?(path)}
    end
  end

  defp assign_document_upload_errors(socket) do
    case document_upload_errors(socket) do
      [] -> socket
      errors -> assign(socket, :document_error, document_upload_error(errors))
    end
  end

  defp document_upload_errors(socket) do
    upload = socket.assigns.uploads.document_import

    Phoenix.Component.upload_errors(upload) ++
      Enum.flat_map(upload.entries, &Phoenix.Component.upload_errors(upload, &1))
  end

  defp document_upload_error([:not_accepted | _errors]), do: "Select a supported document."
  defp document_upload_error([:too_large | _errors]), do: "Selected file is too large."
  defp document_upload_error([:too_many_files | _errors]), do: "Select one file at a time."
  defp document_upload_error([_error | _errors]), do: "Local document import failed."

  defp agent_session_opts(socket) do
    workspace = socket.assigns.workspace || %{}
    workspace_path = workspace_root_path(workspace)
    agent_ui = Application.get_env(:ecrits, :agent_ui, [])

    adapter_opts =
      agent_ui
      |> Keyword.get(:adapter_opts, [])
      |> Keyword.merge(agent_adapter_opts(socket, workspace_path))

    agent_ui
    |> Keyword.put(:provider, socket.assigns.agent.provider.key)
    |> Keyword.put(:approval_policy, socket.assigns.agent.access.approval_policy)
    |> Keyword.put(:access_control, socket.assigns.agent.access.id)
    |> Keyword.put(:adapter_opts, adapter_opts)
    |> Keyword.put(:workspace_root, workspace_path)
    |> Keyword.put(:document_path, socket.assigns.active_document_path)
    |> Keyword.put(:workspace_path, workspace_path)
    |> put_pool_document_id(socket.assigns[:pool_document_id])

    # NOTE: no `:id` here. `Ecrits.Workspace.Session` derives it from the
    # canonical workspace path and this LiveView's active rail key.
  end

  defp agent_adapter_opts(socket, workspace_path) do
    socket.assigns.agent
    |> AgentConfig.adapter_opts(workspace_path)
    |> Keyword.put(
      :doc_vfs_mounted,
      is_binary(workspace_path) and Ecrits.Fuse.DocMount.mounted?(workspace_path)
    )
  end

  # The agent's doc.* ACTIVE doc is the `Ecrits.Doc.Pool` id (what doc.context
  # returns and doc.edit/doc.open target), distinct from the LiveView document_id.
  # register_pool_document stores it in :pool_document_id; seed/forward it so the
  # agent's tool context points at the doc this viewer opened.
  defp put_pool_document_id(opts, pool_document_id)
       when is_binary(pool_document_id) and pool_document_id != "",
       do: Keyword.put(opts, :pool_document_id, pool_document_id)

  defp put_pool_document_id(opts, _pool_document_id), do: opts

  defp refresh_tree(%{assigns: %{workspace: nil}} = socket), do: socket

  defp refresh_tree(socket) do
    expanded_paths = FileTree.expanded_path_set(socket.assigns.file_tree)

    case Adapter.list_tree(socket.assigns.workspace, expanded_paths) do
      {:ok, tree} ->
        update(socket, :file_tree, &FileTree.put_nodes(&1, tree))

      {:error, reason} ->
        # The workspace became unreadable (e.g. the folder was removed). Don't
        # strand the user on a dead-end error page — send them back to the
        # folder picker ("/"), mirroring do_mount_workspace's mount-failure path.
        socket
        |> put_flash(:error, "Workspace is no longer available: #{error_message(reason)}")
        |> push_navigate(to: ~p"/")
    end
  end

  # Subscribe to the shared per-workspace file watcher owned by
  # `Ecrits.Workspace.Session`. Idempotent per workspace root: multiple tabs can
  # subscribe, but only the Session starts a macOS watcher for that root.
  defp maybe_subscribe_workspace_fs_events(socket) do
    root = workspace_root_path(socket.assigns.workspace)
    subscribed_paths = socket.assigns.workspace_fs_subscribed_paths

    cond do
      not (connected?(socket) and is_binary(root) and root != "") ->
        socket

      MapSet.member?(subscribed_paths, Path.expand(root)) ->
        socket

      true ->
        :ok = WorkspaceSession.subscribe_file_events(root)

        assign(
          socket,
          :workspace_fs_subscribed_paths,
          MapSet.put(subscribed_paths, Path.expand(root))
        )
    end
  end

  defp stop_fs_watcher(%{assigns: %{fs_watcher_pid: pid}}) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  end

  defp stop_fs_watcher(_socket), do: :ok

  # Subscribe (once) to the agent-file-write topic so a server-side doc.create /
  # doc.save shows up in the tree LIVE. Idempotent: the flag guards against a
  # second subscribe on a same-process re-mount (which would deliver every
  # broadcast twice). Gated on `connected?` — there's no point subscribing the
  # throwaway static-render process.
  defp maybe_subscribe_workspace_files(%{assigns: %{workspace_files_subscribed?: true}} = socket),
    do: socket

  defp maybe_subscribe_workspace_files(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Ecrits.PubSub, Ecrits.Doc.Tools.workspace_files_topic())
      assign(socket, :workspace_files_subscribed?, true)
    else
      socket
    end
  end

  # True when `path` (the absolute file an agent just wrote) lives under the
  # currently-mounted workspace root. Both sides are expanded so a relative /
  # symlinked / `..`-laden path still compares correctly, and we reject the root
  # itself / unrelated siblings (Path.relative_to leaves an absolute path or a
  # leading ".." when `path` is NOT under `root`).
  defp workspace_contains_path?(socket, path) do
    root = workspace_root_path(socket.assigns.workspace)

    if is_binary(root) and root != "" and is_binary(path) and path != "" do
      abs_root = DocMount.canonical_root(root)
      abs_path = canonical_path_for_compare(path)
      relative = Path.relative_to(abs_path, abs_root)

      relative != abs_path and relative != "." and
        not String.starts_with?(relative, "..")
    else
      false
    end
  end

  defp canonical_path_for_compare(path) when is_binary(path) do
    path = Path.expand(path)
    Path.join(DocMount.canonical_root(Path.dirname(path)), Path.basename(path))
  end

  # Ignore the metadata tree, dotfiles, and editor swap files; everything else
  # is a workspace change worth re-listing.
  #
  # Exception: our own atomic-write temp files (`.<name>.tmp-<n>`, see
  # `Ecrits.FS.tmp_path/1`). An atomic save writes the bytes to that hidden
  # temp then `rename(2)`s it onto the final name. On macOS fsevents the *only*
  # event guaranteed to reach us for a brand-new file is the temp's create event
  # — the final rename event is reported on the destination path but may be
  # coalesced away or split into a separate fsevents latency batch, so we cannot
  # rely on it. Treating the temp path as relevant schedules a (debounced)
  # refresh; by the time it fires the rename has completed and `list_tree` sees
  # the final file. Without this, an agent `doc.save` / atomic write of a NEW
  # file does not show up in the tree until a manual refresh.
  defp fs_relevant_path?(path) when is_binary(path) do
    segments = path |> Path.split() |> Enum.reject(&(&1 in ["/", ""]))
    base = Path.basename(path)

    cond do
      Enum.any?(segments, &(&1 == ".ecrits")) -> false
      atomic_write_temp?(base) -> true
      String.starts_with?(base, ".") -> false
      String.ends_with?(base, "~") -> false
      true -> true
    end
  end

  # Matches `Ecrits.FS.tmp_path/1`: ".<basename>.tmp-<monotonic-int>".
  defp atomic_write_temp?(base) do
    String.starts_with?(base, ".") and base =~ ~r/\.tmp-\d+$/
  end

  # Debounce: collapse a burst of file events into a single refresh.
  defp schedule_tree_refresh(socket) do
    case socket.assigns.fs_refresh_timer do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _ -> :ok
    end

    timer = Process.send_after(self(), :refresh_tree, 150)
    assign(socket, :fs_refresh_timer, timer)
  end

  # After the tree is rebuilt, drop any tabs whose backing file disappeared and
  # focus a neighbor if the active document vanished. Existence is checked on
  # disk (not via the tree) so tabs for files inside collapsed directories are
  # not dropped spuriously.
  defp reconcile_open_documents(socket) do
    root = workspace_root_path(socket.assigns.workspace)
    tabs = socket.assigns.open_documents
    {kept, dropped} = Enum.split_with(tabs, &open_document_exists?(root, &1.path))

    cond do
      dropped == [] ->
        socket

      true ->
        active_id = socket.assigns.active_document_id
        active_dropped? = Enum.any?(dropped, &(&1.id == active_id))

        # Drop dirty state + cancel auto-save timers for tabs that vanished
        # from disk so a removed doc never lingers dirty or auto-saves.
        socket =
          Enum.reduce(dropped, socket, fn tab, acc -> mark_doc_clean(acc, tab.id) end)

        socket =
          dropped
          |> Enum.reduce(assign(socket, :open_documents, kept), fn tab, acc ->
            persist_session_closed_document(acc, tab)
          end)

        cond do
          not active_dropped? ->
            socket

          kept == [] ->
            socket
            |> tear_down_active_document()
            |> assign(:active_document_id, nil)
            |> update(:file_tree, &FileTree.select(&1, nil))

          true ->
            # Pick the tab nearest the one that vanished to keep focus stable.
            dropped_index =
              Enum.find_index(tabs, &(&1.id == active_id)) || 0

            neighbor =
              Enum.at(kept, min(dropped_index, length(kept) - 1)) || List.first(kept)

            schedule_document_open(socket, neighbor.path)
        end
    end
  end

  defp open_document_exists?(root, relative_path)
       when is_binary(root) and root != "" and is_binary(relative_path) do
    case WorkspacePath.normalize(relative_path) do
      {:ok, rel} ->
        case WorkspacePath.join(root, rel) do
          {:ok, absolute} -> File.exists?(absolute)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp open_document_exists?(_root, _relative_path), do: false

  defp workspace_title(nil), do: "Workspace"
  defp workspace_title(workspace), do: Map.get(workspace, :title) || "Workspace"

  defp workspace_root_path(nil), do: ""
  defp workspace_root_path(workspace), do: Map.get(workspace, :root_path) || ""

  defp error_message({:invalid_path, message}) when is_binary(message), do: message
  defp error_message({:error, message}) when is_binary(message), do: message
  defp error_message({:substrate_unavailable, message}) when is_binary(message), do: message
  defp error_message({:write_failed, message}) when is_binary(message), do: message
  defp error_message({:render_failed, message}) when is_binary(message), do: message
  defp error_message({:office_replay_failed, message}) when is_binary(message), do: message

  defp error_message({:invalid_page_count, count}),
    do: "Invalid EHWP page count: #{inspect(count)}."

  defp error_message(:not_found), do: "Local document session was not found."
  defp error_message(:format_mismatch), do: "Local document format did not match."
  defp error_message(:missing_bytes), do: "Local document payload did not include document bytes."
  defp error_message(:missing_replay_journal), do: "Office save did not include replayable edits."

  defp error_message(:unsupported_replay_format),
    do: "Office replay save is only supported for docx, pptx, and xlsx."

  defp error_message(:unsupported_format), do: "Select a supported document."
  defp error_message(:workspace_not_mounted), do: "Workspace is not mounted."
  defp error_message(:import_name_conflict), do: "Could not choose a local import path."
  defp error_message(message) when is_binary(message), do: message
  defp error_message(_reason), do: "Workspace could not be loaded."

  defp persist_rhwp_snapshot(_action, %{"error" => error} = params, socket)
       when is_binary(error) do
    request_id = params["request_id"] || params["requestId"]
    document_id = params["document_id"] || active_document_id(socket)
    _ = ack_rhwp_snapshot_failed(request_id, document_id, error)

    {:reply, %{error: error}, assign(socket, :document_error, error)}
  end

  defp persist_rhwp_snapshot(action, params, socket) when action in [:checkpoint, :save] do
    document_id = params["document_id"] || active_document_id(socket)
    request_id = params["request_id"] || params["requestId"]

    with :ok <- verify_snapshot_document(action, socket, document_id),
         {:ok, response} <- rhwp_persist(action, document_id, params) do
      _ = ack_rhwp_snapshot_committed(request_id, document_id, response)

      socket =
        if document_id == active_document_id(socket) do
          socket
          |> assign(:active_document, document_summary(response))
          |> assign(:document_status, action_status(action))
          |> assign(:document_snapshot, response.snapshot)
          |> assign(:document_error, nil)
          |> maybe_clear_dirty_on_save(action, document_id)
          |> maybe_render_active_hwp_pages(document_id)
        else
          # Flush-before-detach checkpoint for a doc that is no longer the
          # active tab: persist it (that is the whole point — the edits must
          # not be lost to the tab switch) but don't touch the active-doc UI
          # assigns, which belong to the NEW tab.
          maybe_clear_dirty_on_save(socket, action, document_id)
        end

      {:reply,
       %{
         ok: true,
         format: response.format,
         snapshot: response.snapshot
       }, socket}
    else
      {:error, reason} ->
        _ = ack_rhwp_snapshot_failed(request_id, document_id, reason)
        error = error_message(reason)

        {:reply, %{error: error}, assign(socket, :document_error, error)}
    end
  end

  # A checkpoint is accepted for ANY workspace document (the flush-before-detach
  # checkpoint arrives right AFTER the viewer switched tabs, so gating it on the
  # active doc silently dropped the final edits — observed as agent edits lost
  # to a tab switch). The document's existence is still verified downstream by
  # `RhwpAdapter.checkpoint` (`Document.document/1`). A SAVE keeps the strict
  # active-doc gate: it is a user-initiated canonical write for the visible tab.
  defp verify_snapshot_document(:checkpoint, _socket, document_id)
       when is_binary(document_id),
       do: :ok

  defp verify_snapshot_document(_action, socket, document_id),
    do: verify_active_document(socket, document_id)

  defp rhwp_persist(:checkpoint, document_id, params),
    do: RhwpAdapter.checkpoint(document_id, params)

  defp rhwp_persist(:save, document_id, params),
    do: RhwpAdapter.save(document_id, params)

  defp persist_viewer_save(%{"error" => error} = params, socket)
       when is_binary(error) do
    if replay_viewer_save?(params) do
      do_persist_viewer_save(params, socket, &RhwpAdapter.save_replay/2)
    else
      error = error_message(error)

      {:reply, %{error: error}, assign(socket, :document_error, error)}
    end
  end

  defp persist_viewer_save(params, socket) when is_map(params) do
    persist =
      if replay_viewer_save?(params), do: &RhwpAdapter.save_replay/2, else: &RhwpAdapter.save/2

    do_persist_viewer_save(params, socket, persist)
  end

  defp do_persist_viewer_save(params, socket, persist) when is_function(persist, 2) do
    document_id = params["document_id"] || active_document_id(socket)

    with :ok <- verify_active_document(socket, document_id),
         {:ok, response} <- persist.(document_id, params) do
      socket =
        socket
        |> assign(:active_document, document_summary(response))
        |> assign(:document_status, :saved)
        |> assign(:document_snapshot, response.snapshot)
        |> assign(:document_error, nil)
        |> mark_doc_clean(document_id)

      {:reply,
       %{
         ok: true,
         format: response.format,
         snapshot: response.snapshot
       }, socket}
    else
      {:error, reason} ->
        error = error_message(reason)

        {:reply, %{error: error}, assign(socket, :document_error, error)}
    end
  end

  defp replay_viewer_save?(params) when is_map(params) do
    journal = params["journal"] || params["replay_journal"]
    replay_only? = params["replay_only"] == true || params["replay_only"] == "true"

    no_bytes? =
      not Enum.any?(
        ["bytes_token", "bytes_path", "bytes_base64", "bytes"],
        &Map.has_key?(params, &1)
      )

    is_list(journal) and journal != [] and
      (replay_only? or no_bytes? or is_binary(params["error"]))
  end

  defp verify_active_document(socket, document_id) when is_binary(document_id) do
    if document_id == active_document_id(socket), do: :ok, else: {:error, :not_found}
  end

  defp verify_active_document(_socket, _document_id), do: {:error, :not_found}

  defp reset_document_search(socket) do
    search = DocumentSearch.new()

    socket
    |> assign(:document_search, search)
    |> assign(:document_search_form, document_search_form(search.query))
    |> update(:editor_toolbar, &EditorToolbar.reset/1)
  end

  defp put_document_search_query(socket, query) do
    search = DocumentSearch.put_query(socket.assigns.document_search, query)

    socket
    |> assign(:document_search, search)
    |> assign(:document_search_form, document_search_form(search.query))
  end

  defp document_search_form(query) do
    to_form(%{"query" => query}, as: :document_search)
  end

  defp document_search_enabled?(%{assigns: %{active_document: %{format: format}}}) do
    format not in ["md", "markdown"]
  end

  defp document_search_enabled?(_socket), do: false

  defp maybe_push_document_search_action(socket, action) do
    if socket.assigns.document_search.open? and document_search_enabled?(socket) do
      push_document_search_action(socket, action)
    else
      socket
    end
  end

  defp push_document_search_action(socket, action) do
    document = socket.assigns[:active_document] || %{}

    case DocumentSearch.command(socket.assigns.document_search, action, document[:format]) do
      {:ok, payload} -> push_event(socket, "document.search.command", payload)
      :error -> socket
    end
  end

  defp push_editor_toolbar_command(socket, command, attrs) do
    if markdown_document_active?(socket) and command in ~w(bold italic strikethrough) do
      state = MarkdownEditorState.apply_toolbar_command(socket.assigns.markdown_editor, command)

      socket
      |> assign(:markdown_editor, state)
      |> assign(:markdown_preview_html, EcritsWeb.Markdown.to_preview_html(state.source))
      |> mark_doc_dirty(active_document_id(socket))
    else
      case EditorToolbar.command(
             socket.assigns.editor_toolbar,
             command,
             attrs,
             socket.assigns[:active_document]
           ) do
        {:ok, payload} ->
          toolbar =
            EditorToolbar.remember_command(socket.assigns.editor_toolbar, command, payload)

          socket
          |> assign(:editor_toolbar, toolbar)
          |> push_event("document.toolbar.command", payload)

        :error ->
          socket
      end
    end
  end

  defp active_document_id(%{assigns: %{active_document: %{id: id}}}) when is_binary(id), do: id
  defp active_document_id(_socket), do: nil

  defp viewer_document_dirty?(socket, pool_document_id) do
    dirty_ids = socket.assigns[:dirty_document_ids] || MapSet.new()
    active_id = active_document_id(socket)

    MapSet.member?(dirty_ids, active_id) or MapSet.member?(dirty_ids, pool_document_id)
  end

  # --- Unsaved-changes (dirty) tracking + debounced auto-save ----------------
  # `:dirty_document_ids` (a MapSet) is the single source of truth for which
  # tabs render the "unsaved changes" dot. A doc becomes dirty on a user edit
  # (`rhwp.text.mutated`, office viewer input) or an agent `doc.edit`/`doc.set`
  # routed through the browser bridge, and clean on a save (Ctrl/Cmd+S,
  # auto-save, or `doc.save`).

  defp mark_doc_dirty(socket, nil), do: socket

  defp mark_doc_dirty(socket, id),
    do: update(socket, :dirty_document_ids, &MapSet.put(&1, id))

  defp mark_doc_clean(socket, nil), do: socket

  defp mark_doc_clean(socket, id) do
    socket
    |> update(:dirty_document_ids, &MapSet.delete(&1, id))
    |> cancel_autosave(id)
  end

  # (Re)arm the idle auto-save timer for `id`, cancelling any prior one so the
  # window is measured from the most recent edit.
  defp arm_autosave(socket, nil), do: socket

  defp arm_autosave(socket, id) do
    socket = cancel_autosave(socket, id)
    ref = Process.send_after(self(), {:autosave, id}, @autosave_idle_ms)
    update(socket, :autosave_timers, &Map.put(&1, id, ref))
  end

  # Cancel + drop any pending auto-save timer for `id`.
  defp cancel_autosave(socket, id) do
    update(socket, :autosave_timers, fn timers ->
      case Map.pop(timers, id) do
        {nil, rest} ->
          rest

        {ref, rest} ->
          _ = Process.cancel_timer(ref)
          rest
      end
    end)
  end

  defp maybe_clear_dirty_on_save(socket, :save, id), do: mark_doc_clean(socket, id)
  defp maybe_clear_dirty_on_save(socket, _action, _id), do: socket

  # Reflect an agent-routed browser op's result in the dirty set. Edits/sets
  # that succeeded mark the active doc dirty (and arm auto-save); a successful
  # save marks it clean. Reads and failures leave the set untouched.
  defp apply_browser_op_dirty(socket, verb, result) do
    id = active_document_id(socket)

    if match?({:ok, _}, result) do
      cond do
        verb in [:edit, :set] -> socket |> mark_doc_dirty(id) |> arm_autosave(id)
        verb == :save -> mark_doc_clean(socket, id)
        true -> socket
      end
    else
      socket
    end
  end

  defp save_active_document(socket), do: save_document(socket, active_document_id(socket))

  defp save_document(socket, nil), do: socket

  defp save_document(socket, id) do
    case socket.assigns[:active_document] do
      %{id: ^id, format: format} ->
        if viewer_save_format?(format) do
          push_event(socket, "document.save.command", %{
            document_id: id,
            request_id: "save:#{System.unique_integer([:positive])}"
          })
        else
          save_pool_document(socket, id)
        end

      _ ->
        save_pool_document(socket, id)
    end
  end

  defp save_pool_document(socket, id) do
    # Fire-and-forget in a SEPARATE process: `Ecrits.Doc.Tools.call/3` for a
    # browser-backed doc sends `{:doc_browser_request, ...}` to THIS LiveView
    # pid and blocks in `receive`, so calling it inline here would deadlock.
    # The dot clears when the resulting `doc.save` round-trips back through
    # `document.engine.operation.replied` (verb `:save`).
    Task.start(fn ->
      Ecrits.Doc.Tools.call(%{pool: DocPool}, "doc.save", %{"document" => id})
    end)

    socket
  end

  defp viewer_save_format?(format) when is_binary(format),
    do: Document.ehwp_format?(format) or Document.libreoffice_format?(format)

  defp viewer_save_format?(_format), do: false

  defp action_status(:checkpoint), do: :checkpointed
  defp action_status(:save), do: :saved

  defp apply_document_snapshot(socket, status, %Document{id: id} = document, snapshot) do
    socket =
      if id == active_document_id(socket) do
        socket
        |> assign(:active_document, document_summary(document))
        |> assign(:document_status, status)
        |> assign(:document_snapshot, snapshot)
        |> assign(:document_error, nil)
        |> render_document_pages(document)
      else
        socket
      end

    if status == :saved, do: mark_doc_clean(socket, id), else: socket
  end

  defp document_summary(%Document{} = document) do
    %{
      id: document.id,
      relative_path: document.relative_path,
      format: document.format,
      byte_size: document.byte_size,
      sha256: document.sha256
    }
  end

  defp document_summary(response) when is_map(response) do
    %{
      id: response.document_id,
      relative_path: response.relative_path,
      format: response.format,
      byte_size: response[:byte_size],
      sha256: response[:sha256]
    }
  end

  defp load_reply(response) do
    response
    |> Map.delete(:bytes)
    |> Map.put(:bytes_base64, Base.encode64(response.bytes))
  end

  defp mutation_reply(mutation) when is_map(mutation) do
    %{
      event_id: mutation["event_id"],
      lamport: mutation["lamport"]
    }
  end

  defp document_spec(%{format: "hwp"} = document) do
    %{
      key: "hwp",
      name: Path.basename(document.relative_path),
      template_hwp_path: document.relative_path
    }
  end

  defp document_spec(document) do
    %{
      key: "hwpx",
      name: Path.basename(document.relative_path),
      template_hwpx_path: document.relative_path
    }
  end

  defp rhwp_dom_id(%{id: id}), do: "rhwp-editor-#{dom_token(id)}"

  defp render_document_pages(socket, %Document{format: format} = document) do
    cond do
      Document.ehwp_format?(format) -> render_hwp_pages(socket, document)
      Document.markdown_format?(format) -> render_markdown(socket, document)
      true -> render_office_wasm(socket, document)
    end
  end

  # Markdown (.md/.markdown) is plain text — no engine, no stream, no LOK/WASM.
  # We load the canonical workspace bytes as UTF-8 source into the editable
  # textarea and render a live MDEx preview alongside it. Re-entrant on save
  # (the `:document_saved` broadcast re-renders), so we only reseed the
  # source when it actually differs from what's already in the editor — the
  # textarea is phx-update="ignore" anyway, so this just keeps the assign honest
  # and the preview in sync without clobbering the user's in-flight edits.
  defp render_markdown(socket, %Document{} = document) do
    socket =
      socket
      |> unsubscribe_hwp_stream()
      |> clear_hwp_pages()
      |> assign(:hwp_stream_renderer, :markdown)
      |> assign(:hwp_stream_document_id, document.id)
      |> assign(:hwp_stream_loading?, false)

    source =
      case Document.read(document.id) do
        {:ok, bytes} when is_binary(bytes) -> bytes
        _ -> ""
      end

    state = MarkdownEditorState.load(socket.assigns.markdown_editor, document.id, source)

    socket
    |> assign(:markdown_editor, state)
    |> assign(:markdown_preview_html, EcritsWeb.Markdown.to_preview_html(state.source))
  end

  # HWP/HWPX now render entirely in the browser via rhwp_core WASM. The server
  # no longer rasterizes pages (the `ehwp` NIF is gone); it just tells the
  # `WasmHwpEditor` hook where to fetch the document's raw bytes, and the hook
  # does `new HwpDocument(bytes)` + renderPageToCanvas + hitTest locally.
  defp render_hwp_pages(socket, %Document{} = document) do
    socket =
      socket
      |> unsubscribe_hwp_stream()
      |> clear_hwp_pages()
      |> assign(:hwp_stream_renderer, :rhwp_wasm)
      |> assign(:hwp_stream_document_id, document.id)
      |> assign(:hwp_stream_loading?, false)

    if connected?(socket) do
      url =
        document_bytes_url(socket.assigns.workspace_path, document.relative_path)

      push_event(socket, "document.hwp.load_command", %{
        url: url,
        document_id: document.id
      })
    else
      socket
    end
  end

  # Read-only raw-bytes URL the WasmHwpEditor hook fetches to feed rhwp_core.
  defp document_bytes_url(workspace_path, relative_path)
       when is_binary(workspace_path) and is_binary(relative_path) do
    "/document-bytes?" <>
      URI.encode_query(%{"path" => workspace_path, "document" => relative_path})
  end

  defp document_bytes_url(_workspace_path, _relative_path), do: nil

  defp document_bytes_url(workspace_path, relative_path, nil),
    do: document_bytes_url(workspace_path, relative_path)

  defp document_bytes_url(workspace_path, relative_path, version) do
    case document_bytes_url(workspace_path, relative_path) do
      base when is_binary(base) -> base <> "&v=" <> URI.encode_www_form(to_string(version))
      _ -> nil
    end
  end

  defp preview_snapshot_bytes_url(workspace_path, relative_path, document, snapshot) do
    with snapshot when is_map(snapshot) <- preview_snapshot_for_document(snapshot, document),
         snapshot_id when is_binary(snapshot_id) <- item_field(snapshot, :id),
         base when is_binary(base) <- document_bytes_url(workspace_path, relative_path) do
      base <> "&snapshot=" <> URI.encode_www_form(snapshot_id)
    else
      _ -> nil
    end
  end

  # Office (docx/pptx/xlsx) rendering. Office documents render SOLELY through the
  # in-browser LibreOffice WASM editor (the `WasmOfficeEditor` hook): the server
  # only tells the hook where to fetch the raw bytes — all open/render happens
  # client-side. Mirrors the HWP `:rhwp_wasm` branch; no server stream/session.
  defp render_office_wasm(socket, %Document{} = document) do
    socket =
      socket
      |> unsubscribe_hwp_stream()
      |> clear_hwp_pages()
      |> assign(:hwp_stream_renderer, :office_wasm)
      |> assign(:hwp_stream_document_id, document.id)
      |> assign(:hwp_stream_loading?, false)

    if connected?(socket) do
      url = document_bytes_url(socket.assigns.workspace_path, document.relative_path)

      push_event(socket, "document.office.load_command", %{
        url: url,
        document_id: document.id
      })
    else
      socket
    end
  end

  defp maybe_render_active_hwp_pages(socket, document_id) do
    case Document.document(document_id) do
      {:ok, %Document{} = document} -> render_document_pages(socket, document)
      {:error, _reason} -> socket
    end
  end

  defp clear_hwp_pages(socket) do
    socket
    |> assign(:hwp_page_count, 0)
    |> assign(:hwp_stream_renderer, nil)
    |> assign(:hwp_stream_document_id, nil)
    |> assign(:hwp_stream_loading?, false)
    |> stream(:hwp_pages, [], reset: true)
  end

  # HWP/HWPX render entirely in the browser via rhwp_core WASM and office
  # documents via the LibreOffice WASM hook, so there is no server-side stream to
  # tear down. Kept as a no-op so callers (and `terminate/2`) stay uniform.
  defp unsubscribe_hwp_stream(socket), do: socket

  defp markdown_document_active?(%{assigns: %{active_document: %{format: format}}})
       when is_binary(format),
       do: Document.markdown_format?(format)

  defp markdown_document_active?(_socket), do: false

  defp rhwp_request_value(request, keys) when is_map(request) do
    Enum.find_value(keys, &Map.get(request, &1))
  end

  defp rhwp_request_value(_request, _keys), do: nil

  defp maybe_put_base_snapshot(payload, %{} = base_snapshot),
    do: Map.put(payload, :base_snapshot, base_snapshot)

  defp maybe_put_base_snapshot(payload, _base_snapshot), do: payload

  defp register_rhwp_materializer_editor(document_id) when is_binary(document_id) do
    Ecrits.RhwpSnapshot.Materializer.register_editor(document_id)
  end

  defp register_rhwp_materializer_editor(_document_id), do: :ok

  defp unregister_rhwp_materializer_editor(document_id) when is_binary(document_id) do
    Ecrits.RhwpSnapshot.Materializer.unregister_editor(document_id)
  end

  defp unregister_rhwp_materializer_editor(_document_id), do: :ok

  defp update_rhwp_materializer_editor(previous_document_id, next_document_id)
       when previous_document_id == next_document_id,
       do: :ok

  defp update_rhwp_materializer_editor(previous_document_id, next_document_id) do
    _ = unregister_rhwp_materializer_editor(previous_document_id)
    register_rhwp_materializer_editor(next_document_id)
  end

  defp ack_rhwp_snapshot_committed(request_id, document_id, response)
       when is_binary(request_id) and request_id != "" do
    Ecrits.RhwpSnapshot.Materializer.ack(request_id, %{
      status: :committed,
      request_id: request_id,
      document_id: document_id,
      snapshot: %{
        path: response.snapshot["path"],
        format: response.format
      }
    })
  end

  defp ack_rhwp_snapshot_committed(_request_id, _document_id, _response), do: :ok

  defp ack_rhwp_snapshot_failed(request_id, document_id, reason)
       when is_binary(request_id) and request_id != "" do
    Ecrits.RhwpSnapshot.Materializer.ack(request_id, %{
      status: :failed,
      request_id: request_id,
      document_id: document_id,
      reason: inspect(reason)
    })
  end

  defp ack_rhwp_snapshot_failed(_request_id, _document_id, _reason), do: :ok

  defp dom_token(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "root"
      token -> token
    end
  end

  defp save_state(document, snapshot, status) do
    size = document.byte_size || 0

    case {status, snapshot} do
      {:saved, %{} = _snapshot} ->
        "Saved - #{format_byte_size(size)} - #{document.format}"

      {:checkpointed, %{} = _snapshot} ->
        "Checkpointed - canonical file unchanged - #{document.format}"

      _ ->
        "Loaded - #{format_byte_size(size)} - #{document.format}"
    end
  end

  defp format_byte_size(size) when is_integer(size) and size >= 1_048_576 do
    "#{Float.round(size / 1_048_576, 1)} MB"
  end

  defp format_byte_size(size) when is_integer(size) and size >= 1024 do
    "#{Float.round(size / 1024, 1)} KB"
  end

  defp format_byte_size(size) when is_integer(size), do: "#{size} B"
  defp format_byte_size(_size), do: "0 B"

  defp agent_options_form do
    to_form(%{}, as: :agent_options)
  end

  defp agent_provider_param(params) do
    params["provider"] ||
      params["value"] ||
      get_in(params, ["agent_model", "provider"])
  end

  defp agent_option_param(params) do
    option = params["option"]
    value = params["value"] || params[option]

    cond do
      is_binary(option) and is_binary(value) ->
        {option, value}

      is_binary(params["reasoning"]) ->
        {"reasoning", params["reasoning"]}

      is_binary(params["access"]) ->
        {"access", params["access"]}

      true ->
        nil
    end
  end

  # No "did it change?" guard: assign the new value, then persist the WHOLE
  # canonical session-owned bundle (session_owned_agent_opts/1). Re-persisting
  # the unchanged fields is idempotent — the session merges identical opts — so
  # the old `if value == current, do: noop` branches are dead weight.
  defp select_agent_reasoning(value, socket) do
    effort =
      AgentConfig.reasoning_effort(
        value,
        agent_reasoning_efforts(socket.assigns.agent.provider.key)
      )

    socket
    |> put_agent(reasoning_effort: effort)
    |> persist_agent_options()
    |> noreply()
  end

  defp select_agent_access(value, socket) do
    socket
    |> put_agent_access(AgentConfig.access_control(value))
    |> apply_vfs_write_policy()
    |> persist_agent_options()
    |> noreply()
  end

  # Persist the canonical bundle to the durable session; returns the socket so it
  # threads in a pipe. No-op (returns socket) when no session is bound yet.
  defp persist_agent_options(%{assigns: %{workspace_session: %{} = ws}} = socket) do
    _ =
      WorkspaceSession.update_options(
        ws,
        AgentConfig.session_opts(socket.assigns.agent)
      )

    socket
  end

  defp persist_agent_options(socket), do: socket

  defp noreply(socket), do: {:noreply, socket}

  defp agent_provider_display(provider \\ default_provider_id()) do
    provider_id =
      AgentConfig.allowed_provider(provider, allowed_provider_ids()) ||
        default_provider_id()

    metadata = provider_metadata(provider_id) || provider_metadata("codex")

    %{
      key: metadata.id,
      label: metadata.label,
      favicon_src: metadata.favicon_src
    }
  end

  defp agent_model(model_id) when is_binary(model_id) do
    AgentModels.get(model_id)
  end

  defp agent_model(_model_id), do: nil

  defp agent_models_for_provider(provider_id) do
    AgentModels.for_provider(provider_id)
  end

  defp default_agent_model_id("claude"), do: "default"
  defp default_agent_model_id(_provider), do: "gpt-5.5"

  defp agent_config(key) do
    agent_ui = Application.get_env(:ecrits, :agent_ui, [])
    agent = Application.get_env(:ecrits, :agent, [])

    Keyword.get(agent_ui, key) || Keyword.get(agent, key)
  end

  defp default_provider_id do
    configured =
      agent_config(:provider) ||
        agent_adapter_provider(agent_config(:adapter))

    AgentConfig.allowed_provider(configured, allowed_provider_ids()) || "codex"
  end

  defp agent_adapter_provider(nil), do: nil
  defp agent_adapter_provider(adapter), do: AgentConfig.provider(adapter)

  defp provider_metadata(provider_id) do
    Enum.find(ACP.provider_metadata(), &(&1.id == provider_id))
  end

  defp allowed_provider_ids do
    selectable_provider_ids()
  end

  defp selectable_provider_ids do
    ACP.provider_metadata()
    |> Enum.map(& &1.id)
    |> Enum.filter(&(&1 in @selectable_agent_provider_ids))
  end

  defp agent_providers do
    ACP.provider_metadata()
    |> Enum.filter(&(&1.id in @selectable_agent_provider_ids))
    |> Enum.map(fn provider ->
      %{
        id: provider.id,
        label: provider.label,
        favicon_src: provider.favicon_src
      }
    end)
  end

  defp agent_provider_details(integrations) do
    integrations_by_id = Map.new(integrations, &{&1.id, &1})

    agent_providers()
    |> Enum.map(fn provider ->
      integration = Map.get(integrations_by_id, provider.id, %{})
      status = Map.get(integration, :status, :unavailable)

      provider
      |> Map.put(:runtime, provider_runtime_label(provider.id))
      |> Map.put(:status, status)
      |> Map.put(:status_label, provider_integration_status_label(status))
      |> Map.put(:detail, Map.get(integration, :detail, ""))
    end)
  end

  defp provider_setup_required?(%{status: :ready}), do: false
  defp provider_setup_required?(_provider), do: true

  defp agent_provider_setup_href(_assigns, provider_id) do
    ~p"/local/agent-providers/#{provider_id}/setup?#{[return_to: ~p"/workspace"]}"
  end

  defp agent_selected_model_label(model_id) do
    case AgentModels.get(model_id) do
      %{label: label} -> label
      _missing -> "Model"
    end
  end

  defp default_reasoning_effort do
    AgentConfig.reasoning_effort(
      :ecrits
      |> Application.get_env(:agent, [])
      |> Keyword.get(:reasoning_effort, "medium"),
      agent_reasoning_efforts("codex")
    )
  end

  # Claude's `--effort` tiers are low|medium|high|xhigh|max (per `claude --help`).
  # We surface `max` as the top "Ultracode" tier in the rail — Claude Code's most
  # exhaustive reasoning mode — and additionally fire the `ultrathink` workflow
  # keyword for it (see acp_stream). Internally the tier id is "ultracode".
  defp agent_reasoning_efforts("claude"), do: ~w(low medium high xhigh ultracode)
  defp agent_reasoning_efforts(_provider), do: ~w(minimal low medium high xhigh)

  defp agent_reasoning_label("minimal"), do: "Minimal - fastest, least tokens"
  defp agent_reasoning_label("low"), do: "Low - light reasoning, lower tokens"
  defp agent_reasoning_label("medium"), do: "Medium - balanced reasoning/tokens"
  defp agent_reasoning_label("high"), do: "High - deeper reasoning, more tokens"
  defp agent_reasoning_label("xhigh"), do: "XHigh - maximum reasoning/tokens"

  defp agent_reasoning_label("ultracode"),
    do: "Ultracode - exhaustive reasoning"

  defp agent_reasoning_label(reasoning), do: reasoning

  defp agent_reasoning_short_label("minimal"), do: "Minimal"
  defp agent_reasoning_short_label("low"), do: "Low"
  defp agent_reasoning_short_label("medium"), do: "Medium"
  defp agent_reasoning_short_label("high"), do: "High"
  defp agent_reasoning_short_label("xhigh"), do: "XHigh"
  defp agent_reasoning_short_label("ultracode"), do: "Ultracode"
  defp agent_reasoning_short_label(reasoning), do: reasoning

  defp agent_reasoning_title("minimal"),
    do: "Fastest responses with the smallest token budget."

  defp agent_reasoning_title("low"),
    do: "Lower-cost reasoning for routine edits and lookups."

  defp agent_reasoning_title("medium"), do: "Balanced reasoning depth and token usage."
  defp agent_reasoning_title("high"), do: "More planning tokens for harder document work."
  defp agent_reasoning_title("xhigh"), do: "Maximum reasoning budget for complex tasks."

  defp agent_reasoning_title("ultracode"),
    do: "Claude's most exhaustive mode: top effort tier plus the ultrathink keyword."

  defp agent_reasoning_title(reasoning), do: reasoning

  defp agent_integrations, do: ACP.integration_options()

  defp provider_integration_status_label(:ready), do: "ready"
  defp provider_integration_status_label(:login_required), do: "login"
  defp provider_integration_status_label(:missing), do: "install"
  defp provider_integration_status_label(_status), do: "setup"

  # Merge fields into the bound `%AgentConfig{}` (the `:agent` assign) —
  # the ONE seam every provider/model/reasoning/access update flows through.
  defp put_agent(socket, fields) do
    assign(
      socket,
      :agent,
      AgentConfig.put(socket.assigns.agent, Map.new(fields))
    )
  end

  # Resolve an access-mode id to its full record and store it as `access`, so the
  # five access-derived values read off `@agent.access.*`.
  defp put_agent_access(socket, access_control) do
    put_agent(socket, access: AgentAccess.resolve(access_control))
  end

  defp agent_access_controls, do: AgentAccess.all()

  defp default_access_control do
    agent = Application.get_env(:ecrits, :agent, [])
    agent_ui = Application.get_env(:ecrits, :agent_ui, [])
    config = Keyword.merge(agent, agent_ui)
    adapter_opts = Keyword.get(config, :adapter_opts, [])

    AgentConfig.access_control(
      Keyword.get(config, :access_control) ||
        Keyword.get(config, :access) ||
        Keyword.get(adapter_opts, :access_control) ||
        Keyword.get(adapter_opts, :access) ||
        access_control_from_provider_opts(config, adapter_opts)
    )
  end

  defp access_control_from_provider_opts(config, adapter_opts) do
    approval_policy =
      Keyword.get(config, :approval_policy) || Keyword.get(adapter_opts, :approval_policy)

    sandbox = Keyword.get(config, :sandbox) || Keyword.get(adapter_opts, :sandbox)

    cond do
      sandbox in ["read-only", :read_only] ->
        "read-only"

      approval_policy in [:on_write, "on_write", :always, "always"] ->
        "ask"

      sandbox in ["workspace-write", :workspace_write] ->
        "full-workspace"

      true ->
        "read-only"
    end
  end

  defp provider_runtime_label("codex"), do: "CLI/app-server"
  defp provider_runtime_label("claude"), do: "CLI"
  defp provider_runtime_label(_provider), do: "ACP"

  # Stream dom_id resolver — PUBLIC so it can be captured as `&__MODULE__.../1` in
  # stream_configure (see mount/3). A named capture survives dev hot-reloads,
  # unlike an anonymous closure compiled into this module.
  @doc false
  def hwp_page_dom_id(%{id: id}), do: id

  # ── inline chat: send / queue ──────────────────────────────────────

  # The workspace Session handle (delegates send/cancel/rename to the foreground
  # agent), or nil before the agent is bound.
  defp ws(%{assigns: %{workspace_session: %{} = ws}}), do: ws
  defp ws(_socket), do: nil

  defp submit_agent_message(socket, message) do
    picks = DocumentElementPicker.compact_picks(socket.assigns.document_element_picker, [])
    handle_send(socket, message, picks)
  end

  defp clear_document_element_picks(socket) do
    update(socket, :document_element_picker, &DocumentElementPicker.clear/1)
  end

  defp handle_send(socket, message, picks) do
    message = String.trim(message || "")

    cond do
      # Re-Enter gesture (Phase 5 FIFO queue): an empty Enter while a message is
      # queued FLUSHES the head — cancel the in-flight turn and run the next
      # queued message NOW instead of waiting for the running turn to finish.
      # A picks-only send is NOT this gesture: the chips are the message.
      message == "" and picks == [] and socket.assigns.agent_pending > 0 ->
        socket
        |> clear_document_element_picks()
        |> flush_agent_queue()

      message == "" and picks == [] ->
        {:noreply,
         socket
         |> clear_document_element_picks()
         |> assign(:agent_form, agent_form())}

      is_nil(socket.assigns.agent_session_id) ->
        {:noreply,
         socket
         |> clear_document_element_picks()
         |> assign(:agent_error, "Agent session is not ready.")}

      # A turn is in flight (or a message is already queued): ENQUEUE this send
      # behind the running turn rather than cancelling it (Phase 5). It drains in
      # order when the running turn finishes.
      socket.assigns.agent_status == :running or socket.assigns.agent_pending > 0 ->
        enqueue_agent_turn(socket, message, picks)

      true ->
        send_agent_turn(socket, message, picks)
    end
  end

  defp compose_picks_message(message, picks),
    do: Prompt.with_selected_elements(message, picks, DocMount.backend())

  # Enqueue a mid-turn send: record the user bubble immediately (so the user sees
  # their message), bump the pending count, and let the durable agent drain it
  # when the running turn terminates. The placeholders (reasoning / assistant
  # bubble) are rendered later, when the queued turn actually drains (its
  # `turn_started` event arrives with `agent_turn_id` nil).
  defp enqueue_agent_turn(socket, message, picks) do
    case WorkspaceSession.send_turn(
           ws(socket),
           compose_picks_message(message, picks),
           current_turn_opts(socket) ++ [display: message, picks: picks]
         ) do
      # The turn is QUEUED, not running yet — do NOT render the user bubble here.
      # It renders only when the queue drains to this turn (the :turn_started
      # context switch), so the transcript shows what the agent is ACTUALLY
      # processing, not what is merely waiting in line.
      {:ok, %{id: queued_id}} ->
        {:noreply,
         socket
         |> update_agent_queue(queue_display_item(queued_id, message, picks))
         |> sync_agent_pending()
         |> assign(:agent_error, nil)
         |> clear_document_element_picks()
         |> assign(:agent_form, agent_form())}

      {:error, :foreground_transition_in_progress} ->
        {:noreply, assign(socket, :agent_form, agent_form(%{"message" => message}))}

      {:error, reason} ->
        {:noreply,
         socket
         |> clear_document_element_picks()
         |> assign(:agent_error, agent_error(reason))}
    end
  end

  defp flush_agent_queue(socket) do
    case WorkspaceSession.flush_queue(ws(socket)) do
      {:ok, _turn} ->
        {:noreply, assign(socket, :agent_form, agent_form())}

      {:error, :empty_queue} ->
        {:noreply,
         socket
         |> assign(:agent_pending, 0)
         |> assign(:agent_queue, [])
         |> assign(:agent_queue_index, 0)}

      {:error, :foreground_transition_in_progress} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :agent_error, agent_error(reason))}
    end
  end

  defp queued_items_from_snapshot(items) when is_list(items) do
    items
    |> Enum.map(&queue_display_item_from_map/1)
    |> Enum.reject(&is_nil/1)
  end

  defp queued_items_from_snapshot(_items), do: []

  defp queue_display_item_from_map(item) when is_map(item) do
    turn_id = item_field(item, :turn_id)
    body = item_field(item, :input) || item_field(item, :body) || ""
    picks = DocumentElementPicker.compact_picks(item_field(item, :picks))

    if is_binary(turn_id) and turn_id != "" do
      queue_display_item(turn_id, body, picks)
    end
  end

  defp queue_display_item_from_map(_item), do: nil

  defp queue_display_item(turn_id, body, picks) do
    %{
      turn_id: turn_id,
      body: if(is_binary(body), do: body, else: ""),
      picks: DocumentElementPicker.compact_picks(picks)
    }
  end

  defp maybe_update_agent_queue_from_event(socket, %{turn_id: turn_id} = event)
       when is_binary(turn_id) do
    update_agent_queue(
      socket,
      queue_display_item(turn_id, Map.get(event, :input, ""), Map.get(event, :picks, []))
    )
  end

  defp maybe_update_agent_queue_from_event(socket, _event), do: socket

  defp update_agent_queue(socket, %{turn_id: turn_id} = item) do
    queue = socket.assigns.agent_queue || []

    queue =
      if Enum.any?(queue, &(&1.turn_id == turn_id)) do
        Enum.map(queue, fn
          %{turn_id: ^turn_id} -> item
          other -> other
        end)
      else
        queue ++ [item]
      end

    socket
    |> assign(:agent_queue, queue)
    |> clamp_agent_queue_index()
  end

  defp remove_agent_queue_item(socket, turn_id) when is_binary(turn_id) do
    queue =
      socket.assigns.agent_queue
      |> List.wrap()
      |> Enum.reject(&(&1.turn_id == turn_id))

    socket
    |> assign(:agent_queue, queue)
    |> clamp_agent_queue_index()
  end

  defp clamp_agent_queue_index(socket) do
    max_index = max(length(socket.assigns.agent_queue) - 1, 0)
    index = socket.assigns.agent_queue_index || 0
    assign(socket, :agent_queue_index, min(index, max_index))
  end

  defp sync_agent_pending(socket, min_pending \\ 0) do
    assign(
      socket,
      :agent_pending,
      max(min_pending, length(socket.assigns.agent_queue || []))
    )
  end

  defp agent_queued_item(queue, index) when is_list(queue) do
    Enum.at(queue, index || 0) || List.first(queue)
  end

  defp agent_queued_item(_queue, _index), do: nil

  # The composer's CURRENT options ride on every send: the turn runs with
  # exactly what the UI shows at send time, instead of trusting that an earlier
  # access/model toggle's update_options round-trip already landed on the agent
  # (the access-switch desync: a write turn sent right after flipping to Full
  # workspace was still auto-rejected under the old approval policy).
  defp current_turn_opts(socket) do
    workspace_path = workspace_root_path(socket.assigns.workspace || %{})

    [
      adapter_opts: agent_adapter_opts(socket, workspace_path),
      document_path: socket.assigns[:active_document_path],
      pool_document_id: socket.assigns[:pool_document_id]
    ]
  end

  defp send_agent_turn(socket, message, picks) do
    case WorkspaceSession.send_turn(
           ws(socket),
           compose_picks_message(message, picks),
           current_turn_opts(socket) ++ [display: message, picks: picks]
         ) do
      {:ok, %{id: turn_id}} ->
        {:noreply,
         socket
         |> cancel_agent_reasoning_flush()
         |> stream_insert(:agent_items, agent_user_item(turn_id, message, picks))
         |> stream_insert(:agent_items, agent_reasoning_item(turn_id, "", :pending, 0))
         |> stream_insert(:agent_items, agent_assistant_item(turn_id, "", :running, 0))
         |> assign(:agent_turn_id, turn_id)
         |> assign(:agent_text, "")
         |> assign(:agent_text_segment, 0)
         |> assign(:agent_reasoning_text, "")
         |> assign(:agent_reasoning_segment, 0)
         |> assign(:agent_status, :running)
         |> assign(:agent_error, nil)
         |> clear_document_element_picks()
         |> assign(:agent_form, agent_form())}

      {:error, :foreground_transition_in_progress} ->
        {:noreply, assign(socket, :agent_form, agent_form(%{"message" => message}))}

      {:error, reason} ->
        {:noreply,
         socket
         |> clear_document_element_picks()
         |> assign(:agent_error, agent_error(reason))}
    end
  end

  # Start a fresh foreground rail while preserving the older rail in the recent
  # drawer. The current browser tab owns the active rail; older rails stay in the
  # browser session's recent list.
  defp restart_agent_session(socket) do
    _ = maybe_cancel_active_agent(socket)

    case safe_new_foreground(
           socket.assigns.workspace_path,
           agent_attach_settings(socket)
         ) do
      {:ok, %{agent_id: agent_id} = ws} when is_binary(agent_id) ->
        socket
        |> bind_agent_subscription(agent_id)
        |> bind_fresh_agent_session(ws, agent_id)

      {:pending, _ws} ->
        socket

      {:error, :foreground_transition_in_progress} ->
        socket

      {:error, reason} ->
        assign(socket, :agent_error, agent_error(reason))
    end
  end

  defp maybe_cancel_active_agent(%{
         assigns: %{workspace_session: %{} = ws, agent_turn_id: turn_id}
       })
       when is_binary(turn_id) do
    _ = WorkspaceSession.cancel(ws, turn_id)
    :ok
  end

  defp maybe_cancel_active_agent(_socket), do: :ok

  # A LiveView process may only hold one foreground-agent subscription. PubSub
  # does not deduplicate repeated subscribe calls, so selecting the same recent
  # rail again used to deliver every streaming delta multiple times. Switching
  # rails also releases the old topic instead of accumulating dormant topics for
  # the lifetime of the workspace LiveView.
  defp bind_agent_subscription(socket, agent_id) when is_binary(agent_id) do
    previous_agent_id = socket.assigns.agent_session_id

    cond do
      previous_agent_id == agent_id ->
        socket

      is_binary(previous_agent_id) ->
        :ok = Phoenix.PubSub.unsubscribe(Ecrits.PubSub, ACP.topic(previous_agent_id))
        :ok = WorkspaceSession.subscribe_agent(agent_id)
        socket

      true ->
        :ok = WorkspaceSession.subscribe_agent(agent_id)
        socket
    end
  end

  # ── inline chat: streaming event application ───────────────────────

  # A mid-turn send was enqueued behind the running turn (Phase 5). The agent is
  # the source of truth for the pending count; sync it from the event so a flush /
  # drain elsewhere never drifts the indicator.
  defp apply_agent_event(socket, %{type: :turn_queued, pending: pending} = event)
       when is_integer(pending) do
    socket
    |> maybe_update_agent_queue_from_event(event)
    |> sync_agent_pending(pending)
  end

  # `send_agent_turn/2` already set `agent_turn_id` (and :running)
  # from the synchronous send_turn reply, which carries the SAME id this event
  # echoes. So a turn_started whose id != the current turn is stale and must be
  # ignored; the catch-all clause drops the rest.
  defp apply_agent_event(
         %{assigns: %{agent_turn_id: turn_id}} = socket,
         %{type: :turn_started, turn_id: turn_id}
       ) do
    socket
    |> cancel_agent_reasoning_flush()
    |> assign(:agent_turn_id, turn_id)
    |> assign(:agent_status, :running)
    |> assign(:agent_editor_preview, nil)
  end

  # A QUEUED turn just drained (Phase 5): `agent_turn_id` was nil (the prior
  # turn cleared it) and this is a fresh id — i.e. the chat context just SWITCHED
  # to this message. Render the user bubble NOW (it is intentionally NOT rendered
  # at enqueue time, so a queued message only appears once the agent is actually
  # on it), then the reasoning + assistant placeholders, reset the per-turn
  # buffers, and decrement pending. The bubble's `input`/`picks` ride on the event.
  defp apply_agent_event(
         %{assigns: %{agent_turn_id: nil}} = socket,
         %{type: :turn_started, turn_id: turn_id} = event
       )
       when is_binary(turn_id) do
    socket
    |> assign(:agent_turn_id, turn_id)
    |> assign(:agent_status, :running)
    |> assign(:agent_text, "")
    |> assign(:agent_text_segment, 0)
    |> assign(:agent_editor_preview, nil)
    |> assign(:agent_reasoning_text, "")
    |> assign(:agent_reasoning_segment, 0)
    |> cancel_agent_reasoning_flush()
    |> remove_agent_queue_item(turn_id)
    |> sync_agent_pending()
    |> stream_insert(
      :agent_items,
      agent_user_item(turn_id, Map.get(event, :input, ""), Map.get(event, :picks, []))
    )
    |> stream_insert(:agent_items, agent_reasoning_item(turn_id, "", :pending, 0))
    |> stream_insert(:agent_items, agent_assistant_item(turn_id, "", :running, 0))
  end

  defp apply_agent_event(socket, %{type: type, title: title})
       when type in [:title_generated, :title_updated, :thread_title] and is_binary(title) do
    if socket.assigns.agent_title_user_edited? do
      socket
    else
      persist_generated_agent_title(socket, title)

      socket
      |> assign_agent_title(title)
      |> refresh_agent_rails()
    end
  end

  defp apply_agent_event(
         %{assigns: %{agent_turn_id: turn_id}} = socket,
         %{type: :text_delta, turn_id: turn_id, delta: delta}
       )
       when is_binary(delta) do
    socket = close_agent_reasoning_segment(socket)
    text = socket.assigns.agent_text <> delta
    segment = socket.assigns.agent_text_segment

    socket
    |> ensure_agent_text_placeholder()
    |> assign(:agent_text, text)
    |> push_event("agent.stream.text_appended", %{
      message_id: agent_assistant_dom_id(turn_id, segment),
      piece: String.replace(delta, ~r/\n{2,}/, "\n")
    })
    |> schedule_agent_text_flush()
  end

  defp apply_agent_event(
         %{assigns: %{agent_turn_id: turn_id}} = socket,
         %{type: :edit_delta, turn_id: turn_id, delta: delta} = event
       )
       when is_binary(delta) do
    socket
    |> split_agent_text_before_preview()
    |> close_agent_reasoning_segment()
    |> ensure_inline_editor_preview(turn_id, Map.get(event, :path))
    |> inline_editor_preview_accumulate_delta(
      turn_id,
      delta,
      Map.get(event, :path),
      Map.get(event, :edit_id)
    )
  end

  defp apply_agent_event(
         %{assigns: %{agent_turn_id: turn_id}} = socket,
         %{type: :reasoning_delta, turn_id: turn_id, delta: delta} = event
       )
       when is_binary(delta) do
    segment = Map.get(event, :segment, socket.assigns.agent_reasoning_segment)

    socket =
      socket
      |> close_agent_text_segment()
      |> prepare_agent_reasoning_segment(turn_id, segment)

    prev = socket.assigns.agent_reasoning_text

    socket
    |> assign(:agent_reasoning_text, prev <> delta)
    |> assign(:agent_reasoning_open?, true)
    |> push_event("agent.stream.reasoning_appended", %{
      message_id: agent_reasoning_dom_id(turn_id, segment),
      piece: delta
    })
    |> schedule_agent_reasoning_flush()
  end

  defp apply_agent_event(socket, %{type: type} = event)
       when type in [
              :file_operation_started,
              :file_operation_completed,
              :file_operation_failed
            ] do
    apply_file_operation_event(socket, event, file_operation_event_status(type))
  end

  # Older ACP snapshots and adapters reported editor file I/O using the generic
  # tool-call envelope. Keep those rows visible while classifying them with the
  # same file-activity semantics as the current dedicated events.
  defp apply_agent_event(
         socket,
         %{type: :tool_call_started, tool_call_id: id, name: name} = event
       )
       when name in @acp_file_operation_names do
    event
    |> Map.put(:file_operation_id, id)
    |> Map.put(:operation, name)
    |> then(&apply_file_operation_event(socket, &1, :running))
  end

  defp apply_agent_event(
         socket,
         %{type: :tool_call_completed, tool_call_id: id, name: name} = event
       )
       when name in @acp_file_operation_names do
    event
    |> Map.put(:file_operation_id, id)
    |> Map.put(:operation, name)
    |> then(&apply_file_operation_event(socket, &1, :completed))
  end

  defp apply_agent_event(
         socket,
         %{type: :tool_call_failed, tool_call_id: id, name: name} = event
       )
       when name in @acp_file_operation_names do
    event
    |> Map.put(:file_operation_id, id)
    |> Map.put(:operation, name)
    |> then(&apply_file_operation_event(socket, &1, :failed))
  end

  defp apply_agent_event(
         socket,
         %{
           type: :tool_call_started,
           tool_call_id: tool_call_id,
           name: name,
           arguments: arguments
         } = event
       ) do
    input = agent_tool_payload(name, arguments)
    kind = Map.get(event, :kind)

    socket
    |> close_agent_text_segment()
    |> close_agent_reasoning_segment()
    |> maybe_remove_empty_agent_placeholder()
    |> update(
      :agent_active_tools,
      &Map.put(&1 || %{}, tool_call_id, %{
        name: name,
        kind: kind,
        input: input,
        args: arguments
      })
    )
    |> stream_insert(
      :agent_items,
      agent_tool_item(tool_call_id, name, :running, tool_io_body(input, nil), kind)
    )
  end

  defp apply_agent_event(
         socket,
         %{
           type: :tool_call_completed,
           tool_call_id: tool_call_id,
           name: name,
           result: result
         } = event
       ) do
    active = Map.get(socket.assigns.agent_active_tools || %{}, tool_call_id, %{})
    input = active[:input]
    kind = active[:kind] || Map.get(event, :kind)
    output = agent_tool_payload(name, result)
    # Close the text segment / drop the empty placeholder here too: a provider
    # that only reports terminal tool updates (no started event) must not leave
    # the turn-start placeholder parked ABOVE this row soaking up the reply.
    socket =
      socket
      |> close_agent_text_segment()
      |> close_agent_reasoning_segment()
      |> maybe_remove_empty_agent_placeholder()
      |> update(:agent_active_tools, &Map.delete(&1 || %{}, tool_call_id))
      |> stream_insert(
        :agent_items,
        agent_tool_item(tool_call_id, name, :completed, tool_io_body(input, output), kind)
      )

    # A native picture fallback that follows a committed VFS edit belongs to
    # that same immutable descriptor. Persist the semantic picture delta onto
    # the exact turn/document snapshot before repainting it; a standalone
    # doc.edit keeps the older bounded live-preview fallback.
    case maybe_compose_doc_edit_preview(
           socket,
           Map.get(event, :turn_id),
           tool_call_id,
           name,
           active[:args],
           result
         ) do
      {:ok, preview} ->
        socket
        |> replace_live_vfs_editor_preview(preview)
        |> stream_insert(:agent_items, preview)

      :not_applicable ->
        case maybe_doc_edit_preview_item(socket, tool_call_id, name, active[:args], result) do
          nil ->
            socket

          preview ->
            socket
            |> replace_live_vfs_editor_preview(preview)
            |> stream_insert(:agent_items, preview)
        end

      {:error, _reason} ->
        socket
    end
  end

  defp apply_agent_event(
         socket,
         %{
           type: :tool_call_failed,
           tool_call_id: tool_call_id,
           name: name,
           reason: reason
         } = event
       ) do
    active = Map.get(socket.assigns.agent_active_tools || %{}, tool_call_id, %{})
    input = active[:input]
    kind = active[:kind] || Map.get(event, :kind)

    socket
    |> close_agent_text_segment()
    |> close_agent_reasoning_segment()
    |> maybe_remove_empty_agent_placeholder()
    |> update(:agent_active_tools, &Map.delete(&1 || %{}, tool_call_id))
    |> stream_insert(
      :agent_items,
      agent_tool_item(tool_call_id, name, :failed, tool_io_body(input, reason), kind)
    )
  end

  defp apply_agent_event(
         socket,
         %{
           type: :tool_approval_required,
           tool_call_id: tool_call_id,
           name: name,
           arguments: arguments
         } = event
       ) do
    input = agent_tool_payload(name, arguments)

    stream_insert(
      socket
      |> close_agent_reasoning_segment()
      |> maybe_remove_empty_agent_placeholder(),
      :agent_items,
      agent_tool_item(
        tool_call_id,
        name,
        :approval_required,
        tool_io_body(input, nil),
        Map.get(event, :kind)
      )
    )
  end

  defp apply_agent_event(
         %{assigns: %{agent_turn_id: turn_id}} = socket,
         %{type: :turn_completed, turn_id: turn_id}
       ) do
    # Flush ONLY the still-pending text segment (text streamed AFTER the last tool
    # call). Every earlier segment was already emitted at its tool boundary by
    # close_agent_text_segment/1.
    pending = socket.assigns.agent_text
    segment = socket.assigns.agent_text_segment
    editor_preview? = editor_preview_turn?(socket.assigns[:agent_editor_preview], turn_id)

    socket
    |> cancel_agent_text_flush()
    |> close_agent_reasoning_segment()
    |> assign(:agent_turn_id, nil)
    |> assign(:agent_text, "")
    |> finalize_inline_editor_preview(turn_id, :sent)
    |> assign(:agent_status, :idle)
    |> assign(:agent_reasoning_text, "")
    |> assign(:agent_reasoning_segment, 0)
    |> maybe_remove_empty_agent_placeholder_for_editor_preview(
      turn_id,
      pending,
      segment,
      editor_preview?
    )
    |> maybe_stream_final_agent_text(turn_id, pending)
    |> finalize_dangling_tools("Turn ended before the tool finished.")
  end

  defp apply_agent_event(
         %{assigns: %{agent_turn_id: turn_id}} = socket,
         %{type: :turn_failed, turn_id: turn_id, reason: reason}
       ) do
    socket
    |> cancel_agent_text_flush()
    |> close_agent_reasoning_segment()
    |> assign(:agent_turn_id, nil)
    |> assign(:agent_text, "")
    |> finalize_inline_editor_preview(turn_id, :failed)
    |> assign(:agent_status, :failed)
    |> assign(:agent_error, agent_error(reason))
    |> assign(:agent_reasoning_text, "")
    |> assign(:agent_reasoning_segment, 0)
    |> stream_insert(
      :agent_items,
      agent_assistant_item(turn_id, "Agent failed.", :failed)
    )
    |> finalize_dangling_tools("Turn failed.")
  end

  defp apply_agent_event(
         %{assigns: %{agent_turn_id: turn_id}} = socket,
         %{type: :turn_cancelled, turn_id: turn_id} = event
       ) do
    partial = socket.assigns.agent_text
    segment = socket.assigns.agent_text_segment

    identity = %{
      agent_id: event[:session_id],
      instance_id: event[:instance_id],
      turn_id: turn_id
    }

    socket
    |> cancel_doc_browser_identity(identity,
      reason: {:turn_cancelled, turn_id},
      reply?: true
    )
    |> cancel_agent_text_flush()
    |> close_agent_reasoning_segment()
    |> assign(:agent_turn_id, nil)
    |> assign(:agent_text, "")
    |> finalize_inline_editor_preview(turn_id, :cancelled)
    |> assign(:agent_status, :cancelled)
    |> assign(:agent_reasoning_text, "")
    |> assign(:agent_reasoning_segment, 0)
    |> finalize_cancelled_agent_text(turn_id, partial, segment)
    |> finalize_dangling_tools("Turn cancelled.")
  end

  # The stop button clears the visible turn id eagerly before the PubSub event
  # returns to this LiveView. Transaction cancellation must still consume that
  # terminal event, even when there is no longer UI state left to finalize.
  defp apply_agent_event(socket, %{type: :turn_cancelled, turn_id: turn_id} = event) do
    cancel_doc_browser_identity(
      socket,
      %{
        agent_id: event[:session_id],
        instance_id: event[:instance_id],
        turn_id: turn_id
      },
      reason: {:turn_cancelled, turn_id},
      reply?: true
    )
  end

  defp apply_agent_event(socket, _event), do: socket

  defp file_operation_event_status(:file_operation_started), do: :running
  defp file_operation_event_status(:file_operation_completed), do: :completed
  defp file_operation_event_status(:file_operation_failed), do: :failed

  defp apply_file_operation_event(socket, event, status) do
    operation_id = file_operation_id(event)

    active =
      socket.assigns.agent_active_file_operations
      |> Map.get(operation_id, %{})

    item = agent_file_activity_item(operation_id, event, active, status)

    active_file_operations =
      case status do
        :running ->
          Map.put(socket.assigns.agent_active_file_operations, operation_id, item)

        _terminal ->
          Map.delete(socket.assigns.agent_active_file_operations, operation_id)
      end

    socket
    |> close_agent_text_segment()
    |> close_agent_reasoning_segment()
    |> maybe_remove_empty_agent_placeholder()
    |> assign(:agent_active_file_operations, active_file_operations)
    |> stream_insert(:agent_items, item)
  end

  defp persist_generated_agent_title(socket, title) do
    case socket.assigns.agent_session_id do
      session_id when is_binary(session_id) -> ACP.set_generated_title(session_id, title)
      _ -> :ok
    end
  end

  # ── inline chat: transcript repaint ────────────────────────────────

  # Restore the chat header from the durable agent's retained title. The snapshot
  # carries the manual-edit pin separately; an auto-derived stored title must not
  # block later provider/generated title events.
  defp restore_agent_title(socket, title, title_user_edited?)
       when is_binary(title) and title != "" do
    socket
    |> assign(:agent_title_user_edited?, title_user_edited? == true)
    |> assign_agent_title(title)
  end

  defp restore_agent_title(socket, _title, _title_user_edited?) do
    socket
    |> assign(:agent_title_user_edited?, false)
    |> assign_agent_title(default_agent_title())
  end

  # Repaint the chat pane from the selected agent's display-only transcript.
  # New transcript entries store ordered display rows (`items`) so tool-call
  # history survives in the recent-chat list.
  # Older in-memory sessions only have %{turn_id, user, agent}; keep that fallback.
  defp replay_agent_transcript(socket, turns) when is_list(turns) do
    {socket, _seen_preview_identities} =
      Enum.reduce(turns, {socket, MapSet.new()}, fn turn, {acc, seen} ->
        case transcript_items(turn) do
          items when is_list(items) and items != [] ->
            items
            |> Enum.with_index()
            |> Enum.reduce({acc, seen}, fn {item, index}, {item_acc, item_seen} ->
              case Agent.edit_preview_identity(item, turn_id(turn)) do
                nil ->
                  {stream_transcript_item(item_acc, turn, item, index), item_seen}

                identity ->
                  if MapSet.member?(item_seen, identity) do
                    {item_acc, item_seen}
                  else
                    {
                      stream_transcript_item(item_acc, turn, item, index),
                      MapSet.put(item_seen, identity)
                    }
                  end
              end
            end)

          _empty ->
            {
              acc
              |> maybe_stream_transcript_user(turn)
              |> maybe_stream_transcript_agent(turn),
              seen
            }
        end
      end)

    socket
  end

  defp replay_agent_transcript(socket, _turns), do: socket

  # A same-tab sibling can attach after a turn has already emitted deltas and
  # tool starts. Repaint the immutable Session snapshot using the same stable
  # DOM ids as the live event path, then restore the open buffers so later
  # deltas and the terminal event continue that turn instead of creating a
  # second display-only copy.
  defp replay_agent_current(socket, current) when is_map(current) do
    turn_id = item_field(current, :turn_id) || item_field(current, :id)

    if is_binary(turn_id) and turn_id != "" do
      current = Map.put(current, :turn_id, turn_id)
      items = current |> item_field(:items) |> List.wrap()

      socket =
        items
        |> Enum.with_index()
        |> Enum.reduce(socket, fn {item, index}, acc ->
          stream_transcript_item(acc, current, item, index)
        end)

      socket =
        restore_current_edit_preview(
          socket,
          turn_id,
          item_field(current, :edit_preview)
        )

      pending_text = snapshot_text(item_field(current, :pending_text))
      text_segment = snapshot_segment(item_field(current, :text_segment))
      pending_reasoning = snapshot_text(item_field(current, :pending_reasoning))
      reasoning_segment = snapshot_segment(item_field(current, :reasoning_segment))

      socket
      |> assign(:agent_turn_id, turn_id)
      |> assign(:agent_text, pending_text)
      |> assign(:agent_text_segment, text_segment)
      |> assign(:agent_reasoning_text, pending_reasoning)
      |> assign(:agent_reasoning_segment, reasoning_segment)
      |> assign(:agent_reasoning_open?, pending_reasoning != "")
      |> assign(
        :agent_active_tools,
        snapshot_active_tools(item_field(current, :active_tools))
      )
      |> assign(:agent_active_file_operations, snapshot_active_file_operations(items))
      |> maybe_stream_current_reasoning(turn_id, pending_reasoning, reasoning_segment)
      |> maybe_stream_current_text(turn_id, pending_text, text_segment)
    else
      socket
    end
  end

  defp replay_agent_current(socket, _current), do: socket

  defp restore_current_edit_preview(socket, turn_id, preview) when is_map(preview) do
    path = item_field(preview, :path)

    case inline_editor_preview_seed(socket, turn_id, path) do
      nil ->
        socket

      seed ->
        state =
          Map.merge(seed, %{
            edit_id: item_field(preview, :edit_id),
            text: snapshot_text(item_field(preview, :text)),
            delta_count: snapshot_delta_count(item_field(preview, :delta_count)),
            status: :running
          })

        socket
        |> assign(:agent_editor_preview, state)
        |> stream_insert(:agent_items, agent_editor_preview_item(state))
    end
  end

  defp restore_current_edit_preview(socket, _turn_id, _preview), do: socket

  defp maybe_stream_current_text(socket, _turn_id, "", _segment), do: socket

  defp maybe_stream_current_text(socket, turn_id, text, segment) do
    stream_insert(
      socket,
      :agent_items,
      agent_assistant_item(turn_id, text, :running, segment)
    )
  end

  defp maybe_stream_current_reasoning(socket, _turn_id, "", _segment), do: socket

  defp maybe_stream_current_reasoning(socket, turn_id, text, segment) do
    stream_insert(
      socket,
      :agent_items,
      agent_reasoning_item(turn_id, text, :running, segment)
    )
  end

  defp snapshot_active_tools(tools) when is_map(tools) do
    Enum.reduce(tools, %{}, fn {tool_call_id, tool}, acc ->
      if is_binary(tool_call_id) and is_map(tool) do
        name = item_field(tool, :name) || "tool"
        args = item_field(tool, :args) || %{}

        Map.put(acc, tool_call_id, %{
          name: name,
          kind: item_field(tool, :kind),
          input: item_field(tool, :input) || agent_tool_payload(name, args),
          args: args
        })
      else
        acc
      end
    end)
  end

  defp snapshot_active_tools(_tools), do: %{}

  defp snapshot_active_file_operations(items) when is_list(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {item, index}, acc ->
      role = item_field(item, :role) |> to_string()
      operation = item_field(item, :operation) || item_field(item, :name)
      status = transcript_status(item_field(item, :status))

      if status == :running and
           (role == "file_activity" or
              (role == "tool" and operation in @acp_file_operation_names)) do
        operation_id =
          item_field(item, :file_operation_id) ||
            item_field(item, :tool_call_id) ||
            item_field(item, :id) || "current-#{index}"

        activity = agent_file_activity_item(operation_id, item, %{}, :running)
        Map.put(acc, operation_id, activity)
      else
        acc
      end
    end)
  end

  defp snapshot_text(text) when is_binary(text), do: text
  defp snapshot_text(_text), do: ""

  defp snapshot_segment(segment) when is_integer(segment) and segment >= 0, do: segment
  defp snapshot_segment(_segment), do: 0

  defp snapshot_delta_count(count) when is_integer(count) and count >= 0, do: count
  defp snapshot_delta_count(_count), do: 0

  defp transcript_items(%{items: items}) when is_list(items), do: items
  defp transcript_items(%{"items" => items}) when is_list(items), do: items
  defp transcript_items(_turn), do: []

  defp stream_transcript_item(socket, turn, item, index) do
    turn_id = turn_id(turn)

    case item_field(item, :role) |> to_string() do
      "user" ->
        body =
          case item_field(item, :body) do
            body when is_binary(body) -> body
            _other -> ""
          end

        # The session stores already-sanitized picks; re-sanitizing keeps the
        # repaint robust against an older session's foreign item shapes.
        picks = DocumentElementPicker.compact_picks(item_field(item, :picks))

        if body != "" or picks != [] do
          stream_insert(socket, :agent_items, agent_user_item(turn_id, body, picks))
        else
          socket
        end

      "agent" ->
        case item_field(item, :body) do
          body when is_binary(body) and body != "" ->
            segment = item_field(item, :segment) |> transcript_segment(index)

            stream_insert(
              socket,
              :agent_items,
              agent_assistant_item(turn_id, body, :sent, segment)
            )

          _empty ->
            socket
        end

      "thinking" ->
        case item_field(item, :body) do
          body when is_binary(body) and body != "" ->
            segment = item_field(item, :segment) |> transcript_segment(index)

            stream_insert(
              socket,
              :agent_items,
              agent_reasoning_item(turn_id, body, :sent, segment)
            )

          _empty ->
            socket
        end

      "file_activity" ->
        stream_transcript_file_activity(socket, turn_id, item, index)

      "tool" ->
        tool_call_id =
          item_field(item, :tool_call_id) ||
            item_field(item, :id) ||
            "#{turn_id}-#{index}"

        name = item_field(item, :name) || item_field(item, :title) || "tool"

        if name in @acp_file_operation_names do
          item =
            item
            |> Map.put_new(:file_operation_id, tool_call_id)
            |> Map.put_new(:operation, name)

          stream_transcript_file_activity(socket, turn_id, item, index)
        else
          kind = item_field(item, :kind)
          input = agent_tool_body(name, item_field(item, :input))
          output = agent_tool_body(name, item_field(item, :output))
          body = tool_io_body(input, output) || agent_tool_body(name, item_field(item, :body))

          stream_insert(
            socket,
            :agent_items,
            agent_tool_item(
              tool_call_id,
              name,
              transcript_status(item_field(item, :status)),
              body,
              kind
            )
          )
        end

      "edit_preview" ->
        case transcript_edit_preview_item(socket, turn_id, item, index) do
          nil ->
            socket

          preview ->
            socket
            |> replace_live_vfs_editor_preview(preview)
            |> stream_insert(:agent_items, preview)
        end

      _other ->
        socket
    end
  end

  defp stream_transcript_file_activity(socket, turn_id, item, index) do
    operation_id =
      item_field(item, :file_operation_id) ||
        item_field(item, :tool_call_id) ||
        item_field(item, :id) ||
        "#{turn_id}-#{index}"

    activity =
      agent_file_activity_item(
        operation_id,
        item,
        %{},
        transcript_status(item_field(item, :status))
      )

    stream_insert(socket, :agent_items, activity)
  end

  defp turn_id(%{turn_id: turn_id}), do: turn_id
  defp turn_id(%{"turn_id" => turn_id}), do: turn_id

  defp item_field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp item_field(_map, _key), do: nil

  defp transcript_segment(segment, _index) when is_integer(segment) and segment >= 0, do: segment

  defp transcript_segment(segment, _index) when is_binary(segment) do
    case Integer.parse(segment) do
      {int, ""} when int >= 0 -> int
      _other -> 0
    end
  end

  defp transcript_segment(_segment, index), do: index

  defp transcript_status(status)
       when status in [:running, :completed, :failed, :approval_required],
       do: status

  defp transcript_status(status) when is_binary(status) do
    case status do
      "running" -> :running
      "completed" -> :completed
      "failed" -> :failed
      "approval_required" -> :approval_required
      _other -> :completed
    end
  end

  defp transcript_status(_status), do: :completed

  defp maybe_stream_transcript_user(socket, %{turn_id: turn_id, user: user})
       when is_binary(user) and user != "" do
    stream_insert(socket, :agent_items, agent_user_item(turn_id, user))
  end

  defp maybe_stream_transcript_user(socket, _turn), do: socket

  defp maybe_stream_transcript_agent(socket, %{turn_id: turn_id, agent: agent})
       when is_binary(agent) and agent != "" do
    stream_insert(socket, :agent_items, agent_assistant_item(turn_id, agent, :sent))
  end

  defp maybe_stream_transcript_agent(socket, _turn), do: socket

  # ── inline chat: streaming text buffer helpers ─────────────────────

  defp ensure_inline_editor_preview(socket, turn_id, path) when is_binary(turn_id) do
    case inline_editor_preview_seed(socket, turn_id, path) do
      nil ->
        socket

      seed ->
        state = socket.assigns[:agent_editor_preview]

        if state && state.turn_id == turn_id && state.document_id == seed.document_id do
          socket
        else
          state = Map.merge(seed, %{text: "", delta_count: 0, status: :running})

          socket
          |> assign(:agent_editor_preview, state)
          |> stream_insert(:agent_items, agent_editor_preview_item(state))
        end
    end
  end

  defp ensure_inline_editor_preview(socket, _turn_id, _path), do: socket

  defp inline_editor_preview_accumulate_delta(socket, turn_id, delta, path, edit_id)
       when is_binary(turn_id) and is_binary(delta) do
    socket = ensure_inline_editor_preview(socket, turn_id, path)

    case socket.assigns[:agent_editor_preview] do
      %{turn_id: ^turn_id, document_id: document_id} = state when is_binary(document_id) ->
        text = preview_text_append(state.text, delta)

        state =
          state
          |> Map.put(:text, text)
          |> Map.put(:delta_count, state.delta_count + 1)
          |> Map.put(:status, :running)
          |> Map.put(:edit_id, edit_id || Map.get(state, :edit_id))

        payload = %{
          turn_id: turn_id,
          document_id: document_id,
          delta: delta,
          text: text,
          delta_count: state.delta_count,
          edit_id: Map.get(state, :edit_id)
        }

        Process.send_after(self(), {:editor_preview_delta, payload}, 0)

        socket
        |> assign(:agent_editor_preview, state)
        |> stream_insert(:agent_items, agent_editor_preview_item(state))
        |> push_event("document.preview.delta_received", payload)

      _other ->
        socket
    end
  end

  defp inline_editor_preview_accumulate_delta(socket, _turn_id, _delta, _path, _edit_id),
    do: socket

  defp finalize_inline_editor_preview(socket, turn_id, status) when is_binary(turn_id) do
    case socket.assigns[:agent_editor_preview] do
      %{turn_id: ^turn_id} = state ->
        state = %{state | status: status}

        socket
        |> assign(:agent_editor_preview, nil)
        |> stream_insert(:agent_items, agent_editor_preview_item(state))

      _other ->
        socket
    end
  end

  defp finalize_inline_editor_preview(socket, _turn_id, _status), do: socket

  defp inline_editor_preview_seed(socket, turn_id, path) do
    case inline_editor_preview_document(socket, path) do
      {:ok, %{document: document, relative_path: relative_path}} ->
        inline_editor_preview_seed(socket, turn_id, document, relative_path)

      _ ->
        inline_editor_preview_seed_from_active_document(socket, turn_id)
    end
  end

  defp inline_editor_preview_seed_from_active_document(socket, turn_id) do
    document = socket.assigns[:active_document]
    path = socket.assigns[:active_document_path]
    document_id = active_document_id(socket)

    with %{relative_path: relative_path} <- document,
         true <- is_binary(relative_path),
         true <- is_binary(document_id) do
      %{
        turn_id: turn_id,
        document_id: document_id,
        document: document,
        document_path: path || relative_path,
        document_spec: document_spec(document),
        canvas_id: "agent-editor-preview-#{dom_token(turn_id)}-#{dom_token(document_id)}-canvas",
        bytes_url: document_bytes_url(socket.assigns.workspace_path, relative_path)
      }
    else
      _other -> nil
    end
  end

  defp inline_editor_preview_seed(socket, turn_id, document, relative_path) do
    %{
      turn_id: turn_id,
      document_id: document.id,
      document: document,
      document_path: relative_path,
      document_spec: document_spec(document),
      canvas_id: "agent-editor-preview-#{dom_token(turn_id)}-#{dom_token(document.id)}-canvas",
      bytes_url: document_bytes_url(socket.assigns.workspace_path, relative_path)
    }
  end

  defp inline_editor_preview_document(socket, path) when is_binary(path) and path != "" do
    with {:ok, source_path} <- inline_editor_preview_source_path(socket, path) do
      vfs_preview_document(socket, source_path)
    end
  end

  defp inline_editor_preview_document(_socket, _path), do: nil

  defp inline_editor_preview_source_path(socket, path) do
    workspace_path = socket.assigns[:workspace_path]
    projected_name = path |> Path.basename() |> Projection.source_basename()

    cond do
      is_binary(workspace_path) and is_binary(projected_name) ->
        OpenDocs.source_path(workspace_path, projected_name)

      Path.type(path) == :absolute and File.regular?(path) ->
        {:ok, path}

      is_binary(workspace_path) ->
        with {:ok, normalized} <- WorkspacePath.normalize(path),
             {:ok, source_path} <- WorkspacePath.join(workspace_path, normalized),
             true <- File.regular?(source_path) do
          {:ok, source_path}
        else
          _ -> :error
        end

      true ->
        :error
    end
  end

  defp preview_text_append(text, delta) do
    text = (text || "") <> delta

    if String.length(text) <= @agent_editor_preview_max do
      text
    else
      start = String.length(text) - @agent_editor_preview_max
      "..." <> String.slice(text, start, @agent_editor_preview_max)
    end
  end

  defp close_agent_text_segment(socket) do
    socket = cancel_agent_text_flush(socket)

    case socket.assigns.agent_text do
      text when is_binary(text) and text != "" ->
        turn_id = socket.assigns.agent_turn_id
        segment = socket.assigns.agent_text_segment

        socket
        |> stream_insert(:agent_items, agent_assistant_item(turn_id, text, :sent, segment))
        |> assign(:agent_text, "")
        |> assign(:agent_text_segment, segment + 1)

      _empty ->
        socket
    end
  end

  defp ensure_agent_text_placeholder(socket) do
    if socket.assigns.agent_text == "" do
      stream_insert(
        socket,
        :agent_items,
        agent_assistant_item(
          socket.assigns.agent_turn_id,
          "",
          :running,
          socket.assigns.agent_text_segment
        )
      )
    else
      socket
    end
  end

  defp prepare_agent_reasoning_segment(socket, turn_id, segment) do
    socket =
      if socket.assigns.agent_reasoning_segment == segment do
        socket
      else
        socket
        |> cancel_agent_reasoning_flush()
        |> assign(:agent_reasoning_text, "")
        |> assign(:agent_reasoning_segment, segment)
      end

    if socket.assigns.agent_reasoning_text == "" do
      stream_insert(
        socket,
        :agent_items,
        agent_reasoning_item(turn_id, "", :pending, segment)
      )
    else
      socket
    end
  end

  defp close_agent_reasoning_segment(socket) do
    socket = cancel_agent_reasoning_flush(socket)
    turn_id = socket.assigns.agent_turn_id
    segment = socket.assigns.agent_reasoning_segment

    socket =
      case socket.assigns.agent_reasoning_text do
        text when is_binary(text) and text != "" ->
          stream_insert(
            socket,
            :agent_items,
            agent_reasoning_item(turn_id, text, :sent, segment)
          )

        _empty ->
          stream_delete(
            socket,
            :agent_items,
            agent_reasoning_item(turn_id, "", :pending, segment)
          )
      end

    socket
    |> assign(:agent_reasoning_text, "")
    |> assign(:agent_reasoning_segment, segment + 1)
    |> assign(:agent_reasoning_open?, false)
  end

  # The empty thinking placeholder stays hidden. Once reasoning has text, a
  # debounced stream refresh makes the existing disclosure visible mid-turn.
  defp schedule_agent_reasoning_flush(socket) do
    if socket.assigns.agent_reasoning_flush_ref do
      socket
    else
      ref = make_ref()

      Process.send_after(
        self(),
        {:flush_agent_reasoning, ref},
        @agent_reasoning_flush_ms
      )

      assign(socket, :agent_reasoning_flush_ref, ref)
    end
  end

  defp flush_agent_reasoning(socket) do
    socket = assign(socket, :agent_reasoning_flush_ref, nil)

    case {socket.assigns.agent_turn_id, socket.assigns.agent_reasoning_text} do
      {turn_id, text} when is_binary(turn_id) and text != "" ->
        stream_insert(
          socket,
          :agent_items,
          agent_reasoning_item(
            turn_id,
            text,
            :running,
            socket.assigns.agent_reasoning_segment
          )
        )

      _empty ->
        socket
    end
  end

  defp cancel_agent_reasoning_flush(socket) do
    assign(socket, :agent_reasoning_flush_ref, nil)
  end

  defp split_agent_text_before_preview(socket) do
    if is_binary(socket.assigns[:agent_turn_id]) do
      socket
      |> close_agent_text_segment()
      |> maybe_remove_empty_agent_placeholder()
    else
      socket
    end
  end

  # Coalesces streaming text deltas into a single debounced re-render. A monotonic
  # ref guards a flush that fires after the buffer was already finalized (tool
  # boundary / turn completion). Only one timer is outstanding; while it is
  # pending, new deltas extend the buffer and it renders the latest.
  defp schedule_agent_text_flush(socket) do
    if socket.assigns.agent_text_flush_ref do
      socket
    else
      ref = make_ref()
      Process.send_after(self(), {:flush_agent_text, ref}, @agent_text_flush_ms)
      assign(socket, :agent_text_flush_ref, ref)
    end
  end

  defp flush_agent_text(socket) do
    socket = assign(socket, :agent_text_flush_ref, nil)

    case socket.assigns.agent_text do
      text when is_binary(text) and text != "" ->
        turn_id = socket.assigns.agent_turn_id
        segment = socket.assigns.agent_text_segment

        stream_insert(
          socket,
          :agent_items,
          agent_assistant_item(turn_id, text, :running, segment)
        )

      _empty ->
        socket
    end
  end

  defp cancel_agent_text_flush(socket) do
    assign(socket, :agent_text_flush_ref, nil)
  end

  defp maybe_remove_empty_agent_placeholder(socket) do
    case socket.assigns.agent_text do
      "" ->
        stream_delete(
          socket,
          :agent_items,
          agent_assistant_item(
            socket.assigns.agent_turn_id,
            "",
            :running,
            socket.assigns.agent_text_segment
          )
        )

      _text ->
        socket
    end
  end

  defp maybe_stream_final_agent_text(socket, turn_id, text) when is_binary(text) and text != "" do
    stream_insert(
      socket,
      :agent_items,
      agent_assistant_item(turn_id, text, :sent, socket.assigns.agent_text_segment)
    )
  end

  defp maybe_stream_final_agent_text(socket, _turn_id, _text), do: socket

  defp maybe_remove_empty_agent_placeholder_for_editor_preview(
         socket,
         turn_id,
         pending,
         segment,
         true
       )
       when pending in [nil, ""] do
    stream_delete(
      socket,
      :agent_items,
      agent_assistant_item(turn_id, "", :running, segment)
    )
  end

  defp maybe_remove_empty_agent_placeholder_for_editor_preview(
         socket,
         _turn_id,
         _pending,
         _segment,
         _editor_preview?
       ),
       do: socket

  # On cancel, keep what the agent already streamed (finalize the in-flight bubble
  # with the accumulated partial, in place). Do NOT emit a "Cancelled."
  # placeholder; if nothing was streamed yet, drop the empty running bubble.
  defp finalize_cancelled_agent_text(socket, turn_id, partial_text, segment) do
    if is_binary(partial_text) and partial_text != "" do
      stream_insert(
        socket,
        :agent_items,
        agent_assistant_item(turn_id, partial_text, :sent, segment)
      )
    else
      stream_delete(
        socket,
        :agent_items,
        agent_assistant_item(turn_id, "", :running, segment)
      )
    end
  end

  defp agent_tool_payload(name, payload) do
    Ecrits.Doc.ToolPayloadSanitizer.encode_tool_payload(name, payload)
  end

  defp agent_tool_body(name, body) do
    Ecrits.Doc.ToolPayloadSanitizer.sanitize_tool_body(name, body)
  end

  # A turn can end (complete/fail/cancel/die) while a tool_call is still
  # mid-flight — that tool_call never gets its terminal event, so its row would be
  # stuck on "running" forever. On every turn terminal, flip any still-tracked
  # in-flight tool_calls to :failed.
  defp finalize_dangling_tools(socket, reason) do
    active = socket.assigns[:agent_active_tools] || %{}
    active_file_operations = socket.assigns[:agent_active_file_operations] || %{}

    socket =
      Enum.reduce(active, socket, fn {tool_call_id, tool}, acc ->
        name = active_tool_name(tool)
        input = active_tool_input(tool)
        kind = active_tool_kind(tool)

        stream_insert(
          acc,
          :agent_items,
          agent_tool_item(tool_call_id, name, :failed, tool_io_body(input, reason), kind)
        )
      end)

    socket =
      Enum.reduce(active_file_operations, socket, fn {operation_id, activity}, acc ->
        stream_insert(
          acc,
          :agent_items,
          agent_file_activity_item(
            operation_id,
            %{reason: "Turn ended before the file operation finished."},
            activity,
            :failed
          )
        )
      end)

    socket
    |> assign(:agent_active_tools, %{})
    |> assign(:agent_active_file_operations, %{})
  end

  # ── inline chat: stream item builders ──────────────────────────────

  defp agent_user_item(turn_id, body, picks \\ []) do
    %{
      dom_id: "agent-user-#{turn_id}",
      role: :user,
      status: :sent,
      body: body,
      picks: picks
    }
  end

  defp agent_assistant_item(turn_id, body, status, segment \\ 0) do
    %{
      dom_id: agent_assistant_dom_id(turn_id, segment),
      role: :agent,
      status: status,
      body: body,
      turn_id: turn_id
    }
  end

  defp agent_reasoning_item(turn_id, body, status, segment) do
    %{
      dom_id: agent_reasoning_dom_id(turn_id, segment),
      role: :thinking,
      status: status,
      title: "Thinking",
      body: body,
      segment: segment
    }
  end

  defp agent_tool_item(tool_call_id, name, status, body, kind) do
    %{
      dom_id: "agent-tool-#{tool_call_id}",
      role: :tool,
      title: name,
      kind: kind,
      status: status,
      body: body || ""
    }
  end

  defp agent_file_activity_item(operation_id, event, active, status) do
    operation =
      file_activity_value(event, :operation) ||
        file_activity_value(event, :name) ||
        item_field(active, :operation) || "file_operation"

    path = file_activity_value(event, :path) || item_field(active, :path)
    query = file_activity_value(event, :query) || item_field(active, :query)
    reason = file_activity_value(event, :reason) || item_field(active, :reason)
    result = item_field(event, :result) || item_field(active, :result)

    %{
      dom_id: "agent-file-#{dom_token(operation_id)}",
      role: :file_activity,
      file_operation_id: operation_id,
      operation: to_string(operation),
      path: normalize_file_activity_text(path),
      query: normalize_file_activity_text(query),
      reason: normalize_file_activity_text(reason),
      result: result,
      status: status
    }
  end

  defp file_operation_id(event) do
    case file_activity_value(event, :file_operation_id) ||
           file_activity_value(event, :tool_call_id) ||
           file_activity_value(event, :id) do
      id when is_binary(id) and id != "" ->
        id

      id when not is_nil(id) ->
        to_string(id)

      _missing ->
        fingerprint =
          {
            file_activity_value(event, :operation) || file_activity_value(event, :name),
            file_activity_value(event, :path),
            file_activity_value(event, :query),
            file_activity_value(event, :turn_id)
          }
          |> :erlang.phash2()

        "activity-#{fingerprint}"
    end
  end

  defp file_activity_value(map, key) when is_map(map) do
    item_field(map, key) ||
      Enum.find_value([:arguments, :args, :input], fn container_key ->
        map
        |> item_field(container_key)
        |> file_activity_container_value(key)
      end)
  end

  defp file_activity_value(_map, _key), do: nil

  defp file_activity_container_value(container, key) when is_map(container),
    do: item_field(container, key)

  defp file_activity_container_value(container, key) when is_binary(container) do
    case Jason.decode(container) do
      {:ok, decoded} when is_map(decoded) -> item_field(decoded, key)
      _other -> nil
    end
  end

  defp file_activity_container_value(_container, _key), do: nil

  defp normalize_file_activity_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp normalize_file_activity_text(nil), do: nil
  defp normalize_file_activity_text(value), do: inspect(value)

  defp agent_editor_preview_item(state) do
    %{
      dom_id:
        Map.get(state, :dom_id) ||
          "agent-editor-preview-#{state.turn_id}-#{dom_token(state.document_id)}",
      role: :editor_preview,
      status: state.status,
      turn_id: state.turn_id,
      document_id: state.document_id,
      document: state.document,
      document_path: state.document_path,
      document_spec: state.document_spec,
      canvas_id: state.canvas_id,
      bytes_url: state.bytes_url,
      final_bytes_url: Map.get(state, :final_bytes_url),
      body: state.text,
      delta_count: state.delta_count,
      highlights: Map.get(state, :highlights, []),
      preview_steps: Map.get(state, :preview_steps, []),
      scroll: Map.get(state, :scroll, %{scroll_top: 0, scroll_left: 0}),
      marker: Map.get(state, :marker, ""),
      summary: Map.get(state, :summary, ""),
      edit_id: Map.get(state, :edit_id),
      preview_snapshot: Map.get(state, :preview_snapshot),
      preview_identity: Map.get(state, :preview_identity),
      preview_unavailable: Map.get(state, :preview_unavailable, false),
      preview_error: Map.get(state, :preview_error),
      provisional: Map.get(state, :provisional, false)
    }
  end

  defp maybe_compose_doc_edit_preview(
         socket,
         turn_id,
         tool_call_id,
         "doc.edit",
         args,
         result
       )
       when is_binary(turn_id) and turn_id != "" and is_binary(tool_call_id) and
              tool_call_id != "" and is_map(args) do
    with %{} = op <- doc_edit_primary_op(args),
         "insert_picture" <- item_field(op, :op),
         {:ok, path} <- resolve_edit_doc_path(socket, args),
         {:ok, %{document: document, relative_path: relative_path}} <-
           vfs_preview_document(socket, path),
         {:ok, descriptor, index} <-
           persisted_vfs_edit_preview(socket, turn_id, document.id, relative_path) do
      {descriptor, changed?} =
        compose_picture_edit_descriptor(descriptor, tool_call_id, op, result)

      with :ok <- maybe_persist_composed_edit_preview(socket, descriptor, changed?),
           %{} = preview <- transcript_edit_preview_item(socket, turn_id, descriptor, index) do
        {:ok, preview}
      else
        nil -> {:error, :preview_unavailable}
        {:error, _reason} = error -> error
        other -> {:error, other}
      end
    else
      :not_applicable -> :not_applicable
      {:error, _reason} = error -> error
      _other -> :not_applicable
    end
  end

  defp maybe_compose_doc_edit_preview(
         _socket,
         _turn_id,
         _tool_call_id,
         _name,
         _args,
         _result
       ),
       do: :not_applicable

  defp persisted_vfs_edit_preview(socket, turn_id, document_id, relative_path) do
    case socket.assigns[:agent_vfs_preview_item] do
      %{role: :editor_preview} = live_preview ->
        if item_field(live_preview, :turn_id) == turn_id and
             item_field(live_preview, :document_id) == document_id and
             item_field(live_preview, :document_path) == relative_path do
          with session_id when is_binary(session_id) and session_id != "" <-
                 socket.assigns[:agent_session_id],
               identity when not is_nil(identity) <-
                 live_edit_preview_identity(live_preview, turn_id) do
            snapshot = ACP.agent_snapshot(session_id)

            snapshot
            |> edit_preview_turn_items(turn_id)
            |> Enum.with_index()
            |> Enum.find_value(fn {item, index} ->
              if item_field(item, :role) |> to_string() == "edit_preview" and
                   item_field(item, :document_id) == document_id and
                   item_field(item, :document_path) == relative_path and
                   Agent.edit_preview_identity(item, turn_id) == identity do
                {:ok, item, index}
              end
            end)
            |> case do
              {:ok, _item, _index} = found -> found
              _other -> {:error, :persisted_preview_not_found}
            end
          else
            _other -> {:error, :live_preview_identity_mismatch}
          end
        else
          :not_applicable
        end

      _other ->
        :not_applicable
    end
  rescue
    _error -> {:error, :preview_snapshot_unavailable}
  catch
    :exit, _reason -> {:error, :preview_snapshot_unavailable}
  end

  defp live_edit_preview_identity(live_preview, turn_id) do
    Agent.edit_preview_identity(
      %{
        role: :edit_preview,
        turn_id: item_field(live_preview, :turn_id),
        edit_id: item_field(live_preview, :edit_id),
        document_id: item_field(live_preview, :document_id),
        preview_snapshot: item_field(live_preview, :preview_snapshot),
        preview_unavailable: item_field(live_preview, :preview_unavailable)
      },
      turn_id
    )
  end

  defp edit_preview_turn_items(snapshot, turn_id) when is_map(snapshot) do
    current = Map.get(snapshot, :current_turn)

    turn =
      if item_field(current, :turn_id) == turn_id do
        current
      else
        Enum.find(
          Map.get(snapshot, :transcript, []),
          &(item_field(&1, :turn_id) == turn_id)
        )
      end

    case item_field(turn, :items) do
      items when is_list(items) -> items
      _other -> []
    end
  end

  defp edit_preview_turn_items(_snapshot, _turn_id), do: []

  defp compose_picture_edit_descriptor(descriptor, tool_call_id, op, result) do
    composed_tool_call_ids =
      descriptor
      |> item_field(:composed_tool_call_ids)
      |> List.wrap()
      |> Enum.filter(&is_binary/1)

    if tool_call_id in composed_tool_call_ids do
      {descriptor, false}
    else
      highlights = List.wrap(item_field(descriptor, :highlights))
      highlights = highlights ++ [doc_edit_picture_highlight(op, result)]
      applied = persisted_edit_applied(descriptor) + doc_edit_delta_count(result)

      descriptor =
        descriptor
        |> Map.put(:applied, applied)
        |> Map.put(
          :ops,
          List.wrap(item_field(descriptor, :ops)) ++ [strip_transient_preview_bytes(op)]
        )
        |> Map.put(:highlights, highlights)
        |> Map.put(:hash, edit_preview_hash(highlights))
        |> Map.put(:composed_tool_call_ids, composed_tool_call_ids ++ [tool_call_id])

      {descriptor, true}
    end
  end

  defp persisted_edit_applied(descriptor) do
    case item_field(descriptor, :applied) do
      applied when is_integer(applied) and applied >= 0 -> applied
      _other -> 0
    end
  end

  defp maybe_persist_composed_edit_preview(_socket, _descriptor, false), do: :ok

  defp maybe_persist_composed_edit_preview(socket, descriptor, true) do
    case socket.assigns[:agent_session_id] do
      session_id when is_binary(session_id) and session_id != "" ->
        ACP.append_transcript_item(session_id, descriptor)

      _other ->
        {:error, :agent_session_unavailable}
    end
  end

  defp doc_edit_picture_highlight(op, result) do
    %{
      "kind" => "picture",
      "op" => "insert_picture",
      "ref" => doc_edit_picture_highlight_ref(op, result),
      "text" => doc_edit_picture_marker(op)
    }
  end

  defp doc_edit_picture_highlight_ref(op, result) do
    ref = op |> item_field(:ref) |> decode_doc_edit_ref()

    case doc_edit_inserted_control(result) do
      {:ok, paragraph, control} ->
        %{
          "section" => item_field(ref, :section) || 0,
          "paragraph" => paragraph,
          "control" => control,
          "type" => "picture"
        }

      :error when is_map(ref) ->
        Map.put(ref, "type", "picture")

      :error ->
        ref
    end
  end

  defp doc_edit_inserted_control(result) when is_map(result) do
    result = item_field(result, :structuredContent) || result

    candidate =
      case item_field(result, :native) do
        [first | _rest] when is_map(first) -> item_field(first, :extra) || first
        _other -> item_field(result, :extra) || result
      end

    paragraph = item_field(candidate, :paraIdx)
    control = item_field(candidate, :controlIdx)

    if is_integer(paragraph) and is_integer(control),
      do: {:ok, paragraph, control},
      else: :error
  end

  defp doc_edit_inserted_control(_result), do: :error

  defp decode_doc_edit_ref(ref) when is_binary(ref) do
    case Jason.decode(ref) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> ref
    end
  end

  defp decode_doc_edit_ref(ref), do: ref

  defp doc_edit_picture_marker(op) do
    case item_field(op, :src) do
      src when is_binary(src) and src != "" -> Path.basename(src)
      _other -> "picture"
    end
  end

  # Build the document-renderer preview for a completed doc.edit. nil for
  # non-edit tools or when no editable content/document can be resolved (the
  # plain tool block still renders either way).
  defp maybe_doc_edit_preview_item(socket, tool_call_id, "doc.edit", args, result)
       when is_map(args) do
    with op when is_map(op) <- doc_edit_primary_op(args),
         marker when is_binary(marker) <- doc_edit_marker(op),
         {:ok, path} <- resolve_edit_doc_path(socket, args),
         {:ok, %{document: document, relative_path: relative_path}} <-
           vfs_preview_document(socket, path),
         true <-
           Document.ehwp_format?(document.format) or Document.libreoffice_format?(document.format) or
             Document.markdown_format?(document.format) do
      highlights = doc_edit_preview_highlights(op, marker)

      state = %{
        dom_id: "agent-docedit-preview-#{dom_token(tool_call_id)}",
        turn_id: tool_call_id,
        document_id: document.id,
        document: document,
        document_path: relative_path,
        document_spec: document_spec(document),
        canvas_id: "agent-docedit-preview-#{dom_token(tool_call_id)}-canvas",
        bytes_url:
          socket.assigns.workspace_path
          |> document_bytes_url(relative_path)
          |> cache_bust_url(),
        text: "",
        delta_count: doc_edit_delta_count(result),
        highlights: highlights,
        marker: marker,
        status: :sent
      }

      agent_editor_preview_item(state)
    else
      _ -> nil
    end
  end

  defp maybe_doc_edit_preview_item(_socket, _id, _name, _args, _result), do: nil

  defp doc_edit_preview_highlights(op, marker) when is_map(op) do
    ref = op["ref"] || op[:ref]
    kind = op["kind"] || op[:kind] || "text"
    verb = op["op"] || op[:op] || kind

    [
      %{
        "kind" => kind,
        "op" => verb,
        "ref" => ref,
        "text" => marker
      }
    ]
  end

  defp edit_preview_ref(highlights) when is_list(highlights) do
    ranged =
      Enum.filter(highlights, fn highlight ->
        is_map(highlight) and
          (Map.get(highlight, "length") || Map.get(highlight, :length) || 0) > 0
      end)

    highlight =
      Enum.find(ranged, fn highlight ->
        ref = Map.get(highlight, "ref") || Map.get(highlight, :ref)
        is_map(ref) and not is_map(Map.get(ref, "cell") || Map.get(ref, :cell))
      end) || List.first(ranged) || List.first(highlights)

    edit_preview_ref_from_highlight(highlight)
  end

  defp edit_preview_ref_from_highlight(highlight) when is_map(highlight) do
    ref = Map.get(highlight, "ref") || Map.get(highlight, :ref)
    offset = Map.get(highlight, "offset") || Map.get(highlight, :offset)
    length = Map.get(highlight, "length") || Map.get(highlight, :length)
    text = Map.get(highlight, "text") || Map.get(highlight, :text)

    if is_map(ref) and is_integer(offset) and is_integer(length) and length > 0 do
      ref
      |> Map.put("offset", offset)
      |> Map.put("highlightLength", length)
      |> maybe_put_preview_anchor(text)
    else
      ref
    end
  end

  defp edit_preview_ref_from_highlight(_highlight), do: nil

  defp maybe_put_preview_anchor(ref, text) when is_binary(text) and text != "",
    do: Map.put(ref, "anchorText", text)

  defp maybe_put_preview_anchor(ref, _text), do: ref

  defp doc_edit_delta_count(result) when is_map(result) do
    case result["applied"] || result[:applied] || result["count"] || result[:count] do
      value when is_integer(value) and value >= 1 -> value
      _ -> 1
    end
  end

  defp doc_edit_delta_count(_result), do: 1

  defp doc_edit_primary_op(args) do
    cond do
      is_map(args["op"]) -> args["op"]
      is_list(args["ops"]) -> Enum.find(args["ops"], &is_map/1)
      true -> nil
    end
  end

  # The text the edit put into the document (insert_text/insert_paragraph text,
  # or replace_text/set_cell replacement) — what we locate in the projection.
  defp doc_edit_marker(op) when is_map(op) do
    case op["replacement"] || op["text"] do
      raw when is_binary(raw) ->
        raw |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.find(&(&1 != ""))

      _ ->
        nil
    end
  end

  # Resolve doc.edit's `document` arg to an absolute path for projection: a
  # workspace-relative/abs path that exists, else an open Pool doc matched by id
  # or basename. :error when unresolvable (card renders without an excerpt).
  defp resolve_edit_doc_path(socket, args) do
    root = socket.assigns[:workspace_path]
    doc = args["document"]

    cond do
      is_binary(doc) and is_binary(root) and File.regular?(Path.expand(doc, root)) ->
        {:ok, Path.expand(doc, root)}

      is_binary(doc) ->
        pool_doc_path(doc)

      true ->
        :error
    end
  end

  defp pool_doc_path(doc) do
    Ecrits.Doc.Pool.list()
    |> Enum.find(fn d -> d[:id] == doc or Path.basename(to_string(d[:path])) == doc end)
    |> case do
      %{path: path} when is_binary(path) -> {:ok, path}
      _ -> :error
    end
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  defp active_tool_name(%{name: name}), do: name
  defp active_tool_name(name) when is_binary(name), do: name
  defp active_tool_name(_tool), do: "tool"

  defp active_tool_input(%{input: input}), do: input
  defp active_tool_input(_tool), do: nil

  defp active_tool_kind(%{kind: kind}), do: kind
  defp active_tool_kind(_tool), do: nil

  defp tool_io_body(input, output) do
    parts =
      []
      |> maybe_tool_io_part("Input", input)
      |> maybe_tool_io_part("Output", output)

    case parts do
      [] -> nil
      _ -> Enum.join(parts, "\n\n")
    end
  end

  defp maybe_tool_io_part(parts, _label, nil), do: parts
  defp maybe_tool_io_part(parts, _label, ""), do: parts
  defp maybe_tool_io_part(parts, label, body), do: parts ++ ["#{label}:\n#{body}"]

  defp agent_assistant_dom_id(turn_id, segment), do: "agent-assistant-#{turn_id}-#{segment}"

  defp agent_reasoning_dom_id(turn_id, segment),
    do: "agent-thinking-#{turn_id}-#{segment}"

  # Stream dom_id resolver — PUBLIC so it can be captured as `&__MODULE__.../1` in
  # stream_configure (mount/3). Named captures survive dev hot-reloads, unlike
  # anonymous closures compiled into this module.
  @doc false
  def agent_item_dom_id(%{dom_id: dom_id}), do: dom_id

  # ── inline chat: stream item view extractors ───────────────────────

  defp agent_item_data_role(%{role: :tool}), do: "agent-tool"
  defp agent_item_data_role(%{role: :file_activity}), do: "file-activity"
  defp agent_item_data_role(%{role: :thinking}), do: "agent-thinking"
  defp agent_item_data_role(%{role: :editor_preview}), do: "agent-editor-preview"
  defp agent_item_data_role(_item), do: "agent-message"

  defp agent_item_role(%{role: role}), do: to_string(role)
  defp agent_item_role(_item), do: "agent"

  defp agent_item_status(%{status: status}), do: to_string(status)
  defp agent_item_status(_item), do: "idle"

  # The bouncing-dots indicator renders ONLY while the assistant placeholder is
  # in-flight (`running`) AND has no body yet. Once the first token lands the
  # debounced re-render carries a body, so the guard drops the span.
  defp agent_item_loading?(item) do
    agent_item_status(item) == "running" and agent_item_body(item) == ""
  end

  defp agent_item_loading?(item, editor_preview) do
    agent_item_loading?(item) and not editor_preview_turn_item?(editor_preview, item)
  end

  defp editor_preview_turn_item?(editor_preview, item) do
    case {editor_preview, item} do
      {%{turn_id: turn_id}, %{turn_id: turn_id}} when is_binary(turn_id) -> true
      _other -> false
    end
  end

  defp editor_preview_turn?(%{turn_id: turn_id}, turn_id) when is_binary(turn_id), do: true
  defp editor_preview_turn?(_editor_preview, _turn_id), do: false

  defp agent_item_title(%{title: title}) when is_binary(title), do: title
  defp agent_item_title(_item), do: "Tool"

  defp agent_item_operation_kind(%{kind: kind}) when kind in [:execute, "execute"],
    do: "shell"

  defp agent_item_operation_kind(item) do
    if shell_tool_name?(agent_item_title(item)), do: "shell", else: "tool"
  end

  defp agent_item_operation_icon(item) do
    case agent_item_operation_kind(item) do
      "shell" -> "hero-command-line"
      _tool -> "hero-wrench-screwdriver"
    end
  end

  defp agent_item_operation_label(item) do
    case agent_item_operation_kind(item) do
      "shell" -> "Shell"
      _tool -> "Tool"
    end
  end

  defp file_activity_kind(item) do
    case item_field(item, :operation) do
      "read_text_file" -> "read"
      "search_text_file" -> "search"
      "edit_text_file" -> "edit"
      _other -> "file"
    end
  end

  defp file_activity_label(item) do
    case file_activity_kind(item) do
      "read" -> "Read"
      "search" -> "Search"
      "edit" -> "Edit"
      _other -> "File"
    end
  end

  defp file_activity_icon(item) do
    case file_activity_kind(item) do
      "read" -> "hero-document-text"
      "search" -> "hero-magnifying-glass"
      "edit" -> "hero-pencil-square"
      _other -> "hero-document"
    end
  end

  defp file_activity_detail(item) do
    path = item_field(item, :path)
    query = item_field(item, :query)

    reason =
      if agent_item_status(item) == "failed" do
        item_field(item, :reason)
      end

    [path, file_activity_query_detail(query), brief_file_activity_reason(reason)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "file"
      detail -> detail
    end
  end

  defp file_activity_query_detail(query) when is_binary(query) and query != "",
    do: ~s(“#{query}”)

  defp file_activity_query_detail(_query), do: nil

  defp brief_file_activity_reason(reason) when is_binary(reason) and reason != "",
    do: String.slice(reason, 0, 120)

  defp brief_file_activity_reason(_reason), do: nil

  defp shell_tool_name?(name) when is_binary(name) do
    String.downcase(name) in ["bash", "shell", "exec_command", "functions.exec_command"]
  end

  defp agent_item_body(%{body: body}) when is_binary(body), do: body
  defp agent_item_body(_item), do: ""

  defp agent_item_picks(%{picks: picks}) when is_list(picks), do: picks
  defp agent_item_picks(_item), do: []

  defp agent_editor_preview_document(%{document: document}), do: document

  defp agent_editor_preview_unavailable?(%{preview_unavailable: true}), do: true
  defp agent_editor_preview_unavailable?(_item), do: false

  defp agent_editor_preview_state(item) do
    document = agent_editor_preview_document(item)
    document_path = agent_editor_preview_path(item)
    preview_text = agent_editor_preview_text(item)

    EditorPreviewState.new(%{
      document: document,
      document_path: document_path,
      canvas_id: agent_editor_preview_canvas_id(item),
      status: agent_editor_preview_status(item),
      canvas: %{
        document_id: document.id,
        document_path: document_path,
        document_format: document.format,
        bytes_url: agent_editor_preview_bytes_url(item),
        preview_final_bytes_url: agent_editor_preview_final_bytes_url(item),
        mirror?: true,
        preview_turn_id: Map.get(item, :turn_id),
        preview_text: preview_text,
        preview_delta_count: agent_editor_preview_delta_count(item),
        preview_highlights: Jason.encode!(agent_editor_preview_highlights(item)),
        preview_steps: Jason.encode!(agent_editor_preview_steps(item)),
        scroll_top: agent_editor_preview_scroll(item).scroll_top,
        scroll_left: agent_editor_preview_scroll(item).scroll_left,
        spec: agent_editor_preview_spec(item),
        markdown_editor:
          MarkdownEditorState.new(%{
            document_id: document.id,
            source: preview_text,
            view: :preview
          }),
        markdown_preview_html: ""
      }
    })
  end

  defp agent_editor_preview_path(%{document_path: path}) when is_binary(path), do: path
  defp agent_editor_preview_path(_item), do: nil

  defp agent_editor_preview_spec(%{document_spec: spec}) when is_map(spec), do: spec
  defp agent_editor_preview_spec(_item), do: nil

  defp agent_editor_preview_canvas_id(%{canvas_id: id}) when is_binary(id), do: id
  defp agent_editor_preview_canvas_id(_item), do: "agent-editor-preview"

  defp agent_editor_preview_bytes_url(%{bytes_url: url}) when is_binary(url), do: url
  defp agent_editor_preview_bytes_url(_item), do: nil

  defp agent_editor_preview_final_bytes_url(%{final_bytes_url: url}) when is_binary(url),
    do: url

  defp agent_editor_preview_final_bytes_url(_item), do: nil

  defp agent_editor_preview_status(%{status: status}) when is_atom(status), do: status
  defp agent_editor_preview_status(_item), do: :running

  defp agent_editor_preview_text(%{body: body}) when is_binary(body), do: body
  defp agent_editor_preview_text(_item), do: ""

  defp agent_editor_preview_delta_count(%{delta_count: count}) when is_integer(count), do: count
  defp agent_editor_preview_delta_count(_item), do: 0

  defp agent_editor_preview_highlights(%{highlights: highlights}) when is_list(highlights),
    do: highlights

  defp agent_editor_preview_highlights(_item), do: []

  defp agent_editor_preview_steps(%{preview_steps: steps}) when is_list(steps), do: steps
  defp agent_editor_preview_steps(_item), do: []

  defp agent_editor_preview_scroll(%{scroll: scroll}) when is_map(scroll) do
    %{
      scroll_top: scroll_coordinate(item_field(scroll, :scroll_top) || item_field(scroll, :top)),
      scroll_left:
        scroll_coordinate(item_field(scroll, :scroll_left) || item_field(scroll, :left))
    }
  end

  defp agent_editor_preview_scroll(_item), do: %{scroll_top: 0, scroll_left: 0}

  # Chip label: the picked snippet only. An empty element (blank paragraph,
  # image, ...) keeps the chip compact — icon + type, ref on hover — instead of
  # blowing the label up with a filename that names the document, not the pick.
  defp pick_chip_label(pick) do
    pick["text"] |> to_string() |> String.trim()
  end

  # PNG paths a doc.render tool call produced, scraped from the chip body (the
  # tool output JSON arrives escape-wrapped inside the ACP rawOutput, so a
  # direct path scan beats parsing nested JSON). Only files in the canonical
  # render scratch dir count — the preview route serves nothing else anyway.
  defp agent_item_render_files(%{title: title, body: body})
       when is_binary(title) and is_binary(body) do
    if String.contains?(title, "render") do
      ~r{(/[^"'\\\s]*?/ecrits_render/[^"'\\\s]*?\.png)}
      |> Regex.scan(body)
      |> Enum.map(fn [_, file] -> file end)
      |> Enum.uniq()
    else
      []
    end
  end

  defp agent_item_render_files(_item), do: []

  defp agent_item_status_label(%{status: :approval_required}), do: "Needs approval"

  defp agent_item_status_label(%{status: status}),
    do: status |> to_string() |> String.replace("_", " ")

  defp agent_item_status_label(_item), do: ""

  defp agent_item_class(%{role: :user}) do
    "group/message relative mt-2 flex min-w-0 w-full flex-col items-stretch gap-0.5 self-end"
  end

  defp agent_item_class(%{role: :tool}) do
    "group/message relative flex min-w-0 w-full flex-col items-stretch gap-0.5"
  end

  defp agent_item_class(%{role: :file_activity}) do
    "group/message relative flex min-w-0 w-full flex-col items-stretch gap-0.5"
  end

  defp agent_item_class(%{role: :editor_preview}) do
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

  # ── inline chat: status / placeholder labels ───────────────────────

  defp agent_status_label(:offline), do: "Offline"
  defp agent_status_label(:starting), do: "Starting"
  defp agent_status_label(:running), do: "Running"
  defp agent_status_label(:cancelled), do: "Cancelled"
  defp agent_status_label(:failed), do: "Failed"
  defp agent_status_label(_status), do: "Idle"

  defp agent_rail_title(%{title: title}) when is_binary(title) and title != "" do
    title
  end

  defp agent_rail_title(_rail), do: default_agent_title()

  defp agent_rail_meta(%{provider: provider, status: status}) do
    [provider_label(provider), agent_status_label(status)]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" / ")
  end

  defp agent_rail_meta(%{status: status}), do: agent_status_label(status)
  defp agent_rail_meta(_rail), do: agent_status_label(:idle)

  defp provider_label(provider) when is_binary(provider) and provider != "" do
    provider
  end

  defp provider_label(_provider), do: ""

  defp agent_input_placeholder(:offline), do: "Agent unavailable"
  defp agent_input_placeholder(:starting), do: "Starting agent"
  defp agent_input_placeholder(_status), do: "Ask about this workspace"

  # ── inline chat: forms / title ─────────────────────────────────────

  defp agent_form(params \\ %{"message" => ""}) do
    to_form(params, as: :agent)
  end

  defp agent_title_form(title \\ default_agent_title()) do
    to_form(%{"title" => agent_title(title)}, as: :agent_title)
  end

  defp assign_agent_title(socket, title) do
    title = agent_title(title)

    socket
    |> assign(:agent_title, title)
    |> assign(:agent_title_form, agent_title_form(title))
  end

  defp agent_title(title) when is_binary(title) do
    title |> String.trim() |> String.slice(0, 120)
  end

  defp agent_title(_title), do: ""

  defp default_agent_title, do: "New Chat"

  # ── inline chat: error mapping ─────────────────────────────────────

  defp agent_error({:codex_executable_missing, candidates}) do
    "Codex ACP unavailable. Install one of: #{Enum.join(candidates, ", ")}."
  end

  defp agent_error({:claude_executable_missing, candidates}) do
    "Claude unavailable. Install one of: #{Enum.join(candidates, ", ")}."
  end

  defp agent_error("{:codex_executable_missing" <> _reason) do
    "Codex ACP unavailable. Install codex-acp or codex, then refresh agent chat."
  end

  defp agent_error("{:claude_executable_missing" <> _reason) do
    "Claude unavailable. Install and authenticate Claude CLI, then refresh agent chat."
  end

  defp agent_error("{:unsupported_provider, \"fake\"" <> _reason) do
    "Selected provider is disabled. Choose Codex or Claude."
  end

  defp agent_error(:acp_unavailable) do
    "Local agent runtime unavailable. Refresh the workspace."
  end

  # ExMCP.ACP adapter failures arrive as inspected strings; map the common
  # provider-startup failures onto the same friendly guidance.
  defp agent_error(reason) when is_binary(reason) do
    cond do
      acp_codex_unavailable?(reason) ->
        "Codex ACP unavailable. Install codex, then refresh agent chat."

      acp_claude_unavailable?(reason) ->
        "Claude unavailable. Install and authenticate Claude CLI, then refresh agent chat."

      true ->
        reason
    end
  end

  defp agent_error(reason), do: inspect(reason)

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
