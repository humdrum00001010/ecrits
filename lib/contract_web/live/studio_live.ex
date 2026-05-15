defmodule ContractWeb.StudioLive do
  @moduledoc """
  The one big LiveView. Disposable UI process. Does NOT own document truth.

  See SPEC.md §10–§11 for the design. This module is Wave 3C1's shell
  contract — its assigns shape, dispatch funnel, and `handle_info/2` protocol
  are the seam that all 12 component subagents plug into.

  ## Assigns shape (binding contract)

  Components consume the keys listed below and nothing else. Adding a key
  here is a contract change and requires the shell coordinator to ship a
  follow-up.

      socket.assigns = %{
        # Set by on_mount
        current_scope: %Contract.Context{
          user: %Contract.Accounts.User{},
          tenant: ...,
          matter: %{id: matter_id, name: matter_name} | nil,
          perms: [...]
        },

        # Set by mount
        studio_state: %Contract.Studio.State{
          matter_id: ...,
          selected_document_id: ...,
          selected_node_id: ...,
          last_seen_revision: ...,
          mode: :no_document | :briefing | :editing | :reviewing,
          chat_open?: true,
          document_picker_open?: false,
          metadata_panel_open?: false,
          migration_panel_open?: false,
          upload_panel_open?: false,
          agent_run_id: nil
        },

        # Derived per-mount
        projection: %{nodes: ..., fields: ..., marks: ..., refs: ...},
        breadcrumbs: [%{label, navigate, current?}],
        page_title: "Studio · <matter_name>",
        reconcile_modal_open?: false,

        # LV streams (preferred over assign for collections, LV 1.1)
        streams: %{
          chat_messages: stream,
          changes: stream,
          toasts: stream
        },

        # Viewport (set by the .Viewport JS hook on connect)
        viewport: :desktop | :mobile,
        preview_modal_open?: false,

        # Reconnect tracking
        last_pubsub_message_at: ...
      }

  ## Dispatch funnel

  `event_to_action/2` is the ONE place UI events become Actions. Components
  fire `phx-click="<event_name>"` and let the shell build the typed action.
  Clauses:

      "rename_document"       → :rename_document
      "set_contract_type"     → :set_contract_type
      "edit_document"         → :edit_document
      "send_chat_message"     → :chat_message
      "revoke_change"         → :revoke_change
      "upload_document"       → :upload_document
      "create_variant"        → :create_converted_variant
      "open_document"         → :open_document
      "duplicate_document"    → :duplicate_document
      "request_export"        → :request_export
      "command_palette_picked" → resolved to the right Action.kind

  Local-only UI events (no Action emitted):

      "toggle_preview", "open_modal", "close_modal", "set_node_focus",
      "viewport_change", "noop"

  ## Protocol messages (§11)

  `handle_info/2` is the LiveView protocol surface. Every message type is
  pattern-matched explicitly. See `handle_protocol_message/2`.
  """

  use ContractWeb, :live_view

  alias Contract.Action
  alias Contract.Context
  alias Contract.Studio
  alias ContractWeb.Components.Breadcrumbs
  alias ContractWeb.Live.Studio.Components

  on_mount {ContractWeb.UserAuth, :require_authenticated}
  on_mount {ContractWeb.MatterScope, :assign_scope}

  @impl true
  def mount(params, _session, socket) do
    scope = socket.assigns.current_scope

    case Studio.load(scope, params) do
      {:ok, {studio_state, projection}} ->
        _ = Studio.subscribe(scope, studio_state)

        breadcrumbs = build_breadcrumbs(scope, studio_state, projection)

        socket =
          socket
          |> assign(:current_scope, scope)
          |> assign(:studio_state, studio_state)
          |> assign(:projection, projection)
          |> assign(:breadcrumbs, breadcrumbs)
          |> assign(:page_title, page_title(scope))
          |> assign(:viewport, :desktop)
          |> assign(:preview_modal_open?, false)
          |> assign(:reconcile_modal_open?, false)
          |> assign(:reconcile_request, nil)
          |> assign(:migration_plan, nil)
          |> assign(:last_pubsub_message_at, nil)
          |> allow_upload(:document_upload,
            accept: :any,
            max_entries: 1,
            max_file_size: 50_000_000
          )
          |> stream_configure(:chat_messages, dom_id: &"chat-msg-#{&1.id}")
          |> stream(:chat_messages, [])
          |> stream_configure(:changes, dom_id: &"change-#{&1.id}")
          |> stream(:changes, [])
          |> stream_configure(:toasts, dom_id: &"toast-#{&1.id}")
          |> stream(:toasts, [])
          |> recompute_grill_assigns()

        {:ok, socket}

      {:error, reason} ->
        socket =
          socket
          |> put_flash(:error, "Could not load Studio: #{inspect(reason)}")
          |> assign(:studio_state, %Contract.Studio.State{mode: :no_document})
          |> assign(:projection, empty_projection())
          |> assign(:breadcrumbs, build_breadcrumbs(scope, nil, nil))
          |> assign(:page_title, "Studio")
          |> assign(:viewport, :desktop)
          |> assign(:preview_modal_open?, false)
          |> assign(:reconcile_modal_open?, false)
          |> assign(:reconcile_request, nil)
          |> assign(:migration_plan, nil)
          |> assign(:last_pubsub_message_at, nil)
          |> allow_upload(:document_upload,
            accept: :any,
            max_entries: 1,
            max_file_size: 50_000_000
          )
          |> stream_configure(:chat_messages, dom_id: &"chat-msg-#{&1.id}")
          |> stream(:chat_messages, [])
          |> stream_configure(:changes, dom_id: &"change-#{&1.id}")
          |> stream(:changes, [])
          |> stream_configure(:toasts, dom_id: &"toast-#{&1.id}")
          |> stream(:toasts, [])
          |> recompute_grill_assigns()

        {:ok, socket}
    end
  end

  # ----------------------------------------------------------------------------
  # handle_event/3
  # ----------------------------------------------------------------------------

  @impl true
  def handle_event("viewport_change", %{"w" => w}, socket) when is_integer(w) do
    viewport = if w >= 1024, do: :desktop, else: :mobile
    {:noreply, assign(socket, :viewport, viewport)}
  end

  def handle_event("viewport_change", %{"w" => w}, socket) when is_binary(w) do
    case Integer.parse(w) do
      {n, _} -> handle_event("viewport_change", %{"w" => n}, socket)
      :error -> {:noreply, socket}
    end
  end

  def handle_event("toggle_preview", _params, socket) do
    {:noreply, update(socket, :preview_modal_open?, &(!&1))}
  end

  def handle_event("open_modal", %{"modal" => modal}, socket) do
    {:noreply, update_modal(socket, modal, true)}
  end

  def handle_event("close_modal", %{"modal" => modal}, socket) do
    {:noreply, update_modal(socket, modal, false)}
  end

  def handle_event("set_node_focus", %{"node_id" => node_id}, socket) do
    {:noreply,
     update(socket, :studio_state, fn state ->
       %{state | selected_node_id: node_id}
     end)}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  # ---------------------------------------------------------------------------
  # Conversion wizard events (Wave 4 — Contract.Conversion)
  # ---------------------------------------------------------------------------

  def handle_event("start_type_conversion", params, socket) do
    target_type_key =
      Map.get(params, "target_type_key") || Map.get(params, "type_key")

    scope = socket.assigns.current_scope
    state = socket.assigns.studio_state
    document_id = state && state.selected_document_id

    cond do
      is_nil(document_id) ->
        {:noreply, put_flash(socket, :error, "No document selected for conversion.")}

      is_nil(target_type_key) or target_type_key == "" ->
        {:noreply, put_flash(socket, :error, "Pick a target type first.")}

      true ->
        case Contract.Conversion.plan(scope, document_id, target_type_key, []) do
          {:ok, plan} ->
            socket =
              socket
              |> assign(:migration_plan, plan)
              |> update(:studio_state, fn st -> %{st | migration_panel_open?: true} end)

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not plan conversion: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("set_field_migration_strategy", params, socket) do
    case socket.assigns[:migration_plan] do
      nil ->
        {:noreply, put_flash(socket, :error, "No active conversion plan.")}

      %Contract.Conversion.Plan{} = plan ->
        field_id = Map.get(params, "source_field_id") || Map.get(params, "field_id")
        strategy = Map.get(params, "strategy")

        case Contract.Conversion.set_field_strategy(
               socket.assigns.current_scope,
               plan,
               to_string(field_id || ""),
               strategy
             ) do
          {:ok, new_plan} ->
            {:noreply, assign(socket, :migration_plan, new_plan)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Bad strategy: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("create_variant", _params, socket) do
    case socket.assigns[:migration_plan] do
      nil ->
        {:noreply, put_flash(socket, :error, "No active conversion plan.")}

      %Contract.Conversion.Plan{} = plan ->
        case Contract.Conversion.create_variant(socket.assigns.current_scope, plan) do
          {:ok, {%Contract.Documents.Document{} = new_doc, _change}} ->
            socket =
              socket
              |> assign(:migration_plan, nil)
              |> update(:studio_state, fn st -> %{st | migration_panel_open?: false} end)
              |> put_flash(:info, "Created variant document #{new_doc.title}.")

            {:noreply, push_navigate(socket, to: ~p"/matters/#{new_doc.matter_id}/documents/#{new_doc.id}")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Variant creation failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event(event, params, socket) do
    case event_to_action(event, params, socket.assigns) do
      {:ok, %Action{} = action} ->
        {:noreply, dispatch(socket, action)}

      :local ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unknown action: #{inspect(reason)}")}
    end
  end

  # ----------------------------------------------------------------------------
  # handle_info/2
  # ----------------------------------------------------------------------------

  @impl true
  def handle_info(message, socket) do
    socket = handle_protocol_message(message, socket)
    socket = assign(socket, :last_pubsub_message_at, DateTime.utc_now())
    {:noreply, socket}
  end

  # ----------------------------------------------------------------------------
  # dispatch/2
  # ----------------------------------------------------------------------------

  @doc """
  The ONE place that takes a typed Action and submits it through the
  product façade.

    1. Calls `Studio.submit/3`.
    2. On success: re-assigns updated state, may flash an info toast.
    3. On `{:error, _}`: flashes the error string, leaves state untouched.

  Returns the updated socket. The caller wraps in `{:noreply, ...}`.
  """
  @spec dispatch(Phoenix.LiveView.Socket.t(), Action.t()) :: Phoenix.LiveView.Socket.t()
  def dispatch(socket, %Action{} = action) do
    scope = socket.assigns.current_scope
    state = socket.assigns.studio_state

    case Studio.submit(scope, state, action) do
      {:ok, %Contract.Studio.State{} = new_state} ->
        # If a new agent run was registered, subscribe to its topic.
        if new_state.agent_run_id && new_state.agent_run_id != state.agent_run_id do
          _ = Studio.subscribe(scope, new_state)
        end

        assign(socket, :studio_state, new_state)

      {:error, reason} ->
        put_flash(socket, :error, "Could not submit action: #{inspect(reason)}")
    end
  end

  # ----------------------------------------------------------------------------
  # event_to_action/3 — the dispatch funnel
  # ----------------------------------------------------------------------------

  @doc """
  Translates a UI event name + params into a typed `Contract.Action`. Returns
  `:local` for events that don't translate to an Action (UI-only). Returns
  `{:error, reason}` for unknown events.
  """
  @spec event_to_action(String.t(), map(), map()) ::
          {:ok, Action.t()} | :local | {:error, term()}
  def event_to_action(event, params, assigns)

  def event_to_action("rename_document", params, assigns) do
    build_action(assigns, :rename_document, params)
  end

  def event_to_action("set_contract_type", params, assigns) do
    build_action(assigns, :set_contract_type, params)
  end

  def event_to_action("edit_document", params, assigns) do
    build_action(assigns, :edit_document, params)
  end

  def event_to_action("send_chat_message", params, assigns) do
    build_action(assigns, :chat_message, params, document_required: false)
  end

  def event_to_action("revoke_change", params, assigns) do
    build_action(assigns, :revoke_change, params)
  end

  def event_to_action("upload_document", params, assigns) do
    build_action(assigns, :upload_document, params, document_required: false)
  end

  # "create_variant" is intercepted by handle_event/3 directly (Wave 4 —
  # the wizard fires it with the in-flight Plan held in assigns, not as
  # an Action payload). The mapping below remains for backward compat
  # in case a caller still routes it through the funnel.
  def event_to_action("create_variant", params, assigns) do
    build_action(assigns, :create_converted_variant, params, document_required: false)
  end

  def event_to_action("open_document", params, assigns) do
    build_action(assigns, :open_document, params)
  end

  def event_to_action("duplicate_document", params, assigns) do
    build_action(assigns, :duplicate_document, params)
  end

  def event_to_action("request_export", params, assigns) do
    build_action(assigns, :request_export, params)
  end

  def event_to_action("command_palette_picked", %{"kind" => kind} = params, assigns)
      when is_binary(kind) do
    build_action(assigns, String.to_existing_atom(kind), Map.drop(params, ["kind"]),
      document_required: false
    )
  rescue
    ArgumentError -> {:error, {:unknown_palette_kind, kind}}
  end

  # Local-only UI events (no Action emitted).
  def event_to_action(local, _params, _assigns)
      when local in [
             "toggle_preview",
             "open_modal",
             "close_modal",
             "set_node_focus",
             "viewport_change"
           ] do
    :local
  end

  def event_to_action(event, _params, _assigns) do
    {:error, {:unknown_event, event}}
  end

  defp build_action(assigns, kind, params, opts \\ []) do
    document_required = Keyword.get(opts, :document_required, true)

    scope = assigns[:current_scope]
    state = assigns[:studio_state]

    actor_id = scope && scope.user && scope.user.id

    document_id =
      params["document_id"] || params[:document_id] ||
        (state && state.selected_document_id)

    matter_id =
      params["matter_id"] || params[:matter_id] ||
        (state && state.matter_id)

    if document_required and is_nil(document_id) do
      {:error, {:missing_document_id, kind}}
    else
      {:ok,
       %Action{
         kind: kind,
         actor_type: :user,
         actor_id: actor_id,
         matter_id: matter_id,
         document_id: document_id,
         base_revision: state && state.last_seen_revision,
         idempotency_key: generate_idempotency_key(),
         payload: params_to_payload(params),
         message: params["message"] || params[:message]
       }}
    end
  end

  defp params_to_payload(params) when is_map(params) do
    Map.drop(params, ["document_id", "matter_id", "message"])
  end

  defp generate_idempotency_key do
    "ui-" <> (Ecto.UUID.generate() |> String.replace("-", ""))
  end

  # ----------------------------------------------------------------------------
  # handle_protocol_message/2 — SPEC.md §11
  # ----------------------------------------------------------------------------

  @doc """
  Pattern matches every protocol message type from SPEC.md §11 and updates
  assigns/streams. Public so tests can drive the funnel directly without
  the PubSub round-trip.
  """
  @spec handle_protocol_message(term(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_protocol_message({:studio_loaded, %Contract.Studio.State{} = state}, socket) do
    assign(socket, :studio_state, state)
  end

  def handle_protocol_message({:document_selected, document_id, revision}, socket)
      when is_binary(document_id) do
    case Studio.select_document(
           socket.assigns.current_scope,
           socket.assigns.studio_state,
           document_id
         ) do
      {:ok, {new_state, projection}} ->
        socket
        |> assign(:studio_state, %{
          new_state
          | last_seen_revision: revision || new_state.last_seen_revision
        })
        |> assign(:projection, projection)

      {:error, _} ->
        socket
    end
  end

  def handle_protocol_message({:change_committed, %Contract.Change{} = change}, socket) do
    socket
    |> update(:studio_state, fn state ->
      if change.applied_revision &&
           change.applied_revision > (state.last_seen_revision || 0) do
        %{state | last_seen_revision: change.applied_revision}
      else
        state
      end
    end)
    |> stream_insert(:changes, change, at: 0)
    |> recompute_grill_assigns()
  end

  def handle_protocol_message({:change_revoked, %Contract.Change{} = change}, socket) do
    stream_insert(socket, :changes, change, at: 0)
  end

  def handle_protocol_message({:revision_conflict, change_id, node_id}, socket) do
    push_event(socket, "editor-revert", %{node_id: node_id, change_id: change_id})
  end

  def handle_protocol_message({:revoke_requested, request}, socket) do
    socket
    |> assign(:reconcile_request, request)
    |> assign(:reconcile_modal_open?, true)
    |> stream_insert(:toasts, build_toast(:info, "Revoke requested", request_summary(request)))
  end

  def handle_protocol_message({:change_reconciled, %Contract.Change{} = change}, socket) do
    socket
    |> assign(:reconcile_request, nil)
    |> assign(:reconcile_modal_open?, false)
    |> stream_insert(:changes, change, at: 0)
  end

  def handle_protocol_message({:dismiss_toast, toast_id}, socket) do
    stream_delete(socket, :toasts, %{id: toast_id})
  end

  def handle_protocol_message({:marks_changed, marks}, socket) when is_map(marks) do
    socket
    |> update(:projection, fn proj -> Map.put(proj, :marks, marks) end)
    |> recompute_grill_assigns()
  end

  def handle_protocol_message({:agent_stream, agent_run_id, stream_event}, socket) do
    bubble = %{
      id: stream_event_id(agent_run_id, stream_event),
      agent_run_id: agent_run_id,
      role: :agent,
      event: stream_event,
      transient?: true
    }

    stream_insert(socket, :chat_messages, bubble)
  end

  def handle_protocol_message({:agent_completed, agent_run_id, result}, socket) do
    bubble = %{
      id: "agent-#{agent_run_id}-final",
      agent_run_id: agent_run_id,
      role: :agent,
      result: result,
      transient?: false
    }

    socket
    |> update(:studio_state, fn state ->
      if state.agent_run_id == agent_run_id do
        %{state | agent_run_id: nil}
      else
        state
      end
    end)
    |> stream_insert(:chat_messages, bubble)
    |> recompute_grill_assigns()
  end

  def handle_protocol_message({:agent_failed, agent_run_id, reason}, socket) do
    socket
    |> update(:studio_state, fn state ->
      if state.agent_run_id == agent_run_id do
        %{state | agent_run_id: nil}
      else
        state
      end
    end)
    |> stream_insert(:toasts, build_toast(:error, "Agent failed", inspect(reason)))
    |> recompute_grill_assigns()
  end

  def handle_protocol_message({:session_stale, document_id}, socket)
      when is_binary(document_id) do
    Process.send_after(self(), {:reconnect_attempt, document_id}, 500)

    stream_insert(
      socket,
      :toasts,
      build_toast(:warning, "Session lost", "Reconnecting…")
    )
  end

  def handle_protocol_message({:session_recovered, document_id, revision}, socket)
      when is_binary(document_id) do
    socket =
      case Studio.sync(
             socket.assigns.current_scope,
             socket.assigns.studio_state,
             socket.assigns.studio_state.last_seen_revision || 0
           ) do
        {:ok, {new_state, _changes}} ->
          assign(socket, :studio_state, %{
            new_state
            | last_seen_revision: revision || new_state.last_seen_revision
          })

        {:error, _} ->
          socket
      end

    stream_insert(
      socket,
      :toasts,
      build_toast(:info, "Session recovered", "Caught up to revision #{revision}.")
    )
  end

  def handle_protocol_message({:reconnect_attempt, document_id}, socket)
      when is_binary(document_id) do
    case Studio.reload(socket.assigns.current_scope, socket.assigns.studio_state) do
      {:ok, {new_state, projection}} ->
        socket
        |> assign(:studio_state, new_state)
        |> assign(:projection, projection)

      {:error, _} ->
        socket
    end
  end

  def handle_protocol_message({:import_completed, document}, socket) do
    stream_insert(
      socket,
      :toasts,
      build_toast(:info, "Import completed", import_summary(document))
    )
  end

  def handle_protocol_message({:import_failed, import_id, reason}, socket) do
    stream_insert(
      socket,
      :toasts,
      build_toast(:error, "Import failed (#{short_id(import_id)})", inspect(reason))
    )
  end

  def handle_protocol_message({:export_ready, export}, socket) do
    stream_insert(
      socket,
      :toasts,
      build_toast(:info, "Export ready", export_summary(export))
    )
  end

  def handle_protocol_message({:export_failed, export_id, reason}, socket) do
    stream_insert(
      socket,
      :toasts,
      build_toast(:error, "Export failed (#{short_id(export_id)})", inspect(reason))
    )
  end

  def handle_protocol_message(_unknown, socket) do
    # Spec invariant 7: PubSub events are advisory. Ignore noise.
    socket
  end

  # ----------------------------------------------------------------------------
  # Render
  # ----------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      variant="split"
      breadcrumbs={@breadcrumbs}
      page_title={@page_title}
    >
      <div
        id="studio-root"
        phx-hook=".Viewport"
        class="flex flex-col h-[calc(100vh-4rem)] min-h-[480px]"
      >
        <script :type={Phoenix.LiveView.ColocatedHook} name=".Viewport">
          export default {
            mounted() {
              this.push_viewport = () => {
                const w = window.innerWidth || document.documentElement.clientWidth
                this.pushEventTo(this.el, "viewport_change", {w: w})
              }
              this.push_viewport()
              this.handler = () => {
                if (this.t) clearTimeout(this.t)
                this.t = setTimeout(this.push_viewport, 120)
              }
              window.addEventListener("resize", this.handler)
            },
            destroyed() {
              window.removeEventListener("resize", this.handler)
              if (this.t) clearTimeout(this.t)
            }
          }
        </script>

        <%!-- Desktop: 3-pane grid --%>
        <div
          :if={@viewport == :desktop}
          class="grid grid-cols-[280px_1fr_360px] flex-1 min-h-0 gap-0"
        >
          <.live_component
            module={Components.DocumentList}
            id="document-list"
            studio_state={@studio_state}
            current_scope={@current_scope}
          />
          <div class="relative min-h-0">
            <.live_component
              :if={@studio_state.mode == :reviewing}
              module={Components.Canvas.Review}
              id="canvas"
              studio_state={@studio_state}
              projection={@projection}
              current_scope={@current_scope}
              changes_stream={@streams.changes}
            />
            <.live_component
              :if={@studio_state.mode != :reviewing}
              module={canvas_module(@studio_state.mode)}
              id="canvas"
              studio_state={@studio_state}
              projection={@projection}
              current_scope={@current_scope}
            />
            <.live_component
              module={Components.MarksLayer}
              id="marks-layer"
              projection={@projection}
              studio_state={@studio_state}
              viewport={@viewport}
            />
          </div>
          <.live_component
            module={Components.ChatRail}
            id="chat-rail"
            studio_state={@studio_state}
            streams={%{chat_messages: @streams.chat_messages}}
            current_scope={@current_scope}
            grill_marks={@grill_marks}
            grill_active?={@grill_active?}
          />
        </div>

        <%!-- Mobile: chat-first --%>
        <div :if={@viewport == :mobile} class="flex flex-col flex-1 min-h-0">
          <.live_component
            module={Components.ChatRail}
            id="chat-rail-mobile"
            studio_state={@studio_state}
            streams={%{chat_messages: @streams.chat_messages}}
            current_scope={@current_scope}
            layout={:mobile_full}
            grill_marks={@grill_marks}
            grill_active?={@grill_active?}
          />

          <.live_component
            module={Components.ChatCommandButton}
            id="chat-command-button"
            current_scope={@current_scope}
            studio_state={@studio_state}
            viewport={@viewport}
          />

          <button
            type="button"
            phx-click="toggle_preview"
            class="fixed bottom-6 right-6 btn btn-primary btn-circle z-30"
            style="padding-bottom: env(safe-area-inset-bottom, 0px);"
            aria-label="Toggle document preview"
          >
            <.icon name="hero-document-text" class="size-6" />
          </button>

          <.live_component
            :if={@preview_modal_open?}
            module={Components.PreviewOverlay}
            id="preview-overlay"
            projection={@projection}
            studio_state={@studio_state}
            current_scope={@current_scope}
            viewport={@viewport}
            streams={%{changes: @streams.changes}}
          />
        </div>

        <.live_component
          module={Components.ModalHost}
          id="modal-host"
          studio_state={@studio_state}
          current_scope={@current_scope}
          projection={@projection}
          reconcile_modal_open?={@reconcile_modal_open?}
          reconcile_request={@reconcile_request}
          migration_plan={@migration_plan}
        />

        <.live_component
          module={Components.ToastQueue}
          id="toast-queue"
          streams={%{toasts: @streams.toasts}}
          viewport={@viewport}
        />
      </div>
    </Layouts.app>
    """
  end

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp canvas_module(:briefing), do: Components.Canvas.Briefing
  defp canvas_module(:editing), do: Components.Canvas.Editor
  defp canvas_module(:reviewing), do: Components.Canvas.Review
  defp canvas_module(:no_document), do: Components.Canvas.Empty
  defp canvas_module(_), do: Components.Canvas.Empty

  defp page_title(%Context{matter: %{name: name}}) when is_binary(name) do
    "Studio · " <> name
  end

  defp page_title(_), do: "Studio"

  defp build_breadcrumbs(scope, _state, _projection) do
    matter =
      case scope do
        %Context{matter: %{name: _} = m} -> m
        _ -> nil
      end

    Breadcrumbs.build(scope, page: :studio, matter: matter)
  end

  defp empty_projection, do: Contract.Runtime.State.empty_projection()

  defp update_modal(socket, "document_picker", value),
    do: put_state_flag(socket, :document_picker_open?, value)

  defp update_modal(socket, "metadata", value),
    do: put_state_flag(socket, :metadata_panel_open?, value)

  defp update_modal(socket, "migration", value),
    do: put_state_flag(socket, :migration_panel_open?, value)

  defp update_modal(socket, "upload", value),
    do: put_state_flag(socket, :upload_panel_open?, value)

  defp update_modal(socket, "reconcile", value),
    do: assign(socket, :reconcile_modal_open?, value)

  defp update_modal(socket, _other, _value), do: socket

  defp put_state_flag(socket, key, value) do
    update(socket, :studio_state, fn state -> Map.put(state, key, value) end)
  end

  defp recompute_grill_assigns(socket) do
    marks = (socket.assigns[:projection] || %{})[:marks] || %{}
    current_agent_run = socket.assigns[:studio_state] && socket.assigns.studio_state.agent_run_id

    grill_marks =
      if current_agent_run do
        marks
        |> Map.values()
        |> Enum.filter(fn m ->
          m[:intent] == :ask and
            get_in(m, [:data, "agent_run_id"]) == current_agent_run
        end)
      else
        []
      end

    socket
    |> assign(:grill_marks, grill_marks)
    |> assign(:grill_active?, grill_marks != [])
  end

  defp build_toast(level, title, body) do
    %{
      id: "toast-" <> (Ecto.UUID.generate() |> String.replace("-", "")),
      level: level,
      title: title,
      body: body,
      inserted_at: DateTime.utc_now()
    }
  end

  defp request_summary(%{id: id}), do: "Request #{short_id(id)}"
  defp request_summary(_), do: "Pending revoke."

  defp import_summary(%{title: title}) when is_binary(title), do: title
  defp import_summary(%{id: id}) when is_binary(id), do: "Document " <> short_id(id)
  defp import_summary(_), do: "Document imported."

  defp export_summary(%{download_url: url}) when is_binary(url), do: url
  defp export_summary(%{id: id}) when is_binary(id), do: "Export " <> short_id(id)
  defp export_summary(_), do: "Export ready."

  defp short_id(nil), do: "?"

  defp short_id(id) when is_binary(id) do
    case String.split(id, "-", parts: 2) do
      [head | _] -> head
      _ -> String.slice(id, 0, 8)
    end
  end

  defp short_id(other), do: inspect(other)

  defp stream_event_id(agent_run_id, %{id: id}) when not is_nil(id),
    do: "agent-#{agent_run_id}-#{id}"

  defp stream_event_id(agent_run_id, _event),
    do: "agent-#{agent_run_id}-" <> Integer.to_string(System.unique_integer([:positive]))
end
