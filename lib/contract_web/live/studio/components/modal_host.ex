defmodule ContractWeb.Live.Studio.Components.ModalHost do
  @moduledoc """
  Studio modal host (Wave 3C1 / modal-host).

  Single `Phoenix.LiveComponent` that owns every modal-style overlay in
  Studio. The parent `ContractWeb.StudioLive` toggles flags on
  `@studio_state` (or on its own `@reconcile_modal_open?` assign); this
  component renders the matching dialog, debounces Esc / backdrop close
  via colocated JS, and emits the Studio event vocabulary back to the
  parent.

  ## Modals supported

      studio_state.document_picker_open?  → document picker (search + list)
      studio_state.metadata_panel_open?   → edit document metadata
      studio_state.upload_panel_open?     → new-document upload form
      studio_state.migration_panel_open?  → type-conversion wizard (3-step)
      reconcile_modal_open?               → revoke-overlap reconciliation
      studio_state.type_picker_open?      → set-contract-type picker
      modal_param == "new_document"       → create new document picker
      modal_param == "export"             → export format picker

  The first six are driven from parent assigns. The last two live as
  local component state (`:modal_param`) because the parent's
  `update_modal/3` does not map them onto `studio_state`. The parent's
  `open_modal` event with `phx-value-modal=new_document` (or `export`)
  is also captured here via `phx-target={@myself}` so the parent does
  not need a new state field. The type-picker is also opened by the
  global Cmd+K command palette — the parent LV's
  `handle_event("command_palette_picked", %{"kind" =>
  "document.type.set"}, ...)` flips
  `studio_state.type_picker_open?` to true when no `type_key` is
  supplied, and each picker row fires `document.type.set` with the
  chosen `type_key` (which the parent's `event_to_action/3` funnel
  then converts into an Action and flips the flag back to false).

  ## Event vocabulary emitted

  All Studio events bubble up to the parent LV — never `phx-target`ed
  here — so the parent's `event_to_action/3` funnel can map them to
  Actions:

      "document.open"              (picker)
      "document.rename"            (metadata)
      "document.type.set"           (metadata)
      "document.upload"             (upload)
      "export.request"              (export picker)
      "conversion.create_variant"              (migration wizard, step 3)
      "document.create"             (new-document modal)
      "revoke.resolve"              (reconcile)

  Component-local events (target=@myself):

      "close_modal"                 — closes by clearing the parent flag
                                      (re-bubbled to the parent LV)
      "select_migration_step"       — moves wizard to step :plan|:fields|:confirm
      "set_field_strategy"          — records a per-field choice
      "set_migration_target"        — records the migration target type
      "set_modal_param"             — flips local :modal_param assign
      "key"                         — Esc dismiss

  ## Migration wizard

  Backed by `Contract.Conversion` (Wave 4). The parent LV is expected
  to:

    1. Pass `migration_plan` assign — a `%Contract.Conversion.Plan{}` —
       once the user has picked a target type. While `migration_plan`
       is `nil`, step 1 still renders the target-type dropdown.
    2. Handle the `conversion.start`, `conversion.field_strategy.set`,
       and `conversion.create_variant` events that bubble out of the wizard.
  """

  use ContractWeb, :live_component

  alias Contract.ContractTypes

  # The strategy enum mandated by SPEC for field migration. Rendered as
  # the dropdown options on step 2 of the wizard. Wave 4 will validate
  # these against `Contract.Conversion`.
  @field_strategies ~w(copy_once link_to_shared_fact derive reference_only ignore ask_user)a

  @export_formats ~w(pdf docx hwpx markdown lawyer_packet)

  # --- attrs --------------------------------------------------------------

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :current_scope, :map, required: true
  attr :projection, :map, default: %{}
  attr :document_upload, :any, default: nil
  attr :reconcile_modal_open?, :boolean, default: false
  attr :reconcile_request, :map, default: nil

  # Caller can pre-supply a list of `%{id, title, type_key}` rows for the
  # document picker; falls back to an empty list. DocumentList subagent
  # is the natural source of this data, but the picker does not depend
  # on a sibling component — it just renders whatever it's given.
  attr :documents, :list, default: []

  # Test-only — `render_component` cannot push events, so tests can
  # force step / strategy state directly.
  attr :initial_migration_step, :atom, default: nil
  attr :initial_modal_param, :string, default: nil

  # Optional — parent LV passes a built `%Contract.Conversion.Plan{}`
  # once the user has picked a target type. While `nil`, the wizard
  # renders the target-type dropdown so the user can kick the planner
  # off via `conversion.start`.
  attr :migration_plan, :any, default: nil

  # Wave 4.5 — parent flips this to `true` after the async
  # ConversionPlanJob broadcasts `{:plan_refined, plan_id}`. The wizard
  # paints a small AI-refined indicator on step 2 next to each strategy
  # row so the user knows the suggestions came from the model.
  attr :migration_plan_refined?, :boolean, default: false

  # Parent LV uses `send_update/2` to seed these when the wizard opens
  # (Wave 4 bug #2 + #3). Defaulting them to `nil` keeps the existing
  # render_component contract — the wizard's local state stays the
  # source of truth when nothing is sent.
  attr :migration_target, :any, default: nil
  attr :field_strategies, :any, default: nil

  # --- LiveComponent callbacks -------------------------------------------

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:modal_param, nil)
     |> assign(:migration_step, :plan)
     |> assign(:migration_target, nil)
     |> assign(:field_strategies, %{})
     |> assign(:picker_query, "")
     |> assign(:export_formats, @export_formats)}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign_new(:modal_param, fn -> nil end)
      |> assign_new(:migration_step, fn -> :plan end)
      |> assign_new(:migration_target, fn -> nil end)
      |> assign_new(:field_strategies, fn -> %{} end)
      |> assign_new(:picker_query, fn -> "" end)
      |> assign(:export_formats, @export_formats)
      |> assign(:id, Map.get(assigns, :id))
      |> assign(:studio_state, Map.get(assigns, :studio_state))
      |> assign(:current_scope, Map.get(assigns, :current_scope))
      |> assign(:projection, Map.get(assigns, :projection, %{}))
      |> assign(:document_upload, Map.get(assigns, :document_upload))
      |> assign(:reconcile_modal_open?, Map.get(assigns, :reconcile_modal_open?, false))
      |> assign(:reconcile_request, Map.get(assigns, :reconcile_request))
      |> assign(:documents, Map.get(assigns, :documents, []))
      |> assign(:migration_plan, Map.get(assigns, :migration_plan))
      |> assign(:migration_plan_refined?, Map.get(assigns, :migration_plan_refined?, false))

    socket =
      case Map.get(assigns, :initial_migration_step) do
        nil -> socket
        step -> assign(socket, :migration_step, step)
      end

    socket =
      case Map.get(assigns, :initial_modal_param) do
        nil -> socket
        param -> assign(socket, :modal_param, param)
      end

    # The parent LV uses send_update/2 to seed `:migration_target` and
    # `:field_strategies` when the wizard opens (Wave 4 bug #2 + #3) —
    # accept those overrides here so step 3's "Create variant" button is
    # enabled and the "전략이 지정된 필드 수" counter is non-zero from
    # the first paint, without the user touching every dropdown.
    socket =
      case Map.get(assigns, :migration_target) do
        nil -> socket
        target -> assign(socket, :migration_target, target)
      end

    socket =
      case Map.get(assigns, :field_strategies) do
        nil -> socket
        strategies when is_map(strategies) -> assign(socket, :field_strategies, strategies)
        _ -> socket
      end

    {:ok, socket}
  end

  # --- handle_event/3 ----------------------------------------------------

  # The parent's open_modal event with modal=new_document|export is not
  # mapped into studio_state by the parent's `update_modal/3`. We
  # intercept those two values locally; the others fall through to the
  # parent.
  @impl true
  def handle_event("open_modal", %{"modal" => "new_document"}, socket) do
    {:noreply, assign(socket, :modal_param, "new_document")}
  end

  def handle_event("open_modal", %{"modal" => "export"}, socket) do
    {:noreply, assign(socket, :modal_param, "export")}
  end

  def handle_event("set_modal_param", %{"value" => value}, socket) do
    {:noreply, assign(socket, :modal_param, value)}
  end

  def handle_event("close_modal_local", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal_param, nil)
     |> assign(:migration_step, :plan)
     |> assign(:migration_target, nil)
     |> assign(:field_strategies, %{})
     |> assign(:picker_query, "")}
  end

  def handle_event("select_migration_step", %{"step" => step}, socket)
      when step in ["plan", "fields", "confirm"] do
    {:noreply, assign(socket, :migration_step, String.to_atom(step))}
  end

  def handle_event("set_migration_target", %{"type_key" => key}, socket) do
    {:noreply, assign(socket, :migration_target, key)}
  end

  def handle_event(
        "set_field_strategy",
        %{"field_id" => field_id, "strategy" => strategy},
        socket
      ) do
    strategies = Map.put(socket.assigns.field_strategies, field_id, strategy)
    {:noreply, assign(socket, :field_strategies, strategies)}
  end

  def handle_event("picker_query", %{"value" => value}, socket) do
    {:noreply, assign(socket, :picker_query, value)}
  end

  # Esc keydown reaches us when the active modal is new_document/export
  # (local state). For state-driven modals, Esc bubbles to the parent
  # LV via phx-window-keydown="close_modal" (see render_*).
  def handle_event("key", %{"key" => "Escape"}, socket) do
    if socket.assigns.modal_param in ["new_document", "export"] do
      {:noreply,
       socket
       |> assign(:modal_param, nil)
       |> assign(:migration_step, :plan)
       |> assign(:migration_target, nil)
       |> assign(:field_strategies, %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("key", _params, socket), do: {:noreply, socket}

  # --- helpers -----------------------------------------------------------

  defp any_modal_open?(assigns) do
    state = assigns.studio_state

    truthy?(state && state.document_picker_open?) or
      truthy?(state && state.metadata_panel_open?) or
      truthy?(state && state.upload_panel_open?) or
      truthy?(state && state.migration_panel_open?) or
      truthy?(state && state.type_picker_open?) or
      truthy?(state && state.export_picker_open?) or
      truthy?(assigns[:reconcile_modal_open?]) or
      assigns[:modal_param] in ["new_document", "export"]
  end

  defp truthy?(true), do: true
  defp truthy?(_), do: false

  defp filter_documents(documents, ""), do: documents

  defp filter_documents(documents, query) when is_binary(query) do
    q = String.downcase(query)

    Enum.filter(documents, fn doc ->
      title = doc[:title] || doc["title"] || ""
      String.contains?(String.downcase(to_string(title)), q)
    end)
  end

  defp doc_field(doc, key) do
    doc[key] || doc[Atom.to_string(key)]
  end

  defp type_options do
    {:ok, specs} = ContractTypes.list()

    Enum.map(specs, fn spec ->
      # Use locale-aware display_name so the dropdown shows the user's
      # locale (Korean for ko, English for en). The version + key
      # suffix keeps the technical identifier visible to power users
      # since <option> can only render a single line of text.
      label = "#{ContractTypes.display_name(spec)} · #{spec.key} v#{spec.version}"
      {label, spec.key}
    end)
  end

  # Type-picker variant — returns `{display_name, key, version}` triples
  # so the row template can render the localized name prominently with a
  # `{key} v{version}` secondary line, instead of cramming everything
  # into a single <option>-style string.
  defp type_picker_rows do
    {:ok, specs} = ContractTypes.list()

    Enum.map(specs, fn spec ->
      {ContractTypes.display_name(spec), spec.key, spec.version}
    end)
  end

  defp strategy_options do
    Enum.map(@field_strategies, fn s ->
      {strategy_label(s), Atom.to_string(s)}
    end)
  end

  defp strategy_label(:copy_once), do: dgettext("studio", "Copy once (snapshot)")

  defp strategy_label(:link_to_shared_fact),
    do: dgettext("studio", "Link to shared document fact")

  defp strategy_label(:derive), do: dgettext("studio", "Derive")
  defp strategy_label(:reference_only), do: dgettext("studio", "Reference only")
  defp strategy_label(:ignore), do: dgettext("studio", "Ignore")
  defp strategy_label(:ask_user), do: dgettext("studio", "Ask user")

  defp format_label(:pdf), do: "PDF"
  defp format_label(:docx), do: "Word (.docx)"
  defp format_label(:hwpx), do: "Hangul (.hwpx)"
  defp format_label(:markdown), do: "Markdown"
  defp format_label(:lawyer_packet), do: "Lawyer packet"
  defp format_label("pdf"), do: "PDF"
  defp format_label("docx"), do: "Word (.docx)"
  defp format_label("hwpx"), do: "Hangul (.hwpx)"
  defp format_label("markdown"), do: "Markdown"
  defp format_label("lawyer_packet"), do: "Lawyer packet"
  defp format_label(other), do: to_string(other)

  # --- render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} data-role="modal-host" data-any-open={to_string(any_modal_open?(assigns))}>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ModalEsc">
        export default {
          // Forwards a single Escape keydown to the LiveComponent. The
          // component decides whether to act on it (only when one of
          // the local-state modals — new_document / export — is open;
          // for state-driven modals the dialog itself has a
          // window-keydown handler that bubbles straight to the parent
          // LV).
          mounted() {
            this.handler = (e) => {
              if (e.key === "Escape") {
                this.pushEventTo(this.el, "key", {key: "Escape"})
              }
            }
            window.addEventListener("keydown", this.handler)
          },
          destroyed() {
            window.removeEventListener("keydown", this.handler)
          }
        }
      </script>

      <div id={"#{@id}-keys"} phx-hook=".ModalEsc" phx-target={@myself} />

      <%= cond do %>
        <% @studio_state && @studio_state.document_picker_open? -> %>
          {render_document_picker(assigns)}
        <% @studio_state && @studio_state.metadata_panel_open? -> %>
          {render_metadata_panel(assigns)}
        <% @studio_state && @studio_state.upload_panel_open? -> %>
          {render_upload_panel(assigns)}
        <% @studio_state && @studio_state.migration_panel_open? -> %>
          {render_migration_wizard(assigns)}
        <% @studio_state && @studio_state.type_picker_open? -> %>
          {render_type_picker(assigns)}
        <% @studio_state && @studio_state.export_picker_open? -> %>
          {render_export_picker(assigns)}
        <% @reconcile_modal_open? -> %>
          {render_reconcile_modal(assigns)}
        <% @modal_param == "new_document" -> %>
          {render_new_document_modal(assigns)}
        <% @modal_param == "export" -> %>
          {render_export_modal(assigns)}
        <% true -> %>
          <%!-- No modal active. --%>
      <% end %>
    </div>
    """
  end

  # --- private modal renderers -----------------------------------------

  defp render_document_picker(assigns) do
    assigns =
      assigns
      |> assign(:filtered_documents, filter_documents(assigns.documents, assigns.picker_query))

    ~H"""
    <div
      id={"#{@id}-document-picker"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-document-picker-title"}
      data-modal="document_picker"
    >
      <div
        id={"#{@id}-document-picker-esc"}
        phx-window-keydown="close_modal"
        phx-key="Escape"
        phx-value-modal="document_picker"
      />
      <div
        class="modal-backdrop"
        phx-click="close_modal"
        phx-value-modal="document_picker"
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-xl">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-document-picker-title"} class="text-lg font-semibold">
            {dgettext("studio", "Switch document")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_modal"
            phx-value-modal="document_picker"
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <.form
          for={%{}}
          as={:picker}
          phx-change="picker_query"
          phx-target={@myself}
          phx-submit="picker_query"
        >
          <.input
            type="search"
            name="value"
            value={@picker_query}
            label={dgettext("studio", "Search by title")}
            phx-debounce="200"
            data-role="document-picker-search"
          />
        </.form>

        <ul class="menu menu-sm w-full mt-2" data-role="document-picker-list">
          <li :for={doc <- @filtered_documents} id={"picker-#{doc_field(doc, :id)}"}>
            <button
              type="button"
              phx-click="document.open"
              phx-value-document_id={doc_field(doc, :id)}
            >
              <span class="font-medium">{doc_field(doc, :title)}</span>
              <span :if={doc_field(doc, :type_key)} class="text-xs text-base-content/60">
                {ContractTypes.display_name(doc_field(doc, :type_key))}
              </span>
            </button>
          </li>
          <li :if={@filtered_documents == []} class="text-base-content/60 text-sm px-3 py-2">
            {dgettext("studio", "No documents found.")}
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp render_metadata_panel(assigns) do
    projection = assigns.projection || %{}

    assigns =
      assigns
      |> assign(:current_title, Map.get(projection, :title))
      |> assign(:current_type_key, Map.get(projection, :type_key))
      |> assign(:current_notes, projection |> Map.get(:metadata, %{}) |> Map.get(:notes, ""))

    ~H"""
    <div
      id={"#{@id}-metadata-panel"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-metadata-title"}
      data-modal="metadata"
    >
      <div
        id={"#{@id}-metadata-esc"}
        phx-window-keydown="close_modal"
        phx-key="Escape"
        phx-value-modal="metadata"
      />
      <div
        class="modal-backdrop"
        phx-click="close_modal"
        phx-value-modal="metadata"
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-lg">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-metadata-title"} class="text-lg font-semibold">
            {dgettext("studio", "Edit document metadata")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_modal"
            phx-value-modal="metadata"
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>
        <.form for={%{}} as={:metadata} phx-submit="document.rename" data-role="metadata-rename-form">
          <.input type="text" name="title" value={@current_title} label={dgettext("studio", "Title")} />
          <button type="submit" class="btn btn-primary btn-sm mt-2">
            {dgettext("studio", "Save title")}
          </button>
        </.form>
        <.form
          for={%{}}
          as={:type}
          phx-submit="document.type.set"
          class="mt-4"
          data-role="metadata-type-form"
        >
          <.input
            type="select"
            name="type_key"
            value={@current_type_key}
            label={dgettext("studio", "Contract type")}
            options={type_options()}
            prompt={dgettext("studio", "Choose a type…")}
          />
          <button type="submit" class="btn btn-primary btn-sm mt-2">
            {dgettext("studio", "Apply type")}
          </button>
        </.form>
        <.form
          for={%{}}
          as={:notes}
          phx-submit="document.metadata.update"
          class="mt-4"
          data-role="metadata-notes-form"
        >
          <.input
            type="textarea"
            name="notes"
            value={@current_notes}
            label={dgettext("studio", "Notes")}
          />
          <button type="submit" class="btn btn-primary btn-sm mt-2">
            {dgettext("studio", "Save notes")}
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp render_upload_panel(assigns) do
    ~H"""
    <div
      id={"#{@id}-upload-panel"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-upload-title"}
      data-modal="upload"
    >
      <div
        id={"#{@id}-upload-esc"}
        phx-window-keydown="close_modal"
        phx-key="Escape"
        phx-value-modal="upload"
      />
      <div
        class="modal-backdrop"
        phx-click="close_modal"
        phx-value-modal="upload"
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-md">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-upload-title"} class="text-lg font-semibold">
            {dgettext("studio", "Upload a document")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_modal"
            phx-value-modal="upload"
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>
        <.form
          for={%{}}
          as={:upload}
          phx-submit="document.upload"
          phx-change="document.upload.validate"
          data-role="upload-form"
        >
          <label class="block text-sm font-medium text-base-content/80">
            {dgettext("studio", "Choose a file")}
          </label>
          <%= if upload_config = @document_upload do %>
            <.live_file_input
              upload={upload_config}
              class="file-input file-input-bordered file-input-sm mt-1 w-full"
              data-role="upload-file-input"
            />
          <% else %>
            <.input
              type="file"
              name="upload"
              value={nil}
              accept=".pdf,.docx,.hwpx,.txt,.md"
              data-role="upload-file-input"
            />
          <% end %>
          <button type="submit" class="btn btn-primary btn-sm mt-2">
            {dgettext("studio", "Upload")}
          </button>
        </.form>
      </div>
    </div>
    """
  end

  defp render_migration_wizard(assigns) do
    ~H"""
    <div
      id={"#{@id}-migration-wizard"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-migration-title"}
      data-modal="migration"
    >
      <div
        id={"#{@id}-migration-esc"}
        phx-window-keydown="close_modal"
        phx-key="Escape"
        phx-value-modal="migration"
      />
      <div
        class="modal-backdrop"
        phx-click="close_modal"
        phx-value-modal="migration"
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-2xl">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-migration-title"} class="text-lg font-semibold">
            {dgettext("studio", "Convert document type")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_modal"
            phx-value-modal="migration"
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <ul class="steps w-full mb-4" data-role="migration-steps">
          <li class={["step", @migration_step in [:plan, :fields, :confirm] && "step-primary"]}>
            {dgettext("studio", "Plan")}
          </li>
          <li class={["step", @migration_step in [:fields, :confirm] && "step-primary"]}>
            {dgettext("studio", "Field strategies")}
          </li>
          <li class={["step", @migration_step == :confirm && "step-primary"]}>
            {dgettext("studio", "Confirm")}
          </li>
        </ul>

        <%= case @migration_step do %>
          <% :plan -> %>
            {render_migration_plan(assigns)}
          <% :fields -> %>
            {render_migration_fields(assigns)}
          <% :confirm -> %>
            {render_migration_confirm(assigns)}
        <% end %>
      </div>
    </div>
    """
  end

  defp render_migration_plan(assigns) do
    ~H"""
    <section data-role="migration-step-plan" data-step="plan">
      <p class="text-sm text-base-content/70 mb-3">
        {dgettext(
          "studio",
          "Pick the target contract type. The planner will report which fields can carry over."
        )}
      </p>

      <.form
        for={%{}}
        as={:plan}
        phx-change="set_migration_target"
        phx-submit="conversion.start"
        phx-target={@myself}
        data-role="migration-target-form"
      >
        <.input
          type="select"
          name="type_key"
          value={@migration_target}
          label={dgettext("studio", "Target type")}
          options={type_options()}
          prompt={dgettext("studio", "Choose a target type…")}
          data-role="migration-target-select"
        />
      </.form>

      <%= if @migration_plan do %>
        <%!--
          Mature-visual-language: NO emerald-block fill. Per
          `feedback-mature-visual-language` the wizard summary is a
          restrained hairline accent — left border + base-200 wash, no
          DaisyUI alert chip. The compatibility warning still uses the
          warning swatch (intentional alert).
        --%>
        <div
          class="border-l-2 border-primary bg-base-200 p-4 rounded-md text-sm mt-3 space-y-1"
          data-role="migration-plan-summary"
        >
          <p>
            <span class="font-medium">{dgettext("studio", "Source type:")}</span>
            <span>
              <%= if @migration_plan.source_type_key do %>
                {ContractTypes.display_name(@migration_plan.source_type_key)}
                <span class="font-mono text-xs text-base-content/60">
                  {@migration_plan.source_type_key}
                </span>
              <% else %>
                <span class="font-mono">—</span>
              <% end %>
            </span>
          </p>
          <p>
            <span class="font-medium">{dgettext("studio", "Target type:")}</span>
            <span>
              {ContractTypes.display_name(@migration_plan.target_type_key)}
              <span class="font-mono text-xs text-base-content/60">
                {@migration_plan.target_type_key}
              </span>
            </span>
          </p>
          <p>
            <span class="font-medium">{dgettext("studio", "Fields to consider:")}</span>
            <span>{length(@migration_plan.field_plans || [])}</span>
          </p>
          <p
            :if={@migration_plan.impact && @migration_plan.impact[:compatible?] == false}
            class="text-warning"
            data-role="migration-incompatible-warning"
          >
            {dgettext(
              "studio",
              "These types are not declared compatible — every field defaults to Ask user."
            )}
          </p>
        </div>
      <% else %>
        <div
          class="border-l-2 border-base-300 bg-base-200/60 p-4 rounded-md text-sm mt-3"
          data-role="migration-plan-prompt"
        >
          <span class="text-base-content/70">
            {dgettext("studio", "Choose a target type then run the planner.")}
          </span>
        </div>
      <% end %>

      <div class="modal-action">
        <button
          type="button"
          class="btn btn-sm"
          phx-click="close_modal"
          phx-value-modal="migration"
        >
          {dgettext("studio", "Cancel")}
        </button>
        <button
          :if={is_nil(@migration_plan)}
          type="button"
          class="btn btn-secondary btn-sm"
          phx-click="conversion.start"
          phx-value-target_type_key={@migration_target}
          disabled={is_nil(@migration_target)}
          data-role="migration-run-planner"
        >
          {dgettext("studio", "Run planner")}
        </button>
        <button
          :if={@migration_plan}
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="select_migration_step"
          phx-value-step="fields"
          phx-target={@myself}
          data-role="migration-next-fields"
        >
          {dgettext("studio", "Next: field strategies")}
        </button>
      </div>
    </section>
    """
  end

  defp render_migration_fields(assigns) do
    plans = (assigns.migration_plan && assigns.migration_plan.field_plans) || []
    assigns = assign(assigns, :plans, plans)

    ~H"""
    <section data-role="migration-step-fields" data-step="field-strategies">
      <p class="text-sm text-base-content/70 mb-3">
        {dgettext("studio", "Choose how each source field is carried over.")}
      </p>

      <div
        :if={@migration_plan_refined?}
        class="inline-flex items-center gap-1 text-xs text-secondary mb-2"
        data-role="migration-ai-refined-indicator"
      >
        <.icon name="hero-sparkles" class="size-3" />
        <span>{dgettext("studio", "AI-refined")}</span>
      </div>

      <%= if @plans == [] do %>
        <div class="alert alert-info" data-role="migration-fields-empty">
          <span>
            {dgettext("studio", "No source fields to migrate — go back and run the planner first.")}
          </span>
        </div>
      <% end %>

      <table class="table table-sm mt-3" data-role="migration-fields-table">
        <thead>
          <tr>
            <th>{dgettext("studio", "Source field")}</th>
            <th>{dgettext("studio", "Strategy")}</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={fp <- @plans}
            data-role="migration-field-row"
            data-source-field-id={fp.source_field_id}
          >
            <td>
              <span class="font-mono text-xs">{fp.source_field_id}</span>
              <span :if={fp.justification} class="block text-[0.65rem] text-base-content/60 mt-0.5">
                {fp.justification}
              </span>
            </td>
            <td>
              <.form
                for={%{}}
                as={:strategy}
                phx-change="conversion.field_strategy.set"
                data-role="migration-field-form"
              >
                <input type="hidden" name="source_field_id" value={fp.source_field_id} />
                <.input
                  type="select"
                  name="strategy"
                  value={Map.get(@field_strategies, fp.source_field_id, Atom.to_string(fp.strategy))}
                  options={strategy_options()}
                />
              </.form>
            </td>
          </tr>
        </tbody>
      </table>

      <div class="modal-action">
        <button
          type="button"
          class="btn btn-sm"
          phx-click="select_migration_step"
          phx-value-step="plan"
          phx-target={@myself}
        >
          {dgettext("studio", "Back")}
        </button>
        <button
          type="button"
          class="btn btn-primary btn-sm"
          phx-click="select_migration_step"
          phx-value-step="confirm"
          phx-target={@myself}
          data-role="migration-next-confirm"
        >
          {dgettext("studio", "Next: confirm")}
        </button>
      </div>
    </section>
    """
  end

  defp render_migration_confirm(assigns) do
    ~H"""
    <section data-role="migration-step-confirm" data-step="create-variant">
      <p class="text-sm text-base-content/70 mb-3">
        {dgettext(
          "studio",
          "Review and create the converted variant. This does not modify the original document."
        )}
      </p>

      <dl class="text-sm space-y-1 mb-4" data-role="migration-summary">
        <div>
          <dt class="inline font-medium">{dgettext("studio", "Target type:")}</dt>
          <dd class="inline">{@migration_target || dgettext("studio", "—")}</dd>
        </div>
        <div>
          <dt class="inline font-medium">{dgettext("studio", "Fields with explicit strategies:")}</dt>
          <dd class="inline">{map_size(@field_strategies)}</dd>
        </div>
        <div :if={@migration_plan}>
          <dt class="inline font-medium">{dgettext("studio", "Field plans:")}</dt>
          <dd class="inline">{length(@migration_plan.field_plans || [])}</dd>
        </div>
      </dl>

      <.form
        for={%{}}
        as={:variant}
        phx-submit="conversion.create_variant"
        data-role="migration-create-form"
      >
        <input type="hidden" name="target_type_key" value={@migration_target || ""} />
        <input
          type="hidden"
          name="field_strategies"
          value={Jason.encode!(@field_strategies)}
        />

        <div class="modal-action">
          <button
            type="button"
            class="btn btn-sm"
            phx-click="select_migration_step"
            phx-value-step="fields"
            phx-target={@myself}
          >
            {dgettext("studio", "Back")}
          </button>
          <button
            type="submit"
            class="btn btn-primary btn-sm"
            disabled={is_nil(@migration_target)}
            data-role="migration-create-variant"
          >
            {dgettext("studio", "Create variant")}
          </button>
        </div>
      </.form>
    </section>
    """
  end

  defp render_reconcile_modal(assigns) do
    ~H"""
    <div
      id={"#{@id}-reconcile"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-reconcile-title"}
      data-modal="reconcile"
    >
      <div
        id={"#{@id}-reconcile-esc"}
        phx-window-keydown="close_modal"
        phx-key="Escape"
        phx-value-modal="reconcile"
      />
      <div
        class="modal-backdrop"
        phx-click="close_modal"
        phx-value-modal="reconcile"
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-lg">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-reconcile-title"} class="text-lg font-semibold">
            {dgettext("studio", "Resolve revoke conflict")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="close_modal"
            phx-value-modal="reconcile"
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <p class="text-sm text-base-content/70 mb-3">
          {dgettext(
            "studio",
            "Another change has touched the same content since you asked to revoke. Choose how to proceed."
          )}
        </p>

        <pre
          class="bg-base-200 rounded-md p-3 text-xs font-mono overflow-auto max-h-48"
          data-role="reconcile-diff"
        ><%= inspect(@reconcile_request, pretty: true) %></pre>

        <div class="modal-action">
          <button
            type="button"
            class="btn btn-sm"
            phx-click="revoke.resolve"
            phx-value-resolution="cancel"
            data-role="reconcile-cancel"
          >
            {dgettext("studio", "Cancel revoke")}
          </button>
          <button
            type="button"
            class="btn btn-warning btn-sm"
            phx-click="revoke.resolve"
            phx-value-resolution="force"
            data-role="reconcile-force"
          >
            {dgettext("studio", "Force revoke")}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Per SPEC.md §18 the contract type is set AFTER creation via
  # `Action(:document.type.set)` — by the user via Cmd+K or by the
  # agent once it has read enough context. The new-document modal
  # therefore renders ONLY the title input (required). Ownership comes
  # from `current_scope`; `type_key` is intentionally omitted so the
  # command lands with `type_key: nil`.
  defp render_new_document_modal(assigns) do
    ~H"""
    <div
      id={"#{@id}-new-document"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-new-document-title"}
      data-modal="new_document"
    >
      <div
        class="modal-backdrop"
        phx-click="set_modal_param"
        phx-value-value=""
        phx-target={@myself}
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-md">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-new-document-title"} class="text-lg font-semibold">
            {dgettext("studio", "New document")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="set_modal_param"
            phx-value-value=""
            phx-target={@myself}
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <.form
          for={%{}}
          as={:document}
          phx-submit="document.create"
          data-role="new-document-form"
        >
          <%!-- No `type_key` field — SPEC.md §18 sets it later. --%>
          <.input
            type="text"
            name="title"
            value=""
            label={dgettext("studio", "Title")}
            required
          />

          <p class="text-xs text-base-content/60 mt-1" data-role="new-document-type-hint">
            {dgettext("studio", "Type is set later by you or the agent.")}
          </p>

          <%!-- Affordance to switch to the upload modal for users who
                already have a PDF/HWPX/HWP file. The parent's
                update_modal/3 maps `upload` onto
                studio_state.upload_panel_open?. --%>
          <div class="mt-3">
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="open_modal"
              phx-value-modal="upload"
              data-role="new-document-upload-link"
            >
              {dgettext("studio", "Upload from PDF/HWPX/HWP…")}
            </button>
          </div>

          <div class="modal-action">
            <button
              type="button"
              class="btn btn-sm"
              phx-click="set_modal_param"
              phx-value-value=""
              phx-target={@myself}
            >
              {dgettext("studio", "Cancel")}
            </button>
            <button type="submit" class="btn btn-primary btn-sm">
              {dgettext("studio", "Create")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  defp render_export_modal(assigns) do
    ~H"""
    <div
      id={"#{@id}-export"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-export-title"}
      data-modal="export"
    >
      <div
        class="modal-backdrop"
        phx-click="set_modal_param"
        phx-value-value=""
        phx-target={@myself}
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-md">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-export-title"} class="text-lg font-semibold">
            {dgettext("studio", "Export document")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="set_modal_param"
            phx-value-value=""
            phx-target={@myself}
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <p class="text-sm text-base-content/70 mb-3">
          {dgettext("studio", "Pick an output format.")}
        </p>

        <ul class="menu menu-sm w-full" data-role="export-format-list">
          <li :for={format <- @export_formats} id={"export-#{format}"}>
            <button
              type="button"
              phx-click="export.request"
              phx-value-format={format}
              data-format={format}
            >
              {format_label(format)}
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # State-driven export picker (Wave 3C1 small-task #77). Opened by the
  # Cmd+K command palette which routes `export.request` (no format) through
  # the parent LV; the parent flips `studio_state.export_picker_open?` and
  # this dialog renders. The form submits `export.request` with the chosen
  # `format`, the parent then emits `Action(:export.request)` and flips the
  # flag back to false. Hairline borders only per the studio visual lang.
  defp render_export_picker(assigns) do
    ~H"""
    <dialog
      :if={@studio_state.export_picker_open?}
      id={"#{@id}-export-picker"}
      class="modal modal-open"
      data-role="export-picker"
      data-modal="export"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-export-picker-title"}
    >
      <div
        id={"#{@id}-export-picker-esc"}
        phx-window-keydown="close_modal"
        phx-key="Escape"
        phx-value-modal="export"
      />
      <div
        class="modal-backdrop"
        phx-click="close_modal"
        phx-value-modal="export"
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-md border border-base-200">
        <h2 id={"#{@id}-export-picker-title"} class="font-serif text-lg mb-4">
          {dgettext("studio", "Export format")}
        </h2>
        <form phx-submit="export.request">
          <fieldset class="space-y-2">
            <label
              :for={fmt <- @export_formats}
              class="flex items-center gap-2 px-3 py-2 border border-base-200 rounded-md cursor-pointer hover:bg-base-200"
              data-role="export-picker-row"
              data-format={fmt}
            >
              <input type="radio" name="format" value={fmt} class="radio radio-sm radio-primary" />
              <span>{format_label(fmt)}</span>
            </label>
          </fieldset>
          <div class="modal-action mt-4 flex justify-end gap-2">
            <button
              type="button"
              phx-click="close_modal"
              phx-value-modal="export"
              class="link link-hover"
              data-role="export-picker-cancel"
            >
              {dgettext("studio", "취소")}
            </button>
            <button
              type="submit"
              class="btn btn-sm btn-primary"
              data-role="export-picker-submit"
            >
              {dgettext("studio", "내보내기")}
            </button>
          </div>
        </form>
      </div>
    </dialog>
    """
  end

  # Set-contract-type picker. Opened by Cmd+K → "Set contract type…" or by
  # the mobile chat-command-button (both routes fire `command_palette_picked`
  # with `kind=document.type.set` and no `type_key`; the parent LV catches
  # that case and opens this modal).
  #
  # Each row submits the `document.type.set` Action directly (bubbles to
  # the parent LV) with the picked `type_key`. The list is sourced from
  # `Contract.ContractTypes.list/0` so it stays in sync with the registry.
  defp render_type_picker(assigns) do
    assigns = assign(assigns, :contract_types, type_picker_rows())

    ~H"""
    <div
      id={"#{@id}-type-picker"}
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      aria-labelledby={"#{@id}-type-picker-title"}
      data-modal="type_picker"
      data-role="type-picker"
    >
      <div
        class="modal-backdrop"
        phx-click="set_modal_param"
        phx-value-value=""
        phx-target={@myself}
        data-role="modal-backdrop"
      />
      <div class="modal-box max-w-md">
        <header class="flex items-start justify-between mb-3">
          <h2 id={"#{@id}-type-picker-title"} class="text-lg font-semibold">
            {dgettext("studio", "Set contract type")}
          </h2>
          <button
            type="button"
            class="btn btn-sm btn-ghost btn-circle"
            phx-click="set_modal_param"
            phx-value-value=""
            phx-target={@myself}
            aria-label={dgettext("studio", "Close")}
            data-role="modal-close"
          >
            ✕
          </button>
        </header>

        <p class="text-sm text-base-content/70 mb-3">
          {dgettext("studio", "Pick a contract type for this document.")}
        </p>

        <ul class="menu menu-sm w-full" data-role="type-picker-list">
          <li :for={{label, key, version} <- @contract_types} id={"type-picker-#{key}"}>
            <button
              type="button"
              phx-click="document.type.set"
              phx-value-type_key={key}
              data-type-key={key}
              data-role="type-picker-row"
            >
              <span class="font-medium">{label}</span>
              <span class="text-xs text-base-content/60 font-mono">{key} · v{version}</span>
            </button>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
