defmodule ContractWeb.Live.Studio.Components.DocumentList do
  @moduledoc """
  Studio left rail: document tree.

  Owned by Wave 3C1 / document-list.

  ## Data sources

  `Contract.Studio.list_documents/1` is the real source. The result shape
  (document_id, title, type_key, status, last_activity_at, last_revision)
  is stable.

  ## Persona perms

    * `:viewer` — read-only; the "+ 새 문서" controls are hidden.
    * All other personas — full controls.

  ## Responsive

    * Default / `:desktop` layout — fixed-width sidebar
      (`w-[280px] border-r ...`), used inside the 3-pane studio grid.
    * `:drawer` layout — chromeless wrapper for mounting inside a mobile
      drawer; the parent provides the drawer scaffolding and passes
      `layout={:drawer}` to hint we should drop the standalone border /
      width.

  ## Events emitted

    * `phx-click="open_modal"` with `phx-value-modal="new_document"`
      → opens the new-document modal (handled by `DocumentLive`).
    * `phx-click="document.open"` with `phx-value-document_id={id}`
      -> routed through the dispatch funnel as the open-document Command.
  """
  use ContractWeb, :live_component

  @impl true
  def update(assigns, socket) do
    documents = list_documents_for_matter(assigns.current_scope, assigns.studio_state)

    socket =
      socket
      |> assign(assigns)
      |> assign(:documents, documents)
      |> assign(:can_create?, can_create?(assigns.current_scope))

    {:ok, socket}
  end

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :current_scope, :map, required: true
  attr :layout, :atom, default: :desktop, values: [:desktop, :drawer]
  attr :documents, :list, default: []
  attr :can_create?, :boolean, default: false

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id={@id}
      class={container_class(@layout)}
      data-stub="document-list"
      data-role="document-list"
      data-layout={Atom.to_string(@layout)}
      aria-label={dgettext("studio", "Documents")}
    >
      <%!-- ----------------------------------------------------------- --%>
      <%!-- Workspace header (internal: Matter)                          --%>
      <%!--                                                              --%>
      <%!-- The user-facing label is "Workspace" / "워크스페이스" per   --%>
      <%!-- SPEC.md (Document-pivot). Backend symbols (matter_name,      --%>
      <%!-- scope.matter) keep their internal names.                    --%>
      <%!-- ----------------------------------------------------------- --%>
      <header class="px-4 pt-4 pb-2 flex items-start justify-between gap-2">
        <div class="min-w-0">
          <p class="text-[0.65rem] font-medium tracking-wide uppercase text-base-content/50">
            {dgettext("studio", "Documents")}
          </p>
          <h2
            class="text-sm font-semibold tracking-tight truncate"
            title={dgettext("studio", "Documents")}
          >
            {dgettext("studio", "Documents")}
          </h2>
        </div>
        <button
          :if={@can_create?}
          type="button"
          phx-click="open_modal"
          phx-value-modal="new_document"
          class="btn btn-xs btn-ghost shrink-0"
          data-role="new-document-btn"
          aria-label={dgettext("studio", "+ New document")}
        >
          <span aria-hidden="true">+</span>
          <span class="hidden sm:inline">{dgettext("studio", "New")}</span>
        </button>
      </header>

      <%!-- ----------------------------------------------------------- --%>
      <%!-- Body                                                         --%>
      <%!-- ----------------------------------------------------------- --%>
      <%= if @documents == [] do %>
        <div
          id={"#{@id}-empty"}
          class="px-4 py-8 text-center"
          data-role="documents-empty"
        >
          <p class="text-sm font-medium">
            {dgettext("studio", "No documents yet")}
          </p>
          <p class="mt-1 text-xs text-base-content/60">
            {dgettext("studio", "Pick a contract type to start your first draft.")}
          </p>
          <button
            :if={@can_create?}
            type="button"
            phx-click="open_modal"
            phx-value-modal="new_document"
            class="btn btn-sm btn-primary mt-4"
            data-role="new-document-empty-cta"
          >
            <span aria-hidden="true">+</span>
            {dgettext("studio", "New document")}
          </button>
        </div>
      <% else %>
        <nav class="px-2 pb-4 overflow-y-auto" aria-label={dgettext("studio", "Document tree")}>
          <.document_group
            id={"#{@id}-documents"}
            heading={dgettext("studio", "Documents")}
            documents={@documents}
            selected_document_id={@studio_state.selected_document_id}
          />
        </nav>
      <% end %>
    </aside>
    """
  end

  # ---------------------------------------------------------------------------
  # Private — rendering helpers
  # ---------------------------------------------------------------------------

  attr :id, :string, required: true
  attr :heading, :string, required: true
  attr :documents, :list, required: true
  attr :selected_document_id, :string, default: nil
  attr :muted?, :boolean, default: false

  defp document_group(assigns) do
    ~H"""
    <section id={@id} class="mt-3 first:mt-1" data-role="document-group">
      <h3 class={[
        "px-2 py-1 text-[0.65rem] font-medium tracking-wide uppercase",
        if(@muted?, do: "text-base-content/40", else: "text-base-content/50")
      ]}>
        {@heading}
      </h3>
      <ul class="menu menu-sm w-full p-0 gap-0.5" role="list">
        <li :for={doc <- @documents} role="listitem" class="w-full">
          <.document_row
            document={doc}
            selected?={doc.document_id == @selected_document_id}
            muted?={@muted?}
          />
        </li>
      </ul>
    </section>
    """
  end

  attr :document, :map, required: true
  attr :selected?, :boolean, default: false
  attr :muted?, :boolean, default: false

  defp document_row(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="document.open"
      phx-value-document_id={@document.document_id}
      class={[
        "w-full text-left flex flex-col gap-1 rounded-none px-3 py-2",
        "border-l-2 transition-colors",
        if(@selected?,
          do: "bg-base-200 border-primary",
          else: "border-transparent hover:bg-base-200/60 hover:border-base-300"
        ),
        if(@muted?, do: "opacity-70", else: "")
      ]}
      data-role="document-row"
      data-document-id={@document.document_id}
      data-selected={if @selected?, do: "true", else: "false"}
      aria-current={if @selected?, do: "true", else: "false"}
    >
      <span class="flex items-center justify-between gap-2 min-w-0">
        <span class="truncate text-sm font-medium" title={@document.title}>
          {@document.title}
        </span>
        <span
          class="badge badge-ghost badge-xs shrink-0"
          title={@document.type_key}
          data-role="type-badge"
        >
          {Contract.ContractTypes.display_name(@document.type_key)}
        </span>
      </span>
      <span class="text-[0.65rem] text-base-content/50 tabular-nums">
        {format_timestamp(@document.last_activity_at)}
      </span>
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # Private — data fetching
  # ---------------------------------------------------------------------------

  defp list_documents_for_matter(scope, _state) do
    Contract.Studio.list_documents(scope)
  end

  # ---------------------------------------------------------------------------
  # Private — perm gating + small helpers
  # ---------------------------------------------------------------------------

  defp can_create?(%{perms: perms}) when is_list(perms), do: :write in perms
  defp can_create?(_), do: false

  defp container_class(:drawer) do
    "h-full overflow-y-auto bg-base-100"
  end

  defp container_class(_) do
    "w-[280px] border-r border-base-200 bg-base-100 h-full overflow-y-auto"
  end

  defp format_timestamp(nil), do: "—"

  defp format_timestamp(%NaiveDateTime{} = t),
    do: t |> DateTime.from_naive!("Etc/UTC") |> format_timestamp()

  defp format_timestamp(%DateTime{} = t) do
    diff = DateTime.diff(DateTime.utc_now(), t, :second)

    cond do
      diff < 60 -> dgettext("studio", "just now")
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86_400 -> "#{div(diff, 3600)}h"
      diff < 604_800 -> "#{div(diff, 86_400)}d"
      true -> Calendar.strftime(t, "%d %b")
    end
  end
end
