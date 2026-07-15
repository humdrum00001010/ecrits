defmodule EcritsWeb.Components.Breadcrumbs do
  @moduledoc """
  Consistent navigation trail rendered above local workspace content.

  The component is intentionally dumb: it is fed a list of crumb maps and
  paints them. The shape is fixed:

      %{label: String.t(), navigate: String.t() | nil, current?: boolean()}

  The last crumb is always the current page — it has `current?: true` and
  `navigate: nil`, so it renders as plain text with `aria-current="page"`
  rather than a link.

  `build/2` remains a compatibility helper for callers constructing local
  workspace and document trails. The layout reads `@breadcrumbs` and passes
  it as `trail={...}`.

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

    * `:page` — `:storage | :studio` (legacy names for workspace surfaces)
    * `:matter` — `%{name: String.t()}` or `nil`, accepted for backwards
      compatibility but no longer rendered as its own crumb (Document
      pivot). Studio trails are now `Storage > Document.title` (or
      `Storage > Studio` when no document is selected).
    * `:document` — `%{title: String.t()}` or `nil`, optional for `:studio`
  """
  @spec build(map() | nil, keyword()) :: [map()]
  def build(nil, _opts), do: []
  def build(%{user: nil}, _opts), do: []

  def build(%{user: %{}} = _scope, opts) do
    case Keyword.get(opts, :page) do
      :storage ->
        [%{label: "Workspace", navigate: nil, current?: true}]

      :studio ->
        matter = Keyword.get(opts, :matter)
        document = Keyword.get(opts, :document)
        studio_trail(matter, document)

      _ ->
        []
    end
  end

  def build(_scope, _opts), do: []

  # Document-pivot studio trails: Matter is internal context, not a
  # breadcrumb step. The trail is always two levels — Workspace then
  # the current Document (or "Document" when no document is loaded).
  # The `matter` arg is accepted but ignored.
  defp studio_trail(_matter, nil) do
    [
      %{label: "Workspace", navigate: "/workspace", current?: false},
      %{label: "Document", navigate: nil, current?: true}
    ]
  end

  defp studio_trail(_matter, %{title: doc_title}) do
    [
      %{label: "Workspace", navigate: "/workspace", current?: false},
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
