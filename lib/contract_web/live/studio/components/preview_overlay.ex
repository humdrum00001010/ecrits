defmodule ContractWeb.Live.Studio.Components.PreviewOverlay do
  @moduledoc """
  Mobile-only full-screen overlay that shows the document projection when
  the user taps the floating preview button (Wave 3C1 / preview-overlay).

  Per SPEC.md §10 responsive-scope: desktop renders the Canvas inline,
  mobile uses chat-first + this overlay. The component is a no-op when
  `@viewport == :desktop`.

  ## Tabs

    * `:body`    — read-only render of `@projection.nodes` (same shape as
      the inline `Canvas.Review`; render logic is inlined here because
      Canvas.Review is owned by a sibling subagent and the brief
      forbids cross-component edits).
    * `:marks`   — flat list of `@projection.marks` grouped by node,
      with click-to-jump (emits `set_node_focus`).
    * `:changes` — recent changes feed from `@streams.changes`.

  ## Persona perms

    * `:viewer` (perms list without `:write`) — only the Body tab is
      visible. The Marks and Changes tabs are hidden. Jump-to-node from
      the Marks/Changes tabs is also disabled.
    * All others — three tabs, jump-to-node enabled.

  ## Hook (`.PreviewOverlay`)

    * `mounted`   — traps focus inside the overlay and freezes body scroll.
    * `destroyed` — restores body scroll.
    * Swipe down  — vertical pan ≥ 80px from the top edge pushes
      `toggle_preview`.
    * `Escape`    — pushes `toggle_preview`.
  """

  use ContractWeb, :live_component

  attr :id, :string, required: true
  attr :projection, :map, required: true
  attr :studio_state, :map, required: true

  # The shell currently does not thread these into the LiveComponent.
  # We accept them as optional attrs so the overlay degrades gracefully
  # until the shell-coordinator wires them in. Defaults: full perms,
  # mobile viewport (the overlay is mounted from the mobile branch),
  # no changes stream.
  attr :current_scope, :map, default: nil
  attr :viewport, :atom, default: :mobile
  attr :streams, :map, default: %{}
  attr :initial_tab, :atom, default: :body

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :tab, :body)}
  end

  @impl true
  def update(assigns, socket) do
    # On the very first update for this component, honour `initial_tab`
    # as a test-only override. On subsequent updates, preserve whatever
    # tab the user picked via `switch_tab`.
    initial_tab = Map.get(assigns, :initial_tab, :body)

    # `:streams` is a reserved assign on the LV socket — we can't blindly
    # copy it onto our LC's socket. Pull the changes stream out and re-key
    # it onto our own `:changes_stream` assign instead. Mirrors the
    # pattern in ContractWeb.Live.Studio.Components.ToastQueue.
    changes_stream =
      case Map.get(assigns, :streams) do
        %{changes: cs} -> cs
        _ -> nil
      end

    safe_assigns = Map.drop(assigns, [:streams])

    socket =
      socket
      |> assign(safe_assigns)
      |> assign(:changes_stream, changes_stream)
      |> assign_new(:_seen?, fn -> false end)
      |> apply_initial_tab(initial_tab)
      |> maybe_pin_to_body()
      |> assign(:_seen?, true)

    {:ok, socket}
  end

  defp apply_initial_tab(socket, initial_tab) do
    if socket.assigns._seen? do
      socket
    else
      assign(socket, :tab, initial_tab)
    end
  end

  # Viewers are forced onto the body tab because they cannot see Marks
  # or Changes.
  defp maybe_pin_to_body(socket) do
    if viewer?(socket.assigns.current_scope) and socket.assigns.tab != :body do
      assign(socket, :tab, :body)
    else
      socket
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)

    cond do
      tab_atom not in [:body, :marks, :changes] ->
        {:noreply, socket}

      tab_atom != :body and viewer?(socket.assigns.current_scope) ->
        # Viewer trying to switch to a gated tab — keep them on body.
        {:noreply, assign(socket, :tab, :body)}

      true ->
        {:noreply, assign(socket, :tab, tab_atom)}
    end
  rescue
    ArgumentError -> {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(%{viewport: :desktop} = assigns) do
    # Hard local constraint: never render on desktop. Desktop uses the
    # inline Canvas instead.
    ~H"""
    <div id={@id} data-role="preview-overlay-skipped-desktop" hidden></div>
    """
  end

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="preview-overlay fixed inset-0 z-40 flex flex-col"
      phx-hook=".PreviewOverlay"
      phx-target={@myself}
      role="dialog"
      aria-modal="true"
      aria-label={dgettext("studio", "Document preview")}
      data-role="preview-overlay"
      data-viewport={Atom.to_string(@viewport)}
      style="background-color: var(--cs-bg, #FAFAF7); padding-top: env(safe-area-inset-top, 0px); padding-bottom: env(safe-area-inset-bottom, 0px);"
    >
      <script :type={Phoenix.LiveView.ColocatedHook} name=".PreviewOverlay">
        export default {
          mounted() {
            // Lock body scroll while overlay is open.
            this._prevOverflow = document.body.style.overflow
            document.body.style.overflow = "hidden"

            // Focus trap: keep TAB within the overlay's focusables.
            this._onKey = (e) => {
              if (e.key === "Escape") {
                e.preventDefault()
                this.pushEventTo(this.el, "noop", {})
                this.pushEvent("toggle_preview", {})
                return
              }
              if (e.key !== "Tab") return
              const focusables = this.el.querySelectorAll(
                'button, [href], input, select, textarea, [tabindex]:not([tabindex="-1"])'
              )
              if (focusables.length === 0) return
              const first = focusables[0]
              const last = focusables[focusables.length - 1]
              if (e.shiftKey && document.activeElement === first) {
                e.preventDefault()
                last.focus()
              } else if (!e.shiftKey && document.activeElement === last) {
                e.preventDefault()
                first.focus()
              }
            }
            window.addEventListener("keydown", this._onKey)

            // Move focus into the overlay on open.
            const firstFocus =
              this.el.querySelector("[data-role='preview-close']") ||
              this.el.querySelector("button")
            if (firstFocus) firstFocus.focus()

            // Swipe-down: vertical pan starting near the top edge
            // closes the overlay.
            this._startY = null
            this._startX = null
            this._onTouchStart = (e) => {
              if (!e.touches || e.touches.length !== 1) return
              const t = e.touches[0]
              // Only start a swipe from the top 120px of the overlay.
              const rect = this.el.getBoundingClientRect()
              if (t.clientY - rect.top > 120) return
              this._startY = t.clientY
              this._startX = t.clientX
            }
            this._onTouchMove = (e) => {
              if (this._startY === null) return
              if (!e.touches || e.touches.length !== 1) return
              const t = e.touches[0]
              const dy = t.clientY - this._startY
              const dx = Math.abs(t.clientX - this._startX)
              if (dy >= 80 && dx < 60) {
                this._startY = null
                this._startX = null
                this.pushEvent("toggle_preview", {})
              }
            }
            this._onTouchEnd = () => {
              this._startY = null
              this._startX = null
            }
            this.el.addEventListener("touchstart", this._onTouchStart, { passive: true })
            this.el.addEventListener("touchmove", this._onTouchMove, { passive: true })
            this.el.addEventListener("touchend", this._onTouchEnd, { passive: true })
            this.el.addEventListener("touchcancel", this._onTouchEnd, { passive: true })
          },
          destroyed() {
            document.body.style.overflow = this._prevOverflow || ""
            if (this._onKey) window.removeEventListener("keydown", this._onKey)
          }
        }
      </script>

      <%!-- Thin top strip: document title (truncated) + close button. --%>
      <header
        class="preview-overlay__strip flex items-center justify-between gap-3 px-4 py-2 shrink-0"
        style="background-color: var(--cs-bg, #FAFAF7); border-bottom: 1px solid var(--cs-line, #E5E7EB);"
      >
        <form
          phx-submit="rename_document"
          phx-change="rename_document"
          class="flex-1 min-w-0"
          data-role="preview-title-form"
        >
          <% preview_title = document_title(@projection) %>
          <input
            type="text"
            name="title"
            value={preview_title}
            aria-label={dgettext("studio", "문서 제목")}
            placeholder={dgettext("studio", "제목을 입력하세요")}
            autocomplete="off"
            spellcheck="false"
            phx-debounce="400"
            class="w-full bg-transparent text-sm font-medium text-base-content px-2 py-1 rounded-md border border-base-300 hover:border-base-content/30 focus:border-base-content/50 focus:bg-base-100 outline-none focus:outline-none focus:ring-0 focus:shadow-none transition-colors"
          />
        </form>

        <button
          type="button"
          phx-click="toggle_preview"
          class="inline-flex size-8 items-center justify-center rounded-full text-base-content/70 hover:bg-base-200"
          aria-label={dgettext("studio", "Close preview")}
          data-role="preview-close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </header>

      <%!-- Scroll container — light grey backdrop hosting the centered
           paper page. --%>
      <section
        class="preview-overlay__scroll flex-1 min-h-0 overflow-y-auto"
        role="tabpanel"
        data-role={"preview-panel-#{@tab}"}
        data-viewport={Atom.to_string(@viewport)}
      >
        <div class={[
          "preview-overlay__paper mx-auto bg-white",
          @viewport == :mobile && "preview-overlay__paper--mobile"
        ]}>
          <%= case @tab do %>
            <% :body -> %>
              {render_body(assigns)}
            <% :marks -> %>
              {render_marks(assigns)}
            <% :changes -> %>
              {render_changes(assigns)}
          <% end %>
        </div>
      </section>
    </div>
    """
  end

  # --- Body tab: read-only document render -----------------------------------

  defp render_body(assigns) do
    nodes = assigns.projection[:nodes] || %{}
    order = assigns.projection[:node_order] || []

    # Stable order — fall back to insertion order if node_order is empty.
    ordered_ids =
      case order do
        [] -> Map.keys(nodes)
        list -> list
      end

    assigns =
      assigns
      |> assign(
        :ordered_nodes,
        Enum.map(ordered_ids, &Map.get(nodes, &1)) |> Enum.reject(&is_nil/1)
      )

    ~H"""
    <article
      class="preview-overlay__body"
      data-role="preview-body"
    >
      <%= if @ordered_nodes == [] do %>
        <p class="preview-overlay__empty">
          {dgettext("studio", "No document selected.")}
        </p>
      <% else %>
        <%= for node <- @ordered_nodes do %>
          {render_node(node)}
        <% end %>
      <% end %>
    </article>
    """
  end

  defp render_node(%{kind: :heading, content: text} = node) do
    level = get_in(node, [:attrs, :level]) || 2
    assigns = %{text: text || "", level: level, id: node[:id]}

    case level do
      1 ->
        ~H|<h1 id={"node-#{@id}"} class="preview-overlay__h1">{@text}</h1>|

      2 ->
        ~H|<h2 id={"node-#{@id}"} class="preview-overlay__h2">{@text}</h2>|

      _ ->
        ~H|<h3 id={"node-#{@id}"} class="preview-overlay__h3">{@text}</h3>|
    end
  end

  defp render_node(%{kind: :paragraph} = node) do
    assigns = %{text: node[:content] || "", id: node[:id]}

    ~H|<p id={"node-#{@id}"} class="preview-overlay__p">{@text}</p>|
  end

  defp render_node(%{kind: :list_item} = node) do
    ordered? = get_in(node, [:attrs, :ordered]) == true
    assigns = %{text: node[:content] || "", id: node[:id], ordered?: ordered?}

    if ordered? do
      ~H|<ol class="preview-overlay__ol">
  <li id={"node-#{@id}"}>{@text}</li>
</ol>|
    else
      ~H|<ul class="preview-overlay__ul">
  <li id={"node-#{@id}"}>{@text}</li>
</ul>|
    end
  end

  defp render_node(%{kind: :list} = node) do
    assigns = %{text: node[:content] || "", id: node[:id]}

    ~H|<ul id={"node-#{@id}"} class="preview-overlay__ul">{@text}</ul>|
  end

  defp render_node(%{kind: :table} = node) do
    rows = get_in(node, [:attrs, :rows]) || []
    assigns = %{rows: rows, id: node[:id]}

    ~H"""
    <table id={"node-#{@id}"} class="preview-overlay__table">
      <tbody>
        <tr :for={row <- @rows}>
          <td :for={cell <- row}>{cell}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp render_node(%{} = node) do
    # Fallback for any unknown kind — render content as plain text so we
    # never silently drop user-authored text.
    assigns = %{
      text: node[:content] || "",
      id: node[:id],
      kind: Atom.to_string(node[:kind] || :unknown)
    }

    ~H|<div id={"node-#{@id}"} class="preview-overlay__p" data-node-kind={@kind}>{@text}</div>|
  end

  # --- Marks tab: grouped by node, click-to-jump -----------------------------

  defp render_marks(assigns) do
    marks = assigns.projection[:marks] || %{}
    nodes = assigns.projection[:nodes] || %{}

    grouped =
      marks
      |> Map.values()
      |> Enum.group_by(fn m -> m[:target_id] || :unanchored end)
      |> Enum.sort_by(fn {target_id, _} ->
        case Map.get(nodes, target_id) do
          %{} -> 0
          _ -> 1
        end
      end)

    assigns =
      assigns
      |> assign(:grouped, grouped)
      |> assign(:can_jump?, !viewer?(assigns.current_scope))

    ~H"""
    <div class="space-y-4" data-role="preview-marks">
      <%= if @grouped == [] do %>
        <p class="text-base-content/50 italic">
          {dgettext("studio", "No marks on this document.")}
        </p>
      <% else %>
        <%= for {target_id, marks_for_node} <- @grouped do %>
          <section class="border border-base-200 rounded-md p-3">
            <header class="text-xs uppercase tracking-wider text-base-content/60 mb-2 font-mono">
              {node_label(target_id, @projection)}
            </header>
            <ul class="space-y-1">
              <%= for mark <- marks_for_node do %>
                <li class="flex items-start gap-2 text-sm">
                  <span class={[
                    "badge badge-sm shrink-0 mt-0.5",
                    intent_badge_class(mark[:intent])
                  ]}>
                    {mark[:intent]}
                  </span>
                  <%= if @can_jump? and is_binary(target_id) do %>
                    <button
                      type="button"
                      phx-click="set_node_focus"
                      phx-value-node_id={target_id}
                      class="link link-hover text-left flex-1"
                      data-role="preview-mark-jump"
                    >
                      {mark[:text] || dgettext("studio", "(no text)")}
                    </button>
                  <% else %>
                    <span class="flex-1">{mark[:text] || dgettext("studio", "(no text)")}</span>
                  <% end %>
                </li>
              <% end %>
            </ul>
          </section>
        <% end %>
      <% end %>
    </div>
    """
  end

  # --- Changes tab: recent changes feed --------------------------------------

  defp render_changes(assigns) do
    # `:changes_stream` is set in `update/2` from the parent's
    # `streams={%{changes: @streams.changes}}` attr. We can't carry the
    # raw `:streams` map onto the LC socket (LV reserves that key), so
    # we re-key it in update/2 and read from `:changes_stream` here.
    stream = Map.get(assigns, :changes_stream)

    assigns = assign(assigns, :has_stream?, not is_nil(stream))

    ~H"""
    <div
      id={"#{@id}-changes-list"}
      phx-update={if @has_stream?, do: "stream", else: "ignore"}
      class="space-y-2"
      data-role="preview-changes"
    >
      <%= if @has_stream? do %>
        <div
          :for={{dom_id, change} <- @changes_stream}
          id={dom_id}
          class="border border-base-200 rounded-md p-3 text-sm"
        >
          <div class="flex items-center justify-between gap-2">
            <span class="font-mono text-xs text-base-content/60">
              r{change.result_revision}
            </span>
            <span class="badge badge-sm">{change.command_kind}</span>
          </div>
          <p :if={change.message} class="mt-1 whitespace-pre-wrap">{change.message}</p>
        </div>
      <% else %>
        <p class="text-base-content/50 italic">
          {dgettext("studio", "Recent changes will appear here.")}
        </p>
      <% end %>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp document_title(projection) do
    cond do
      is_binary(projection[:title]) and projection[:title] != "" ->
        projection[:title]

      true ->
        dgettext("studio", "Untitled document")
    end
  end

  defp node_label(:unanchored, _projection), do: dgettext("studio", "Unanchored")

  defp node_label(node_id, projection) when is_binary(node_id) do
    case get_in(projection, [:nodes, node_id]) do
      %{kind: kind} when is_atom(kind) ->
        kind_str = kind |> Atom.to_string() |> String.capitalize()
        "#{kind_str} · #{String.slice(node_id, 0, 8)}"

      _ ->
        "Node · #{String.slice(node_id, 0, 8)}"
    end
  end

  defp node_label(_, _), do: dgettext("studio", "Unknown node")

  defp intent_badge_class(:assertion), do: "badge-info"
  defp intent_badge_class(:question), do: "badge-warning"
  defp intent_badge_class(:risk), do: "badge-error"
  defp intent_badge_class(_), do: "badge-ghost"

  # Persona perm: a viewer is anyone whose perms list does NOT include
  # `:write`. The scope may also be nil during tests / before mount —
  # default to "not a viewer" so the tabs are visible.
  defp viewer?(nil), do: false

  defp viewer?(%{perms: perms}) when is_list(perms) do
    :write not in perms
  end

  defp viewer?(_), do: false
end
