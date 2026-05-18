defmodule ContractWeb.Live.Studio.Components.Canvas.Briefing do
  @moduledoc """
  Canvas pane shown when `studio_state.mode == :briefing` — the agent has
  triaged the document and is now grilling the user with clarifying questions.

  The body renders read-only (no edit UI): contracts still display in the
  Iosevka mono `.contract-body` style. Nodes that are the target of a
  `Mark{intent: :ask}` are wrapped in a highlighted span. Clicking the span
  emits `set_node_focus` with the node id so ChatRail can jump to the
  matching question.

  Viewer persona (perms == [:read]) sees the same body without the
  jump-to-question affordance — there is no chat to jump into.

  See SPEC.md §13 (Projection shape) / §11 (Mark intents) and Wave 3C1
  brief `lib/contract_web/live/studio/components/canvas/briefing.ex`.
  """
  use ContractWeb, :live_component

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :projection, :map, required: true
  attr :current_scope, :map, required: true

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:ask_marks_by_node, ask_marks_by_node(assigns.projection))
      |> assign(:matter_name, matter_name(assigns.current_scope))
      |> assign(:document_title, document_title(assigns.projection))
      |> assign(:viewer?, viewer?(assigns.current_scope))
      |> assign(:node_ids, node_order(assigns.projection))

    ~H"""
    <section
      id={@id}
      class="bg-base-100"
      data-component="canvas-briefing"
      data-mode="briefing"
    >
      <div class="w-full px-6 py-4">
        <article
          class="contract-body text-base-content"
          data-role="briefing-body"
          aria-readonly="true"
        >
          <%= if @node_ids == [] do %>
            <p class="text-base-content/40 italic" data-role="briefing-empty">
              {dgettext("studio", "No document content yet.")}
            </p>
          <% else %>
            <.render_node
              :for={node_id <- @node_ids}
              node={Map.get(@projection.nodes, node_id)}
              ask_marks={Map.get(@ask_marks_by_node, node_id, [])}
              viewer?={@viewer?}
            />
          <% end %>
        </article>
      </div>
    </section>
    """
  end

  # ----------------------------------------------------------------------------
  # Internal render helpers
  # ----------------------------------------------------------------------------

  attr :node, :map, required: true
  attr :ask_marks, :list, required: true
  attr :viewer?, :boolean, required: true

  defp render_node(%{node: nil} = assigns), do: ~H""

  defp render_node(%{node: %{kind: kind}} = assigns) when kind in [:footer, "footer"] do
    ~H""
  end

  defp render_node(assigns) do
    assigns =
      assigns
      |> assign(:node_class, node_kind_class(assigns.node))
      |> assign(:has_ask?, assigns.ask_marks != [])
      |> assign(:tag, node_tag(assigns.node))
      |> assign(:content, node_content(assigns.node))

    ~H"""
    <.dynamic_tag
      tag_name={@tag}
      id={"node-#{@node.id}"}
      data-node-id={@node.id}
      data-node-kind={to_string(@node.kind)}
      data-has-ask={to_string(@has_ask?)}
      class={[@node_class, "briefing-node"]}
    >
      <%= cond do %>
        <% @has_ask? and not @viewer? -> %>
          <button
            type="button"
            phx-click="set_node_focus"
            phx-value-node_id={@node.id}
            class="ask-mark inline cursor-pointer bg-warning/20 hover:bg-warning/30 rounded px-0.5 -mx-0.5 transition-colors"
            data-role="ask-mark"
            data-mark-target={@node.id}
            aria-label={dgettext("studio", "Jump to clarifying question")}
            title={ask_titles(@ask_marks)}
          >
            {@content}
          </button>
        <% @has_ask? and @viewer? -> %>
          <span
            class="ask-mark inline bg-warning/20 rounded px-0.5 -mx-0.5"
            data-role="ask-mark-readonly"
            data-mark-target={@node.id}
          >
            {@content}
          </span>
        <% true -> %>
          {@content}
      <% end %>
    </.dynamic_tag>
    """
  end

  # ----------------------------------------------------------------------------
  # Projection helpers
  # ----------------------------------------------------------------------------

  @doc false
  @spec ask_marks_by_node(map()) :: %{binary() => [map()]}
  def ask_marks_by_node(%{marks: marks}) when is_map(marks) do
    marks
    |> Map.values()
    |> Enum.filter(&ask_mark?/1)
    |> Enum.group_by(&Map.get(&1, :target_id))
    |> Map.delete(nil)
  end

  def ask_marks_by_node(_), do: %{}

  defp ask_mark?(%{intent: :ask, target_id: target}) when not is_nil(target), do: true
  defp ask_mark?(_), do: false

  defp node_order(%{node_order: order}) when is_list(order), do: order
  defp node_order(_), do: []

  defp matter_name(%{matter: %{name: name}}) when is_binary(name), do: name
  defp matter_name(_), do: nil

  defp document_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp document_title(_), do: dgettext("studio", "Untitled document")

  # A viewer persona has read perms only (no :write).
  defp viewer?(%{perms: perms}) when is_list(perms) do
    :read in perms and :write not in perms
  end

  defp viewer?(_), do: false

  # Tag mapping is conservative: headings -> h2, lists -> ul, list_items -> li,
  # everything else renders as <p> so legal copy stays as flowing paragraphs.
  defp node_tag(%{kind: :heading}), do: "h2"
  defp node_tag(%{kind: :list}), do: "ul"
  defp node_tag(%{kind: :list_item}), do: "li"
  defp node_tag(%{kind: :section}), do: "section"
  defp node_tag(_), do: "p"

  defp node_kind_class(%{kind: :heading}), do: "text-lg font-semibold mt-6 mb-2 chrome"
  defp node_kind_class(%{kind: :section}), do: "mb-4"
  defp node_kind_class(%{kind: :list}), do: "list-disc list-inside my-3"
  defp node_kind_class(%{kind: :list_item}), do: "my-1"
  defp node_kind_class(_), do: "my-3"

  defp node_content(%{content: content}) when is_binary(content), do: content
  defp node_content(_), do: ""

  defp ask_titles(marks) when is_list(marks) do
    marks
    |> Enum.map(&Map.get(&1, :text, ""))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end
end
