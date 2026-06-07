defmodule EcritsWeb.Local.WorkspaceLive do
  @moduledoc """
  Local workspace shell.
  """

  use EcritsWeb, :live_view

  require Logger

  alias Ecrits.Doc.Editor, as: DocEditor
  alias Ecrits.Doc.Pool, as: DocPool
  alias Ecrits.Local.AcpAgent, as: ACP
  alias Ecrits.Local.Document
  alias Ecrits.Local.Document.RhwpAdapter
  alias Ecrits.Local.Path, as: LocalPath
  alias Ecrits.Local.Workspace
  alias Ecrits.Workspace.Session, as: WorkspaceSession
  alias EcritsWeb.Components.LocalFileTree
  alias EcritsWeb.Live.Studio.Components.ChatRail
  alias EcritsWeb.Live.Studio.Components.EditorSurface
  alias EcritsWeb.Local.WorkspaceAdapter

  @local_document_upload_max_size 50_000_000
  # Debounce interval for re-rendering the streaming agent message body as
  # formatted markdown (raw client-side appends give instant sub-debounce
  # feedback; the tick re-renders the accumulated buffer through MDEx).
  @local_agent_text_flush_ms 120
  # Idle window before a dirty viewed document is auto-saved. Each user/agent
  # edit (re)arms a per-document timer; when it fires and the doc is still dirty
  # we fire a canonical `doc.save` (the same path Ctrl/Cmd+S uses).
  @autosave_idle_ms 4_000
  @employment_contract_type_key "employment_v1"
  @selectable_local_agent_provider_ids ~w(codex claude)
  @local_agent_models [
    %{
      id: "gpt-5.5",
      provider: "codex",
      label: "GPT-5.5",
      description: "Frontier Codex model"
    },
    %{
      id: "gpt-5.4",
      provider: "codex",
      label: "GPT-5.4",
      description: "Balanced Codex model"
    },
    %{
      id: "gpt-5.4-mini",
      provider: "codex",
      label: "GPT-5.4 mini",
      description: "Lower token spend"
    },
    %{
      id: "gpt-5.3-codex",
      provider: "codex",
      label: "GPT-5.3 Codex",
      description: "Coding-specialized"
    },
    %{
      id: "gpt-5.3-codex-spark",
      provider: "codex",
      label: "GPT-5.3 Codex Spark",
      description: "Fast coding model"
    },
    # Claude follows Claude's own selection style: aliases, not pinned versions.
    # `--model` takes "an alias for the latest model" (claude --help), so
    # `opus`/`sonnet`/`haiku` always resolve to the newest of each family the
    # installed `claude` CLI supports — they never go stale like a pinned
    # `claude-opus-4-7`. `default` forwards no `--model` (the CLI's own
    # recommended default). To get a newer model (e.g. Opus 4.8), update the
    # `claude` CLI — no change here is needed.
    %{
      id: "default",
      provider: "claude",
      label: "Default",
      description: "Recommended — latest Claude"
    },
    %{
      id: "opus",
      provider: "claude",
      label: "Opus",
      description: "Most capable — latest Opus"
    },
    %{
      id: "sonnet",
      provider: "claude",
      label: "Sonnet",
      description: "Balanced speed and capability"
    },
    %{
      id: "haiku",
      provider: "claude",
      label: "Haiku",
      description: "Fastest, lowest cost"
    },
    %{
      id: "opusplan",
      provider: "claude",
      label: "Opus Plan",
      description: "Opus plans, Sonnet executes"
    }
  ]
  @local_agent_access_controls [
    %{
      id: "read-only",
      label: "Read only",
      approval_policy: :on_write,
      adapter_approval_policy: "on_write",
      sandbox: "read-only",
      permission_mode: "plan"
    },
    %{
      id: "ask",
      label: "Ask",
      approval_policy: :on_write,
      adapter_approval_policy: "on_write",
      sandbox: "workspace-write",
      permission_mode: "default"
    },
    %{
      id: "full-workspace",
      label: "Full workspace",
      approval_policy: :never,
      adapter_approval_policy: "never",
      sandbox: "workspace-write",
      permission_mode: "dontAsk"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     # The durable per-workspace `Ecrits.Workspace.Session` (keyed by canonical
     # path, cookieless) owns the foreground agent and survives this LiveView; a
     # refresh re-attaches in handle_params. `nil` until the first attach.
     |> assign(:workspace_session, nil)
     # NAMED captures (not anon closures): a stream `dom_id` resolver is stored on
     # the long-lived LiveView at mount. An anonymous `& &1.dom_id` is compiled
     # INTO this module, so a dev hot-reload that purges the old module version
     # while the LiveView is still alive turns it into a stale function reference
     # ("points to an old version of the code" -> BadFunctionError on the next
     # stream_insert). A remote capture `&__MODULE__.fun/1` is resolved by name at
     # call time and therefore survives recompiles.
     |> stream_configure(:local_hwp_pages, dom_id: &__MODULE__.local_hwp_page_dom_id/1)
     |> stream(:local_hwp_pages, [])
     |> stream_configure(:local_agent_items, dom_id: &__MODULE__.local_agent_item_dom_id/1)
     |> stream(:local_agent_items, [])
     # Markdown (.md/.markdown) editor: plain-text source + live MDEx preview.
     |> assign(:local_markdown_source, "")
     |> assign(:local_markdown_preview_html, "")
     |> assign(:page_title, "Workspace")
     |> assign(:workspace, nil)
     |> assign(:workspace_path, nil)
     |> assign(:tree, [])
     |> assign(:expanded_paths, MapSet.new())
     |> assign(:selected_path, nil)
     |> assign(:active_document_path, nil)
     |> assign(:active_document, nil)
     |> assign(:open_documents, [])
     |> assign(:active_document_id, nil)
     |> assign(:pool_document_id, nil)
     # Browser-backed agent edits (design §6.2): when the open HWP is registered
     # `:browser` in the Pool, the agent's doc.* edits route HERE. We push the op
     # to the WasmHwpEditor hook (authoritative WASM model) and relay its reply
     # back to the waiting MCP caller. `doc_browser_pending` maps a per-request
     # ref -> the caller pid so a hook reply finds its requester; `browser_revision`
     # is the monotonic revision the WASM model has applied (the value doc.edit
     # returns), seeded at 0 on open and bumped per applied op.
     |> assign(:doc_browser_pending, %{})
     |> assign(:browser_revision, 0)
     # Unsaved-changes tracking (LiveView is the source of truth). A document id
     # is in `dirty_document_ids` once it is touched (user edit via
     # `rhwp.text.mutated`, or an agent doc.edit/doc.set routed through the browser
     # bridge) and removed once saved (Ctrl+S/auto-save, or an agent doc.save) —
     # so the tab dot reflects user AND agent ops uniformly. `autosave_timers`
     # holds the per-document debounce timer that fires a canonical save on idle.
     |> assign(:dirty_document_ids, MapSet.new())
     |> assign(:autosave_timers, %{})
     |> assign(:fs_watcher_pid, nil)
     |> assign(:fs_refresh_timer, nil)
     # Subscribed-once flag for the agent-file-write PubSub topic
     # (`Ecrits.Doc.Tools.workspace_files_topic/0`): an agent doc.create-clone /
     # doc.save broadcasts the written path there, and we refresh the tree LIVE
     # (mid-turn) when the path is under this workspace's root.
     |> assign(:workspace_files_subscribed?, false)
     |> assign(:local_document_error, nil)
     |> assign(:local_document_status, :none)
     |> assign(:local_document_snapshot, nil)
     |> assign(:local_hwp_page_count, 0)
     |> assign(:local_hwp_stream_renderer, nil)
     |> assign(:local_hwp_stream_document_id, nil)
     |> assign(:local_hwp_stream_revision, nil)
     |> assign(:local_hwp_stream_loading?, false)
     |> assign(:last_caret, nil)
     |> assign(:workspace_error, nil)
     # The chat thread (title / status / streamed transcript / composer + queue)
     # is rendered INLINE in this single LiveView (the only LiveView for the
     # workspace). `local_agent_session_id` is the bound durable foreground-agent
     # id (set synchronously by attach_workspace_session in handle_params); it
     # both dedupes a doc-switch re-attach AND gates the chat send path here.
     |> assign(:local_agent_session_id, nil)
     |> assign(:local_agent_status, :starting)
     |> assign(:local_agent_error, nil)
     |> assign(:local_agent_turn_id, nil)
     # Count of mid-turn sends still queued behind the running turn (Phase 5 FIFO
     # queue). Drives the "N 대기" pending indicator; decremented as each queued
     # turn drains.
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
     |> assign(:local_agent_provider, local_agent_provider_display())
     |> assign(:local_agent_provider_warning, nil)
     |> assign(:local_agent_model, default_agent_model_id(default_provider_id()))
     |> assign(:local_agent_model_modal_open, false)
     |> assign(:local_agent_reasoning_effort, default_reasoning_effort())
     |> assign_local_agent_access(default_access_control())
     |> assign(:local_agent_integrations, local_agent_integrations())
     |> assign(:local_agent_options_form, local_agent_options_form())
     |> allow_upload(:local_document_import,
       accept: ~w(.hwp .hwpx .doc .docx),
       max_entries: 1,
       max_file_size: @local_document_upload_max_size,
       auto_upload: true,
       progress: &handle_local_document_upload/3
     )}
  end

  @impl true
  def handle_params(%{"path" => path} = params, _uri, socket) do
    requested_provider = Map.get(params, "provider")
    requested_model = Map.get(params, "model")
    {provider, provider_warning} = local_agent_provider_from_params(requested_provider)
    model = local_agent_model_from_params(requested_model, provider.key)
    provider = local_agent_provider_display(model.provider)
    # `model.provider` already drives `provider`, so a Claude model selected while
    # on Codex flips `provider` here — `provider_changed?` therefore captures BOTH
    # a dropdown provider switch AND a cross-provider model selection (each is a
    # genuine provider/adapter change, not a per-turn option).
    provider_changed? = provider.key != socket.assigns.local_agent_provider.key
    # Whether a foreground agent was ALREADY bound (under the OLD provider) before
    # this phase. A provider switch only RESTARTS when one already exists; the very
    # first connected attach seeds the right provider directly (no restart needed).
    had_bound_agent? = is_binary(socket.assigns.local_agent_session_id)
    model_changed? = model.id != socket.assigns.local_agent_model
    reasoning_effort = normalize_reasoning_effort(Map.get(params, "reasoning"), model.provider)
    reasoning_changed? = reasoning_effort != socket.assigns.local_agent_reasoning_effort
    access_control = normalize_access_control(Map.get(params, "access"))
    access_changed? = access_control != socket.assigns.local_agent_access_control

    socket =
      socket
      |> assign(:local_agent_provider, provider)
      |> assign(:local_agent_provider_warning, provider_warning)
      |> assign(:local_agent_model, model.id)
      |> assign(:local_agent_reasoning_effort, reasoning_effort)
      |> assign_local_agent_access(access_control)
      |> assign(:local_agent_integrations, local_agent_integrations())
      |> mount_workspace(path)
      # Attach the durable per-path workspace Session and bind its foreground
      # agent BEFORE opening the document — this is the refresh-survival seam.
      # `Session.attach` get-or-starts the path-keyed Session (cookieless), which
      # get-or-starts the foreground agent: on a browser refresh the SAME agent
      # pid / provider thread / transcript / title are re-attached, NOT recreated.
      |> attach_workspace_session()
      |> maybe_open_local_document(params)

    # A PROVIDER change (codex<->claude, or a cross-provider model selection) is
    # NOT a per-turn option: the ACP adapter is bound at start_session and cannot
    # be swapped on a running session. So when an agent is already bound under the
    # old provider, KILL it and start a fresh one (empty transcript, "New Chat"),
    # then re-bind the LiveView. SAME-provider changes (access / reasoning /
    # same-provider model) stay on the live-apply path — they preserve the
    # conversation.
    restart_for_provider? = provider_changed? and had_bound_agent? and connected?(socket)

    socket =
      if restart_for_provider? do
        restart_local_agent_for_provider(socket)
      else
        options_changed? = access_changed? or reasoning_changed? or model_changed?
        maybe_apply_live_local_agent_options(socket, options_changed?)
      end

    socket =
      if (provider_param_invalid?(requested_provider) or model_param_invalid?(requested_model)) and
           is_nil(socket.assigns.workspace_error) do
        push_patch(socket, to: workspace_provider_path(socket, provider.key))
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    # No workspace path in the URL — there is no cookie/store to restore from
    # (the path keys everything now), so send to the folder picker ("/").
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  @impl true
  def handle_event("local_agent_model_modal.open", _params, socket) do
    {:noreply, assign(socket, :local_agent_model_modal_open, true)}
  end

  def handle_event("toggle_dir", %{"path" => path}, socket) do
    expanded_paths = toggle_path(socket.assigns.expanded_paths, path)

    socket =
      socket
      |> assign(:expanded_paths, expanded_paths)
      |> refresh_tree(expanded_paths)

    {:noreply, socket}
  end

  def handle_event("select_file", %{"path" => path}, socket) do
    {:noreply, assign(socket, :selected_path, path)}
  end

  def handle_event("open_file", %{"path" => path}, socket) do
    {:noreply,
     socket
     |> assign(:selected_path, path)
     |> push_patch(to: workspace_document_path(socket, path))}
  end

  def handle_event("tab_switch", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.open_documents, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      %{path: path} ->
        {:noreply,
         socket
         |> assign(:selected_path, path)
         |> push_patch(to: workspace_document_path(socket, path))}
    end
  end

  def handle_event("tab_close", %{"id" => id}, socket) do
    {:noreply, close_open_document_tab(socket, id)}
  end

  def handle_event("rhwp.local.load", %{"document_id" => document_id}, socket) do
    with :ok <- verify_active_document(socket, document_id),
         {:ok, response} <- RhwpAdapter.load(document_id) do
      socket =
        socket
        |> assign(:active_document, document_summary(response))
        |> assign(:local_document_status, :loaded)
        |> assign(:local_document_error, nil)

      {:reply, local_load_reply(response), socket}
    else
      {:error, reason} ->
        {:reply, %{error: error_message(reason)},
         assign(socket, :local_document_error, error_message(reason))}
    end
  end

  def handle_event("rhwp.text.mutated", %{"documentId" => document_id} = params, socket) do
    with :ok <- verify_active_document(socket, document_id),
         {:ok, response} <- RhwpAdapter.record_mutation(document_id, params) do
      socket = socket |> mark_doc_dirty(document_id) |> arm_autosave(document_id)
      {:reply, %{ok: true, local: true, mutation: mutation_reply(response.mutation)}, socket}
    else
      {:error, reason} ->
        {:reply, %{error: error_message(reason)}, socket}
    end
  end

  def handle_event("rhwp.text.mutated", params, socket) do
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
  # that is blocked in `Ecrits.Doc.Tools.browser_call/4`, and for an applied edit
  # adopt the revision the WASM model reports so doc.edit returns the real value.
  def handle_event("doc.browser_reply", %{"request_id" => request_id} = params, socket) do
    case Map.pop(socket.assigns.doc_browser_pending, request_id) do
      {{from, ref, verb}, pending} ->
        result = doc_browser_result(params)
        send(from, {:doc_browser_reply, ref, result})

        socket =
          socket
          |> assign(:doc_browser_pending, pending)
          |> maybe_adopt_browser_revision(result)
          |> apply_browser_op_dirty(verb, result)

        {:noreply, socket}

      {nil, _pending} ->
        {:noreply, socket}
    end
  end

  # Ctrl/Cmd+S over the editor shell. The `phx-key="s"` filter narrows the
  # window keydown to the "s" key; the modifier check guards against a bare "s"
  # keystroke triggering a save. NOTE: a save only fires when the keydown
  # payload carries `ctrlKey`/`metaKey` — see the second clause for plain "s".
  def handle_event("rhwp_save", %{"key" => key} = params, socket)
      when key in ["s", "S"] do
    if params["ctrlKey"] || params["metaKey"] do
      {:noreply, save_active_document(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("rhwp_save", _params, socket), do: {:noreply, socket}

  def handle_event("rhwp.local.snapshot.checkpoint", params, socket) do
    persist_local_rhwp_snapshot(:checkpoint, params, socket)
  end

  def handle_event("rhwp.local.snapshot.save", params, socket) do
    persist_local_rhwp_snapshot(:save, params, socket)
  end

  # --- Markdown (.md/.markdown) editor events (from the MarkdownEditor hook) ----
  # Debounced source changes re-render the live preview; Ctrl/Cmd+S persists the
  # current source to the canonical workspace file via the file-based Document
  # persistence. Both are no-ops unless the active document is markdown, so a
  # stray client event can never crash the LiveView.

  def handle_event("markdown.source_changed", %{"source" => source}, socket)
      when is_binary(source) do
    if markdown_document_active?(socket) do
      {:noreply,
       socket
       |> assign(:local_markdown_source, source)
       |> assign(:local_markdown_preview_html, EcritsWeb.Markdown.to_safe_html(source))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("markdown.source_changed", _params, socket), do: {:noreply, socket}

  def handle_event("markdown.save", %{"source" => source}, socket) when is_binary(source) do
    with %{id: document_id} <- socket.assigns[:active_document],
         true <- markdown_document_active?(socket),
         {:ok, _document, _snapshot} <- Document.save(document_id, source) do
      # The `:local_document_saved` broadcast updates save_state + revision via
      # apply_local_document_snapshot/4; we just confirm the save to the client.
      {:noreply, push_event(socket, "markdown_saved", %{ok: true})}
    else
      {:error, reason} ->
        {:noreply,
         push_event(socket, "markdown_saved", %{ok: false, error: error_message(reason)})}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("markdown.save", _params, socket), do: {:noreply, socket}

  def handle_event("refresh_tree", _params, socket) do
    {:noreply, refresh_tree(socket, socket.assigns.expanded_paths)}
  end

  def handle_event("open_local_agent_model_modal", _params, socket) do
    {:noreply, assign(socket, :local_agent_model_modal_open, true)}
  end

  def handle_event("close_local_agent_model_modal", _params, socket) do
    {:noreply, assign(socket, :local_agent_model_modal_open, false)}
  end

  def handle_event("select_local_agent_provider", params, socket) do
    provider = local_agent_provider_param(params)

    case normalize_selectable_provider_id(provider) do
      nil ->
        {:noreply, socket}

      provider_id when provider_id == socket.assigns.local_agent_provider.key ->
        {:noreply, socket}

      provider_id ->
        {:noreply,
         push_patch(socket,
           to:
             workspace_provider_path(socket, provider_id,
               model: default_agent_model_id(provider_id)
             )
         )}
    end
  end

  def handle_event("select_local_agent_model", params, socket) do
    model_id =
      params["model"] ||
        params["value"] ||
        get_in(params, ["agent_model", "model"])

    case local_agent_model(model_id) do
      nil ->
        {:noreply, socket}

      model ->
        {:noreply,
         push_patch(socket, to: workspace_provider_path(socket, model.provider, model: model.id))}
    end
  end

  def handle_event("select_local_agent_option", params, socket) do
    case local_agent_option_param(params) do
      {"reasoning", value} ->
        select_local_agent_reasoning(value, socket)

      {"access", value} ->
        select_local_agent_access(value, socket)

      _other ->
        {:noreply, socket}
    end
  end

  def handle_event("select_local_agent_reasoning", %{"reasoning" => value}, socket) do
    select_local_agent_reasoning(value, socket)
  end

  def handle_event("select_local_agent_access", %{"access" => value}, socket) do
    select_local_agent_access(value, socket)
  end

  def handle_event("validate_local_document_upload", _params, socket) do
    {:noreply, assign_local_document_upload_errors(socket)}
  end

  # ── inline chat events ─────────────────────────────────────────────

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

  # The composer is a native form (phx-submit) so `agent[message]` is the nested
  # param shape; the colocated `.ChatInput` hook also pushEvents the same handler
  # with a flat `%{"message" => ...}` on Enter/click, so accept both.
  def handle_event("send_local_agent", %{"agent" => %{"message" => message}}, socket) do
    handle_send(socket, message)
  end

  def handle_event("send_local_agent", %{"message" => message}, socket) do
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

  @impl true
  # Foreground-agent events for the bound session drive BOTH the inline chat
  # transcript (this is the only LiveView; the chat renders here) AND, on a turn
  # terminal, the DOCUMENT-side hook (auto-save the agent's dirty docs + re-list
  # the tree — the agent may stall before its final doc.save, or have created
  # files). Apply the chat-stream update first, then layer the doc-side hook on
  # the turn-complete event.
  def handle_info({:local_agent_event, %{session_id: session_id} = event}, socket)
      when session_id == socket.assigns.local_agent_session_id do
    # Close the contiguous-reasoning run on any non-reasoning event so the NEXT
    # reasoning delta starts a fresh paragraph (codex glues reasoning items).
    socket =
      case event do
        %{type: :reasoning_delta} -> socket
        _ -> assign(socket, :local_agent_reasoning_open?, false)
      end

    socket = apply_local_agent_event(socket, event)

    socket =
      case event do
        %{type: :turn_completed} ->
          socket
          |> persist_pending_agent_docs()
          |> refresh_tree(socket.assigns.expanded_paths)

        _ ->
          socket
      end

    {:noreply, socket}
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

  def handle_info({:rhwp_positional_index_request, request}, socket) do
    selected_document_id = active_document_id(socket)
    request_id = rhwp_request_value(request, ["request_id", :request_id])
    requested_document_id = rhwp_request_value(request, ["document_id", :document_id])
    min_revision = rhwp_request_value(request, ["min_revision", :min_revision])
    text_events = rhwp_request_value(request, ["text_events", :text_events]) || []
    base_snapshot = rhwp_request_value(request, ["base_snapshot", :base_snapshot])
    document_id = requested_document_id || selected_document_id

    cond do
      not is_binary(request_id) or request_id == "" ->
        {:noreply, socket}

      not is_binary(selected_document_id) ->
        _ = ack_local_rhwp_snapshot_failed(request_id, document_id, :no_document)
        {:noreply, socket}

      is_binary(document_id) and document_id != selected_document_id ->
        _ = ack_local_rhwp_snapshot_failed(request_id, document_id, :document_mismatch)
        {:noreply, socket}

      true ->
        payload =
          %{
            request_id: request_id,
            document_id: selected_document_id,
            min_revision: min_revision,
            text_events: text_events
          }
          |> maybe_put_base_snapshot(base_snapshot)

        {:noreply, push_event(socket, "rhwp:positional_index.request", payload)}
    end
  end

  # Agent edit/read/find for the OPEN HWP, routed from `Ecrits.Doc.Tools` because
  # this document is `:browser`-backed in the Pool (its authority is the WASM
  # model in the viewer, not the server NIF). Push the verb to the WasmHwpEditor
  # hook and remember the caller so the hook's reply (a `doc.browser_reply`
  # client event) is relayed back to the waiting MCP process. Edits bump the
  # browser revision the hook reports back so `doc.edit` returns a real revision.
  def handle_info({:doc_browser_request, from, ref, verb, payload}, socket) do
    request_id = doc_browser_request_id(ref)

    socket =
      socket
      |> update(:doc_browser_pending, &Map.put(&1, request_id, {from, ref, verb}))
      |> push_event("doc.apply_edit", %{
        request_id: request_id,
        verb: to_string(verb),
        payload: doc_browser_payload(payload, socket)
      })

    {:noreply, socket}
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

  def handle_info({:local_document_saved, %Document{} = document, snapshot}, socket) do
    {:noreply, apply_local_document_snapshot(socket, :saved, document, snapshot)}
  end

  def handle_info({:local_document_checkpointed, %Document{} = document, snapshot}, socket) do
    {:noreply, apply_local_document_snapshot(socket, :checkpointed, document, snapshot)}
  end

  def handle_info({:file_event, pid, :stop}, %{assigns: %{fs_watcher_pid: pid}} = socket) do
    {:noreply, assign(socket, :fs_watcher_pid, nil)}
  end

  def handle_info(
        {:file_event, pid, {path, _events}},
        %{assigns: %{fs_watcher_pid: pid}} = socket
      ) do
    if fs_relevant_path?(path) do
      {:noreply, schedule_tree_refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  # Watcher events from a stale/replaced watcher are ignored.
  def handle_info({:file_event, _pid, _payload}, socket), do: {:noreply, socket}

  def handle_info(:refresh_tree, socket) do
    socket =
      socket
      |> assign(:fs_refresh_timer, nil)
      |> refresh_tree(socket.assigns.expanded_paths)
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

  @impl true
  def terminate(_reason, socket) do
    _ = unsubscribe_local_hwp_stream(socket)
    _ = unregister_local_rhwp_materializer_editor(active_document_id(socket))
    _ = stop_fs_watcher(socket)
    :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant="split">
      <main
        id="local-workspace-root"
        class="h-[calc(100dvh-60px)] min-h-0 overflow-hidden bg-[var(--cs-bg)] text-[var(--cs-ink)]"
      >
        <div
          :if={@workspace_error}
          id="local-workspace-error"
          class="mx-auto max-w-xl px-4 py-16"
        >
          <div class="rounded-md border border-error/25 bg-error/10 px-4 py-3 text-sm text-error">
            {@workspace_error}
          </div>
          <.link navigate={~p"/"} class="btn btn-ghost btn-sm mt-4">Back</.link>
        </div>

        <div
          :if={!@workspace_error}
          id="local-workspace-grid"
          phx-hook="LocalChatRailResizer"
          data-mobile-pane="chat"
          style="--local-editor-z: 0; --local-agent-rail-z: 30"
          class="isolate grid h-full min-h-0 grid-cols-1 overflow-hidden lg:grid-cols-[var(--local-file-tree-width,260px)_minmax(0,1fr)_var(--local-chat-rail-width,340px)] lg:overflow-hidden"
        >
          <aside
            id="local-file-tree-panel"
            data-component="repo-browser"
            data-local-file-tree-panel="true"
            data-collapsed="false"
            class="relative flex min-h-0 flex-col overflow-hidden border-b border-base-300 bg-base-100 max-lg:hidden lg:border-b-0 lg:border-r"
          >
            <div
              id="local-file-tree-content"
              data-role="file-tree-content"
              class="flex min-h-0 flex-1 flex-col"
            >
              <div
                data-role="repo-browser-header"
                data-action="collapse-file-tree"
                class="cursor-pointer border-b border-base-300 bg-base-100 transition-colors hover:bg-base-200/60"
              >
                <div class="flex h-11 items-center justify-between gap-2 px-3">
                  <div class="min-w-0">
                    <h1 class="truncate text-sm font-semibold text-base-content">
                      {workspace_title(@workspace)}
                    </h1>
                  </div>
                  <button
                    id="local-file-tree-hide"
                    type="button"
                    data-role="file-tree-hide"
                    aria-label="Hide file tree"
                    aria-controls="local-file-tree-content"
                    aria-expanded="true"
                    class="inline-flex size-7 shrink-0 items-center justify-center rounded text-base-content/55 transition-colors hover:bg-base-200 hover:text-base-content focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content/35"
                  >
                    <.icon name="hero-chevron-left" class="size-4" />
                  </button>
                </div>
              </div>

              <div class="max-h-[42vh] overflow-auto lg:min-h-0 lg:flex-1 lg:max-h-none">
                <LocalFileTree.tree
                  id="local-file-tree"
                  nodes={@tree}
                  expanded_paths={@expanded_paths}
                  selected_path={@selected_path}
                />
              </div>
            </div>

            <div
              id="local-file-tree-restore"
              data-role="file-tree-restore"
              class="hidden border-b border-base-300 bg-base-100 px-1.5 py-1.5 lg:border-b-0"
            >
              <button
                id="local-file-tree-show"
                type="button"
                data-role="file-tree-show"
                aria-label="Show file tree"
                aria-controls="local-file-tree-content"
                aria-expanded="false"
                class="inline-flex size-7 items-center justify-center rounded text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content/35"
              >
                <.icon name="hero-chevron-right" class="size-4" />
              </button>
            </div>

            <button
              id="local-file-tree-resizer"
              type="button"
              data-role="file-tree-resizer"
              aria-label="Resize file tree"
              class={[
                "absolute -right-1 top-0 z-10 hidden h-full w-2 cursor-col-resize touch-none select-none lg:block",
                "focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content/35",
                "before:absolute before:left-1/2 before:top-0 before:h-full before:w-px before:-translate-x-1/2",
                "before:bg-base-300 before:transition-colors before:duration-150",
                "hover:before:bg-base-content/35 data-[dragging=true]:before:bg-base-content/35"
              ]}
            >
            </button>
          </aside>

          <section
            id="local-editor-shell"
            data-local-editor-shell="true"
            class="relative z-[var(--local-editor-z)] h-full min-h-0 min-w-0 overflow-hidden bg-[var(--cs-bg)] max-lg:hidden"
          >
            <EditorSurface.local_document
              :if={@active_document || @open_documents != []}
              shell_id="local-rhwp-shell"
              toolbar_id="local-rhwp-toolbar"
              frame_id="local-rhwp-editor-frame"
              document={@active_document}
              document_spec={@active_document && local_document_spec(@active_document)}
              canvas_id={@active_document && local_rhwp_dom_id(@active_document)}
              hwp_bytes_url={
                @active_document &&
                  local_document_bytes_url(@workspace_path, @active_document.relative_path)
              }
              open_documents={@open_documents}
              active_document_id={@active_document_id}
              dirty_document_ids={@dirty_document_ids}
              hwp_pages={@streams.local_hwp_pages}
              hwp_page_count={@local_hwp_page_count}
              markdown_source={@local_markdown_source}
              markdown_preview_html={@local_markdown_preview_html}
              save_state={
                @active_document &&
                  local_save_state(
                    @active_document,
                    @local_document_snapshot,
                    @local_document_status
                  )
              }
            />

            <div :if={!@active_document && @open_documents == []} class="px-5 py-6">
              <div class="rounded-md border border-base-300 bg-base-100 p-4">
                <%= if @selected_path do %>
                  <p id="local-selected-file" class="text-sm font-medium text-base-content">
                    {@selected_path}
                  </p>
                  <p class="mt-2 text-sm text-base-content/60">
                    {selected_file_state(@selected_path, @active_document_path)}
                  </p>
                <% else %>
                  <p id="local-no-file-selected" class="text-sm text-base-content/60">
                    Select a local document from the file tree.
                  </p>
                <% end %>
              </div>
            </div>
          </section>

          <aside
            id="local-agent-sidebar"
            data-default-visible="true"
            data-session-id={@local_agent_session_id || ""}
            data-agent-status={to_string(@local_agent_status)}
            data-component="chat-rail"
            data-local-chat-rail="true"
            data-provider-key={@local_agent_provider.key}
            class="relative z-[var(--local-agent-rail-z)] flex h-full min-h-0 flex-col overflow-visible border-t border-base-300 bg-base-200 text-base-content lg:border-l lg:border-t-0"
          >
            <button
              id="local-agent-rail-resizer"
              type="button"
              data-role="chat-rail-resizer"
              aria-label="Resize chat rail"
              class={[
                "absolute -left-1 top-0 z-10 hidden h-full w-2 cursor-col-resize touch-none select-none lg:block",
                "focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content/35",
                "before:absolute before:left-1/2 before:top-0 before:h-full before:w-px before:-translate-x-1/2",
                "before:bg-base-300 before:transition-colors before:duration-150",
                "hover:before:bg-base-content/35 data-[dragging=true]:before:bg-base-content/35"
              ]}
            >
            </button>

            <p
              :if={@local_agent_provider_warning}
              id="local-agent-provider-warning"
              class="border-b border-warning/20 bg-warning/10 px-3 py-2 text-xs leading-5 text-warning"
            >
              {@local_agent_provider_warning}
            </p>

            <%!-- The chat thread + composer + queue + title are rendered INLINE
                 in this single LiveView (the only LiveView for the workspace).
                 The title / status controls, the streamed transcript, the error
                 banner and the composer (with the provider/model/reasoning/access
                 options EMBEDDED in the composer box, ChatGPT-style) all live
                 here. A browser refresh re-runs handle_params → re-attaches the
                 SAME durable agent → snapshot_local_agent repaints the transcript
                 + title + status + pending count. --%>
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
                  phx-submit="update_local_agent_title"
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
                          <.icon
                            name="hero-chevron-down"
                            class="size-3 shrink-0 text-base-content/45"
                          />
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
                <%!-- The composer box: the textarea + send/stop row AND the
                     embedded options row (model / 📎 attach / reasoning / access)
                     live in ONE bordered box, ChatGPT-style. The composer is a
                     native `phx-submit` form; the colocated `.ChatInput` hook adds
                     Enter-to-send / button-send UX (pushEvent) WITHOUT a native
                     submit, so a double-Enter mid-stream can never trip the parent
                     grid hook's submit guard. The options stay a SEPARATE sibling
                     form (`local-agent-provider-options`) so they never submit a
                     chat turn. --%>
                <div class="rounded border border-base-300 bg-base-100 transition-colors focus-within:border-base-content/40">
                  <.form
                    for={@local_agent_form}
                    id="local-agent-form"
                    phx-submit="send_local_agent"
                    phx-hook=".ChatInput"
                    data-role="chat-form"
                  >
                    <.input
                      field={@local_agent_form[:message]}
                      id="local-agent-input"
                      type="text"
                      autocomplete="off"
                      data-role="chat-textarea"
                      disabled={@local_agent_status in [:offline, :starting]}
                      placeholder={agent_input_placeholder(@local_agent_status)}
                      class="block h-8 w-full border-0 bg-transparent px-3 py-1 text-[13px] leading-snug text-base-content outline-none placeholder:text-base-content/35 focus:outline-none focus:ring-0 disabled:cursor-not-allowed disabled:text-base-content/40"
                    />
                    <div class="flex items-center justify-end gap-1 px-2 pb-1.5 pt-0.5">
                      <%!-- 📎 attach sits next to Send; its hidden file input stays
                           in the options form below (upload phx-change binding). --%>
                      <label
                        id="local-agent-upload"
                        data-role="chat-upload"
                        for={@uploads.local_document_import.ref}
                        class="inline-flex size-6 shrink-0 cursor-pointer items-center justify-center rounded text-base-content/45 transition-colors hover:text-base-content"
                        aria-label="Open local document"
                      >
                        <.icon name="hero-paper-clip" class="size-3.5" />
                      </label>
                      <button
                        :if={@local_agent_status == :running}
                        id="local-agent-submit"
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
                  </.form>

                  <.form
                    for={@local_agent_options_form}
                    id="local-agent-provider-options"
                    phx-change="validate_local_document_upload"
                    data-role="provider-options"
                    data-selected-provider={@local_agent_provider.key}
                    data-selected-model={@local_agent_model}
                    data-selected-reasoning={@local_agent_reasoning_effort}
                    data-selected-access={@local_agent_access_control}
                    class="flex min-w-0 flex-wrap items-center gap-1 border-t border-base-300 px-2 py-1.5 text-[11px] leading-5 text-base-content/60"
                  >
                    <div class="block min-w-0 shrink-0">
                      <span class="sr-only">Model</span>
                      <details
                        id="local-agent-model-select"
                        data-role="agent-model-select"
                        data-selected-provider={@local_agent_provider.key}
                        data-selected-model={@local_agent_model}
                        class="group relative inline-block min-w-0 max-w-32 align-top"
                      >
                        <summary class="inline-flex h-7 max-w-32 min-w-0 cursor-pointer list-none items-center justify-between gap-1 rounded border border-base-300 bg-base-100 px-1.5 text-left text-[11px] text-base-content transition-colors hover:border-base-content/25 marker:hidden">
                          <img
                            src={@local_agent_provider.favicon_src}
                            data-role="agent-model-provider-favicon"
                            aria-hidden="true"
                            alt=""
                            class="size-3.5 shrink-0 opacity-85 [[data-theme=studio-dark]_&]:invert"
                          />
                          <span class="min-w-0 truncate">
                            {local_agent_selected_model_label(@local_agent_model)}
                          </span>
                          <.icon
                            name="hero-chevron-down"
                            class="size-3 shrink-0 text-base-content/50"
                          />
                        </summary>
                        <div
                          data-role="agent-model-menu"
                          class="absolute bottom-8 left-0 z-40 max-h-[min(24rem,calc(100vh-8rem))] w-[min(17rem,calc(100vw-2rem))] max-w-[calc(var(--local-chat-rail-width,340px)-2rem)] overflow-y-auto rounded border border-base-300 bg-base-100 py-1 text-xs shadow-sm"
                        >
                          <button
                            :for={model <- local_agent_models_for_provider(@local_agent_provider.key)}
                            id={"local-agent-inline-model-#{model.id}"}
                            type="button"
                            phx-click="select_local_agent_model"
                            phx-value-model={model.id}
                            data-role="agent-model-option"
                            data-model={model.id}
                            data-provider={model.provider}
                            data-selected={to_string(@local_agent_model == model.id)}
                            title={model.description}
                            class={[
                              "flex w-full items-start justify-between gap-2 px-2 py-1.5 text-left transition-colors hover:bg-base-200/70",
                              if(@local_agent_model == model.id,
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
                              :if={@local_agent_model == model.id}
                              name="hero-check"
                              class="size-3.5 shrink-0 text-base-content/65"
                            />
                          </button>
                          <div class="my-1 border-t border-base-300" />
                          <button
                            id="local-agent-go-to-provider"
                            type="button"
                            phx-click="local_agent_model_modal.open"
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
                      upload={@uploads.local_document_import}
                      class="sr-only"
                      data-role="local-document-upload-file-input"
                    />
                    <details
                      id="local-agent-reasoning-select"
                      data-role="provider-reasoning-select"
                      data-selected-reasoning={@local_agent_reasoning_effort}
                      class="group relative min-w-0 max-w-28"
                    >
                      <summary class="inline-flex h-6 min-w-0 max-w-28 cursor-pointer list-none items-center justify-between gap-1 rounded border border-base-300 bg-base-100 px-1.5 text-[11px] text-base-content transition-colors hover:border-base-content/25 marker:hidden">
                        <span class="min-w-0 truncate">
                          {local_agent_reasoning_short_label(@local_agent_reasoning_effort)}
                        </span>
                        <.icon
                          name="hero-chevron-down"
                          class="size-2.5 shrink-0 text-base-content/45"
                        />
                      </summary>
                      <div class="absolute bottom-7 right-0 z-40 w-52 rounded border border-base-300 bg-base-100 py-1 text-xs shadow-sm">
                        <button
                          :for={effort <- local_agent_reasoning_efforts(@local_agent_provider.key)}
                          id={"local-agent-inline-reasoning-#{effort}"}
                          type="button"
                          phx-click="select_local_agent_reasoning"
                          phx-value-reasoning={effort}
                          data-role="provider-reasoning-option"
                          data-value={effort}
                          data-selected={to_string(@local_agent_reasoning_effort == effort)}
                          title={local_agent_reasoning_title(effort)}
                          class={[
                            "flex h-8 w-full items-center justify-between gap-2 px-2 text-left transition-colors hover:bg-base-200/70",
                            if(@local_agent_reasoning_effort == effort,
                              do: "text-base-content",
                              else: "text-base-content/70"
                            )
                          ]}
                        >
                          <span class="min-w-0 flex-1 truncate">{local_agent_reasoning_label(effort)}</span>
                          <.icon
                            :if={@local_agent_reasoning_effort == effort}
                            name="hero-check"
                            class="size-3.5 shrink-0 text-base-content/65"
                          />
                        </button>
                      </div>
                    </details>
                    <details
                      id="local-agent-access-select"
                      data-role="agent-access-control"
                      data-selected-access={@local_agent_access_control}
                      class="group relative min-w-0 max-w-36"
                    >
                      <summary class="inline-flex h-7 min-w-0 max-w-36 cursor-pointer list-none items-center justify-between gap-1 rounded border border-base-300 bg-base-100 px-1.5 text-xs text-base-content transition-colors hover:border-base-content/25 marker:hidden">
                        <span class="min-w-0 truncate">
                          {local_agent_access_control(@local_agent_access_control).label}
                        </span>
                        <.icon name="hero-chevron-down" class="size-3 shrink-0 text-base-content/45" />
                      </summary>
                      <div class="absolute bottom-8 right-0 z-20 w-40 rounded border border-base-300 bg-base-100 py-1 text-xs shadow-sm">
                        <button
                          :for={access <- local_agent_access_controls()}
                          id={"local-agent-inline-access-#{access.id}"}
                          type="button"
                          phx-click="select_local_agent_access"
                          phx-value-access={access.id}
                          data-role="agent-access-option"
                          data-access={access.id}
                          data-selected={to_string(@local_agent_access_control == access.id)}
                          title={local_agent_access_title(access)}
                          class={[
                            "flex h-8 w-full items-center justify-between gap-2 px-2 text-left transition-colors hover:bg-base-200/70",
                            if(@local_agent_access_control == access.id,
                              do: "text-base-content",
                              else: "text-base-content/70"
                            )
                          ]}
                        >
                          <span class="whitespace-nowrap">{access.label}</span>
                          <.icon
                            :if={@local_agent_access_control == access.id}
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
                :if={@local_agent_model_modal_open}
                id="local-agent-model-modal"
                class="fixed inset-0 z-50"
                role="dialog"
                aria-modal="true"
                aria-labelledby="local-agent-model-modal-title"
                phx-window-keydown="close_local_agent_model_modal"
                phx-key="Escape"
              >
                <div
                  id="local-agent-model-modal-backdrop"
                  class="absolute inset-0 bg-base-content/20"
                  phx-click="close_local_agent_model_modal"
                />
                <div class="relative mx-3 mt-20 max-w-[420px] rounded-md border border-base-300 bg-base-100 shadow-sm sm:mx-auto">
                  <header class="flex h-10 items-center justify-between border-b border-base-300 px-3">
                    <h3
                      id="local-agent-model-modal-title"
                      class="text-sm font-semibold text-base-content"
                    >
                      Provider config
                    </h3>
                    <button
                      id="local-agent-model-modal-close"
                      type="button"
                      phx-click="close_local_agent_model_modal"
                      aria-label="Close provider config"
                      class="inline-flex size-7 items-center justify-center rounded text-base-content/55 transition-colors hover:bg-base-200 hover:text-base-content focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content/35"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </header>
                  <div class="divide-y divide-base-300 px-3 py-1">
                    <button
                      :for={provider <- local_agent_provider_details(@local_agent_integrations)}
                      id={"local-agent-model-detail-#{provider.id}"}
                      type="button"
                      phx-click="select_local_agent_provider"
                      phx-value-provider={provider.id}
                      data-provider={provider.id}
                      data-selected={to_string(provider.id == @local_agent_provider.key)}
                      data-status={to_string(provider.status)}
                      aria-pressed={to_string(provider.id == @local_agent_provider.key)}
                      class={[
                        "flex w-full items-center justify-between gap-3 py-2 text-left text-sm transition-colors hover:bg-base-200/60 focus:outline-none focus-visible:ring-1 focus-visible:ring-base-content/25",
                        provider.id == @local_agent_provider.key && "text-base-content",
                        provider.id != @local_agent_provider.key && "text-base-content/75"
                      ]}
                    >
                      <div class="flex min-w-0 items-center gap-2">
                        <img
                          src={provider.favicon_src}
                          alt=""
                          class="size-4 shrink-0 opacity-85 [[data-theme=studio-dark]_&]:invert"
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
                  </div>
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
                    if (!value || !value.trim()) {
                      // Empty Enter: still notify the server so a re-Enter can
                      // FLUSH the head of the FIFO queue (Phase 5).
                      this.pushEvent("send_local_agent", { message: "" })
                      return
                    }
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

                  // Swallow the native submit (the hook is the single source of
                  // truth for sending); without this a real submit would also fire
                  // the form's phx-submit and double the user bubble.
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
          </aside>
        </div>
      </main>
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

  defp do_mount_workspace(socket, path) do
    case WorkspaceAdapter.mount(path) do
      {:ok, workspace} ->
        socket
        |> assign(:workspace, workspace)
        |> assign(:workspace_path, workspace_root_path(workspace))
        |> assign(:tree, Map.get(workspace, :tree, []))
        |> assign(:workspace_error, nil)
        |> assign(:page_title, workspace_title(workspace))
        |> maybe_start_fs_watcher()
        |> maybe_subscribe_workspace_files()

      {:error, _reason} ->
        # Workspace failed to mount (bad / inaccessible path) — send the user
        # back to the folder picker ("/") rather than a dead-end error page.
        socket
        |> unsubscribe_local_hwp_stream()
        |> assign(:workspace_path, nil)
        |> assign(:active_document, nil)
        |> assign(:active_document_path, nil)
        |> clear_local_hwp_pages()
        |> push_navigate(to: ~p"/")
    end
  end

  defp maybe_open_local_document(%{assigns: %{workspace_error: error}} = socket, _params)
       when is_binary(error),
       do: socket

  defp maybe_open_local_document(socket, %{"document" => path})
       when is_binary(path) and path != "" do
    open_local_document(socket, path)
  end

  defp maybe_open_local_document(socket, _params) do
    previous_document_id = active_document_id(socket)
    _ = unregister_local_rhwp_materializer_editor(previous_document_id)

    socket
    |> unsubscribe_local_hwp_stream()
    |> clear_pool_document()
    |> assign(:active_document_path, nil)
    |> assign(:active_document, nil)
    |> assign(:active_document_id, nil)
    |> assign(:local_document_status, :none)
    |> assign(:local_document_snapshot, nil)
    |> clear_local_hwp_pages()
    |> maybe_restart_local_agent_for_document(previous_document_id)
  end

  defp open_local_document(%{assigns: %{workspace: nil}} = socket, _path), do: socket

  defp open_local_document(socket, path) do
    socket
    |> upsert_open_document_tab(path)
    |> do_open_local_document(path)
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

  defp tab_id(path), do: dom_token(path)

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
        remaining = List.delete_at(tabs, index)

        socket =
          socket
          |> assign(:open_documents, remaining)
          # A closed doc must never linger as dirty (and its auto-save timer
          # would otherwise fire against a doc with no open tab).
          |> mark_doc_clean(id)

        cond do
          not active? ->
            socket

          remaining == [] ->
            socket
            |> tear_down_active_local_document()
            |> assign(:active_document_id, nil)
            |> assign(:selected_path, nil)
            |> push_patch(to: workspace_no_document_path(socket))

          true ->
            neighbor = Enum.at(remaining, min(index, length(remaining) - 1))

            socket
            |> assign(:active_document_id, neighbor.id)
            |> assign(:selected_path, neighbor.path)
            |> push_patch(to: workspace_document_path(socket, neighbor.path))
        end
    end
  end

  # Close streams/handles for the currently active document, mirroring the
  # teardown that `maybe_open_local_document/2` performs on empty navigation.
  defp tear_down_active_local_document(socket) do
    previous_document_id = active_document_id(socket)
    _ = unregister_local_rhwp_materializer_editor(previous_document_id)

    socket
    |> unsubscribe_local_hwp_stream()
    |> clear_pool_document()
    |> assign(:active_document_path, nil)
    |> assign(:active_document, nil)
    |> assign(:local_document_status, :none)
    |> assign(:local_document_snapshot, nil)
    |> assign(:local_document_error, nil)
    |> clear_local_hwp_pages()
  end

  defp do_open_local_document(socket, path) do
    root = workspace_root_path(socket.assigns.workspace)
    previous_document_id = active_document_id(socket)

    case Document.open(root, path) do
      {:ok, %Document{} = document} ->
        if connected?(socket) do
          :ok = Document.subscribe(document.id)
          update_local_rhwp_materializer_editor(previous_document_id, document.id)
        end

        socket =
          socket
          |> assign(:selected_path, document.relative_path)
          |> assign(:active_document_path, document.relative_path)
          |> assign(:active_document, document_summary(document))
          |> assign(:local_document_status, :opened)
          |> assign(:local_document_snapshot, nil)
          |> assign(:local_document_error, nil)
          |> register_pool_document(document)
          |> render_local_document_pages(document)

        maybe_restart_local_agent_for_document(socket, previous_document_id)

      {:error, reason} ->
        _ = unregister_local_rhwp_materializer_editor(previous_document_id)

        socket
        |> clear_pool_document()
        |> unsubscribe_local_hwp_stream()
        |> assign(:selected_path, path)
        |> assign(:active_document_path, nil)
        |> assign(:active_document, nil)
        |> assign(:local_document_status, :error)
        |> assign(:local_document_error, error_message(reason))
        |> clear_local_hwp_pages()
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
        # Register THIS LiveView as the human viewer of the doc in the workspace
        # Session (the real home of `viewers` since Phase 3) so the agent's doc.*
        # edits route to the WASM model the user is viewing (design §6.2) instead
        # of a divergent server NIF copy. attach_viewer is only meaningful for a
        # connected viewer (the hook lives in the browser); on the dead static
        # render we leave the doc `:server`-backed. There is NO global active doc
        # anymore — the agent's active doc is its own `pool_document_id`, applied
        # live via `maybe_restart_local_agent_for_document`.
        if connected?(socket), do: attach_session_viewer(socket, doc_id)

        socket
        |> assign(:pool_document_id, doc_id)
        |> assign(:browser_revision, 0)
        |> assign(:doc_browser_pending, %{})

      {:error, _reason} ->
        # Pool registration is best-effort: a backend open failure must not
        # break the viewer. The agent simply won't have a handle for this doc.
        clear_pool_document(socket)
    end
  end

  # Office formats (docx/pptx) — a VIEWED office doc has a browser-WASM authority
  # arm too (the `WasmOfficeEditor` hook's LibreOffice->WASM model, O5b), exactly
  # like the HWP clause above. Register THIS connected LiveView as the viewer so
  # the agent's doc.* edits route to the WASM model the user is viewing (the hook
  # applies them via getElements/uno_apply/uno_set/saveToBytes) instead of the
  # divergent server NIF copy. On the dead static render we register no viewer, so
  # a doc opened headlessly (no viewer) still falls back to the Ecrits.Doc.Office
  # libreofficex NIF arm — that COLD path is unchanged.
  defp register_pool_document(socket, %Document{path: path, format: format})
       when format in ["docx", "pptx"] do
    kind = String.to_existing_atom(format)

    case DocPool.open(path, kind: kind) do
      {:ok, doc_id} ->
        if connected?(socket), do: attach_session_viewer(socket, doc_id)

        socket
        |> assign(:pool_document_id, doc_id)
        |> assign(:browser_revision, 0)
        |> assign(:doc_browser_pending, %{})

      {:error, _reason} ->
        clear_pool_document(socket)
    end
  end

  defp register_pool_document(socket, %Document{}), do: clear_pool_document(socket)

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
    assign(socket, :pool_document_id, nil)
  end

  defp clear_pool_document(socket), do: assign(socket, :pool_document_id, nil)

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

  # Augment the verb payload with the doc id + the revision the WASM model should
  # report after applying, so the hook can echo a monotonic revision back. Values
  # cross the wire as JSON, so keyword lists (e.g. doc.read's `opts`) are coerced
  # into plain maps the client (and Jason) can serialise.
  defp doc_browser_payload(payload, socket) do
    payload
    |> Map.put(:document_id, socket.assigns[:pool_document_id])
    |> Map.put(:base_revision, socket.assigns[:browser_revision])
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

  # An applied edit carries a revision from the WASM model; adopt it as the
  # authoritative browser revision (monotonic, what doc.edit returns).
  defp maybe_adopt_browser_revision(socket, {:ok, %{"revision" => rev}}) when is_integer(rev),
    do: assign(socket, :browser_revision, rev)

  defp maybe_adopt_browser_revision(socket, _result), do: socket

  # Attach this LiveView to the durable per-workspace `Ecrits.Workspace.Session`
  # (keyed by canonical path) and START + SEED its foreground agent. This is the
  # ONLY LiveView for the workspace: it holds the provider/model/access +
  # open-document seed, starts the agent, subscribes to it, and renders the chat
  # inline. On a browser refresh the SAME agent pid / provider thread / transcript
  # / title are re-bound, NEVER recreated; this LiveView re-mounts, finds the
  # bound agent and `snapshot_local_agent/3` repaints the transcript. The static
  # (disconnected) render spawns nothing.
  defp attach_workspace_session(%{assigns: %{workspace_error: error}} = socket)
       when is_binary(error),
       do: socket

  defp attach_workspace_session(socket) do
    path = socket.assigns.workspace_path

    cond do
      not connected?(socket) ->
        socket

      not (is_binary(path) and path != "") ->
        socket

      true ->
        do_attach_workspace_session(socket, path)
    end
  end

  defp do_attach_workspace_session(socket, path) do
    case safe_attach_workspace_session(path, local_agent_attach_settings(socket)) do
      {:ok, %{agent_id: agent_id} = ws} when is_binary(agent_id) ->
        # Subscribe + snapshot ONCE per foreground agent. This LiveView is the
        # ONLY LiveView for the workspace and renders the chat inline, so it both
        # drives the document-side turn-end hook AND repaints the chat transcript.
        # A doc switch re-runs handle_params with the SAME agent — don't
        # double-subscribe (it would deliver every event twice) or re-snapshot
        # (it would wipe the live transcript). Snapshot only on a FRESH bind (the
        # initial mount / a browser refresh), which repaints the durable
        # transcript + title + status + pending count (refresh-survival).
        if socket.assigns.local_agent_session_id != agent_id do
          :ok = WorkspaceSession.subscribe(ws)
          snapshot_local_agent(socket, ws, agent_id)
        else
          socket
          |> assign(:workspace_session, ws)
          |> assign(:local_agent_session_id, agent_id)
        end

      {:error, _reason, _ws} ->
        socket

      {:error, _reason} ->
        socket
    end
  end

  # Bind + repaint the inline chat from the durable foreground agent's
  # display-only snapshot (initial bind / browser refresh). codex `thread/resume`
  # restores MEMORY but does NOT re-stream past messages, so without this the
  # re-attached pane is blank — repaint the prior bubbles from the transcript.
  defp snapshot_local_agent(socket, ws, agent_id) do
    snapshot = WorkspaceSession.snapshot(ws)

    socket
    |> assign(:workspace_session, ws)
    |> assign(:local_agent_session_id, agent_id)
    |> assign(:local_agent_error, nil)
    |> assign(:local_agent_status, snapshot.status)
    # Restore the pending-queue count after a refresh (Phase 5). A snapshot from a
    # pre-Phase-5 agent has no `:pending` key → default 0.
    |> assign(:local_agent_pending, Map.get(snapshot, :pending, 0))
    |> maybe_restore_agent_title(snapshot.title)
    |> stream(:local_agent_items, [], reset: true)
    |> replay_local_agent_transcript(snapshot.transcript)
  end

  # GENUINE restart of the foreground agent on a PROVIDER switch (codex<->claude,
  # or a cross-provider model selection). The ACP adapter is bound at the agent's
  # start and cannot be swapped on a running session, so we TERMINATE the current
  # agent and START a fresh one (new adapter + the now-updated provider/model/
  # access settings), then re-bind the LiveView to a genuinely-new, EMPTY session:
  #   * the path-keyed agent id is unchanged, so the LiveView's existing PubSub
  #     subscription to `local_agent:<id>` still routes the NEW agent's events —
  #     we must NOT re-subscribe (that would double-deliver every event); and
  #   * the transcript is CLEARED, title reset to "New Chat", queue/pending/turn/
  #     error cleared — no chat-log replay across providers.
  defp restart_local_agent_for_provider(socket) do
    path = socket.assigns.workspace_path

    case safe_restart_foreground(path, local_agent_attach_settings(socket)) do
      {:ok, %{agent_id: agent_id} = ws} when is_binary(agent_id) ->
        socket
        |> assign(:workspace_session, ws)
        |> assign(:local_agent_session_id, agent_id)
        |> assign(:local_agent_error, nil)
        |> assign(:local_agent_status, :idle)
        |> assign(:local_agent_pending, 0)
        |> assign(:local_agent_turn_id, nil)
        |> assign(:local_agent_text, "")
        |> assign(:local_agent_text_segment, 0)
        |> assign(:local_agent_reasoning_text, "")
        |> assign(:local_agent_reasoning_open?, false)
        |> assign(:local_agent_active_tools, %{})
        |> assign(:local_agent_title_user_edited?, false)
        |> assign_local_agent_title(default_local_agent_title())
        |> assign(:local_agent_form, local_agent_form())
        |> stream(:local_agent_items, [], reset: true)

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

  # Settings used to SEED the foreground agent on first attach (later attaches
  # re-use the agent and these are applied live). Mirrors local_agent_session_opts
  # minus the explicit `:id` (the Session derives the stable foreground id).
  defp local_agent_attach_settings(socket) do
    socket
    |> local_agent_session_opts()
    |> Keyword.delete(:id)
  end

  # Apply per-turn option changes (access/reasoning/model/provider) to the LIVE
  # foreground agent without recreating it, preserving the conversation. No agent
  # bound yet -> nothing to do (the first attach seeds these from the assigns).
  defp maybe_apply_live_local_agent_options(socket, false), do: socket

  defp maybe_apply_live_local_agent_options(
         %{assigns: %{workspace_session: %{} = ws}} = socket,
         true
       ) do
    workspace_path = workspace_root_path(socket.assigns.workspace || %{})

    _ =
      WorkspaceSession.update_options(
        ws,
        local_agent_provider_adapter_opts(socket, workspace_path)
      )

    socket
  end

  defp maybe_apply_live_local_agent_options(socket, _changed?), do: socket

  # Turn-completion auto-save safety net. The agent may stall/stop BEFORE its
  # final `doc_save` (observed with codex/gpt-5.5 on "make a worksheet …"),
  # leaving in-memory edits that never reach disk — so the file the user opens
  # stays the unedited template. On turn end we persist any server-backed pooled
  # doc that is *dirty* (current revision > last-saved) AND carries a real
  # save-target path (the created/cloned/headless worksheet case). It is
  # idempotent: a turn that already `doc_save`d leaves nothing dirty -> no-op.
  # `Pool.dirty_docs/1` already excludes browser-backed (viewed) docs, so a doc
  # the agent did not edit through the server Editor is never auto-overwritten.
  defp persist_pending_agent_docs(socket) do
    case safe_dirty_docs() do
      [] ->
        socket

      docs ->
        saved =
          Enum.reduce(docs, [], fn doc, acc ->
            case auto_save_doc(doc) do
              :ok -> [doc.path | acc]
              :error -> acc
            end
          end)

        case saved do
          [] -> socket
          paths -> after_auto_save(socket, Enum.reverse(paths))
        end
    end
  end

  defp safe_dirty_docs do
    DocPool.dirty_docs()
  rescue
    error ->
      Logger.warning("auto-save: dirty_docs enumeration failed: #{inspect(error)}")
      []
  catch
    :exit, reason ->
      Logger.warning("auto-save: dirty_docs enumeration exited: #{inspect(reason)}")
      []
  end

  defp auto_save_doc(%{editor: editor, kind: kind, path: path}) do
    case DocEditor.save(editor, format: auto_save_format(kind), path: path) do
      :ok ->
        Logger.info("auto-save: persisted dirty doc to #{path} on turn end")
        :ok

      {:ok, _} ->
        Logger.info("auto-save: persisted dirty doc to #{path} on turn end")
        :ok

      {:error, reason} ->
        Logger.warning("auto-save: failed to persist #{path}: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.warning("auto-save: exception persisting doc: #{inspect(error)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("auto-save: editor exited while persisting: #{inspect(reason)}")
      :error
  end

  defp auto_save_format(:hwpx), do: :hwpx
  defp auto_save_format(_kind), do: :hwp

  # NOTE: the tree refresh that used to live here moved to the `:turn_completed`
  # handler, which now ALWAYS re-lists after persist_pending_agent_docs/1 (so a
  # turn that created+saved its own file — leaving nothing dirty here — still
  # refreshes). This callback just surfaces the auto-save flash.
  defp after_auto_save(socket, paths) do
    put_flash(
      socket,
      :info,
      "Saved #{length(paths)} document#{if length(paths) == 1, do: "", else: "s"} the agent left unsaved."
    )
  end

  defp handle_local_document_upload(:local_document_import, entry, socket) do
    if entry.done? do
      socket
      |> import_local_document_entry(entry)
      |> case do
        {:ok, socket} ->
          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, :local_document_error, error_message(reason))}
      end
    else
      {:noreply, socket}
    end
  end

  defp import_local_document_entry(%{assigns: %{workspace: nil}}, _entry),
    do: {:error, :workspace_not_mounted}

  defp import_local_document_entry(socket, entry) do
    root = workspace_root_path(socket.assigns.workspace)

    case consume_uploaded_entry(socket, entry, fn %{path: path} ->
           {:ok, import_local_document_file(root, path, entry.client_name)}
         end) do
      {:ok, relative_path} ->
        to = workspace_document_path(socket, relative_path)

        socket =
          socket
          |> assign(:local_document_error, nil)
          |> refresh_tree(socket.assigns.expanded_paths)
          |> push_patch(to: to)

        {:ok, socket}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp import_local_document_file(root, source_path, client_name) do
    with {:ok, relative_path} <- unique_local_import_path(root, client_name),
         {:ok, bytes} <- File.read(source_path),
         {:ok, _format} <- Document.detect_format(relative_path, bytes),
         :ok <- Workspace.write_file(root, relative_path, bytes) do
      {:ok, relative_path}
    end
  end

  defp unique_local_import_path(root, client_name) do
    with {:ok, base_name} <- local_import_base_name(client_name),
         {:ok, _format} <- Document.detect_format(base_name) do
      0..999
      |> Enum.reduce_while(nil, fn index, _acc ->
        candidate = local_import_candidate(base_name, index)

        case local_import_path_exists?(root, candidate) do
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

  defp local_import_base_name(client_name) when is_binary(client_name) do
    client_name
    |> Path.basename()
    |> String.trim()
    |> case do
      value when value in ["", ".", ".."] -> {:error, :invalid_path}
      value -> {:ok, value}
    end
  end

  defp local_import_base_name(_client_name), do: {:error, :invalid_path}

  defp local_import_candidate(base_name, 0), do: base_name

  defp local_import_candidate(base_name, index) do
    extension = Path.extname(base_name)
    stem = Path.rootname(base_name)

    "#{stem}-#{index + 1}#{extension}"
  end

  defp local_import_path_exists?(root, relative_path) do
    with {:ok, path} <- LocalPath.join(root, relative_path) do
      {:ok, File.exists?(path)}
    end
  end

  defp assign_local_document_upload_errors(socket) do
    case local_document_upload_errors(socket) do
      [] -> socket
      errors -> assign(socket, :local_document_error, local_document_upload_error(errors))
    end
  end

  defp local_document_upload_errors(socket) do
    upload = socket.assigns.uploads.local_document_import

    Phoenix.Component.upload_errors(upload) ++
      Enum.flat_map(upload.entries, &Phoenix.Component.upload_errors(upload, &1))
  end

  defp local_document_upload_error([:not_accepted | _errors]), do: "Select a supported document."
  defp local_document_upload_error([:too_large | _errors]), do: "Selected file is too large."
  defp local_document_upload_error([:too_many_files | _errors]), do: "Select one file at a time."
  defp local_document_upload_error([_error | _errors]), do: "Local document import failed."

  defp local_agent_session_opts(socket) do
    workspace = socket.assigns.workspace || %{}
    workspace_path = workspace_root_path(workspace)
    local_agent_ui = Application.get_env(:ecrits, :local_agent_ui, [])

    adapter_opts =
      local_agent_ui
      |> Keyword.get(:adapter_opts, [])
      |> Keyword.merge(local_agent_provider_adapter_opts(socket, workspace_path))

    local_agent_ui
    |> Keyword.put(:provider, socket.assigns.local_agent_provider.key)
    |> Keyword.put(:approval_policy, socket.assigns.local_agent_approval_policy)
    |> Keyword.put(:access_control, socket.assigns.local_agent_access_control)
    |> Keyword.put(:adapter_opts, adapter_opts)
    |> Keyword.put(:workspace_root, workspace_path)
    |> Keyword.put(:document_path, socket.assigns.active_document_path)
    |> Keyword.put(:workspace_path, workspace_path)
    |> put_current_document_id(active_document_id(socket))
    |> put_pool_document_id(socket.assigns[:pool_document_id])

    # NOTE: no `:id` here. The durable foreground-agent id is derived from the
    # canonical workspace PATH by `Ecrits.Workspace.Session` (cookieless), so a
    # refresh re-derives the SAME id and re-attaches to the SAME agent / provider
    # thread. (local_agent_attach_settings also strips any stray :id defensively.)
  end

  defp put_current_document_id(opts, document_id)
       when is_binary(document_id) and document_id != "",
       do: Keyword.put(opts, :document_id, document_id)

  defp put_current_document_id(opts, _document_id), do: opts

  # The agent's doc.* ACTIVE doc is the `Ecrits.Doc.Pool` id (what doc.context
  # returns and doc.edit/doc.open target), distinct from the LiveView document_id.
  # register_pool_document stores it in :pool_document_id; seed/forward it so the
  # agent's tool context points at the doc this viewer opened.
  defp put_pool_document_id(opts, pool_document_id)
       when is_binary(pool_document_id) and pool_document_id != "",
       do: Keyword.put(opts, :pool_document_id, pool_document_id)

  defp put_pool_document_id(opts, _pool_document_id), do: opts

  # Selecting/opening a document must NOT recreate the agent (that would wipe the
  # chat-rail conversation). The active document is per-turn context, so apply it
  # LIVE to the foreground agent; the next turn's doc.* tools then target the
  # now-active document. The foreground agent is already bound by
  # attach_workspace_session (run earlier in handle_params), so this only nudges
  # the document_id when it actually changed.
  defp maybe_restart_local_agent_for_document(socket, previous_document_id) do
    current_document_id = active_document_id(socket)

    cond do
      not connected?(socket) ->
        socket

      previous_document_id == current_document_id ->
        socket

      not match?(%{}, socket.assigns.workspace_session) ->
        socket

      true ->
        # Follow BOTH the LiveView document_id (provider prompt context) and the
        # Pool document id (the doc.* tools' active doc) so the agent's tool
        # context tracks what the user is now viewing. nil pool id (e.g. a
        # Markdown file with no Pool backend) clears the agent's active doc.
        _ =
          WorkspaceSession.update_options(socket.assigns.workspace_session,
            document_id: current_document_id,
            pool_document_id: socket.assigns[:pool_document_id]
          )

        socket
    end
  end

  defp local_agent_provider_adapter_opts(socket, workspace_path) do
    [
      cwd: workspace_path,
      model: local_agent_adapter_model(socket.assigns.local_agent_model),
      reasoning_effort: socket.assigns.local_agent_reasoning_effort,
      approval_policy: socket.assigns.local_agent_adapter_approval_policy,
      sandbox: socket.assigns.local_agent_sandbox,
      permission_mode: socket.assigns.local_agent_permission_mode
    ]
  end

  defp refresh_tree(%{assigns: %{workspace: nil}} = socket, _expanded_paths), do: socket

  defp refresh_tree(socket, expanded_paths) do
    case WorkspaceAdapter.list_tree(socket.assigns.workspace, expanded_paths) do
      {:ok, tree} ->
        assign(socket, :tree, tree)

      {:error, reason} ->
        # The workspace became unreadable (e.g. the folder was removed). Don't
        # strand the user on a dead-end error page — send them back to the
        # folder picker ("/"), mirroring do_mount_workspace's mount-failure path.
        socket
        |> put_flash(:error, "Workspace is no longer available: #{error_message(reason)}")
        |> push_navigate(to: ~p"/")
    end
  end

  # Start a file-system watcher for the mounted workspace root once the socket
  # is connected. Idempotent: an existing watcher is kept.
  defp maybe_start_fs_watcher(%{assigns: %{fs_watcher_pid: pid}} = socket) when is_pid(pid) do
    socket
  end

  defp maybe_start_fs_watcher(socket) do
    root = workspace_root_path(socket.assigns.workspace)

    if connected?(socket) and is_binary(root) and root != "" do
      case FileSystem.start_link(dirs: [root]) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          assign(socket, :fs_watcher_pid, pid)

        _other ->
          socket
      end
    else
      socket
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
      abs_root = Path.expand(root)
      abs_path = Path.expand(path)
      relative = Path.relative_to(abs_path, abs_root)

      relative != abs_path and relative != "." and
        not String.starts_with?(relative, "..")
    else
      false
    end
  end

  # Ignore the metadata tree, dotfiles, and editor swap files; everything else
  # is a workspace change worth re-listing.
  #
  # Exception: our own atomic-write temp files (`.<name>.tmp-<n>`, see
  # `Ecrits.Local.FS.tmp_path/1`). An atomic save writes the bytes to that hidden
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

  defp fs_relevant_path?(_path), do: false

  # Matches `Ecrits.Local.FS.tmp_path/1`: ".<basename>.tmp-<monotonic-int>".
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

        socket = assign(socket, :open_documents, kept)

        cond do
          not active_dropped? ->
            socket

          kept == [] ->
            socket
            |> tear_down_active_local_document()
            |> assign(:active_document_id, nil)
            |> assign(:selected_path, nil)

          true ->
            # Pick the tab nearest the one that vanished to keep focus stable.
            dropped_index =
              Enum.find_index(tabs, &(&1.id == active_id)) || 0

            neighbor =
              Enum.at(kept, min(dropped_index, length(kept) - 1)) || List.first(kept)

            socket
            |> assign(:active_document_id, neighbor.id)
            |> assign(:selected_path, neighbor.path)
            |> push_patch(to: workspace_document_path(socket, neighbor.path))
        end
    end
  end

  defp open_document_exists?(root, relative_path)
       when is_binary(root) and root != "" and is_binary(relative_path) do
    case LocalPath.normalize(relative_path) do
      {:ok, rel} ->
        case LocalPath.join(root, rel) do
          {:ok, absolute} -> File.exists?(absolute)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp open_document_exists?(_root, _relative_path), do: false

  defp toggle_path(expanded_paths, path) do
    if MapSet.member?(expanded_paths, path) do
      MapSet.delete(expanded_paths, path)
    else
      MapSet.put(expanded_paths, path)
    end
  end

  defp workspace_title(nil), do: "Workspace"
  defp workspace_title(workspace), do: Map.get(workspace, :title) || "Workspace"

  defp workspace_root_path(nil), do: ""
  defp workspace_root_path(workspace), do: Map.get(workspace, :root_path) || ""

  defp workspace_document_path(socket, relative_path) do
    ~p"/workspace?#{workspace_query(socket, document: relative_path, provider: socket.assigns.local_agent_provider.key)}"
  end

  defp workspace_no_document_path(socket) do
    ~p"/workspace?#{workspace_query(socket, provider: socket.assigns.local_agent_provider.key)}"
  end

  defp workspace_provider_path(socket, provider_id, overrides \\ []) do
    overrides = Keyword.put(overrides, :provider, provider_id)

    case socket.assigns.active_document_path do
      nil ->
        ~p"/workspace?#{workspace_query(socket, overrides)}"

      "" ->
        ~p"/workspace?#{workspace_query(socket, overrides)}"

      document ->
        ~p"/workspace?#{workspace_query(socket, Keyword.put(overrides, :document, document))}"
    end
  end

  defp workspace_query(socket, overrides) do
    [
      path: workspace_root_path(socket.assigns.workspace),
      provider: socket.assigns.local_agent_provider.key,
      model: socket.assigns.local_agent_model,
      reasoning: socket.assigns.local_agent_reasoning_effort,
      access: socket.assigns.local_agent_access_control
    ]
    |> Keyword.merge(overrides)
  end

  defp selected_file_state(path, active_document_path) do
    if path == active_document_path do
      "Document open affordance selected."
    else
      "Preview state only."
    end
  end

  defp error_message({:invalid_path, message}) when is_binary(message), do: message
  defp error_message({:error, message}) when is_binary(message), do: message
  defp error_message({:local_substrate_unavailable, message}) when is_binary(message), do: message
  defp error_message({:write_failed, message}) when is_binary(message), do: message
  defp error_message({:render_failed, message}) when is_binary(message), do: message

  defp error_message({:invalid_page_count, count}),
    do: "Invalid EHWP page count: #{inspect(count)}."

  defp error_message(:not_found), do: "Local document session was not found."
  defp error_message(:format_mismatch), do: "Local document format did not match."
  defp error_message(:missing_bytes), do: "Local rhwp payload did not include document bytes."
  defp error_message(:stale_revision), do: "Local document changed before this save."
  defp error_message(:unsupported_format), do: "Select a supported document."
  defp error_message(:workspace_not_mounted), do: "Workspace is not mounted."
  defp error_message(:import_name_conflict), do: "Could not choose a local import path."
  defp error_message(message) when is_binary(message), do: message
  defp error_message(_reason), do: "Workspace could not be loaded."

  defp persist_local_rhwp_snapshot(_action, %{"error" => error} = params, socket)
       when is_binary(error) do
    request_id = params["request_id"] || params["requestId"]
    document_id = params["document_id"] || active_document_id(socket)
    _ = ack_local_rhwp_snapshot_failed(request_id, document_id, error)

    {:reply, %{error: error}, assign(socket, :local_document_error, error)}
  end

  defp persist_local_rhwp_snapshot(action, params, socket) when action in [:checkpoint, :save] do
    document_id = params["document_id"] || active_document_id(socket)
    request_id = params["request_id"] || params["requestId"]

    with :ok <- verify_active_document(socket, document_id),
         {:ok, response} <- local_rhwp_persist(action, document_id, params) do
      _ = ack_local_rhwp_snapshot_committed(request_id, document_id, response)

      socket =
        socket
        |> assign(:active_document, document_summary(response))
        |> assign(:local_document_status, action_status(action))
        |> assign(:local_document_snapshot, response.snapshot)
        |> assign(:local_document_error, nil)
        |> maybe_clear_dirty_on_save(action, document_id)
        |> maybe_render_active_local_hwp_pages(document_id)

      {:reply,
       %{
         ok: true,
         revision: response.revision,
         format: response.format,
         snapshot: response.snapshot
       }, socket}
    else
      {:error, reason} ->
        _ = ack_local_rhwp_snapshot_failed(request_id, document_id, reason)
        error = error_message(reason)

        {:reply, %{error: error}, assign(socket, :local_document_error, error)}
    end
  end

  defp local_rhwp_persist(:checkpoint, document_id, params),
    do: RhwpAdapter.checkpoint(document_id, params)

  defp local_rhwp_persist(:save, document_id, params),
    do: RhwpAdapter.save(document_id, params)

  defp verify_active_document(socket, document_id) when is_binary(document_id) do
    if document_id == active_document_id(socket), do: :ok, else: {:error, :not_found}
  end

  defp verify_active_document(_socket, _document_id), do: {:error, :not_found}

  defp active_document_id(%{assigns: %{active_document: %{id: id}}}) when is_binary(id), do: id
  defp active_document_id(_socket), do: nil

  # --- Unsaved-changes (dirty) tracking + debounced auto-save ----------------
  # `:dirty_document_ids` (a MapSet) is the single source of truth for which
  # tabs render the "unsaved changes" dot. A doc becomes dirty on a user edit
  # (`rhwp.text.mutated`) or an agent `doc.edit`/`doc.set` routed through the
  # browser bridge, and clean on a save (Ctrl/Cmd+S, auto-save, or `doc.save`).

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
    # Fire-and-forget in a SEPARATE process: `Ecrits.Doc.Tools.call/3` for a
    # browser-backed doc sends `{:doc_browser_request, ...}` to THIS LiveView
    # pid and blocks in `receive`, so calling it inline here would deadlock.
    # The dot clears when the resulting `doc.save` round-trips back through
    # `doc.browser_reply` (verb `:save`).
    Task.start(fn ->
      Ecrits.Doc.Tools.call(%{pool: DocPool}, "doc.save", %{"document" => id})
    end)

    socket
  end

  defp action_status(:checkpoint), do: :checkpointed
  defp action_status(:save), do: :saved

  defp apply_local_document_snapshot(socket, status, %Document{id: id} = document, snapshot) do
    if id == active_document_id(socket) do
      socket
      |> assign(:active_document, document_summary(document))
      |> assign(:local_document_status, status)
      |> assign(:local_document_snapshot, snapshot)
      |> assign(:local_document_error, nil)
      |> render_local_document_pages(document)
    else
      socket
    end
  end

  defp document_summary(%Document{} = document) do
    %{
      id: document.id,
      relative_path: document.relative_path,
      format: document.format,
      revision: document.revision,
      byte_size: document.byte_size,
      sha256: document.sha256
    }
  end

  defp document_summary(response) when is_map(response) do
    %{
      id: response.document_id,
      relative_path: response.relative_path,
      format: response.format,
      revision: response.revision,
      byte_size: response[:byte_size],
      sha256: response[:sha256]
    }
  end

  defp local_load_reply(response) do
    response
    |> Map.delete(:bytes)
    |> Map.put(:bytes_base64, Base.encode64(response.bytes))
  end

  defp mutation_reply(mutation) when is_map(mutation) do
    %{
      event_id: mutation["event_id"],
      lamport: mutation["lamport"],
      revision: mutation["revision"]
    }
  end

  defp local_document_spec(%{format: "hwp"} = document) do
    %{
      key: local_document_contract_type_key(document) || "local_hwp",
      name: Path.basename(document.relative_path),
      template_hwp_path: document.relative_path
    }
  end

  defp local_document_spec(document) do
    %{
      key: local_document_contract_type_key(document) || "local_hwpx",
      name: Path.basename(document.relative_path),
      template_hwpx_path: document.relative_path
    }
  end

  defp local_document_contract_type_key(%{relative_path: relative_path})
       when is_binary(relative_path) do
    basename = Path.basename(relative_path)

    if Regex.match?(~r/^employment_v1(?:[-_.].*| \(\d+\))?\.(hwp|hwpx)$/i, basename) do
      @employment_contract_type_key
    end
  end

  defp local_document_contract_type_key(_document), do: nil

  defp local_rhwp_dom_id(%{id: id}), do: "local-rhwp-editor-#{dom_token(id)}"

  defp render_local_document_pages(socket, %Document{format: format} = document) do
    cond do
      Document.ehwp_format?(format) -> render_local_hwp_pages(socket, document)
      Document.markdown_format?(format) -> render_local_markdown(socket, document)
      true -> render_local_office_wasm(socket, document)
    end
  end

  # Markdown (.md/.markdown) is plain text — no engine, no stream, no LOK/WASM.
  # We load the canonical workspace bytes as UTF-8 source into the editable
  # textarea and render a live MDEx preview alongside it. Re-entrant on save
  # (the `:local_document_saved` broadcast re-renders), so we only reseed the
  # source when it actually differs from what's already in the editor — the
  # textarea is phx-update="ignore" anyway, so this just keeps the assign honest
  # and the preview in sync without clobbering the user's in-flight edits.
  defp render_local_markdown(socket, %Document{} = document) do
    socket =
      socket
      |> unsubscribe_local_hwp_stream()
      |> clear_local_hwp_pages()
      |> assign(:local_hwp_stream_renderer, :markdown)
      |> assign(:local_hwp_stream_document_id, document.id)
      |> assign(:local_hwp_stream_revision, document.revision)
      |> assign(:local_hwp_stream_loading?, false)

    source =
      case Document.read(document.id) do
        {:ok, bytes} when is_binary(bytes) -> bytes
        _ -> ""
      end

    socket
    |> assign(:local_markdown_source, source)
    |> assign(:local_markdown_preview_html, EcritsWeb.Markdown.to_safe_html(source))
  end

  # HWP/HWPX now render entirely in the browser via rhwp_core WASM. The server
  # no longer rasterizes pages (the `ehwp` NIF is gone); it just tells the
  # `WasmHwpEditor` hook where to fetch the document's raw bytes, and the hook
  # does `new HwpDocument(bytes)` + renderPageToCanvas + hitTest locally.
  defp render_local_hwp_pages(socket, %Document{} = document) do
    socket =
      socket
      |> unsubscribe_local_hwp_stream()
      |> clear_local_hwp_pages()
      |> assign(:local_hwp_stream_renderer, :rhwp_wasm)
      |> assign(:local_hwp_stream_document_id, document.id)
      |> assign(:local_hwp_stream_revision, document.revision)
      |> assign(:local_hwp_stream_loading?, false)

    if connected?(socket) do
      url =
        local_document_bytes_url(socket.assigns.workspace_path, document.relative_path)

      push_event(socket, "hwp_wasm_load", %{
        url: url,
        document_id: document.id,
        revision: document.revision
      })
    else
      socket
    end
  end

  # Read-only raw-bytes URL the WasmHwpEditor hook fetches to feed rhwp_core.
  defp local_document_bytes_url(workspace_path, relative_path)
       when is_binary(workspace_path) and is_binary(relative_path) do
    "/local/document-bytes?" <>
      URI.encode_query(%{"path" => workspace_path, "document" => relative_path})
  end

  defp local_document_bytes_url(_workspace_path, _relative_path), do: nil

  # Office (docx/pptx/xlsx) rendering. Office documents render SOLELY through the
  # in-browser LibreOffice WASM editor (the `WasmOfficeEditor` hook): the server
  # only tells the hook where to fetch the raw bytes — all open/render happens
  # client-side. Mirrors the HWP `:rhwp_wasm` branch; no server stream/session.
  defp render_local_office_wasm(socket, %Document{} = document) do
    socket =
      socket
      |> unsubscribe_local_hwp_stream()
      |> clear_local_hwp_pages()
      |> assign(:local_hwp_stream_renderer, :office_wasm)
      |> assign(:local_hwp_stream_document_id, document.id)
      |> assign(:local_hwp_stream_revision, document.revision)
      |> assign(:local_hwp_stream_loading?, false)

    if connected?(socket) do
      url = local_document_bytes_url(socket.assigns.workspace_path, document.relative_path)

      push_event(socket, "office_wasm_load", %{
        url: url,
        document_id: document.id,
        revision: document.revision
      })
    else
      socket
    end
  end

  defp maybe_render_active_local_hwp_pages(socket, document_id) do
    case Document.document(document_id) do
      {:ok, %Document{} = document} -> render_local_document_pages(socket, document)
      {:error, _reason} -> socket
    end
  end

  defp clear_local_hwp_pages(socket) do
    socket
    |> assign(:local_hwp_page_count, 0)
    |> assign(:local_hwp_stream_renderer, nil)
    |> assign(:local_hwp_stream_document_id, nil)
    |> assign(:local_hwp_stream_revision, nil)
    |> assign(:local_hwp_stream_loading?, false)
    |> stream(:local_hwp_pages, [], reset: true)
  end

  # HWP/HWPX render entirely in the browser via rhwp_core WASM and office
  # documents via the LibreOffice WASM hook, so there is no server-side stream to
  # tear down. Kept as a no-op so callers (and `terminate/2`) stay uniform.
  defp unsubscribe_local_hwp_stream(socket), do: socket

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

  defp register_local_rhwp_materializer_editor(document_id) when is_binary(document_id) do
    Ecrits.RhwpSnapshot.Materializer.register_editor(document_id)
  end

  defp register_local_rhwp_materializer_editor(_document_id), do: :ok

  defp unregister_local_rhwp_materializer_editor(document_id) when is_binary(document_id) do
    Ecrits.RhwpSnapshot.Materializer.unregister_editor(document_id)
  end

  defp unregister_local_rhwp_materializer_editor(_document_id), do: :ok

  defp update_local_rhwp_materializer_editor(previous_document_id, next_document_id)
       when previous_document_id == next_document_id,
       do: :ok

  defp update_local_rhwp_materializer_editor(previous_document_id, next_document_id) do
    _ = unregister_local_rhwp_materializer_editor(previous_document_id)
    register_local_rhwp_materializer_editor(next_document_id)
  end

  defp ack_local_rhwp_snapshot_committed(request_id, document_id, response)
       when is_binary(request_id) and request_id != "" do
    Ecrits.RhwpSnapshot.Materializer.ack(request_id, %{
      status: :committed,
      request_id: request_id,
      document_id: document_id,
      revision: response.revision,
      snapshot: %{
        path: response.snapshot["path"],
        format: response.format,
        revision: response.revision
      }
    })
  end

  defp ack_local_rhwp_snapshot_committed(_request_id, _document_id, _response), do: :ok

  defp ack_local_rhwp_snapshot_failed(request_id, document_id, reason)
       when is_binary(request_id) and request_id != "" do
    Ecrits.RhwpSnapshot.Materializer.ack(request_id, %{
      status: :failed,
      request_id: request_id,
      document_id: document_id,
      reason: inspect(reason)
    })
  end

  defp ack_local_rhwp_snapshot_failed(_request_id, _document_id, _reason), do: :ok

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

  defp local_save_state(document, snapshot, status) do
    revision = document.revision || 0
    size = document.byte_size || 0

    case {status, snapshot} do
      {:saved, %{"revision" => saved_revision}} ->
        "Saved revision #{saved_revision} - #{format_byte_size(size)} - #{document.format}"

      {:checkpointed, %{"revision" => checkpoint_revision}} ->
        "Checkpointed revision #{checkpoint_revision} - canonical file unchanged - #{document.format}"

      _ ->
        "Loaded revision #{revision} - #{format_byte_size(size)} - #{document.format}"
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

  defp local_agent_options_form do
    to_form(%{}, as: :agent_options)
  end

  defp local_agent_provider_param(params) do
    params["provider"] ||
      params["value"] ||
      get_in(params, ["agent_model", "provider"])
  end

  defp local_agent_option_param(params) do
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

  defp select_local_agent_reasoning(value, socket) do
    reasoning_effort = normalize_reasoning_effort(value, socket.assigns.local_agent_provider.key)

    if reasoning_effort == socket.assigns.local_agent_reasoning_effort do
      {:noreply, socket}
    else
      {:noreply,
       push_patch(socket,
         to:
           workspace_provider_path(socket, socket.assigns.local_agent_provider.key,
             reasoning: reasoning_effort
           )
       )}
    end
  end

  defp select_local_agent_access(value, socket) do
    access_control = normalize_access_control(value)

    if access_control == socket.assigns.local_agent_access_control do
      {:noreply, socket}
    else
      {:noreply,
       push_patch(socket,
         to:
           workspace_provider_path(socket, socket.assigns.local_agent_provider.key,
             access: access_control
           )
       )}
    end
  end

  defp local_agent_provider_display(provider \\ default_provider_id()) do
    provider_id = normalize_allowed_provider_id(provider) || default_provider_id()
    metadata = provider_metadata(provider_id) || provider_metadata("codex")

    %{
      key: metadata.id,
      label: metadata.label,
      favicon_src: metadata.favicon_src
    }
  end

  defp local_agent_model_from_params(model_id, provider_id) do
    local_agent_model(model_id) ||
      local_agent_model(default_agent_model_id(provider_id)) ||
      local_agent_model(default_agent_model_id("codex"))
  end

  defp local_agent_model(model_id) when is_binary(model_id) do
    Enum.find(@local_agent_models, &(&1.id == model_id))
  end

  defp local_agent_model(_model_id), do: nil

  defp local_agent_models_for_provider(provider_id) do
    Enum.filter(@local_agent_models, &(&1.provider == provider_id))
  end

  defp default_agent_model_id("claude"), do: "default"
  defp default_agent_model_id(_provider), do: "gpt-5.5"

  # The model id forwarded to the adapter (→ `--model <id>` on the provider CLI).
  # Claude's `default` alias forwards NO `--model` (the CLI picks its own
  # recommended latest); every other catalog id is a real accepted alias/id and
  # is forwarded verbatim. An unknown/blank id yields nil.
  defp local_agent_adapter_model("default"), do: nil

  defp local_agent_adapter_model(model_id) do
    case local_agent_model(model_id) do
      %{id: id} -> id
      _model -> nil
    end
  end

  defp local_agent_provider_from_params(nil), do: {local_agent_provider_display(), nil}

  defp local_agent_provider_from_params(provider) do
    case normalize_allowed_provider_id(provider) do
      nil ->
        fallback = local_agent_provider_display()

        {fallback, "Selected provider is unavailable in workspace chat. Using #{fallback.label}."}

      provider_id ->
        {local_agent_provider_display(provider_id), nil}
    end
  end

  defp local_agent_config(key) do
    local_agent_ui = Application.get_env(:ecrits, :local_agent_ui, [])
    local_agent = Application.get_env(:ecrits, :local_agent, [])

    Keyword.get(local_agent_ui, key) || Keyword.get(local_agent, key)
  end

  defp default_provider_id do
    configured =
      local_agent_config(:provider) ||
        local_agent_adapter_provider(local_agent_config(:adapter))

    normalize_allowed_provider_id(configured) || "codex"
  end

  defp local_agent_adapter_provider(nil), do: nil
  defp local_agent_adapter_provider(adapter), do: normalize_provider_id(adapter)

  defp normalize_selectable_provider_id(provider) do
    provider_id = normalize_provider_id(provider)

    if provider_id in selectable_provider_ids() do
      provider_id
    end
  end

  defp normalize_allowed_provider_id(provider) do
    provider_id = normalize_provider_id(provider)

    if provider_id in allowed_provider_ids() do
      provider_id
    end
  end

  defp normalize_provider_id(provider)
       when provider in [:codex, :codex_app_server, "codex", "codex_app_server"],
       do: "codex"

  defp normalize_provider_id(provider)
       when provider in [:claude, :claude_cli, "claude", "claude_cli"],
       do: "claude"

  defp normalize_provider_id(provider) when is_atom(provider) do
    provider
    |> Atom.to_string()
    |> normalize_provider_id()
  end

  defp normalize_provider_id(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> case do
      "codex" -> "codex"
      "codex_app_server" -> "codex"
      "claude" -> "claude"
      "claude_cli" -> "claude"
      _other -> nil
    end
  end

  defp normalize_provider_id(_provider), do: nil

  defp provider_metadata(provider_id) do
    Enum.find(ACP.provider_metadata(), &(&1.id == provider_id))
  end

  defp allowed_provider_ids do
    selectable_provider_ids()
  end

  defp selectable_provider_ids do
    ACP.provider_metadata()
    |> Enum.map(& &1.id)
    |> Enum.filter(&(&1 in @selectable_local_agent_provider_ids))
  end

  defp local_agent_providers do
    ACP.provider_metadata()
    |> Enum.filter(&(&1.id in @selectable_local_agent_provider_ids))
    |> Enum.map(fn provider ->
      %{
        id: provider.id,
        label: provider.label,
        favicon_src: provider.favicon_src
      }
    end)
  end

  defp local_agent_provider_details(integrations) do
    integrations_by_id = Map.new(integrations, &{&1.id, &1})

    local_agent_providers()
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

  defp provider_param_invalid?(nil), do: false
  defp provider_param_invalid?(provider), do: is_nil(normalize_allowed_provider_id(provider))

  defp model_param_invalid?(nil), do: false
  defp model_param_invalid?(model_id), do: is_nil(local_agent_model(model_id))

  defp local_agent_selected_model_label(model_id) do
    case Enum.find(@local_agent_models, &(&1.id == model_id)) do
      %{label: label} -> label
      _missing -> "Model"
    end
  end

  defp default_reasoning_effort do
    :ecrits
    |> Application.get_env(:local_agent, [])
    |> Keyword.get(:reasoning_effort, "medium")
    |> normalize_reasoning_effort()
  end

  defp normalize_reasoning_effort(effort, provider \\ "codex") do
    effort
    |> normalize_reasoning_effort_value()
    |> normalize_reasoning_for_provider(provider)
  end

  defp normalize_reasoning_effort_value(effort)
       when effort in ["minimal", "low", "medium", "high", "xhigh", "ultracode"],
       do: effort

  defp normalize_reasoning_effort_value(effort)
       when effort in [:minimal, :low, :medium, :high, :xhigh, :ultracode],
       do: Atom.to_string(effort)

  defp normalize_reasoning_effort_value(_effort), do: "medium"

  defp normalize_reasoning_for_provider(effort, provider) do
    if effort in local_agent_reasoning_efforts(provider), do: effort, else: "medium"
  end

  # Claude's `--effort` tiers are low|medium|high|xhigh|max (per `claude --help`).
  # We surface `max` as the top "Ultracode" tier in the rail — Claude Code's most
  # exhaustive reasoning mode — and additionally fire the `ultrathink` workflow
  # keyword for it (see acp_stream). Internally the tier id is "ultracode".
  defp local_agent_reasoning_efforts("claude"), do: ~w(low medium high xhigh ultracode)
  defp local_agent_reasoning_efforts(_provider), do: ~w(minimal low medium high xhigh)

  defp local_agent_reasoning_label("minimal"), do: "Minimal - fastest, least tokens"
  defp local_agent_reasoning_label("low"), do: "Low - light reasoning, lower tokens"
  defp local_agent_reasoning_label("medium"), do: "Medium - balanced reasoning/tokens"
  defp local_agent_reasoning_label("high"), do: "High - deeper reasoning, more tokens"
  defp local_agent_reasoning_label("xhigh"), do: "XHigh - maximum reasoning/tokens"

  defp local_agent_reasoning_label("ultracode"),
    do: "Ultracode - exhaustive reasoning"

  defp local_agent_reasoning_label(reasoning), do: reasoning

  defp local_agent_reasoning_short_label("minimal"), do: "Minimal"
  defp local_agent_reasoning_short_label("low"), do: "Low"
  defp local_agent_reasoning_short_label("medium"), do: "Medium"
  defp local_agent_reasoning_short_label("high"), do: "High"
  defp local_agent_reasoning_short_label("xhigh"), do: "XHigh"
  defp local_agent_reasoning_short_label("ultracode"), do: "Ultracode"
  defp local_agent_reasoning_short_label(reasoning), do: reasoning

  defp local_agent_reasoning_title("minimal"),
    do: "Fastest responses with the smallest token budget."

  defp local_agent_reasoning_title("low"),
    do: "Lower-cost reasoning for routine edits and lookups."

  defp local_agent_reasoning_title("medium"), do: "Balanced reasoning depth and token usage."
  defp local_agent_reasoning_title("high"), do: "More planning tokens for harder document work."
  defp local_agent_reasoning_title("xhigh"), do: "Maximum reasoning budget for complex tasks."

  defp local_agent_reasoning_title("ultracode"),
    do: "Claude's most exhaustive mode: top effort tier plus the ultrathink keyword."

  defp local_agent_reasoning_title(reasoning), do: reasoning

  defp local_agent_integrations, do: ACP.integration_options()

  defp provider_integration_status_label(:ready), do: "ready"
  defp provider_integration_status_label(_status), do: "setup"

  defp assign_local_agent_access(socket, access_control) do
    access = local_agent_access_control(access_control)

    socket
    |> assign(:local_agent_access_control, access.id)
    |> assign(:local_agent_approval_policy, access.approval_policy)
    |> assign(:local_agent_adapter_approval_policy, access.adapter_approval_policy)
    |> assign(:local_agent_sandbox, access.sandbox)
    |> assign(:local_agent_permission_mode, access.permission_mode)
  end

  defp local_agent_access_controls, do: @local_agent_access_controls

  defp local_agent_access_control(access_control) do
    Enum.find(@local_agent_access_controls, &(&1.id == access_control)) ||
      List.first(@local_agent_access_controls)
  end

  defp local_agent_access_title(%{id: "read-only"}),
    do: "Read workspace context. Write tools stay gated."

  defp local_agent_access_title(%{id: "ask"}),
    do: "Read and request approval before local writes."

  defp local_agent_access_title(%{id: "full-workspace"}),
    do: "Allow workspace writes without per-tool approval."

  defp default_access_control do
    local_agent = Application.get_env(:ecrits, :local_agent, [])
    local_agent_ui = Application.get_env(:ecrits, :local_agent_ui, [])
    config = Keyword.merge(local_agent, local_agent_ui)
    adapter_opts = Keyword.get(config, :adapter_opts, [])

    normalize_access_control(
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

  defp normalize_access_control(access_control) when is_atom(access_control) do
    access_control
    |> Atom.to_string()
    |> normalize_access_control()
  end

  defp normalize_access_control(access_control) when is_binary(access_control) do
    case access_control |> String.trim() |> String.downcase() do
      "read-only" -> "read-only"
      "read_only" -> "read-only"
      "readonly" -> "read-only"
      "ask" -> "ask"
      "on_write" -> "ask"
      "full" -> "full-workspace"
      "full-workspace" -> "full-workspace"
      "full_workspace" -> "full-workspace"
      "workspace-write" -> "full-workspace"
      _other -> "read-only"
    end
  end

  defp normalize_access_control(_access_control), do: "read-only"

  defp provider_runtime_label("codex"), do: "CLI/app-server"
  defp provider_runtime_label("claude"), do: "CLI"
  defp provider_runtime_label(_provider), do: "ACP"

  # Stream dom_id resolver — PUBLIC so it can be captured as `&__MODULE__.../1` in
  # stream_configure (see mount/3). A named capture survives dev hot-reloads,
  # unlike an anonymous closure compiled into this module.
  @doc false
  def local_hwp_page_dom_id(%{id: id}), do: id

  # ── inline chat: send / queue ──────────────────────────────────────

  # The workspace Session handle (delegates send/cancel/rename to the foreground
  # agent), or nil before the agent is bound.
  defp ws(%{assigns: %{workspace_session: %{} = ws}}), do: ws
  defp ws(_socket), do: nil

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

  # Re-sync the chat to the durable foreground agent. The path-keyed Session owns
  # the agent, so "refresh chat" just clears the pane locally and repaints from
  # the (now possibly empty) live transcript — it does NOT tear down the agent (no
  # provider-thread loss).
  defp restart_local_agent_session(socket) do
    _ = maybe_cancel_active_local_agent(socket)

    socket =
      socket
      |> assign(:local_agent_turn_id, nil)
      |> assign(:local_agent_text, "")
      |> assign(:local_agent_text_segment, 0)
      |> assign(:local_agent_reasoning_text, "")
      |> assign(:local_agent_title_user_edited?, false)
      |> assign_local_agent_title(default_local_agent_title())
      |> assign(:local_agent_form, local_agent_form())
      |> stream(:local_agent_items, [], reset: true)

    case ws(socket) do
      %{agent_id: agent_id} = ws when is_binary(agent_id) ->
        snapshot = WorkspaceSession.snapshot(ws)

        socket
        |> assign(:local_agent_error, nil)
        |> assign(:local_agent_status, snapshot.status)
        |> assign(:local_agent_pending, Map.get(snapshot, :pending, 0))
        |> maybe_restore_agent_title(snapshot.title)
        |> replay_local_agent_transcript(snapshot.transcript)

      _ ->
        socket
    end
  end

  defp maybe_cancel_active_local_agent(%{
         assigns: %{workspace_session: %{} = ws, local_agent_turn_id: turn_id}
       })
       when is_binary(turn_id) do
    _ = WorkspaceSession.cancel(ws, turn_id)
    :ok
  end

  defp maybe_cancel_active_local_agent(_socket), do: :ok

  # ── inline chat: streaming event application ───────────────────────

  # A mid-turn send was enqueued behind the running turn (Phase 5). The agent is
  # the source of truth for the pending count; sync it from the event so a flush /
  # drain elsewhere never drifts the indicator.
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
  # now, reset the per-turn buffers, and decrement the pending count.
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
    # Flush ONLY the still-pending text segment (text streamed AFTER the last tool
    # call). Every earlier segment was already emitted at its tool boundary by
    # close_local_agent_text_segment/1.
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

  # ── inline chat: transcript repaint (refresh-survival) ─────────────

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
  # per turn using the SAME dom-id scheme live turns use (so a later live turn with
  # the same id reconciles rather than duplicating).
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

  # ── inline chat: streaming text buffer helpers ─────────────────────

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

  # Coalesces streaming text deltas into a single debounced re-render. A monotonic
  # ref guards a flush that fires after the buffer was already finalized (tool
  # boundary / turn completion). Only one timer is outstanding; while it is
  # pending, new deltas extend the buffer and it renders the latest.
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

  # On cancel, keep what the agent already streamed (finalize the in-flight bubble
  # with the accumulated partial, in place). Do NOT emit a "Cancelled."
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
  # mid-flight — that tool_call never gets its terminal event, so its row would be
  # stuck on "running" forever. On every turn terminal, flip any still-tracked
  # in-flight tool_calls to :failed.
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

  # ── inline chat: stream item builders ──────────────────────────────

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

  # ── inline chat: stream item view extractors ───────────────────────

  defp agent_item_data_role(%{role: :tool}), do: "local-agent-tool"
  defp agent_item_data_role(%{role: :thinking}), do: "local-agent-thinking"
  defp agent_item_data_role(_item), do: "local-agent-message"

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

  # ── inline chat: status / placeholder labels ───────────────────────

  defp agent_status_label(:offline), do: "Offline"
  defp agent_status_label(:starting), do: "Starting"
  defp agent_status_label(:running), do: "Running"
  defp agent_status_label(:cancelled), do: "Cancelled"
  defp agent_status_label(:failed), do: "Failed"
  defp agent_status_label(_status), do: "Idle"

  defp agent_input_placeholder(:offline), do: "Agent unavailable"
  defp agent_input_placeholder(:starting), do: "Starting agent"
  defp agent_input_placeholder(_status), do: "Ask about this workspace"

  # ── inline chat: forms / title ─────────────────────────────────────

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

  # ── inline chat: error mapping ─────────────────────────────────────

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
