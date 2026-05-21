defmodule ContractWeb.StorageLive do
  @moduledoc """
  Authenticated home for the 계약기계 library. Document grid only — no
  metric cards, no recent-activity feed, no left sidebar.

  Per 2026-05-18 owner directive ("문서 업로드도 없네") + the prior
  "공들여 만들었던 문서프리뷰" pass — the library renders documents as a
  Google-Docs-style card grid: each card's thumb shows the first few
  lines of the actual contract body (heading + paragraph snippets),
  faded out at the bottom so the card never looks cropped.

    * Top row: `모든 문서` H1 + right-aligned actions —
      `새 문서` (primary, links to `/studio` for the blank-canvas /
      agent-discussion path). Storage never creates or uploads documents.
    * Tabs: `모든 문서` only. No placeholder tabs.
    * Each card → `/documents/:id`. Overflow `⋮` menu hangs off the
      thumb's top-right corner with a single 삭제 action.

  ## Data sources

    * `Contract.Documents.list_all_for_scope/2` — all owner-scoped
      non-archived documents, ordered by `updated_at DESC`.
    * `Contract.Store.load/1` — per-document projection, used to pull
      the first ~6 body nodes into the thumb. Failures are swallowed
      silently (empty thumb) so a broken doc doesn't kill the page.
  """
  use ContractWeb, :live_view

  alias Contract.Documents
  alias Contract.Store

  @preview_node_limit 6
  @preview_line_chars 38

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, dgettext("storage", "Storage"))
      |> assign(:selected_document_ids, MapSet.new())
      |> load_documents()

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("delete_document", %{"id" => id}, socket) do
    case Documents.archive(socket.assigns.current_scope, id) do
      {:ok, _doc} ->
        {:noreply,
         socket
         |> deselect_document(id)
         |> load_documents()
         |> put_flash(:info, dgettext("storage", "문서를 삭제했습니다."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, dgettext("storage", "문서를 삭제할 수 없습니다."))}
    end
  end

  def handle_event("toggle_select_document", %{"id" => id}, socket) do
    selected_document_ids =
      if MapSet.member?(socket.assigns.selected_document_ids, id) do
        MapSet.delete(socket.assigns.selected_document_ids, id)
      else
        MapSet.put(socket.assigns.selected_document_ids, id)
      end

    {:noreply, assign(socket, :selected_document_ids, selected_document_ids)}
  end

  def handle_event("toggle_select_all_documents", _params, socket) do
    visible_ids = visible_document_ids(socket.assigns)

    selected_document_ids =
      if all_visible_selected?(socket.assigns) do
        Enum.reduce(visible_ids, socket.assigns.selected_document_ids, &MapSet.delete(&2, &1))
      else
        Enum.reduce(visible_ids, socket.assigns.selected_document_ids, &MapSet.put(&2, &1))
      end

    {:noreply, assign(socket, :selected_document_ids, selected_document_ids)}
  end

  def handle_event("delete_selected_documents", _params, socket) do
    selected_ids =
      socket.assigns.selected_document_ids
      |> MapSet.to_list()
      |> Enum.filter(&document_visible?(&1, socket.assigns))

    {deleted_ids, failed_ids} =
      Enum.reduce(selected_ids, {[], []}, fn id, {deleted_ids, failed_ids} ->
        case Documents.archive(socket.assigns.current_scope, id) do
          {:ok, _doc} -> {[id | deleted_ids], failed_ids}
          {:error, _} -> {deleted_ids, [id | failed_ids]}
        end
      end)

    socket =
      socket
      |> assign(
        :selected_document_ids,
        MapSet.difference(socket.assigns.selected_document_ids, MapSet.new(deleted_ids))
      )
      |> load_documents()

    socket =
      cond do
        deleted_ids == [] and failed_ids == [] ->
          socket

        failed_ids == [] ->
          put_flash(
            socket,
            :info,
            dgettext("storage", "%{count}개 문서를 삭제했습니다.", count: length(deleted_ids))
          )

        true ->
          put_flash(
            socket,
            :error,
            dgettext("storage", "일부 문서를 삭제할 수 없습니다.")
          )
      end

    {:noreply, socket}
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_documents(socket) do
    docs = list_all_documents(socket.assigns.current_scope)
    visible_ids = docs |> Enum.map(& &1.document_id) |> MapSet.new()

    socket
    |> assign(:documents, docs)
    |> assign(
      :selected_document_ids,
      MapSet.intersection(socket.assigns.selected_document_ids, visible_ids)
    )
  end

  defp deselect_document(socket, id) do
    assign(
      socket,
      :selected_document_ids,
      MapSet.delete(socket.assigns.selected_document_ids, id)
    )
  end

  defp list_all_documents(scope) do
    scope
    |> Documents.list_all_for_scope()
    |> Enum.reject(&(&1.status == :template))
    |> Enum.reject(&(&1.status == :archived))
    |> Enum.map(fn d ->
      %{
        document_id: d.id,
        title: d.title,
        type_key: d.type_key,
        updated_at: d.updated_at,
        preview_lines: preview_lines_for(d.id)
      }
    end)
  rescue
    DBConnection.ConnectionError -> []
    Postgrex.Error -> []
  end

  # ---------------------------------------------------------------------------
  # Document preview lines — first ~6 body nodes from the projection,
  # rendered into the thumb. We keep this cheap (no rich rendering, just
  # truncated strings) so the grid stays responsive even with many docs.
  # Failures (missing snapshot, decode error) → empty list; the card falls
  # back to its plain document icon.
  # ---------------------------------------------------------------------------
  defp preview_lines_for(document_id) do
    case Store.load(document_id) do
      {:ok, %{projection: projection}} ->
        projection
        |> projection_preview_nodes()
        |> Enum.take(@preview_node_limit)
        |> Enum.map(&node_to_preview_line/1)
        |> Enum.reject(&(&1.text == ""))

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp projection_preview_nodes(%{nodes: nodes, node_order: order}) when is_list(order) do
    order
    |> Enum.map(&Map.get(nodes, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&previewable_node?/1)
  end

  defp projection_preview_nodes(_), do: []

  defp previewable_node?(%{kind: kind, content: content})
       when kind in [:paragraph, :heading] and is_binary(content) do
    String.trim(content) != ""
  end

  defp previewable_node?(_), do: false

  defp node_to_preview_line(%{kind: :heading, content: content}) do
    %{kind: :heading, text: truncate_line(content)}
  end

  defp node_to_preview_line(%{kind: :paragraph, content: content}) do
    %{kind: :paragraph, text: truncate_line(content)}
  end

  defp truncate_line(content) when is_binary(content) do
    content
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, @preview_line_chars)
  end

  defp truncate_line(_), do: ""

  # ---------------------------------------------------------------------------
  # Render
  # ---------------------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="default">
      <main
        data-storage="root"
        class="flex flex-col gap-5 py-6 text-base-content sm:gap-7 sm:py-10"
      >
        <%!-- ------------------------------------------------------------ --%>
        <%!-- Title row — H1 + a single action. 새 문서 is only a link to  --%>
        <%!-- StudioLive; Storage must not create or upload documents.     --%>
        <%!-- ------------------------------------------------------------ --%>
        <header class="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
          <h1 class="m-0 text-[clamp(22px,4vw,28px)] font-semibold tracking-tight text-base-content">
            {dgettext("storage", "모든 문서")}
          </h1>

          <div class="flex flex-wrap items-center gap-2">
            <.link
              navigate={~p"/studio"}
              class="btn btn-primary"
              data-role="dashboard-new-document"
            >
              {dgettext("storage", "새 문서")}
            </.link>
          </div>
        </header>

        <nav
          class="tabs tabs-border flex flex-wrap items-center gap-2"
          role="tablist"
        >
          <div class="flex items-center gap-2">
            <span class="tab tab-active" role="tab" aria-selected="true">
              {dgettext("storage", "모든 문서")}
            </span>
          </div>

          <div
            class="ml-auto flex items-center self-center gap-2"
            data-role="document-selection-actions"
          >
            <button
              type="button"
              phx-click="toggle_select_all_documents"
              disabled={visible_document_ids(assigns) == []}
              class="btn btn-ghost btn-sm gap-2"
            >
              <input
                type="checkbox"
                class="checkbox checkbox-sm pointer-events-none"
                checked={all_visible_selected?(assigns)}
                aria-hidden="true"
              />
              <span>{dgettext("storage", "전체 선택")}</span>
            </button>
            <button
              type="button"
              phx-click="delete_selected_documents"
              disabled={selected_visible_count(@selected_document_ids, assigns) == 0}
              data-confirm={dgettext("storage", "선택한 문서를 삭제하시겠습니까?")}
              class="btn btn-error btn-sm"
            >
              {dgettext("storage", "선택 삭제")}
            </button>
          </div>
        </nav>

        <%!-- ------------------------------------------------------------ --%>
        <%!-- Document grid — Google-Docs-style cards with body preview     --%>
        <%!-- inside the thumb. Per-card hover lifts; the whole card is a   --%>
        <%!-- single navigation target, with the overflow menu opting out   --%>
        <%!-- via stopPropagation on the cell.                              --%>
        <%!-- ------------------------------------------------------------ --%>
        <%= cond do %>
          <% @documents == [] -> %>
            <section
              id="documents-empty"
              class="alert bg-base-100 border border-dashed border-base-300 justify-center text-sm text-base-content/55"
              data-role="dashboard-documents-empty"
            >
              {dgettext(
                "storage",
                "아직 문서가 없습니다. ‘새 문서’로 시작하세요."
              )}
            </section>
          <% true -> %>
            <section
              id="document-grid"
              data-role="document-grid"
              class="grid gap-[18px] [grid-template-columns:repeat(auto-fill,minmax(210px,1fr))] max-sm:grid-cols-1"
            >
              <.document_card
                :for={doc <- @documents}
                document={doc}
                selected?={MapSet.member?(@selected_document_ids, doc.document_id)}
              />
            </section>
        <% end %>
      </main>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Function components
  # ---------------------------------------------------------------------------

  @doc """
  Renders a single document card. Thumb shows the first few body lines
  if the projection is available; otherwise falls back to a generic
  document icon. The overflow `⋮` menu floats on the thumb's top-right
  and uses a native `<details>` (no JS hook).
  """
  attr :document, :map, required: true
  attr :selected?, :boolean, default: false

  def document_card(assigns) do
    ~H"""
    <article
      id={"document-card-#{@document.document_id}"}
      class={[
        "card card-compact group relative grid grid-rows-[160px_auto] overflow-hidden border border-base-300 bg-base-100 text-base-content no-underline transition-all duration-150 hover:-translate-y-0.5 hover:border-base-content/30 hover:shadow-lg focus-within:outline focus-within:outline-2 focus-within:outline-primary focus-within:outline-offset-2 motion-reduce:transform-none motion-reduce:transition-none",
        @selected? && "ring-2 ring-base-content/30"
      ]}
      data-role="document-card"
    >
      <.link
        navigate={~p"/documents/#{@document.document_id}"}
        class="absolute inset-0 z-0"
        aria-label={@document.title}
      >
      </.link>

      <div
        data-role="document-card-thumb"
        class="relative grid place-items-center overflow-hidden border-b border-base-300 bg-base-100"
      >
        <details
          class="absolute right-2 top-2 z-30 inline-grid place-items-center"
          data-role="document-card-menu"
          onclick="event.stopPropagation()"
        >
          <summary class="grid h-8 w-8 cursor-pointer list-none place-items-center rounded-full border border-base-300 bg-base-100/90 text-base-content shadow-sm hover:bg-base-200">
            ⋮
          </summary>
          <div class="absolute right-0 mt-2 w-28 rounded-box border border-base-200 bg-base-100 p-1 text-sm shadow-lg">
            <button
              type="button"
              phx-click="delete_document"
              phx-value-id={@document.document_id}
              data-confirm={dgettext("storage", "문서를 삭제하시겠습니까?")}
              class="w-full rounded-lg px-3 py-2 text-left text-error hover:bg-error/10"
            >
              {dgettext("storage", "삭제")}
            </button>
          </div>
        </details>

        <button
          type="button"
          phx-click="toggle_select_document"
          phx-value-id={@document.document_id}
          aria-pressed={to_string(@selected?)}
          aria-label={dgettext("storage", "문서 선택")}
          class={[
            "absolute left-3 top-3 z-20 grid h-8 w-8 place-items-center rounded-full border text-xs font-bold shadow-sm transition",
            if(@selected?,
              do: "border-base-content bg-base-content text-base-100",
              else: "border-base-300 bg-base-100/90 text-transparent hover:text-base-content"
            )
          ]}
        >
          ✓
        </button>

        <%= case @document.preview_lines do %>
          <% [] -> %>
            <div
              data-role="document-card-preview"
              class="relative w-[72%] h-[82%] flex items-start translate-y-2 overflow-hidden rounded-lg border border-base-300 bg-white shadow-[0_14px_34px_rgb(15_23_42/12%)] pointer-events-none"
            >
              <div
                data-role="document-card-thumb-lines"
                class="block w-full select-none pointer-events-none px-3.5 pt-3 text-left font-sans text-[10.5px] leading-snug text-base-content"
              >
                <span class="block first:mt-1.5 mb-1 overflow-hidden whitespace-nowrap text-ellipsis font-semibold text-[11.5px] opacity-[0.92]">
                  {@document.title}
                </span>
              </div>
            </div>
          <% lines -> %>
            <div
              data-role="document-card-preview"
              class="relative w-[72%] h-[82%] translate-y-2 overflow-hidden rounded-lg border border-base-300 bg-white shadow-[0_14px_34px_rgb(15_23_42/12%)] pointer-events-none"
            >
              <div
                data-role="document-card-thumb-lines"
                class="block select-none pointer-events-none px-3.5 pt-3 text-left font-sans text-[10.5px] leading-snug text-base-content"
              >
                <span
                  :for={line <- lines}
                  class={[
                    "block mb-1 overflow-hidden whitespace-nowrap text-ellipsis opacity-[0.78] first:mt-0",
                    line.kind == :heading && "font-semibold text-[11.5px] opacity-[0.92] mt-1.5"
                  ]}
                >
                  {line.text}
                </span>
              </div>
            </div>
            <div class="pointer-events-none absolute inset-x-0 bottom-0 h-[38px] bg-gradient-to-b from-transparent to-base-100"></div>
        <% end %>
      </div>

      <div class="card-body relative z-10 gap-1.5 pointer-events-none">
        <h2 class="card-title text-[15px] leading-snug">
          {@document.title}
        </h2>
        <time class="text-xs text-base-content/45 tabular-nums">
          {format_date(@document.updated_at)}
        </time>
      </div>
    </article>
    """
  end

  # ---------------------------------------------------------------------------
  # Render helpers
  # ---------------------------------------------------------------------------

  defp format_date(nil), do: "—"

  defp format_date(%NaiveDateTime{} = t),
    do: t |> DateTime.from_naive!("Etc/UTC") |> format_date()

  defp format_date(%DateTime{} = t), do: Calendar.strftime(t, "%Y.%m.%d")
  defp format_date(%Date{} = d), do: Calendar.strftime(d, "%Y.%m.%d")

  defp visible_document_ids(%{documents: documents}) do
    Enum.map(documents, & &1.document_id)
  end

  defp document_visible?(id, assigns) do
    id in visible_document_ids(assigns)
  end

  defp selected_visible_count(selected_document_ids, assigns) do
    assigns
    |> visible_document_ids()
    |> Enum.count(&MapSet.member?(selected_document_ids, &1))
  end

  defp all_visible_selected?(assigns) do
    visible_ids = visible_document_ids(assigns)

    visible_ids != [] and
      Enum.all?(visible_ids, &MapSet.member?(assigns.selected_document_ids, &1))
  end
end
