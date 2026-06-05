defmodule EcritsWeb.Local.WorkspaceLive do
  @moduledoc """
  Local workspace shell.
  """

  use EcritsWeb, :live_view

  alias Ecrits.Doc.Pool, as: DocPool
  alias Ecrits.Local.AcpAgent, as: ACP
  alias Ecrits.Local.Document
  alias Ecrits.Local.Document.RhwpAdapter
  alias Ecrits.Local.Path, as: LocalPath
  alias Ecrits.Local.Workspace
  alias EcritsWeb.Components.LocalFileTree
  alias EcritsWeb.Live.Studio.Components.ChatRail
  alias EcritsWeb.Live.Studio.Components.EditorSurface
  alias EcritsWeb.Local.WorkspaceAdapter

  @local_document_upload_max_size 50_000_000
  # Debounce interval for re-rendering the streaming agent message body as
  # formatted markdown. Raw text appends (client-side) provide instant
  # sub-debounce feedback; on each tick we re-render the accumulated buffer
  # through MDEx so the visible body becomes progressively-formatted markdown
  # without thrashing on every token.
  @local_agent_text_flush_ms 120
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
    %{
      id: "claude-default",
      provider: "claude",
      label: "Claude",
      description: "Claude CLI default"
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
     |> stream_configure(:local_agent_items, dom_id: & &1.dom_id)
     |> stream_configure(:local_hwp_pages, dom_id: & &1.id)
     |> stream(:local_agent_items, [])
     |> stream(:local_hwp_pages, [])
     # Office (libreofficex) virtualization: tiles are accumulated per page and
     # only composited into the DOM for near-viewport pages (placeholders else),
     # so a 1000-tile deck never streams its full ~17MB into one LiveView diff.
     |> assign(:local_office_tiles, %{})
     |> assign(:local_office_page_dims, %{})
     |> assign(:local_office_hydrated, MapSet.new())
     # LOK in-process office EDIT session (docx/pptx/xlsx made editable like the
     # HWP editor). nil when no edit session is available — the read-only PDF-tile
     # path above is the graceful fallback.
     |> assign(:office_edit_session, nil)
     |> assign(:office_edit_document_id, nil)
     |> assign(:office_edit_document, nil)
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
     |> assign(:fs_watcher_pid, nil)
     |> assign(:fs_refresh_timer, nil)
     |> assign(:local_document_error, nil)
     |> assign(:local_document_status, :none)
     |> assign(:local_document_snapshot, nil)
     |> assign(:local_hwp_page_count, 0)
     |> assign(:local_hwp_stream_id, nil)
     |> assign(:local_hwp_stream_renderer, nil)
     |> assign(:local_hwp_stream_document_id, nil)
     |> assign(:local_hwp_stream_revision, nil)
     |> assign(:local_hwp_stream_loading?, false)
     |> assign(:last_caret, nil)
     |> assign(:workspace_error, nil)
     |> assign(:local_agent_session_id, nil)
     |> assign(:local_agent_status, :offline)
     |> assign(:local_agent_error, nil)
     |> assign(:local_agent_turn_id, nil)
     |> assign(:local_agent_text, "")
     |> assign(:local_agent_text_segment, 0)
     |> assign(:local_agent_text_flush_ref, nil)
     |> assign(:local_agent_active_tools, %{})
     |> assign(:local_agent_reasoning_text, "")
     |> assign(:local_agent_title, default_local_agent_title())
     |> assign(:local_agent_title_user_edited?, false)
     |> assign(:local_agent_title_form, local_agent_title_form())
     |> assign(:local_agent_provider, local_agent_provider_display())
     |> assign(:local_agent_provider_warning, nil)
     |> assign(:local_agent_model, default_agent_model_id(default_provider_id()))
     |> assign(:local_agent_model_modal_open, false)
     |> assign(:local_agent_reasoning_effort, default_reasoning_effort())
     |> assign_local_agent_access(default_access_control())
     |> assign(:local_agent_integrations, local_agent_integrations())
     |> assign(:local_agent_form, local_agent_form())
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
    provider_changed? = provider.key != socket.assigns.local_agent_provider.key
    model_changed? = model.id != socket.assigns.local_agent_model
    reasoning_effort = normalize_reasoning_effort(Map.get(params, "reasoning"), model.provider)
    reasoning_changed? = reasoning_effort != socket.assigns.local_agent_reasoning_effort
    access_control = normalize_access_control(Map.get(params, "access"))
    access_changed? = access_control != socket.assigns.local_agent_access_control
    previous_agent_context = local_agent_session_context(socket)

    same_workspace? =
      socket.assigns.workspace_path == path and not is_nil(socket.assigns.workspace)

    socket =
      socket
      |> assign(:local_agent_provider, provider)
      |> assign(:local_agent_provider_warning, provider_warning)
      |> assign(:local_agent_model, model.id)
      |> assign(:local_agent_reasoning_effort, reasoning_effort)
      |> assign_local_agent_access(access_control)
      |> assign(:local_agent_integrations, local_agent_integrations())
      |> mount_workspace(path)
      |> maybe_open_local_document(params)

    # Access/reasoning/same-provider-model changes must NOT recreate the session
    # (that starts a brand-new ACP session and loses the conversation). They are
    # per-turn options, so apply them to the LIVE session in place — the next
    # turn picks them up — and restart only on a real provider switch (codex<->
    # claude) or a workspace/document-context change that needs a fresh session.
    options_changed? = access_changed? or reasoning_changed? or model_changed?

    socket =
      if should_restart_local_agent_session?(
           socket,
           same_workspace?,
           provider_changed?,
           previous_agent_context
         ) do
        restart_local_agent_session(socket)
      else
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
    # No workspace path in the URL — there's nothing to show. Send the user to
    # the folder picker ("/") instead of rendering a dead-end error page.
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  @impl true
  def handle_event("local_agent_model_modal.open", _params, socket) do
    {:noreply, assign(socket, :local_agent_model_modal_open, true)}
  end

  def handle_event(
        "update_local_agent_title",
        %{"local_agent_title" => %{"title" => title}},
        socket
      ) do
    {:noreply,
     socket
     |> assign(:local_agent_title_user_edited?, true)
     |> assign_local_agent_title(title)}
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
      {:reply, %{ok: true, local: true, mutation: mutation_reply(response.mutation)}, socket}
    else
      {:error, reason} ->
        {:reply, %{error: error_message(reason)}, socket}
    end
  end

  def handle_event("rhwp.local.snapshot.checkpoint", params, socket) do
    persist_local_rhwp_snapshot(:checkpoint, params, socket)
  end

  def handle_event("rhwp.local.snapshot.save", params, socket) do
    persist_local_rhwp_snapshot(:save, params, socket)
  end

  # Office (libreofficex) page virtualization: hydrate composites the page's
  # accumulated tiles into the DOM when it scrolls near the viewport; release
  # drops them back to a lightweight placeholder so the deck's full PNG payload
  # is never resident at once. `page` is 1-based (matching the tile `page`).
  def handle_event("office.local.hydrate_page", %{"page" => page}, socket) do
    {:noreply, hydrate_local_office_page(socket, local_hwp_to_int(page))}
  end

  def handle_event("office.local.release_page", %{"page" => page}, socket) do
    {:noreply, release_local_office_page(socket, local_hwp_to_int(page))}
  end

  # --- LOK office EDIT session events (from the OfficeEditor JS hook) ----------
  # All are guarded by an active edit session; with no session they are no-ops,
  # so a stray client event can never crash the LiveView.

  def handle_event("office.edit.hit_test", %{"page" => page, "x" => x, "y" => y}, socket) do
    with_office_edit(socket, fn pid ->
      Ecrits.Local.OfficeEditSession.hit_test(pid, num_to_int(page), num_to_float(x), num_to_float(y))
    end)

    {:noreply, socket}
  end

  # Impress/Draw text-frame entry (the JS hook sends this for presentations,
  # where a single click only selects a shape): activate the clicked slide's part
  # and double-click into the shape's text body so a caret is placed.
  def handle_event("office.edit.enter_text", %{"page" => page, "x" => x, "y" => y}, socket) do
    with_office_edit(socket, fn pid ->
      Ecrits.Local.OfficeEditSession.enter_text(
        pid,
        num_to_int(page),
        num_to_float(x),
        num_to_float(y)
      )
    end)

    {:noreply, socket}
  end

  def handle_event("office.edit.key", params, socket) do
    event = office_edit_key_event(params)

    if event != nil do
      with_office_edit(socket, &Ecrits.Local.OfficeEditSession.keyboard(&1, event))
    end

    {:noreply, socket}
  end

  def handle_event("office.edit.ime", params, socket) do
    event = office_edit_ime_event(params)

    if event != nil do
      with_office_edit(socket, &Ecrits.Local.OfficeEditSession.ime(&1, event))
    end

    {:noreply, socket}
  end

  def handle_event("office.edit.paint", params, socket) do
    viewport = office_edit_viewport(params)
    with_office_edit(socket, &Ecrits.Local.OfficeEditSession.request_tile(&1, viewport))
    {:noreply, socket}
  end

  def handle_event("office.edit.set_part", %{"part" => part}, socket) do
    with_office_edit(socket, &Ecrits.Local.OfficeEditSession.set_part(&1, num_to_int(part)))
    {:noreply, socket}
  end

  def handle_event("office.edit.save", _params, socket) do
    case socket.assigns[:office_edit_session] do
      pid when is_pid(pid) ->
        case Ecrits.Local.OfficeEditSession.save(pid) do
          :ok ->
            {:noreply, push_event(socket, "office_edit_saved", %{ok: true})}

          {:error, reason} ->
            {:noreply,
             push_event(socket, "office_edit_saved", %{ok: false, error: error_message(reason)})}
        end

      _ ->
        {:noreply, socket}
    end
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

  def handle_event("refresh_local_agent", _params, socket) do
    {:noreply, restart_local_agent_session(socket)}
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

  def handle_event("send_local_agent", %{"agent" => %{"message" => message}}, socket) do
    message = String.trim(message || "")

    cond do
      message == "" ->
        {:noreply, assign(socket, :local_agent_form, local_agent_form())}

      is_nil(socket.assigns.local_agent_session_id) ->
        {:noreply, assign(socket, :local_agent_error, "Agent session is not ready.")}

      true ->
        with {:ok, socket} <- maybe_cancel_active_local_agent_for_new_turn(socket) do
          send_local_agent_turn(socket, message)
        else
          {:error, socket} -> {:noreply, socket}
        end
    end
  end

  def handle_event("cancel_local_agent", _params, socket) do
    session_id = socket.assigns.local_agent_session_id
    turn_id = socket.assigns.local_agent_turn_id

    if session_id && turn_id do
      case ACP.cancel(nil, session_id, turn_id) do
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
  def handle_info({:local_agent_event, %{session_id: session_id} = event}, socket)
      when session_id == socket.assigns.local_agent_session_id do
    {:noreply, apply_local_agent_event(socket, event)}
  end

  def handle_info({:local_agent_event, _event}, socket), do: {:noreply, socket}

  # Debounced re-render of the in-flight streaming agent message. Re-renders the
  # accumulated buffer through `markdown_body`/MDEx so LiveView pushes formatted
  # HTML that replaces the raw client-side appends.
  def handle_info({:flush_local_agent_text, ref}, socket) do
    if socket.assigns.local_agent_text_flush_ref == ref do
      {:noreply, flush_local_agent_text(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:libreofficex, subscription, {:ready, metadata}}, socket) do
    socket =
      if current_local_hwp_stream?(socket, subscription) do
        socket
        |> maybe_assign_local_office_page_count(metadata)
        |> seed_local_office_pages(metadata)
        |> assign(:local_hwp_stream_loading?, false)
      else
        socket
      end

    {:noreply, socket}
  end

  # A cold deck rasterizes ~60 tiles per visible page, and the subscription
  # server emits each as its own `{:tile, ...}` message. Handling them one per
  # `handle_info` meant ~60 mailbox messages — each doing a full page
  # `stream_insert` (re-rendering + base64-re-encoding every accumulated tile,
  # ~178KB of diff) — queued AHEAD of any `tab_switch`/`tab_close` the user
  # clicks mid-render. That saturates the single LV mailbox so the tab event
  # waits behind the whole burst (measured ~575ms for a 300-tile burst) and the
  # click feels swallowed. Coalesce instead: drain every tile already waiting in
  # the mailbox, fold them into the per-page tile maps cheaply, then do ONE
  # `stream_insert` per affected page. The expensive render happens once per
  # page per batch instead of once per tile, and because we only drain tiles
  # ALREADY queued (`after 0`), a `tab_switch` that arrived during the burst is
  # processed on the very next mailbox turn instead of behind 60 renders.
  def handle_info({:libreofficex, subscription, {:tile, tile}}, socket) do
    if current_local_hwp_stream?(socket, subscription) do
      tiles = [tile | drain_pending_office_tiles(subscription)]

      socket =
        socket
        |> assign(:local_hwp_stream_loading?, false)
        |> accumulate_local_office_tiles(tiles)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Office (LOK) caret moved. The native LibreOfficeKit cursor backend forwards
  # `{:cursor, %{rect: {x, y, w, h}, page: page}}` here so the office editor can
  # draw a caret the SAME way the HWP (ehwp) path does — via the shared
  # `ehwp_native_cursor` client event the LocalEhwpEditor hook consumes. Until
  # the LOK NIF backend is built it emits no cursor events, so this is dormant
  # plumbing (no-op), but it means an unhandled `{:cursor}` can never crash the
  # LiveView and the caret path is uniform once LOK lands.
  def handle_info({:libreofficex, subscription, {:cursor, payload}}, socket) do
    socket =
      if current_local_hwp_stream?(socket, subscription) do
        push_office_cursor(socket, payload)
      else
        socket
      end

    {:noreply, socket}
  end

  # Office (LOK) text selection changed. Dormant until the LOK backend lands;
  # handled explicitly so the message can never crash the LiveView.
  def handle_info({:libreofficex, subscription, {:selection, _rects}}, socket) do
    _ = subscription
    {:noreply, socket}
  end

  def handle_info({:libreofficex, subscription, {:error, reason}}, socket) do
    socket =
      if current_local_hwp_stream?(socket, subscription) do
        socket
        |> assign(:local_hwp_stream_id, nil)
        |> assign(:local_hwp_stream_loading?, false)
        |> assign(:local_document_error, error_message(reason))
      else
        socket
      end

    {:noreply, socket}
  end

  # LOK edit-session output: forward painted tiles + caret moves to the
  # OfficeEditor hook. The hook draws the PNG tile into its canvas and the caret
  # onto its overlay (the same shape the HWP editor uses, but tiles come from
  # the server LOK paintTile rather than client WASM).
  def handle_info({:office_edit, {:tile, tile}}, socket) do
    socket =
      socket
      |> assign(:local_hwp_stream_loading?, false)
      |> push_event("office_edit_tile", %{
        part: tile.part,
        page: tile.page,
        x: tile.x,
        y: tile.y,
        tile_w: tile.tile_w,
        tile_h: tile.tile_h,
        width: tile.width,
        height: tile.height,
        src: "data:image/png;base64," <> tile.png_base64
      })

    {:noreply, socket}
  end

  def handle_info({:office_edit, {:caret, caret}}, socket) do
    {:noreply,
     push_event(socket, "office_edit_caret", %{
       page: caret.page,
       x: caret.x,
       y: caret.y,
       height: caret.height
     })}
  end

  # The async LOK open finished: hand the metadata to the hook so it builds the
  # page/slide boxes and starts painting. Ignored if the session was torn down
  # (navigated away) while opening.
  def handle_info({:office_edit, {:opened, info}}, socket) do
    if socket.assigns[:office_edit_session] do
      {:noreply,
       socket
       |> assign(:local_hwp_stream_loading?, false)
       |> push_event("office_edit_open", %{
         document_id: socket.assigns[:office_edit_document_id],
         revision: socket.assigns[:local_hwp_stream_revision],
         doc_type: to_string(info.doc_type),
         part_count: info.part_count,
         page_count: info.page_count,
         # Per-part px geometry so the hook sizes each slide box to its REAL
         # (landscape) dims before painting (no portrait clip).
         parts_geometry: Map.get(info, :parts_geometry, [])
       })}
    else
      {:noreply, socket}
    end
  end

  # The async LOK open failed: fall back to the read-only PDF-tile path.
  def handle_info({:office_edit, {:open_error, _reason}}, socket) do
    document = socket.assigns[:office_edit_document]
    socket = tear_down_office_edit_session(socket)

    socket =
      if match?(%Document{}, document) do
        subscribe_read_only_office(socket, document)
      else
        assign(socket, :local_hwp_stream_loading?, false)
      end

    {:noreply, socket}
  end

  def handle_info({:office_edit, {:error, _reason}}, socket) do
    {:noreply, socket}
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

  def handle_info({:local_document_saved, %Document{} = document, snapshot}, socket) do
    {:noreply, apply_local_document_snapshot(socket, :saved, document, snapshot)}
  end

  def handle_info({:local_document_checkpointed, %Document{} = document, snapshot}, socket) do
    {:noreply, apply_local_document_snapshot(socket, :checkpointed, document, snapshot)}
  end

  def handle_info({:file_event, pid, :stop}, %{assigns: %{fs_watcher_pid: pid}} = socket) do
    {:noreply, assign(socket, :fs_watcher_pid, nil)}
  end

  def handle_info({:file_event, pid, {path, _events}}, %{assigns: %{fs_watcher_pid: pid}} = socket) do
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

  @impl true
  def terminate(_reason, socket) do
    _ = unsubscribe_local_hwp_stream(socket)
    _ = tear_down_office_edit_session(socket)
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
              hwp_pages={@streams.local_hwp_pages}
              hwp_page_count={@local_hwp_page_count}
              hwp_stream_loading?={@local_hwp_stream_loading?}
              office_edit?={@local_hwp_stream_renderer == :libreofficex_edit}
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

            <p
              :if={@local_agent_provider_warning}
              id="local-agent-provider-warning"
              class="border-b border-warning/20 bg-warning/10 px-3 py-2 text-xs leading-5 text-warning"
            >
              {@local_agent_provider_warning}
            </p>

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
                          <span
                            aria-hidden="true"
                            class="size-1 rounded-full bg-current chat-typing-dot"
                          >
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
                  <.form
                    for={@local_agent_form}
                    id="local-agent-form"
                    phx-submit="send_local_agent"
                    data-role="chat-form"
                  >
                    <.input
                      field={@local_agent_form[:message]}
                      id="local-agent-input"
                      type="text"
                      autocomplete="off"
                      disabled={@local_agent_status in [:offline, :starting]}
                      placeholder={agent_input_placeholder(@local_agent_status)}
                      class="block h-8 w-full border-0 bg-transparent px-3 py-1 text-[13px] leading-snug text-base-content outline-none placeholder:text-base-content/35 focus:outline-none focus:ring-0 disabled:cursor-not-allowed disabled:text-base-content/40"
                    />
                    <div class="flex items-center justify-end gap-1 px-2 pb-1.5 pt-0.5">
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
                        type="submit"
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
                          <span class="whitespace-nowrap">{local_agent_reasoning_label(effort)}</span>
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
        socket = assign(socket, :open_documents, remaining)

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
  # Only the HWP/HWPX backend is server-routable today (`Ecrits.Doc.backend_for`
  # returns a backend for :hwp/:hwpx only); other formats (Office/Markdown) have
  # no Pool backend yet, so we just clear any stale active doc for them. The
  # Pool keys by absolute path, so re-opening the same file reuses the handle.
  defp register_pool_document(socket, %Document{path: path, format: format})
       when format in ["hwp", "hwpx"] do
    kind = String.to_existing_atom(format)

    case DocPool.open(path, kind: kind) do
      {:ok, doc_id} ->
        previous = socket.assigns[:pool_document_id]
        if previous && previous != doc_id, do: DocPool.clear_active(previous)
        :ok = DocPool.set_active(doc_id)
        assign(socket, :pool_document_id, doc_id)

      {:error, _reason} ->
        # Pool registration is best-effort: a backend open failure must not
        # break the viewer. The agent simply won't have a handle for this doc.
        clear_pool_document(socket)
    end
  end

  defp register_pool_document(socket, %Document{}), do: clear_pool_document(socket)

  # Drop the active-document marker for the doc this LiveView registered. We
  # leave the Editor in the Pool (other sessions may share it); we only relinquish
  # the "active" claim that `doc.context` surfaces.
  defp clear_pool_document(%{assigns: %{pool_document_id: doc_id}} = socket)
       when is_binary(doc_id) do
    _ = DocPool.clear_active(doc_id)
    assign(socket, :pool_document_id, nil)
  end

  defp clear_pool_document(socket), do: assign(socket, :pool_document_id, nil)

  defp start_local_agent_session(socket) do
    if connected?(socket) do
      case ACP.start_session(nil, local_agent_session_opts(socket)) do
        {:ok, %{id: session_id}} ->
          :ok = ACP.subscribe(session_id)

          socket
          |> assign(:local_agent_session_id, session_id)
          |> assign(:local_agent_status, :idle)
          |> assign(:local_agent_error, nil)
          |> stream(:local_agent_items, [], reset: true)

        {:error, reason} ->
          socket
          |> assign(:local_agent_status, :offline)
          |> assign(:local_agent_error, local_agent_error(reason))
      end
    else
      socket
      |> assign(:local_agent_status, :starting)
      |> assign(:local_agent_error, nil)
    end
  end

  defp restart_local_agent_session(socket) do
    maybe_cancel_active_local_agent(socket)

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
    |> start_local_agent_session()
  end

  # Restart (new ACP session, conversation reset) ONLY on a genuine
  # provider switch (codex<->claude) or a workspace/document-context change.
  # Access/reasoning/same-provider-model changes are applied live instead — see
  # maybe_apply_live_local_agent_options/2 — so they preserve the conversation.
  defp should_restart_local_agent_session?(
         socket,
         same_workspace?,
         provider_changed?,
         previous_agent_context
       ) do
    is_nil(socket.assigns.workspace_error) and
      (not same_workspace? or provider_changed? or
         previous_agent_context != local_agent_session_context(socket))
  end

  # Apply per-turn option changes (access/reasoning/same-provider model) to the
  # running session without recreating it, preserving the conversation. No live
  # session yet -> nothing to do (the next start picks up the assigns).
  defp maybe_apply_live_local_agent_options(socket, false), do: socket

  defp maybe_apply_live_local_agent_options(
         %{assigns: %{local_agent_session_id: session_id}} = socket,
         true
       )
       when is_binary(session_id) do
    workspace_path = workspace_root_path(socket.assigns.workspace || %{})
    _ = ACP.update_session_options(session_id, local_agent_provider_adapter_opts(socket, workspace_path))
    socket
  end

  defp maybe_apply_live_local_agent_options(socket, _changed?), do: socket

  # NOTE: neither the active document NOR local_agent_model is part of the
  # restart context. The chat-rail conversation is WORKSPACE-scoped, not
  # document-scoped: selecting/opening a document must preserve the conversation
  # (the document is per-turn context applied live via
  # maybe_restart_local_agent_for_document/2 — mirroring the access/reasoning
  # decoupling). A same-provider model swap is likewise a live per-turn option.
  # Only a workspace change (here) or a cross-provider switch (provider_changed?
  # in handle_params) recreates the session.
  defp local_agent_session_context(socket) do
    socket.assigns.workspace_path
  end

  defp maybe_cancel_active_local_agent(%{
         assigns: %{local_agent_session_id: session_id, local_agent_turn_id: turn_id}
       })
       when is_binary(session_id) and is_binary(turn_id) do
    _ = ACP.cancel(nil, session_id, turn_id)
    :ok
  end

  defp maybe_cancel_active_local_agent(_socket), do: :ok

  defp maybe_cancel_active_local_agent_for_new_turn(
         %{
           assigns: %{local_agent_session_id: session_id, local_agent_turn_id: turn_id}
         } = socket
       )
       when is_binary(session_id) and is_binary(turn_id) do
    case ACP.cancel(nil, session_id, turn_id) do
      {:ok, _turn} ->
        partial = socket.assigns.local_agent_text
        segment = socket.assigns.local_agent_text_segment

        {:ok,
         socket
         |> assign(:local_agent_turn_id, nil)
         |> assign(:local_agent_text, "")
         |> assign(:local_agent_reasoning_text, "")
         |> finalize_cancelled_agent_text(turn_id, partial, segment)}

      {:error, :no_current_turn} ->
        {:ok, assign(socket, :local_agent_turn_id, nil)}

      {:error, reason} ->
        {:error,
         assign(
           socket,
           :local_agent_error,
           local_agent_error(reason)
         )}
    end
  end

  defp maybe_cancel_active_local_agent_for_new_turn(socket), do: {:ok, socket}

  defp send_local_agent_turn(socket, message) do
    session_id = socket.assigns.local_agent_session_id

    case ACP.send_turn(nil, session_id, message) do
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

  defp apply_local_agent_event(socket, %{type: :turn_started, turn_id: turn_id}) do
    socket
    |> assign(:local_agent_turn_id, turn_id)
    |> assign(:local_agent_status, :running)
  end

  defp apply_local_agent_event(socket, %{type: type, title: title})
       when type in [:title_generated, :title_updated, :thread_title] and is_binary(title) do
    if socket.assigns.local_agent_title_user_edited? do
      socket
    else
      assign_local_agent_title(socket, title)
    end
  end

  defp apply_local_agent_event(socket, %{type: :text_delta, turn_id: turn_id, delta: delta})
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

  defp apply_local_agent_event(socket, %{type: :reasoning_delta, turn_id: turn_id, delta: delta})
       when is_binary(delta) do
    text = socket.assigns.local_agent_reasoning_text <> delta

    socket
    |> assign(:local_agent_reasoning_text, text)
    |> push_event("local_agent_reasoning_append", %{
      message_id: agent_reasoning_dom_id(turn_id),
      piece: delta
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
    |> stream_insert(
      :local_agent_items,
      agent_tool_item(tool_call_id, name, :failed, reason)
    )
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

  defp apply_local_agent_event(socket, %{type: :turn_completed, turn_id: turn_id, text: text}) do
    text = text || socket.assigns.local_agent_text

    socket
    |> cancel_local_agent_text_flush()
    |> assign(:local_agent_turn_id, nil)
    |> assign(:local_agent_text, "")
    |> assign(:local_agent_status, :idle)
    |> maybe_remove_empty_reasoning(turn_id)
    |> assign(:local_agent_reasoning_text, "")
    |> maybe_stream_final_agent_text(turn_id, text)
    |> finalize_dangling_tools("Turn ended before the tool finished.")
  end

  defp apply_local_agent_event(socket, %{type: :turn_failed, turn_id: turn_id, reason: reason}) do
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
  end

  defp put_current_document_id(opts, document_id)
       when is_binary(document_id) and document_id != "",
       do: Keyword.put(opts, :document_id, document_id)

  defp put_current_document_id(opts, _document_id), do: opts

  # Selecting/opening a document must NOT recreate the ACP session (that would
  # wipe the chat-rail conversation). The active document is per-turn context, so
  # — exactly like access/reasoning changes (#54) — apply it to the LIVE session
  # in place; the next turn's doc.* tools then target the now-active document.
  # With no live session yet, the next start picks up the current document from
  # local_agent_session_opts, so there is nothing to do.
  defp maybe_restart_local_agent_for_document(socket, previous_document_id) do
    current_document_id = active_document_id(socket)

    cond do
      not connected?(socket) ->
        socket

      previous_document_id == current_document_id ->
        socket

      is_nil(socket.assigns.local_agent_session_id) ->
        start_local_agent_session(socket)

      true ->
        _ =
          ACP.update_session_options(socket.assigns.local_agent_session_id,
            document_id: current_document_id
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
      {:ok, tree} -> assign(socket, :tree, tree)
      {:error, reason} -> assign(socket, :workspace_error, error_message(reason))
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

  # Ignore the metadata tree, dotfiles, and editor swap files; everything else
  # is a workspace change worth re-listing.
  defp fs_relevant_path?(path) when is_binary(path) do
    segments = path |> Path.split() |> Enum.reject(&(&1 in ["/", ""]))
    base = Path.basename(path)

    cond do
      Enum.any?(segments, &(&1 == ".ecrits")) -> false
      String.starts_with?(base, ".") -> false
      String.ends_with?(base, "~") -> false
      true -> true
    end
  end

  defp fs_relevant_path?(_path), do: false

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
      true -> render_local_office_tiles(socket, document)
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

  # Office (docx/pptx/xlsx) rendering. We PREFER the LOK in-process edit session
  # (click->caret, type->edit, real-time tile repaint, Ctrl+S save). If a LOK
  # edit session can't be created (no runtime / open failed), we degrade to the
  # read-only PDF-tile subscription path — the editor never crashes the BEAM.
  defp render_local_office_tiles(socket, %Document{} = document) do
    socket =
      socket
      |> unsubscribe_local_hwp_stream()
      |> clear_local_hwp_pages()

    cond do
      not connected?(socket) ->
        socket
        |> assign(:local_hwp_stream_renderer, :libreofficex)
        |> assign(:local_hwp_stream_document_id, document.id)
        |> assign(:local_hwp_stream_revision, document.revision)

      office_edit_enabled?() ->
        case start_office_edit_session(socket, document) do
          {:ok, socket} -> socket
          {:fallback, socket} -> subscribe_read_only_office(socket, document)
        end

      true ->
        subscribe_read_only_office(socket, document)
    end
  end

  defp subscribe_read_only_office(socket, %Document{} = document) do
    socket =
      socket
      |> assign(:local_hwp_stream_renderer, :libreofficex)
      |> assign(:local_hwp_stream_document_id, document.id)
      |> assign(:local_hwp_stream_revision, document.revision)
      |> assign(:local_hwp_stream_loading?, true)

    case local_libreofficex_runtime().subscribe(document.path, local_libreofficex_opts()) do
      {:ok, subscription} ->
        assign(socket, :local_hwp_stream_id, subscription)

      {:error, reason} ->
        socket
        |> assign(:local_hwp_stream_loading?, false)
        |> assign(:local_document_error, error_message(reason))
    end
  end

  # Start a LOK edit session (a supervised, LiveView-owned process). On success
  # the office renderer becomes `:libreofficex_edit`; the OfficeEditor hook then
  # drives hit_test/keyboard/ime/paint over server events and the session pushes
  # tiles + caret back. Anything other than a clean start falls back read-only.
  defp start_office_edit_session(socket, %Document{} = document) do
    socket = tear_down_office_edit_session(socket)

    try do
      case Ecrits.Local.OfficeEditSession.start(document.path, owner: self()) do
        {:ok, pid} ->
          # Optimistic: the session opens the document async (~0.5s LOK load) and
          # notifies us with `{:office_edit, {:opened, info}}` (-> push
          # office_edit_open) or `{:office_edit, {:open_error, _}}` (-> fall back
          # to the read-only path). We show the editor shell in a loading state
          # immediately so the open never blocks/freezes the LiveView.
          socket =
            socket
            |> assign(:office_edit_session, pid)
            |> assign(:office_edit_document_id, document.id)
            |> assign(:office_edit_document, document)
            |> assign(:local_hwp_stream_renderer, :libreofficex_edit)
            |> assign(:local_hwp_stream_document_id, document.id)
            |> assign(:local_hwp_stream_revision, document.revision)
            |> assign(:local_hwp_stream_loading?, true)

          {:ok, socket}

        {:error, _reason} ->
          {:fallback, socket}
      end
    rescue
      _ -> {:fallback, socket}
    catch
      _, _ -> {:fallback, socket}
    end
  end

  defp office_edit_enabled? do
    Application.get_env(:ecrits, :office_edit_enabled, true) and
      office_edit_runtime_available?()
  end

  defp office_edit_runtime_available? do
    Libreofficex.Edit.available?()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp tear_down_office_edit_session(socket) do
    case socket.assigns[:office_edit_session] do
      pid when is_pid(pid) ->
        _ = Ecrits.Local.OfficeEditSession.close(pid)

        socket
        |> assign(:office_edit_session, nil)
        |> assign(:office_edit_document_id, nil)
        |> assign(:office_edit_document, nil)

      _ ->
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
    |> tear_down_office_edit_session()
    |> assign(:local_hwp_page_count, 0)
    |> assign(:local_hwp_stream_id, nil)
    |> assign(:local_hwp_stream_renderer, nil)
    |> assign(:local_hwp_stream_document_id, nil)
    |> assign(:local_hwp_stream_revision, nil)
    |> assign(:local_hwp_stream_loading?, false)
    |> assign(:local_office_tiles, %{})
    |> assign(:local_office_page_dims, %{})
    |> assign(:local_office_hydrated, MapSet.new())
    |> stream(:local_hwp_pages, [], reset: true)
  end

  # Only the office (libreofficex) renderer holds a server-side subscription now;
  # HWP/HWPX render entirely in the browser (no server stream to tear down).
  defp unsubscribe_local_hwp_stream(%{assigns: %{local_hwp_stream_id: stream_id}} = socket) do
    if not is_nil(stream_id) and office_stream?(socket) do
      local_libreofficex_runtime().unsubscribe(stream_id)
    end

    socket
  end

  defp unsubscribe_local_hwp_stream(socket), do: socket

  defp office_stream?(%{assigns: %{local_hwp_stream_renderer: :libreofficex}}), do: true

  defp office_stream?(_socket), do: false

  defp markdown_document_active?(%{assigns: %{active_document: %{format: format}}})
       when is_binary(format),
       do: Document.markdown_format?(format)

  defp markdown_document_active?(_socket), do: false

  defp current_local_hwp_stream?(socket, stream_id) do
    active_document = socket.assigns.active_document

    stream_id == socket.assigns.local_hwp_stream_id and
      is_map(active_document) and
      active_document.id == socket.assigns.local_hwp_stream_document_id and
      active_document.revision == socket.assigns.local_hwp_stream_revision
  end

  defp maybe_expand_local_hwp_page_count(socket, %{number: number})
       when is_integer(number) and number > socket.assigns.local_hwp_page_count do
    assign(socket, :local_hwp_page_count, number)
  end

  defp maybe_expand_local_hwp_page_count(socket, _page), do: socket

  defp maybe_assign_local_office_page_count(socket, metadata) do
    case local_office_metadata_page_count(metadata) do
      page_count when is_integer(page_count) and page_count >= 0 ->
        assign(socket, :local_hwp_page_count, page_count)

      _other ->
        socket
    end
  end

  defp local_office_metadata_page_count(%{page_count: page_count}) when is_integer(page_count),
    do: page_count

  defp local_office_metadata_page_count(%{"page_count" => page_count})
       when is_integer(page_count),
       do: page_count

  defp local_office_metadata_page_count(%{pages: pages}) when is_list(pages), do: length(pages)

  defp local_office_metadata_page_count(%{"pages" => pages}) when is_list(pages),
    do: length(pages)

  defp local_office_metadata_page_count(_metadata), do: nil

  defp local_hwp_to_int(i) when is_integer(i), do: i
  defp local_hwp_to_int(i) when is_binary(i), do: String.to_integer(i)

  # --- LOK office edit-session helpers ----------------------------------------

  defp with_office_edit(socket, fun) do
    case socket.assigns[:office_edit_session] do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: fun.(pid)
        :ok

      _ ->
        :ok
    end
  end

  # Translate a keydown payload into a `Libreofficex.Edit` keyboard event. A
  # named control key (Backspace/Enter/arrows/…) maps to `%{key:}`; a single
  # printable character maps to `%{text:}`. Anything else returns nil (ignored).
  @office_edit_control_keys ~w(Backspace Delete Enter Return Tab Escape ArrowDown
                               ArrowUp ArrowLeft ArrowRight Home End PageUp PageDown)
  defp office_edit_key_event(%{"key" => key}) when key in @office_edit_control_keys do
    %{key: key}
  end

  defp office_edit_key_event(%{"text" => text}) when is_binary(text) and text != "" do
    %{text: text}
  end

  defp office_edit_key_event(%{"key" => key}) when is_binary(key) do
    # A single-character printable key (e.g. "a", "1", "가") arrives as :key.
    case String.length(key) do
      1 -> %{text: key}
      _ -> nil
    end
  end

  defp office_edit_key_event(_), do: nil

  # IME composition payload -> ext_text_input event.
  defp office_edit_ime_event(%{"commit" => text}) when is_binary(text) and text != "" do
    %{commit: text}
  end

  defp office_edit_ime_event(%{"preedit" => text}) when is_binary(text) do
    %{preedit: text}
  end

  defp office_edit_ime_event(%{"end" => true}), do: %{end: true}
  defp office_edit_ime_event(_), do: nil

  defp office_edit_viewport(params) do
    %{
      page: num_to_int(Map.get(params, "page", 1)),
      x: num_to_float(Map.get(params, "x", 0)),
      y: num_to_float(Map.get(params, "y", 0)),
      width: num_to_float(Map.get(params, "width", 0)),
      height: num_to_float(Map.get(params, "height", 0))
    }
  end

  defp num_to_int(n) when is_integer(n), do: n
  defp num_to_int(n) when is_float(n), do: round(n)
  defp num_to_int(n) when is_binary(n), do: String.to_integer(n)
  defp num_to_int(_), do: 0

  defp num_to_float(n) when is_number(n), do: n / 1

  defp num_to_float(n) when is_binary(n) do
    case Float.parse(n) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp num_to_float(_), do: 0.0

  # --- office (libreofficex) tile virtualization -------------------------
  #
  # Tiles arrive incrementally and tile each page into a (mostly 256px) grid.
  # We accumulate them per page (keyed by their x/y so a re-render replaces the
  # same tile) and only composite a page's tiles into the DOM when its placeholder
  # reports near-viewport (LazyOfficeTile hook). A 1000-tile deck therefore never
  # streams its full PNG payload into a single LiveView diff, and tiles place at
  # their (x, y, w, h) inside a correctly-sized page box (no flex-wrap overlap).

  # Pre-seed one placeholder page per slide from the :ready metadata so the page
  # boxes (and their reserved sizes) exist before tiles land; the Intersection
  # Observer then hydrates the near-viewport ones.
  defp seed_local_office_pages(socket, metadata) do
    pages = office_metadata_pages(metadata)

    if pages == [] do
      socket
    else
      dims =
        Enum.reduce(pages, socket.assigns.local_office_page_dims, fn p, acc ->
          page = office_value(p, :page, map_size(acc) + 1)
          w = office_value(p, :width, 0)
          h = office_value(p, :height, 0)

          if is_integer(w) and is_integer(h) and w > 0 and h > 0,
            do: Map.put(acc, page, {w, h}),
            else: acc
        end)

      socket = assign(socket, :local_office_page_dims, dims)

      # Insert placeholders in ascending page order. `Map.keys/1` is unordered,
      # so iterating it scrambles the deck (the stream renders items in insert
      # order); sort so page 1 is first and the IntersectionObserver hydrates the
      # top of the deck first.
      dims
      |> Map.keys()
      |> Enum.sort()
      |> Enum.reduce(socket, fn page, acc ->
        stream_insert(acc, :local_hwp_pages, office_page_placeholder(acc, page))
      end)
    end
  end

  defp office_metadata_pages(%{pages: pages}) when is_list(pages), do: pages
  defp office_metadata_pages(%{"pages" => pages}) when is_list(pages), do: pages
  defp office_metadata_pages(_metadata), do: []

  defp office_value(map, key, default) do
    case Map.get(map, key, Map.get(map, Atom.to_string(key))) do
      nil -> default
      value -> value
    end
  end

  # Pull every `{:tile, ...}` for this subscription that is ALREADY sitting in
  # the mailbox so a whole page's burst is folded in one `handle_info`. We use
  # `after 0`, so this only sweeps tiles that have already arrived — any user
  # event (or tile that lands after we start draining) stays at the back of the
  # queue and is processed on the next turn, which is what keeps `tab_switch`
  # responsive. A generous cap bounds a single batch so one drain can't itself
  # become an unbounded reduction hog.
  @office_tile_drain_cap 240
  defp drain_pending_office_tiles(subscription) do
    drain_pending_office_tiles(subscription, @office_tile_drain_cap, [])
  end

  defp drain_pending_office_tiles(_subscription, 0, acc), do: Enum.reverse(acc)

  defp drain_pending_office_tiles(subscription, budget, acc) do
    receive do
      {:libreofficex, ^subscription, {:tile, tile}} ->
        drain_pending_office_tiles(subscription, budget - 1, [tile | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Fold a batch of tiles into the per-page tile maps and re-place each affected
  # page just ONCE. Each tile is base64-encoded a single time as it arrives (its
  # data URI is cached on the entry), so re-streaming a page is a cheap string copy
  # rather than a fresh encode of its whole accumulated tile set. Coalescing the
  # batch (one re-stream per page, not per tile) plus encode-once is what keeps a
  # cold render from starving the LV's user-event handling (e.g. a tab_switch).
  defp accumulate_local_office_tiles(socket, tiles) when is_list(tiles) do
    {tiles_by_page, dims, pages} =
      Enum.reduce(tiles, {socket.assigns.local_office_tiles, socket.assigns.local_office_page_dims, MapSet.new()}, fn
        tile, {tiles_acc, dims_acc, pages_acc} when is_map(tile) ->
          # A tile MUST name its own integer page. Previously a tile with a
          # missing/non-integer :page silently defaulted to page 1, so any stray
          # or malformed tile dumped its pixels into page 1's slot (and, symmetrically,
          # was the kind of misrouting that paints "page 1 everywhere"). Drop such
          # tiles instead — a slot only ever shows tiles that explicitly belong to it.
          case office_tile_page(tile) do
            nil ->
              {tiles_acc, dims_acc, pages_acc}

            page ->
              x = int_tile_value(tile, :x, 0)
              y = int_tile_value(tile, :y, 0)
              width = int_tile_value(tile, :width, 256)
              height = int_tile_value(tile, :height, 256)
              page_w = int_tile_value(tile, :page_width, 0)
              page_h = int_tile_value(tile, :page_height, 0)
              data = Map.get(tile, :data) || Map.get(tile, "data") || ""

              # Base64-encode the PNG ONCE, here, the moment a tile arrives — and
              # keep only the data-URI string (the raw bytes are needed nowhere else).
              # Previously every per-page re-stream re-encoded the page's WHOLE
              # accumulated tile set inside the diff, so a page whose N tiles trickled
              # in across N batches paid O(N^2) base64 on the LiveView's critical path,
              # delaying any tab_switch queued behind the burst. Encoding once makes it
              # O(N) total and the re-stream a trivial string copy.
              entry = %{x: x, y: y, width: width, height: height, src: tile_data_uri(data)}

              tiles_acc =
                Map.update(tiles_acc, page, %{{x, y} => entry}, fn page_tiles ->
                  Map.put(page_tiles, {x, y}, entry)
                end)

              dims_acc =
                if page_w > 0 and page_h > 0,
                  do: Map.put_new(dims_acc, page, {page_w, page_h}),
                  else: dims_acc

              {tiles_acc, dims_acc, MapSet.put(pages_acc, page)}
          end

        _tile, acc ->
          acc
      end)

    max_page = pages |> MapSet.to_list() |> Enum.max(fn -> 0 end)

    socket =
      socket
      |> assign(:local_office_tiles, tiles_by_page)
      |> assign(:local_office_page_dims, dims)
      |> maybe_expand_local_hwp_page_count(%{number: max_page})

    Enum.reduce(pages, socket, fn page, acc ->
      if MapSet.member?(acc.assigns.local_office_hydrated, page) do
        stream_insert(acc, :local_hwp_pages, office_page_hydrated(acc, page))
      else
        stream_insert(acc, :local_hwp_pages, office_page_placeholder(acc, page))
      end
    end)
  end

  # A tile's page must be a positive integer; anything else routes nowhere.
  defp office_tile_page(tile) do
    case int_tile_value(tile, :page, 0) do
      page when is_integer(page) and page > 0 -> page
      _ -> nil
    end
  end

  defp hydrate_local_office_page(socket, page) do
    socket
    |> update(:local_office_hydrated, &MapSet.put(&1, page))
    # Ask the engine to render this page's tiles on demand (it streams them back
    # as {:tile, ...}). The engine converted the doc to PDF once on subscribe but
    # rasterizes nothing until a page is requested, so a big deck opens fast and
    # only near-viewport pages ever cost a rasterize. Requesting an
    # already-rendered page is a cheap engine no-op.
    |> request_local_office_page(page)
    |> then(&stream_insert(&1, :local_hwp_pages, office_page_hydrated(&1, page)))
  end

  defp release_local_office_page(socket, page) do
    socket = update(socket, :local_office_hydrated, &MapSet.delete(&1, page))
    release_local_office_page_tiles(socket, page)
  end

  # Tell the engine to forget this off-screen page (so a scroll-back re-renders
  # it fresh) and drop its tiles from this process so the deck's full PNG payload
  # is never resident at once. We keep the page's stream item as a lightweight,
  # box-reserving placeholder.
  defp release_local_office_page_tiles(socket, page) do
    request_release_local_office_page(socket, page)

    socket
    |> update(:local_office_tiles, &Map.delete(&1, page))
    |> stream_insert(:local_hwp_pages, office_page_placeholder(socket, page))
  end

  defp request_local_office_page(%{assigns: %{local_hwp_stream_id: sub}} = socket, page)
       when not is_nil(sub) do
    if office_stream?(socket), do: local_libreofficex_runtime().request_page(sub, page)
    socket
  end

  defp request_local_office_page(socket, _page), do: socket

  defp request_release_local_office_page(%{assigns: %{local_hwp_stream_id: sub}} = socket, page)
       when not is_nil(sub) do
    if office_stream?(socket), do: local_libreofficex_runtime().release_page(sub, page)
    socket
  end

  defp request_release_local_office_page(socket, _page), do: socket

  # Translate a LOK cursor callback into the shared `ehwp_native_cursor` client
  # event (the LocalEhwpEditor hook draws the caret from this), so an office
  # caret is drawn the same way as the HWP caret. The LOK rect is
  # `{x, y, w, h}` on a 1-based `page`; the client draws into the page's tile box
  # using page-relative coordinates, so we forward x/y/height with a 0-based
  # page index. Dormant until the LOK cursor backend is built.
  defp push_office_cursor(socket, %{rect: {x, y, _w, h}, page: page}) when is_integer(page) do
    rect = %{"x" => x, "y" => y, "height" => h, "pageIndex" => page - 1, "pageNumber" => page}

    socket
    |> assign(:last_caret, rect)
    |> push_event("ehwp_native_cursor", %{"cursorRect" => rect})
  end

  defp push_office_cursor(socket, _payload), do: socket

  defp office_page_placeholder(socket, page) do
    {w, h} = office_page_dims(socket, page)

    %{
      id: local_office_page_dom_id(socket.assigns.active_document, page),
      index: page - 1,
      number: page,
      page: page,
      page_width: w,
      page_height: h,
      tiles: nil,
      w: w,
      h: h
    }
  end

  defp office_page_hydrated(socket, page) do
    {pw, ph} = office_page_dims(socket, page)

    case socket.assigns.local_office_tiles |> Map.get(page, %{}) |> Map.values() do
      [] ->
        # Hydrated (its tiles were requested) but none have rasterized back yet.
        # Render it as a placeholder — a clean, box-reserving blank — rather than an
        # empty hydrated <figure>, so the slot never sits as an ambiguous bare box.
        office_page_placeholder(socket, page)

      values ->
        tiles =
          values
          |> Enum.sort_by(&{&1.y, &1.x})
          |> Enum.map(&Map.merge(&1, %{page_width: pw, page_height: ph}))

        %{office_page_placeholder(socket, page) | tiles: tiles}
    end
  end

  # Reserve a sane box even before the page's real raster dims arrive so the
  # placeholder occupies roughly the right space (A4 portrait fallback).
  defp office_page_dims(socket, page) do
    case Map.get(socket.assigns.local_office_page_dims, page) do
      {w, h} when is_integer(w) and is_integer(h) and w > 0 and h > 0 -> {w, h}
      _ -> {1240, 1754}
    end
  end

  defp local_office_page_dom_id(%{id: id, revision: revision}, page) do
    "local-office-page-#{dom_token(id)}-r#{revision}-p#{page}"
  end

  defp local_office_page_dom_id(_document, page), do: "local-office-page-p#{page}"

  defp int_tile_value(tile, key, default) do
    string_key = Atom.to_string(key)

    case Map.get(tile, key) || Map.get(tile, string_key) do
      value when is_integer(value) -> value
      value when is_float(value) -> round(value)
      _value -> default
    end
  end

  defp tile_data_uri(data) when is_binary(data) and byte_size(data) > 0,
    do: "data:image/png;base64," <> Base.encode64(data)

  defp tile_data_uri(_data), do: ""

  defp local_libreofficex_runtime do
    Application.get_env(:ecrits, :local_libreofficex_runtime, Libreofficex)
  end

  defp local_libreofficex_opts do
    # Render tiles at 2x (retina) by default so slide text stays crisp. Only
    # visible pages are ever rasterized (lazy, on-demand via request_page), so
    # the higher DPI costs nothing for off-screen slides. The page box still
    # lays out at CSS pixels — the component sizes tiles as a percentage of the
    # page's raster dims, so a 2x raster just sharpens the same on-screen box.
    Application.get_env(:ecrits, :local_libreofficex_opts,
      tile: %{page: 1, x: 0, y: 0, width: 512, height: 512, scale: 2.0}
    )
  end

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

  defp local_agent_form(params \\ %{"message" => ""}) do
    to_form(params, as: :agent)
  end

  defp local_agent_title_form(title \\ default_local_agent_title()) do
    to_form(%{"title" => local_agent_title(title)}, as: :local_agent_title)
  end

  defp local_agent_options_form do
    to_form(%{}, as: :agent_options)
  end

  defp assign_local_agent_title(socket, title) do
    title = local_agent_title(title)

    socket
    |> assign(:local_agent_title, title)
    |> assign(:local_agent_title_form, local_agent_title_form(title))
  end

  defp local_agent_title(title) when is_binary(title) do
    title
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp local_agent_title(_title), do: ""

  defp default_local_agent_title, do: "New Chat"

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

  defp default_agent_model_id("claude"), do: "claude-default"
  defp default_agent_model_id(_provider), do: "gpt-5.5"

  defp local_agent_adapter_model(model_id) do
    case local_agent_model(model_id) do
      %{id: "claude-default"} -> nil
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
       when effort in ["minimal", "low", "medium", "high", "xhigh"],
       do: effort

  defp normalize_reasoning_effort_value(effort)
       when effort in [:minimal, :low, :medium, :high, :xhigh],
       do: Atom.to_string(effort)

  defp normalize_reasoning_effort_value(_effort), do: "medium"

  defp normalize_reasoning_for_provider(effort, provider) do
    if effort in local_agent_reasoning_efforts(provider), do: effort, else: "medium"
  end

  defp local_agent_reasoning_efforts("claude"), do: ~w(low medium high)
  defp local_agent_reasoning_efforts(_provider), do: ~w(minimal low medium high xhigh)

  defp local_agent_reasoning_label("minimal"), do: "Minimal - fastest, least tokens"
  defp local_agent_reasoning_label("low"), do: "Low - light reasoning, lower tokens"
  defp local_agent_reasoning_label("medium"), do: "Medium - balanced reasoning/tokens"
  defp local_agent_reasoning_label("high"), do: "High - deeper reasoning, more tokens"
  defp local_agent_reasoning_label("xhigh"), do: "XHigh - maximum reasoning/tokens"
  defp local_agent_reasoning_label(reasoning), do: reasoning

  defp local_agent_reasoning_short_label("minimal"), do: "Minimal"
  defp local_agent_reasoning_short_label("low"), do: "Low"
  defp local_agent_reasoning_short_label("medium"), do: "Medium"
  defp local_agent_reasoning_short_label("high"), do: "High"
  defp local_agent_reasoning_short_label("xhigh"), do: "XHigh"
  defp local_agent_reasoning_short_label(reasoning), do: reasoning

  defp local_agent_reasoning_title("minimal"),
    do: "Fastest responses with the smallest token budget."

  defp local_agent_reasoning_title("low"),
    do: "Lower-cost reasoning for routine edits and lookups."

  defp local_agent_reasoning_title("medium"), do: "Balanced reasoning depth and token usage."
  defp local_agent_reasoning_title("high"), do: "More planning tokens for harder document work."
  defp local_agent_reasoning_title("xhigh"), do: "Maximum reasoning budget for complex tasks."
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

  defp agent_user_item(turn_id, body) do
    %{
      dom_id: "local-agent-user-#{turn_id}",
      role: :user,
      status: :sent,
      body: body
    }
  end

  defp agent_assistant_item(turn_id, body, status, segment \\ 0) do
    %{
      dom_id: agent_assistant_dom_id(turn_id, segment),
      role: :agent,
      status: status,
      body: body
    }
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

  defp agent_assistant_dom_id(turn_id, segment), do: "local-agent-assistant-#{turn_id}-#{segment}"
  defp agent_reasoning_dom_id(turn_id), do: "local-agent-thinking-#{turn_id}"

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

  # Coalesces streaming text deltas into a single debounced re-render. We keep a
  # monotonic ref so a flush message that fires after the buffer was already
  # finalized (tool boundary, turn completion) is ignored. Only one timer is
  # ever outstanding: while one is pending, new deltas simply extend the
  # accumulated buffer and the in-flight timer renders the latest text.
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
  # with the accumulated partial text, in place). Do NOT emit any "Cancelled."
  # placeholder — if nothing was streamed yet, just drop the empty running bubble
  # so a cancel leaves no noise.
  defp finalize_cancelled_agent_text(socket, turn_id, partial_text, segment) do
    if is_binary(partial_text) and partial_text != "" do
      stream_insert(socket, :local_agent_items, agent_assistant_item(turn_id, partial_text, :sent, segment))
    else
      stream_delete(socket, :local_agent_items, agent_assistant_item(turn_id, "", :running, segment))
    end
  end

  defp agent_display_tool_name(name), do: name

  defp agent_tool_payload(payload) when is_binary(payload), do: payload

  defp agent_tool_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      {:error, _reason} -> inspect(payload, pretty: true)
    end
  end

  # A turn can end (complete / fail / cancel / die) while a tool_call is still
  # mid-flight — that tool_call never gets its terminal `tool_call_completed` /
  # `tool_call_failed` event, so its rail row would be stuck on "running" forever
  # even though the backend turn is already gone. On every turn terminal, flip
  # any still-tracked in-flight tool_calls to :failed so the UI never shows a
  # phantom running tool after the turn is over.
  defp finalize_dangling_tools(socket, reason) do
    active = socket.assigns[:local_agent_active_tools] || %{}

    socket =
      Enum.reduce(active, socket, fn {tool_call_id, name}, acc ->
        stream_insert(acc, :local_agent_items, agent_tool_item(tool_call_id, name, :failed, reason))
      end)

    assign(socket, :local_agent_active_tools, %{})
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

  defp agent_item_data_role(%{role: :tool}), do: "local-agent-tool"
  defp agent_item_data_role(%{role: :thinking}), do: "local-agent-thinking"
  defp agent_item_data_role(_item), do: "local-agent-message"

  defp agent_item_role(%{role: role}), do: to_string(role)
  defp agent_item_role(_item), do: "agent"

  defp agent_item_status(%{status: status}), do: to_string(status)
  defp agent_item_status(_item), do: "idle"

  # The bouncing-dots waiting indicator renders ONLY while the assistant
  # placeholder is in-flight (`running`) AND has no body yet. Without the
  # empty-body guard, every debounced `flush_local_agent_text/1` re-render
  # (which carries a non-empty body but keeps `status: :running`) re-emits the
  # span; morphdom then re-creates the animated node ~every 120ms, restarting
  # the CSS `animate-bounce` from frame 0 so the dots visibly freeze. Dropping
  # the indicator once the first token lands (matching the JS hook's
  # `agent-loading` removal and `ChatRail.agent_loading?/1`) lets the animation
  # play smoothly on the empty placeholder and resolve cleanly when prose flows.
  defp agent_item_loading?(item) do
    agent_item_status(item) == "running" and agent_item_body(item) == ""
  end

  defp agent_item_title(%{title: title}) when is_binary(title), do: agent_display_tool_name(title)
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

  defp agent_status_label(:offline), do: "Offline"
  defp agent_status_label(:starting), do: "Starting"
  defp agent_status_label(:running), do: "Running"
  defp agent_status_label(:cancelled), do: "Cancelled"
  defp agent_status_label(:failed), do: "Failed"
  defp agent_status_label(_status), do: "Idle"

  defp agent_input_placeholder(:offline), do: "Agent unavailable"
  defp agent_input_placeholder(:starting), do: "Starting agent"
  defp agent_input_placeholder(_status), do: "Ask about this workspace"

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

  # ExMCP.ACP adapter failures arrive as inspected strings (the adapter raises
  # with a descriptive message that Session inspects into the event reason). Map
  # the common provider-startup failures (missing CLI binary, bridge launch
  # failure) onto the same friendly guidance the bespoke adapters produced.
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
