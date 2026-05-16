defmodule ContractWeb.Components.Breadcrumbs do
  @moduledoc """
  Consistent navigation trail rendered above the main content of every
  authenticated page (Dashboard, Settings, Studio).

  The component is intentionally dumb: it is fed a list of crumb maps and
  paints them. The shape is fixed:

      %{label: String.t(), navigate: String.t() | nil, current?: boolean()}

  The last crumb is always the current page — it has `current?: true` and
  `navigate: nil`, so it renders as plain text with `aria-current="page"`
  rather than a link.

  `build/2` is the small helper LiveViews call on mount to construct that
  list from a `Contract.Context` scope and a tiny opts map. The Studio
  LV (Wave 3C1) calls `build/2` and stuffs the result into
  `socket.assigns.breadcrumbs`; Dashboard / Settings do the same. The
  layout reads `@breadcrumbs` and passes it as `trail={...}`.

  Truncation: crumb labels longer than 40 characters are displayed with
  an ellipsis, but the full label is preserved verbatim in the `title`
  attribute and in `aria-label` so screen readers and hover tooltips
  still see the original. The input maps are never mutated.

  Accessibility — WCAG 2.1 patterns:

    * `<nav aria-label="Breadcrumb">` wraps the trail.
    * Each crumb is an `<li>` inside a `<ul>`.
    * The current page has `aria-current="page"` and is not a link.
  """
  use Phoenix.Component

  @max_label_length 40

  attr :trail, :list,
    default: [],
    doc: "List of crumb maps. Empty list renders nothing."

  @doc """
  Renders the breadcrumb trail. If `@trail` is empty, nothing is
  rendered — useful for unauthenticated pages, where the LiveView
  simply omits the assign and the layout passes `[]`.
  """
  def breadcrumbs(assigns) do
    ~H"""
    <nav
      :if={@trail != []}
      class="text-sm breadcrumbs px-6 py-2 border-b border-base-200"
      aria-label="Breadcrumb"
    >
      <ul>
        <li :for={crumb <- @trail}>
          <.link
            :if={crumb.navigate}
            navigate={crumb.navigate}
            class="link link-hover"
            title={crumb.label}
          >
            {display_label(crumb.label)}
          </.link>
          <span
            :if={!crumb.navigate}
            aria-current="page"
            class="text-base-content/80"
            title={crumb.label}
          >
            {display_label(crumb.label)}
          </span>
        </li>
      </ul>
    </nav>
    """
  end

  @doc """
  Builds the trail map list from a scope + opts. Returns `[]` for
  unauthenticated callers.

  Recognised opts:

    * `:page` — `:dashboard | :settings | :studio`
    * `:settings_label` — label for the settings sub-page (defaults to "Account")
    * `:matter` — `%{name: String.t()}` or `nil`, required for `:studio`
    * `:document` — `%{title: String.t()}` or `nil`, optional for `:studio`
  """
  @spec build(map() | nil, keyword()) :: [map()]
  def build(nil, _opts), do: []
  def build(%{user: nil}, _opts), do: []

  def build(%{user: %{}} = _scope, opts) do
    case Keyword.get(opts, :page) do
      :dashboard ->
        [%{label: "Dashboard", navigate: nil, current?: true}]

      :settings ->
        page_label = Keyword.get(opts, :settings_label, "Account")

        [
          %{label: "Dashboard", navigate: "/dashboard", current?: false},
          %{label: "Settings", navigate: "/users/settings", current?: false},
          %{label: page_label, navigate: nil, current?: true}
        ]

      :studio ->
        matter = Keyword.get(opts, :matter)
        document = Keyword.get(opts, :document)
        studio_trail(matter, document)

      _ ->
        []
    end
  end

  def build(_scope, _opts), do: []

  defp studio_trail(nil, _document) do
    # Studio without a matter (e.g. matter picker) — just the Dashboard
    # link and a "Studio" current crumb.
    [
      %{label: "Dashboard", navigate: "/dashboard", current?: false},
      %{label: "Studio", navigate: nil, current?: true}
    ]
  end

  defp studio_trail(%{name: matter_name} = _matter, nil) do
    [
      %{label: "Dashboard", navigate: "/dashboard", current?: false},
      %{label: matter_name, navigate: nil, current?: true}
    ]
  end

  defp studio_trail(%{name: matter_name, id: matter_id} = _matter, %{title: doc_title}) do
    # Document-pivot (SPEC.md §4): the matter crumb links to the
    # workspace surface (`/workspaces/:matter_id`), not the legacy
    # `/matters/:matter_id`. The current crumb is the Document title.
    [
      %{label: "Dashboard", navigate: "/dashboard", current?: false},
      %{label: matter_name, navigate: "/workspaces/#{matter_id}", current?: false},
      %{label: doc_title, navigate: nil, current?: true}
    ]
  end

  defp studio_trail(%{name: matter_name} = _matter, %{title: doc_title}) do
    # Matter without a stable id — fall back to a non-linked matter crumb.
    [
      %{label: "Dashboard", navigate: "/dashboard", current?: false},
      %{label: matter_name, navigate: nil, current?: false},
      %{label: doc_title, navigate: nil, current?: true}
    ]
  end

  # Displayed-only truncation. The input map is never mutated; the full
  # label remains available via the `title=` attribute.
  defp display_label(label) when is_binary(label) do
    if String.length(label) > @max_label_length do
      String.slice(label, 0, @max_label_length - 1) <> "…"
    else
      label
    end
  end

  defp display_label(label), do: to_string(label)
end
