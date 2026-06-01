defmodule ContractWeb.Local.WorkspaceLive do
  @moduledoc """
  Local workspace shell.
  """

  use ContractWeb, :live_view

  alias Contract.Local.ACP
  alias Contract.Local.Document
  alias Contract.Local.Document.RhwpAdapter
  alias Contract.Local.Path, as: LocalPath
  alias Contract.Local.Workspace
  alias ContractWeb.Components.LocalFileTree
  alias ContractWeb.Live.Studio.Components.EditorSurface
  alias ContractWeb.Local.WorkspaceAdapter

  @local_document_upload_max_size 50_000_000
  @employment_contract_type_key "employment_v1"
  @employment_contract_template_path "/assets/standard_contracts/employment_v1.hwp"
  @employment_contract_editables_path "/assets/standard_contracts/employment_v1.editables.json"
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
     |> stream(:local_agent_items, [])
     |> assign(:page_title, "Workspace")
     |> assign(:workspace, nil)
     |> assign(:workspace_path, nil)
     |> assign(:tree, [])
     |> assign(:expanded_paths, MapSet.new())
     |> assign(:selected_path, nil)
     |> assign(:active_document_path, nil)
     |> assign(:active_document, nil)
     |> assign(:local_document_error, nil)
     |> assign(:local_document_status, :none)
     |> assign(:local_document_snapshot, nil)
     |> assign(:workspace_error, nil)
     |> assign(:local_agent_session_id, nil)
     |> assign(:local_agent_status, :offline)
     |> assign(:local_agent_error, nil)
     |> assign(:local_agent_turn_id, nil)
     |> assign(:local_agent_text, "")
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
       accept: ~w(.hwp .hwpx),
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

    socket =
      if should_restart_local_agent_session?(
           socket,
           same_workspace?,
           provider_changed?,
           model_changed?,
           reasoning_changed?,
           access_changed?,
           previous_agent_context
         ) do
        restart_local_agent_session(socket)
      else
        socket
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
    {:noreply, assign(socket, :workspace_error, "Workspace path is required.")}
  end

  @impl true
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
        send_local_agent_turn(socket, message)
    end
  end

  def handle_event("cancel_local_agent", _params, socket) do
    session_id = socket.assigns.local_agent_session_id
    turn_id = socket.assigns.local_agent_turn_id

    if session_id && turn_id do
      case ACP.cancel(nil, session_id, turn_id) do
        {:ok, _turn} ->
          {:noreply,
           socket
           |> assign(:local_agent_status, :cancelled)
           |> assign(:local_agent_turn_id, nil)}

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

  @impl true
  def terminate(_reason, socket) do
    _ = unregister_local_rhwp_materializer_editor(active_document_id(socket))
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
          class="grid h-full min-h-0 grid-cols-1 overflow-y-auto lg:grid-cols-[var(--local-file-tree-width,260px)_minmax(0,1fr)_var(--local-chat-rail-width,340px)] lg:overflow-hidden"
        >
          <aside
            id="local-file-tree-panel"
            data-component="repo-browser"
            data-local-file-tree-panel="true"
            data-collapsed="false"
            class="relative flex min-h-0 flex-col overflow-hidden border-b border-base-300 bg-base-100 lg:border-b-0 lg:border-r"
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

                <nav
                  :if={file_breadcrumb_segments(@selected_path || @active_document_path) != []}
                  id="local-file-tree-breadcrumb"
                  aria-label="Repository path"
                  class="flex min-w-0 items-center gap-1 border-t border-base-300 px-3 py-2 text-xs text-base-content/60"
                >
                  <%= for {segment, index} <- Enum.with_index(file_breadcrumb_segments(@selected_path || @active_document_path)) do %>
                    <.icon
                      :if={index > 0}
                      name="hero-chevron-right"
                      class="size-3 shrink-0 text-base-content/35"
                    />
                    <span class="max-w-28 truncate text-base-content/80" title={segment}>
                      {segment}
                    </span>
                  <% end %>
                </nav>
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

          <section id="local-editor-shell" class="min-h-0 min-w-0 overflow-hidden bg-[var(--cs-bg)]">
            <div
              :if={@local_document_error}
              id="local-rhwp-error"
              class="m-5 rounded-md border border-error/25 bg-error/10 px-4 py-3 text-sm text-error"
            >
              {@local_document_error}
            </div>

            <EditorSurface.local_document
              :if={@active_document}
              shell_id="local-rhwp-shell"
              toolbar_id="local-rhwp-toolbar"
              frame_id="local-rhwp-editor-frame"
              document={@active_document}
              document_spec={local_document_spec(@active_document)}
              editable_spec_candidates={local_editable_spec_candidates(@active_document)}
              canvas_id={local_rhwp_dom_id(@active_document)}
              save_state={
                local_save_state(
                  @active_document,
                  @local_document_snapshot,
                  @local_document_status
                )
              }
              snapshot={local_document_snapshot(@active_document)}
            />

            <div :if={!@active_document} class="px-5 py-6">
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
            class="relative flex min-h-0 flex-col overflow-hidden border-t border-base-300 bg-base-200 text-base-content lg:h-full lg:border-l lg:border-t-0"
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
              <h2
                id="local-agent-title"
                data-role="chat-thread-title"
                title={local_agent_chat_title(@workspace)}
                class="flex min-w-0 flex-1 items-center gap-1.5 text-sm font-semibold leading-5 text-base-content"
              >
                <img
                  src={@local_agent_provider.favicon_src}
                  data-role="chat-title-favicon"
                  aria-hidden="true"
                  alt=""
                  class="size-4 shrink-0 opacity-85 [[data-theme=studio-dark]_&]:invert"
                />
                <span
                  id="local-agent-title-label"
                  data-role="chat-thread-title-label"
                  class="block h-6 min-w-0 flex-1 truncate rounded-sm border border-transparent bg-transparent px-1 py-0 text-sm font-semibold leading-6 text-base-content"
                >
                  {local_agent_chat_title(@workspace)}
                </span>
              </h2>
              <span
                id="local-agent-status"
                data-role="local-agent-status"
                aria-live="polite"
                class="sr-only"
              >
                {agent_status_label(@local_agent_status)}
              </span>
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

            <div class="flex min-h-0 flex-1 flex-col overflow-hidden">
              <div
                id="local-agent-thread"
                phx-update="stream"
                data-role="chat-stream"
                class="flex min-h-0 flex-1 flex-col items-stretch gap-3 overflow-y-auto px-3 py-3"
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
                        class="rounded border border-base-300 bg-base-100 px-3 py-2 text-[13px] leading-snug text-base-content"
                      >
                        <div class="flex items-center justify-between gap-2">
                          <span class="flex min-w-0 items-center gap-2 font-medium">
                            <.icon
                              name="hero-wrench-screwdriver"
                              class="size-4 shrink-0 text-base-content/55"
                            />
                            <span class="truncate">{agent_item_title(item)}</span>
                          </span>
                          <span class="shrink-0 text-xs text-base-content/50">
                            {agent_item_status_label(item)}
                          </span>
                        </div>
                        <p
                          :if={agent_item_body(item) != ""}
                          class="mt-1 truncate text-xs text-base-content/60"
                        >
                          {agent_item_body(item)}
                        </p>
                      </div>
                    <% "user" -> %>
                      <div
                        data-role="chat-message-body"
                        class="w-full border border-base-content/10 bg-base-300/50 px-3 py-1.5 text-[13px] leading-snug whitespace-normal break-words text-base-content/95 shadow-[inset_0_1px_3px_rgba(0,0,0,0.10)]"
                      >
                        {agent_item_body(item)}
                      </div>
                    <% _ -> %>
                      <div
                        data-role="agent-text"
                        data-message-id={dom_id}
                        aria-busy={agent_item_status(item) == "running"}
                        class="block px-3 py-1 text-[14px] leading-relaxed break-words text-base-content"
                      >
                        {agent_item_body(item)}
                        <span
                          :if={agent_item_status(item) == "running"}
                          data-role="agent-loading"
                          role="status"
                          aria-label="Agent responding"
                          class="ml-1 inline-flex h-4 translate-y-[0.125rem] items-end gap-0.5 align-baseline text-base-content/45"
                        >
                          <span
                            aria-hidden="true"
                            class="size-1 rounded-full bg-current motion-safe:animate-bounce [animation-delay:-240ms]"
                          >
                          </span>
                          <span
                            aria-hidden="true"
                            class="size-1 rounded-full bg-current motion-safe:animate-bounce [animation-delay:-120ms]"
                          >
                          </span>
                          <span
                            aria-hidden="true"
                            class="size-1 rounded-full bg-current motion-safe:animate-bounce"
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
                    phx-change="validate_local_document_upload"
                    phx-submit="send_local_agent"
                    data-role="chat-form"
                  >
                    <.input
                      field={@local_agent_form[:message]}
                      id="local-agent-input"
                      type="text"
                      autocomplete="off"
                      disabled={@local_agent_status in [:offline, :starting, :running]}
                      placeholder={agent_input_placeholder(@local_agent_status)}
                      class="block h-8 w-full border-0 bg-transparent px-3 py-1 text-[13px] leading-snug text-base-content outline-none placeholder:text-base-content/35 focus:outline-none focus:ring-0 disabled:cursor-not-allowed disabled:text-base-content/40"
                    />
                    <div class="flex items-center justify-between gap-2 px-2 pb-1.5 pt-0.5">
                      <div class="flex min-w-0 items-center gap-1">
                        <label
                          id="local-agent-upload"
                          data-role="chat-upload"
                          for={@uploads.local_document_import.ref}
                          class="inline-flex size-6 cursor-pointer items-center justify-center rounded text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
                          aria-label="Open local HWP or HWPX"
                        >
                          <.icon name="hero-paper-clip" class="size-3.5" />
                        </label>
                        <.live_file_input
                          upload={@uploads.local_document_import}
                          class="sr-only"
                          data-role="local-document-upload-file-input"
                        />
                      </div>
                      <div class="flex items-center gap-1">
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
                        <button
                          :if={@local_agent_status == :running}
                          id="local-agent-cancel"
                          type="button"
                          phx-click="cancel_local_agent"
                          data-role="chat-stop"
                          data-action="stop"
                          class="inline-flex size-6 items-center justify-center rounded bg-base-content text-base-100 transition-colors hover:bg-base-content/80"
                          aria-label="Cancel agent turn"
                        >
                          <.icon name="hero-stop" class="size-3.5" />
                        </button>
                      </div>
                    </div>
                  </.form>

                  <.form
                    for={@local_agent_options_form}
                    id="local-agent-provider-options"
                    data-role="provider-options"
                    data-selected-provider={@local_agent_provider.key}
                    data-selected-model={@local_agent_model}
                    data-selected-reasoning={@local_agent_reasoning_effort}
                    data-selected-access={@local_agent_access_control}
                    class="grid grid-cols-[minmax(0,1.35fr)_minmax(112px,0.65fr)] gap-1 border-t border-base-300 px-2 py-1.5 text-[11px] leading-5 text-base-content/60 max-sm:grid-cols-1"
                  >
                    <label
                      for="local-agent-model-select"
                      class="col-span-2 block min-w-0 max-sm:col-span-1"
                    >
                      <span class="sr-only">Model</span>
                      <select
                        id="local-agent-model-select"
                        name="model"
                        phx-click="open_local_agent_model_modal"
                        phx-focus="open_local_agent_model_modal"
                        phx-change="select_local_agent_model"
                        data-role="agent-model-select"
                        data-selected-provider={@local_agent_provider.key}
                        data-selected-model={@local_agent_model}
                        aria-label="Model"
                        aria-controls="local-agent-model-modal"
                        aria-expanded={to_string(@local_agent_model_modal_open)}
                        disabled={@local_agent_status == :starting}
                        class="h-7 w-full rounded border border-base-300 bg-base-100 px-2 text-[12px] text-base-content outline-none transition-colors focus:border-base-content/45 focus:ring-1 focus:ring-base-content/15 disabled:cursor-not-allowed disabled:opacity-50"
                      >
                        <option
                          :for={model <- local_agent_models()}
                          id={"local-agent-model-#{model.id}"}
                          value={model.id}
                          selected={model.id == @local_agent_model}
                          data-provider={model.provider}
                          data-model={model.id}
                          title={model.description}
                        >
                          {model.label}
                        </option>
                      </select>
                    </label>
                    <label for="local-agent-reasoning-select" class="block min-w-0">
                      <span class="sr-only">Reasoning</span>
                      <select
                        id="local-agent-reasoning-select"
                        name="reasoning"
                        phx-change="select_local_agent_option"
                        data-role="provider-reasoning-select"
                        data-selected-reasoning={@local_agent_reasoning_effort}
                        aria-label="Reasoning token usage"
                        class="h-7 w-full rounded border border-base-300 bg-base-100 px-2 text-[12px] text-base-content outline-none transition-colors focus:border-base-content/45 focus:ring-1 focus:ring-base-content/15"
                      >
                        <option
                          :for={effort <- local_agent_reasoning_efforts(@local_agent_provider.key)}
                          id={"local-agent-inline-reasoning-#{effort}"}
                          value={effort}
                          selected={@local_agent_reasoning_effort == effort}
                          title={local_agent_reasoning_title(effort)}
                        >
                          {local_agent_reasoning_label(effort)}
                        </option>
                      </select>
                    </label>
                    <label for="local-agent-access-select" class="block min-w-0">
                      <span class="sr-only">Access</span>
                      <select
                        id="local-agent-access-select"
                        name="access"
                        phx-change="select_local_agent_option"
                        data-role="agent-access-control"
                        data-selected-access={@local_agent_access_control}
                        aria-label="Access control"
                        class="h-7 w-full rounded border border-base-300 bg-base-100 px-2 text-[12px] text-base-content outline-none transition-colors focus:border-base-content/45 focus:ring-1 focus:ring-base-content/15"
                      >
                        <option
                          :for={access <- local_agent_access_controls()}
                          id={"local-agent-inline-access-#{access.id}"}
                          value={access.id}
                          selected={@local_agent_access_control == access.id}
                          title={local_agent_access_title(access)}
                        >
                          {access.label}
                        </option>
                      </select>
                    </label>
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
                      Model config
                    </h3>
                    <button
                      id="local-agent-model-modal-close"
                      type="button"
                      phx-click="close_local_agent_model_modal"
                      aria-label="Close model details"
                      class="inline-flex size-7 items-center justify-center rounded text-base-content/55 transition-colors hover:bg-base-200 hover:text-base-content focus:outline-none focus-visible:ring-2 focus-visible:ring-base-content/35"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </header>
                  <.form
                    for={@local_agent_options_form}
                    id="local-agent-modal-options-form"
                    class="grid gap-3 border-b border-base-300 px-3 py-3"
                  >
                    <label for="local-agent-modal-model-select" class="block min-w-0">
                      <span class="block text-xs text-base-content/55">Model</span>
                      <select
                        id="local-agent-modal-model-select"
                        name="model"
                        phx-change="select_local_agent_model"
                        data-role="agent-model-modal-select"
                        data-selected-provider={@local_agent_provider.key}
                        data-selected-model={@local_agent_model}
                        aria-label="Model"
                        class="mt-1 h-8 w-full rounded border border-base-300 bg-base-100 px-2 text-sm text-base-content outline-none transition-colors focus:border-base-content/45 focus:ring-1 focus:ring-base-content/15"
                      >
                        <option
                          :for={model <- local_agent_models()}
                          id={"local-agent-model-modal-#{model.id}"}
                          value={model.id}
                          selected={model.id == @local_agent_model}
                          data-provider={model.provider}
                          data-model={model.id}
                          title={model.description}
                        >
                          {model.label}
                        </option>
                      </select>
                    </label>

                    <label for="local-agent-modal-reasoning-select" class="block min-w-0">
                      <span class="block text-xs text-base-content/55">Reasoning / token usage</span>
                      <select
                        id="local-agent-modal-reasoning-select"
                        name="reasoning"
                        phx-change="select_local_agent_option"
                        data-role="provider-reasoning-select"
                        data-selected-reasoning={@local_agent_reasoning_effort}
                        aria-label="Reasoning"
                        class="mt-1 h-8 w-full rounded border border-base-300 bg-base-100 px-2 text-sm text-base-content outline-none transition-colors focus:border-base-content/45 focus:ring-1 focus:ring-base-content/15"
                      >
                        <option
                          :for={effort <- local_agent_reasoning_efforts(@local_agent_provider.key)}
                          id={"local-agent-reasoning-#{effort}"}
                          value={effort}
                          selected={@local_agent_reasoning_effort == effort}
                          data-role="provider-reasoning-option"
                          data-selected={to_string(@local_agent_reasoning_effort == effort)}
                          title={local_agent_reasoning_title(effort)}
                        >
                          {local_agent_reasoning_label(effort)}
                        </option>
                      </select>
                    </label>

                    <label for="local-agent-modal-access-control" class="block min-w-0">
                      <span class="block text-xs text-base-content/55">Access</span>
                      <select
                        id="local-agent-modal-access-control"
                        name="access"
                        phx-change="select_local_agent_option"
                        data-role="agent-access-control"
                        data-selected-access={@local_agent_access_control}
                        aria-label="Access control"
                        class="mt-1 h-8 w-full rounded border border-base-300 bg-base-100 px-2 text-sm text-base-content outline-none transition-colors focus:border-base-content/45 focus:ring-1 focus:ring-base-content/15"
                      >
                        <option
                          :for={access <- local_agent_access_controls()}
                          id={"local-agent-access-#{access.id}"}
                          value={access.id}
                          selected={@local_agent_access_control == access.id}
                          data-role="agent-access-option"
                          data-access={access.id}
                          data-selected={to_string(@local_agent_access_control == access.id)}
                          title={local_agent_access_title(access)}
                        >
                          {access.label}
                        </option>
                      </select>
                    </label>
                  </.form>
                  <div class="divide-y divide-base-300 px-3 py-1">
                    <div
                      :for={provider <- local_agent_provider_details(@local_agent_integrations)}
                      id={"local-agent-model-detail-#{provider.id}"}
                      data-provider={provider.id}
                      data-selected={to_string(provider.id == @local_agent_provider.key)}
                      data-status={to_string(provider.status)}
                      class="flex items-center justify-between gap-3 py-2 text-sm"
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
                    </div>
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

      {:error, reason} ->
        socket
        |> assign(:workspace_error, error_message(reason))
        |> assign(:workspace_path, nil)
        |> assign(:active_document, nil)
        |> assign(:active_document_path, nil)
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
    |> assign(:active_document_path, nil)
    |> assign(:active_document, nil)
    |> assign(:local_document_status, :none)
    |> assign(:local_document_snapshot, nil)
    |> maybe_restart_local_agent_for_document(previous_document_id)
  end

  defp open_local_document(%{assigns: %{workspace: nil}} = socket, _path), do: socket

  defp open_local_document(socket, path) do
    root = workspace_root_path(socket.assigns.workspace)
    previous_document_id = active_document_id(socket)

    case RhwpAdapter.open(root, path) do
      {:ok, response} ->
        if connected?(socket) do
          :ok = Document.subscribe(response.document_id)
          update_local_rhwp_materializer_editor(previous_document_id, response.document_id)
        end

        socket =
          socket
          |> assign(:selected_path, response.relative_path)
          |> assign(:active_document_path, response.relative_path)
          |> assign(:active_document, document_summary(response))
          |> assign(:local_document_status, :opened)
          |> assign(:local_document_snapshot, nil)
          |> assign(:local_document_error, nil)

        maybe_restart_local_agent_for_document(socket, previous_document_id)

      {:error, reason} ->
        _ = unregister_local_rhwp_materializer_editor(previous_document_id)

        socket
        |> assign(:selected_path, path)
        |> assign(:active_document_path, nil)
        |> assign(:active_document, nil)
        |> assign(:local_document_status, :error)
        |> assign(:local_document_error, error_message(reason))
    end
  end

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
    |> assign(:local_agent_form, local_agent_form())
    |> stream(:local_agent_items, [], reset: true)
    |> start_local_agent_session()
  end

  defp should_restart_local_agent_session?(
         socket,
         same_workspace?,
         provider_changed?,
         model_changed?,
         reasoning_changed?,
         access_changed?,
         previous_agent_context
       ) do
    is_nil(socket.assigns.workspace_error) and
      (not same_workspace? or provider_changed? or model_changed? or reasoning_changed? or
         access_changed? or
         previous_agent_context != local_agent_session_context(socket))
  end

  defp local_agent_session_context(socket) do
    {
      socket.assigns.workspace_path,
      active_document_id(socket),
      socket.assigns.active_document_path,
      socket.assigns.local_agent_model
    }
  end

  defp maybe_cancel_active_local_agent(%{
         assigns: %{local_agent_session_id: session_id, local_agent_turn_id: turn_id}
       })
       when is_binary(session_id) and is_binary(turn_id) do
    _ = ACP.cancel(nil, session_id, turn_id)
    :ok
  end

  defp maybe_cancel_active_local_agent(_socket), do: :ok

  defp send_local_agent_turn(socket, message) do
    session_id = socket.assigns.local_agent_session_id

    case ACP.send_turn(nil, session_id, message) do
      {:ok, %{id: turn_id}} ->
        {:noreply,
         socket
         |> stream_insert(:local_agent_items, agent_user_item(turn_id, message))
         |> stream_insert(:local_agent_items, agent_assistant_item(turn_id, "", :running))
         |> assign(:local_agent_turn_id, turn_id)
         |> assign(:local_agent_text, "")
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

  defp apply_local_agent_event(socket, %{type: :text_delta, turn_id: turn_id, delta: delta})
       when is_binary(delta) do
    text = socket.assigns.local_agent_text <> delta

    socket
    |> assign(:local_agent_text, text)
    |> stream_insert(:local_agent_items, agent_assistant_item(turn_id, text, :running))
  end

  defp apply_local_agent_event(socket, %{
         type: :tool_call_started,
         tool_call_id: tool_call_id,
         name: name,
         arguments: arguments
       }) do
    stream_insert(
      socket,
      :local_agent_items,
      agent_tool_item(tool_call_id, name, :running, inspect(arguments))
    )
  end

  defp apply_local_agent_event(socket, %{
         type: :tool_call_completed,
         tool_call_id: tool_call_id,
         name: name,
         result: result
       }) do
    stream_insert(
      socket,
      :local_agent_items,
      agent_tool_item(tool_call_id, name, :completed, inspect(result))
    )
  end

  defp apply_local_agent_event(socket, %{
         type: :tool_call_failed,
         tool_call_id: tool_call_id,
         name: name,
         reason: reason
       }) do
    stream_insert(
      socket,
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
      socket,
      :local_agent_items,
      agent_tool_item(tool_call_id, name, :approval_required, inspect(arguments))
    )
  end

  defp apply_local_agent_event(socket, %{type: :turn_completed, turn_id: turn_id, text: text}) do
    text = text || socket.assigns.local_agent_text

    socket
    |> assign(:local_agent_turn_id, nil)
    |> assign(:local_agent_text, "")
    |> assign(:local_agent_status, :idle)
    |> stream_insert(:local_agent_items, agent_assistant_item(turn_id, text, :completed))
  end

  defp apply_local_agent_event(socket, %{type: :turn_cancelled, turn_id: turn_id}) do
    socket
    |> assign(:local_agent_turn_id, nil)
    |> assign(:local_agent_text, "")
    |> assign(:local_agent_status, :cancelled)
    |> stream_insert(:local_agent_items, agent_assistant_item(turn_id, "Cancelled.", :cancelled))
  end

  defp apply_local_agent_event(socket, %{type: :turn_failed, turn_id: turn_id, reason: reason}) do
    socket
    |> assign(:local_agent_turn_id, nil)
    |> assign(:local_agent_text, "")
    |> assign(:local_agent_status, :failed)
    |> assign(:local_agent_error, local_agent_error(reason))
    |> stream_insert(:local_agent_items, agent_assistant_item(turn_id, "Agent failed.", :failed))
  end

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

  defp local_document_upload_error([:not_accepted | _errors]), do: "Select an HWP or HWPX file."
  defp local_document_upload_error([:too_large | _errors]), do: "Selected file is too large."
  defp local_document_upload_error([:too_many_files | _errors]), do: "Select one file at a time."
  defp local_document_upload_error([_error | _errors]), do: "Local document import failed."

  defp local_agent_session_opts(socket) do
    workspace = socket.assigns.workspace || %{}
    workspace_path = workspace_root_path(workspace)
    local_agent_ui = Application.get_env(:contract, :local_agent_ui, [])

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
        restart_local_agent_session(socket)
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

  defp toggle_path(expanded_paths, path) do
    if MapSet.member?(expanded_paths, path) do
      MapSet.delete(expanded_paths, path)
    else
      MapSet.put(expanded_paths, path)
    end
  end

  defp workspace_title(nil), do: "Workspace"
  defp workspace_title(workspace), do: Map.get(workspace, :title) || "Workspace"

  defp local_agent_chat_title(nil), do: "Workspace chat"
  defp local_agent_chat_title(workspace), do: "#{workspace_title(workspace)} chat"

  defp workspace_root_path(nil), do: ""
  defp workspace_root_path(workspace), do: Map.get(workspace, :root_path) || ""

  defp file_breadcrumb_segments(nil), do: []
  defp file_breadcrumb_segments(""), do: []

  defp file_breadcrumb_segments(path) when is_binary(path) do
    path
    |> Path.split()
    |> Enum.reject(&(&1 in [".", ""]))
  end

  defp workspace_document_path(socket, relative_path) do
    ~p"/workspace?#{workspace_query(socket, document: relative_path, provider: socket.assigns.local_agent_provider.key)}"
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
      "HWP/HWPX open affordance selected."
    else
      "Preview state only."
    end
  end

  defp error_message({:invalid_path, message}) when is_binary(message), do: message
  defp error_message({:error, message}) when is_binary(message), do: message
  defp error_message({:local_substrate_unavailable, message}) when is_binary(message), do: message
  defp error_message(:not_found), do: "Local document session was not found."
  defp error_message(:format_mismatch), do: "Local document format did not match."
  defp error_message(:missing_bytes), do: "Local rhwp payload did not include document bytes."
  defp error_message(:stale_revision), do: "Local document changed before this save."
  defp error_message(:unsupported_format), do: "Select an HWP or HWPX file."
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

  defp local_editable_spec_candidates(document) do
    case local_document_contract_type_key(document) do
      @employment_contract_type_key ->
        [
          %{
            contractTypeKey: @employment_contract_type_key,
            documentPath: @employment_contract_template_path,
            specPath: @employment_contract_editables_path
          }
        ]

      _other ->
        []
    end
  end

  defp local_document_contract_type_key(%{relative_path: relative_path})
       when is_binary(relative_path) do
    basename = Path.basename(relative_path)

    if Regex.match?(~r/^employment_v1(?:[-_.].*| \(\d+\))?\.(hwp|hwpx)$/i, basename) do
      @employment_contract_type_key
    end
  end

  defp local_document_contract_type_key(_document), do: nil

  defp local_document_snapshot(document) do
    %{
      url: nil,
      revision: document.revision,
      lamport: 0
    }
  end

  defp local_rhwp_dom_id(%{id: id}), do: "local-rhwp-editor-#{dom_token(id)}"

  defp rhwp_request_value(request, keys) when is_map(request) do
    Enum.find_value(keys, &Map.get(request, &1))
  end

  defp rhwp_request_value(_request, _keys), do: nil

  defp maybe_put_base_snapshot(payload, %{} = base_snapshot),
    do: Map.put(payload, :base_snapshot, base_snapshot)

  defp maybe_put_base_snapshot(payload, _base_snapshot), do: payload

  defp register_local_rhwp_materializer_editor(document_id) when is_binary(document_id) do
    Contract.RhwpSnapshot.Materializer.register_editor(document_id)
  end

  defp register_local_rhwp_materializer_editor(_document_id), do: :ok

  defp unregister_local_rhwp_materializer_editor(document_id) when is_binary(document_id) do
    Contract.RhwpSnapshot.Materializer.unregister_editor(document_id)
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
    Contract.RhwpSnapshot.Materializer.ack(request_id, %{
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
    Contract.RhwpSnapshot.Materializer.ack(request_id, %{
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

  defp local_agent_models, do: @local_agent_models

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
    local_agent_ui = Application.get_env(:contract, :local_agent_ui, [])
    local_agent = Application.get_env(:contract, :local_agent, [])

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

  defp normalize_provider_id(Contract.Local.Agent.Adapters.CodexAppServer), do: "codex"
  defp normalize_provider_id(Contract.Local.Agent.Adapters.ClaudeCLI), do: "claude"

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

  defp default_reasoning_effort do
    :contract
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
    local_agent = Application.get_env(:contract, :local_agent, [])
    local_agent_ui = Application.get_env(:contract, :local_agent_ui, [])
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

  defp agent_assistant_item(turn_id, body, status) do
    %{
      dom_id: "local-agent-assistant-#{turn_id}",
      role: :agent,
      status: status,
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

  defp agent_item_data_role(%{role: :tool}), do: "local-agent-tool"
  defp agent_item_data_role(_item), do: "local-agent-message"

  defp agent_item_role(%{role: role}), do: to_string(role)
  defp agent_item_role(_item), do: "agent"

  defp agent_item_status(%{status: status}), do: to_string(status)
  defp agent_item_status(_item), do: "idle"

  defp agent_item_title(%{title: title}) when is_binary(title), do: title
  defp agent_item_title(_item), do: "Tool"

  defp agent_item_body(%{body: body}) when is_binary(body), do: body
  defp agent_item_body(_item), do: ""

  defp agent_item_status_label(%{status: :approval_required}), do: "Needs approval"

  defp agent_item_status_label(%{status: status}),
    do: status |> to_string() |> String.replace("_", " ")

  defp agent_item_status_label(_item), do: ""

  defp agent_item_class(%{role: :user}) do
    "group/message relative flex w-full flex-col items-stretch gap-0.5 self-end"
  end

  defp agent_item_class(%{role: :tool}) do
    "group/message relative flex w-full flex-col items-stretch gap-0.5"
  end

  defp agent_item_class(%{role: :system}) do
    "group/message relative flex w-full flex-col items-stretch gap-0.5 text-base-content/65"
  end

  defp agent_item_class(_item) do
    "group/message relative flex w-full flex-col items-stretch gap-0.5 self-start"
  end

  defp agent_status_label(:offline), do: "Offline"
  defp agent_status_label(:starting), do: "Starting"
  defp agent_status_label(:running), do: "Running"
  defp agent_status_label(:cancelled), do: "Cancelled"
  defp agent_status_label(:failed), do: "Failed"
  defp agent_status_label(_status), do: "Idle"

  defp agent_input_placeholder(:offline), do: "Agent unavailable"
  defp agent_input_placeholder(:starting), do: "Starting agent"
  defp agent_input_placeholder(:running), do: "Agent is responding"
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

  defp local_agent_error(reason) when is_binary(reason), do: reason
  defp local_agent_error(reason), do: inspect(reason)
end
