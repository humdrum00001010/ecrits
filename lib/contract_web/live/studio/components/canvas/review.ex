defmodule ContractWeb.Live.Studio.Components.Canvas.Review do
  @moduledoc """
  Review canvas — shown when `@studio_state.mode == :reviewing`.

  Two-column layout (1fr / 320px):

    * Left: read-only document body in `contract-body` (mono) class. Each node
      with active marks gets a small `hero-bookmark` gutter indicator with
      the active-mark count; clicking expands an inline marks panel listing
      each mark's text / source / confidence.

    * Right: chronological CHANGES FEED fed from `@changes_stream`. Each
      entry carries actor + action_kind + timestamp + message. Clicking the
      entry highlights the affected node (sets selected_node_id via the
      shell's `set_node_focus` event) and asks MarksLayer to flash the
      `#node-${node_id}` element.

  No edit affordances. Persona `:viewer` hides the revoke button; any
  persona carrying `:revoke` in `current_scope.perms` sees an inline
  "↶ Revoke" button next to each feed entry that emits `change.revoke`.

  Local-only events handled here (LiveComponent target):

    * `toggle_marks` — expands/collapses the inline marks panel for a node.

  Bubbled events (shell handles):

    * `set_node_focus` — phx-value-node_id
    * `change.revoke`  — phx-value-change_id

  Dependencies:

    * MarksLayer is expected to listen for elements with `id="node-${id}"`
      and react to the `selected_node_id` assign on the parent.
    * `@changes_stream` is populated by StudioLive's protocol message
      `:change_committed` and forwarded in as a `Phoenix.LiveView.LiveStream`
      (or a plain list of `{dom_id, change}` tuples in component tests).
  """
  use ContractWeb, :live_component

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :projection, :map, required: true
  attr :current_scope, :map, required: true
  # The shell passes the parent's changes stream directly — a
  # `Phoenix.LiveView.LiveStream` at runtime, or a plain list of
  # `{dom_id, change}` tuples in component tests. `:streams` is reserved
  # on LiveComponents, so we take a singular `:changes_stream` and forward
  # it untouched into assigns (mirroring how ChatRail accepts
  # `:chat_messages`).
  attr :changes_stream, :any, default: []

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :expanded_node_ids, MapSet.new())}
  end

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:changes_stream, fn -> [] end)
      |> assign_new(:expanded_node_ids, fn -> MapSet.new() end)

    {:ok, socket}
  end

  @impl true
  def handle_event("toggle_marks", %{"node_id" => node_id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_node_ids, node_id) do
        MapSet.delete(socket.assigns.expanded_node_ids, node_id)
      else
        MapSet.put(socket.assigns.expanded_node_ids, node_id)
      end

    {:noreply, assign(socket, :expanded_node_ids, expanded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={@id}
      class="overflow-auto bg-base-100"
      data-component="canvas-review"
      data-mode="reviewing"
    >
      <div class="grid grid-cols-[1fr_320px] gap-8 p-8 max-w-[1400px] mx-auto">
        <%!-- Document body (read-only) --%>
        <article class="font-mono text-[15px] leading-[1.65] min-w-0">
          <header class="mb-6 pb-4 border-b border-base-300">
            <div class="text-xs uppercase tracking-wider text-base-content/60 font-sans mb-1">
              {dgettext("studio", "검토 모드 / Review")}
            </div>
            <h1 class="text-2xl font-serif font-semibold">
              {document_title(@projection)}
            </h1>
          </header>

          <div :if={node_order(@projection) == []} class="text-base-content/60 italic">
            {dgettext("studio", "문서 본문이 비어 있습니다 / Empty document.")}
          </div>

          <ol class="space-y-3 list-none p-0">
            <li
              :for={node_id <- node_order(@projection)}
              id={"node-#{node_id}"}
              data-node-id={node_id}
              class={[
                "group relative rounded-md px-3 py-2 transition-colors",
                node_highlighted?(@studio_state, node_id) && "bg-warning/10 ring-1 ring-warning",
                !node_highlighted?(@studio_state, node_id) && "hover:bg-base-200/60"
              ]}
            >
              <div class="flex items-start gap-3">
                <div class="flex-1 min-w-0 whitespace-pre-wrap break-words">
                  {node_content(@projection, node_id)}
                </div>

                <button
                  :if={mark_count(@projection, node_id) > 0}
                  type="button"
                  phx-click="toggle_marks"
                  phx-value-node_id={node_id}
                  phx-target={@myself}
                  class="shrink-0 inline-flex items-center gap-1 text-xs font-sans text-info hover:text-info-content hover:bg-info/20 rounded px-2 py-1 transition-colors"
                  aria-label={
                    dgettext("studio", "마크 보기 / Show marks (%{n})",
                      n: mark_count(@projection, node_id)
                    )
                  }
                  aria-expanded={MapSet.member?(@expanded_node_ids, node_id) |> to_string()}
                >
                  <.icon name="hero-bookmark" class="size-3" />
                  <span>{mark_count(@projection, node_id)}</span>
                </button>
              </div>

              <div
                :if={MapSet.member?(@expanded_node_ids, node_id)}
                id={"node-marks-#{node_id}"}
                class="mt-2 ml-1 border-l-2 border-info/40 pl-3 py-2 space-y-2 font-sans text-sm"
                data-marks-panel-for={node_id}
              >
                <div
                  :for={mark <- marks_for_node(@projection, node_id)}
                  class="flex flex-col gap-1 text-base-content/80"
                  data-mark-id={Map.get(mark, :id)}
                >
                  <div class="flex flex-wrap items-center gap-2 text-xs">
                    <span class="badge badge-ghost badge-xs">{mark_source(mark)}</span>
                    <span class="badge badge-outline badge-xs">{mark_confidence(mark)}</span>
                    <span class="text-base-content/50 font-mono">{mark_intent(mark)}</span>
                  </div>
                  <div :if={mark_text(mark)} class="text-base-content/90">
                    {mark_text(mark)}
                  </div>
                </div>
              </div>
            </li>
          </ol>
        </article>

        <%!-- Changes feed --%>
        <aside
          class="border-l border-base-300 pl-6 font-sans min-w-0"
          aria-label={dgettext("studio", "변경 기록 / Changes feed")}
        >
          <header class="sticky top-0 bg-base-100 pb-3 mb-3 border-b border-base-300">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/70">
              {dgettext("studio", "변경 기록 / Changes")}
            </h2>
          </header>

          <ol
            id={"#{@id}-changes-feed"}
            phx-update="stream"
            class="space-y-3 list-none p-0"
            data-feed="changes"
          >
            <%!-- Always-on empty marker. CSS `:only-child` shows when feed is empty. --%>
            <li
              id={"#{@id}-changes-empty-li"}
              class="hidden only:block text-sm text-base-content/60 italic"
              data-empty-state="changes"
            >
              {dgettext("studio", "변경 기록이 없습니다")}
            </li>

            <li
              :for={{dom_id, change} <- @changes_stream}
              id={dom_id}
              class={[
                "rounded-md border border-base-300 bg-base-100 p-3 text-sm",
                "hover:border-info hover:bg-info/5 transition-colors cursor-pointer",
                change_revoked?(change) && "opacity-60"
              ]}
              data-change-id={change.id}
              data-action-kind={change.command_kind}
            >
              <button
                type="button"
                phx-click={focus_change(change)}
                phx-value-node_id={change_node_id(change)}
                class="w-full text-left flex items-start gap-2"
                aria-label={
                  dgettext("studio", "변경 강조 / Highlight change %{kind}", kind: change.command_kind)
                }
              >
                <div class="size-7 shrink-0 rounded-full bg-base-200 flex items-center justify-center text-xs font-mono">
                  {actor_initials(change)}
                </div>
                <div class="flex-1 min-w-0">
                  <div class="flex items-center gap-2 flex-wrap">
                    <span class="font-semibold text-xs">{actor_label(change)}</span>
                    <span class="badge badge-ghost badge-xs font-mono">{change.command_kind}</span>
                  </div>
                  <div class="text-xs text-base-content/60 mt-0.5">
                    {format_timestamp(change.inserted_at)}
                  </div>
                  <p :if={change.message} class="mt-1 text-base-content/80 line-clamp-3">
                    {change.message}
                  </p>
                </div>
              </button>

              <div :if={can_revoke?(@current_scope, change)} class="mt-2 flex justify-end">
                <button
                  type="button"
                  phx-click="change.revoke"
                  phx-value-change_id={change.id}
                  class="btn btn-ghost btn-xs"
                  aria-label={dgettext("studio", "변경 되돌리기 / Revoke change")}
                >
                  ↶ {dgettext("studio", "되돌리기 / Revoke")}
                </button>
              </div>
            </li>
          </ol>
        </aside>
      </div>
    </section>
    """
  end

  # ----------------------------------------------------------------------------
  # Click coordination: highlight the affected node by pushing
  # `set_node_focus` (shell will assign selected_node_id) and adding a
  # transient flash class on the node element for visual coordination
  # with MarksLayer.
  # ----------------------------------------------------------------------------

  defp focus_change(change) do
    node_id = change_node_id(change)

    js = JS.push("set_node_focus", value: %{node_id: node_id})

    if node_id do
      js
      |> JS.add_class("ring-2", to: "#node-#{node_id}", transition: "transition-shadow")
      |> JS.remove_class("ring-2",
        to: "#node-#{node_id}",
        transition: "transition-shadow",
        time: 1200
      )
      |> JS.dispatch("studio:highlight-node", to: "#node-#{node_id}")
    else
      js
    end
  end

  # ----------------------------------------------------------------------------
  # Projection accessors (defensive against partial/empty projections)
  # ----------------------------------------------------------------------------

  defp document_title(%{title: title}) when is_binary(title) and title != "", do: title
  defp document_title(_), do: dgettext("studio", "제목 없음 / Untitled")

  defp node_order(%{node_order: order}) when is_list(order), do: order
  defp node_order(_), do: []

  defp node_content(%{nodes: nodes}, node_id) when is_map(nodes) do
    case Map.get(nodes, node_id) do
      %{content: content} when is_binary(content) -> content
      _ -> ""
    end
  end

  defp node_content(_, _), do: ""

  defp marks_for_node(%{marks: marks}, node_id) when is_map(marks) do
    marks
    |> Map.values()
    |> Enum.filter(fn mark -> Map.get(mark, :target_id) == node_id end)
  end

  defp marks_for_node(_, _), do: []

  defp mark_count(projection, node_id) do
    projection |> marks_for_node(node_id) |> length()
  end

  defp mark_source(%{source: source}) when not is_nil(source), do: to_string(source)
  defp mark_source(_), do: "—"

  defp mark_confidence(%{confidence: confidence}) when not is_nil(confidence),
    do: to_string(confidence)

  defp mark_confidence(_), do: "—"

  defp mark_intent(%{intent: intent}) when not is_nil(intent), do: to_string(intent)
  defp mark_intent(_), do: ""

  defp mark_text(%{text: text}) when is_binary(text) and text != "", do: text
  defp mark_text(_), do: nil

  defp node_highlighted?(%{selected_node_id: id}, node_id) when not is_nil(id),
    do: id == node_id

  defp node_highlighted?(_, _), do: false

  # ----------------------------------------------------------------------------
  # Change accessors
  # ----------------------------------------------------------------------------

  defp change_node_id(%{affected_refs: refs}) when is_list(refs) and refs != [] do
    refs
    |> Enum.find_value(fn
      %{node_id: id} when is_binary(id) -> id
      %{"node_id" => id} when is_binary(id) -> id
      _ -> nil
    end)
  end

  defp change_node_id(_), do: nil

  defp change_revoked?(%{status: :revoked}), do: true
  defp change_revoked?(%{status: :partially_revoked}), do: true
  defp change_revoked?(_), do: false

  defp actor_label(%{actor_type: :user}), do: dgettext("studio", "사용자 / User")
  defp actor_label(%{actor_type: :agent}), do: dgettext("studio", "에이전트 / Agent")
  defp actor_label(%{actor_type: :lawyer}), do: dgettext("studio", "변호사 / Lawyer")
  defp actor_label(%{actor_type: :slack}), do: "Slack"
  defp actor_label(%{actor_type: :system}), do: dgettext("studio", "시스템 / System")
  defp actor_label(_), do: "—"

  defp actor_initials(%{actor_type: :user}), do: "U"
  defp actor_initials(%{actor_type: :agent}), do: "A"
  defp actor_initials(%{actor_type: :lawyer}), do: "L"
  defp actor_initials(%{actor_type: :slack}), do: "S"
  defp actor_initials(%{actor_type: :system}), do: "·"
  defp actor_initials(_), do: "?"

  defp format_timestamp(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  defp format_timestamp(%NaiveDateTime{} = ndt) do
    ndt
    |> NaiveDateTime.truncate(:second)
    |> Calendar.strftime("%Y-%m-%d %H:%M")
  end

  defp format_timestamp(_), do: ""

  # ----------------------------------------------------------------------------
  # Persona perm gates. `:viewer` carries only [:read] — no `:revoke` perm,
  # so the button is hidden. Active changes only.
  # ----------------------------------------------------------------------------

  defp can_revoke?(%{perms: perms}, change) when is_list(perms) do
    :revoke in perms and not change_revoked?(change)
  end

  defp can_revoke?(_, _), do: false
end
