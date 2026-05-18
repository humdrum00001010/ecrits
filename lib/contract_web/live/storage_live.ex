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
      `계약서 업로드` (secondary, opens OS file picker; auto-uploads
      then runs Upstage + LLM refiner before navigating to the new
      document) and `새 문서` (primary, navigates to `/studio` for the
      blank-canvas / agent-discussion path).
    * Tabs: `모든 문서` (active) / `즐겨찾기`.
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

  alias Contract.Command
  alias Contract.ContractTypes
  alias Contract.Documents
  alias Contract.IO.Upstage
  alias Contract.Runtime
  alias Contract.Store

  @preview_node_limit 6
  @preview_line_chars 38

  # Sentinel type assigned to every uploaded private contract — the user
  # picked "사설 계약서" in the new-document dropdown, the upload pipeline
  # parses the file, and the resulting Document is created with this
  # type_key so the rest of the app knows it came from upload rather
  # than from a blank template.
  @custom_type_key "custom_v1"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, dgettext("storage", "Storage"))
      |> assign(:active_tab, :all)
      |> assign(:upload_busy?, false)
      |> allow_upload(:contract_file,
        accept: ~w(.pdf .docx .hwp .hwpx),
        max_entries: 1,
        max_file_size: 50_000_000,
        auto_upload: true
      )
      |> load_documents()

    {:ok, socket}
  end

  # ---------------------------------------------------------------------------
  # Events
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("new_document", params, socket) do
    type_key = Map.get(params, "type_key")

    scope = socket.assigns.current_scope

    action = %Command{
      kind: :create_document,
      actor_type: :user,
      actor_id: scope && scope.user && scope.user.id,
      idempotency_key: Ecto.UUID.generate(),
      payload:
        %{"title" => dgettext("storage", "새 문서")}
        |> maybe_put_type_key(type_key)
    }

    case Runtime.apply(scope, action) do
      {:ok, %Contract.Change{document_id: document_id}} ->
        {:noreply, push_navigate(socket, to: ~p"/documents/#{document_id}")}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           dgettext("storage", "문서를 만들 수 없습니다: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in ~w(all favorites) do
    {:noreply, assign(socket, :active_tab, String.to_existing_atom(tab))}
  end

  def handle_event("delete_document", %{"id" => id}, socket) do
    case Documents.archive(socket.assigns.current_scope, id) do
      {:ok, _doc} ->
        {:noreply,
         socket
         |> load_documents()
         |> put_flash(:info, dgettext("storage", "문서를 삭제했습니다."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, dgettext("storage", "문서를 삭제할 수 없습니다."))}
    end
  end

  # ---------------------------------------------------------------------------
  # Contract upload — selecting a file in the header auto-starts the upload.
  # When the entry is `done?`, we consume it, run it through the Upstage +
  # LLM refiner pipeline (`Upstage.import_upload/3`), persist via
  # `Runtime.apply/2`, and push_navigate to the new document. Parsing
  # blocks the LiveView for a few seconds — acceptable for a single-file
  # flow; if it ever needs to scale, swap to a Task.async + flash hook.
  # ---------------------------------------------------------------------------

  def handle_event("contract_upload_validate", _params, socket) do
    case socket.assigns.uploads.contract_file.entries do
      [%{done?: true} = _entry | _] ->
        {:noreply, finish_upload(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :contract_file, ref)}
  end

  defp finish_upload(socket) do
    scope = socket.assigns.current_scope
    owner_id = scope.user && scope.user.id

    socket = assign(socket, :upload_busy?, true)

    uploads =
      consume_uploaded_entries(socket, :contract_file, fn %{path: path}, entry ->
        dest =
          Path.join(System.tmp_dir!(), "storage-upload-#{entry.uuid}-#{entry.client_name}")

        File.cp!(path, dest)

        {:ok,
         %{
           path: dest,
           client_name: entry.client_name,
           client_type: entry.client_type,
           client_size: entry.client_size
         }}
      end)

    case uploads do
      [upload | _] ->
        case import_uploaded_contract(scope, owner_id, upload) do
          {:ok, document_id} ->
            push_navigate(socket, to: ~p"/documents/#{document_id}")

          {:error, reason} ->
            socket
            |> assign(:upload_busy?, false)
            |> put_flash(
              :error,
              dgettext("storage", "업로드 처리에 실패했습니다: %{reason}",
                reason: inspect(reason)
              )
            )
        end

      [] ->
        assign(socket, :upload_busy?, false)
    end
  end

  defp maybe_put_type_key(payload, key) when is_binary(key) and key != "",
    do: Map.put(payload, "type_key", key)

  defp maybe_put_type_key(payload, _), do: payload

  defp import_uploaded_contract(scope, owner_id, upload) do
    with {:ok, %Contract.Command{} = command} <- Upstage.import_upload(scope, owner_id, upload) do
      # Stamp the upload with the sentinel "사설 계약서" type_key. This is
      # the one and only place the custom type ever gets assigned —
      # picking it in the new-document dropdown is what brings the user
      # into this code path. Once persisted via `:create_document`, the
      # Reducer's immutability guard prevents anyone from changing it.
      command = %{command | payload: Map.put(command.payload, "type_key", @custom_type_key)}

      with {:ok, %Contract.Change{document_id: document_id}} <- Runtime.apply(scope, command) do
        {:ok, document_id}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Data loading
  # ---------------------------------------------------------------------------

  defp load_documents(socket) do
    docs = list_all_documents(socket.assigns.current_scope)
    assign(socket, :documents, docs)
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
      <main class="dashboard-v31 py-6 sm:py-10">
        <%!-- ------------------------------------------------------------ --%>
        <%!-- Title row — H1 + a single 새 문서 ↓ dropdown. Picking a       --%>
        <%!-- standard type creates a blank document with that type_key   --%>
        <%!-- and navigates straight into Studio. Picking the last row    --%>
        <%!-- ("사설 계약서 — 업로드 필요") triggers the hidden            --%>
        <%!-- live_file_input, which auto-uploads, runs the file through  --%>
        <%!-- Upstage + LLM refiner, and creates a document stamped with  --%>
        <%!-- the `custom_v1` type_key. Either way, the type is decided   --%>
        <%!-- at creation and is immutable afterwards.                    --%>
        <%!-- ------------------------------------------------------------ --%>
        <header class="dashboard-v31__top">
          <h1 class="dashboard-v31__title">{dgettext("storage", "모든 문서")}</h1>

          <div class="dashboard-v31__actions">
            <.form
              for={%{}}
              as={:upload}
              id="storage-upload-form"
              phx-change="contract_upload_validate"
              data-role="dashboard-upload-form"
              class="contents"
            >
              <%!-- Hidden file input. The "사설 계약서" row in the picker --%>
              <%!-- below uses <label for=...> to open it without          --%>
              <%!-- needing JS.                                            --%>
              <.live_file_input
                upload={@uploads.contract_file}
                class="sr-only"
                data-role="dashboard-upload-input"
              />
            </.form>

            <details
              class="relative shrink-0"
              data-role="dashboard-new-document-picker"
            >
              <summary
                class={[
                  "list-none dashboard-v31__btn dashboard-v31__btn--primary cursor-pointer inline-flex items-center gap-1",
                  @upload_busy? && "opacity-60 pointer-events-none"
                ]}
                data-role="dashboard-new-document"
                aria-busy={to_string(@upload_busy?)}
              >
                <%= if @upload_busy? do %>
                  {dgettext("storage", "업로드 중…")}
                <% else %>
                  <span>{dgettext("storage", "새 문서")}</span>
                  <.icon name="hero-chevron-down" class="size-3" />
                <% end %>
              </summary>
              <div
                class="absolute right-0 top-full mt-1 z-30 w-64 max-h-80 overflow-y-auto rounded-md border border-base-300 bg-base-100 shadow-lg py-1 text-sm"
                role="menu"
              >
                <p class="px-3 py-1.5 text-xs uppercase tracking-wide text-base-content/40">
                  {dgettext("storage", "표준 양식")}
                </p>
                <button
                  :for={spec <- standard_type_specs()}
                  type="button"
                  role="menuitem"
                  phx-click="new_document"
                  phx-value-type_key={spec.key}
                  class="block w-full text-left px-3 py-1.5 text-base-content hover:bg-base-200"
                  data-role="dashboard-new-document-option"
                  data-type-key={spec.key}
                >
                  {ContractTypes.display_name(spec)}
                </button>

                <div class="border-t border-base-200 my-1"></div>

                <p class="px-3 py-1.5 text-xs uppercase tracking-wide text-base-content/40">
                  {dgettext("storage", "기타")}
                </p>
                <label
                  for={@uploads.contract_file.ref}
                  class={[
                    "block w-full text-left px-3 py-1.5 cursor-pointer hover:bg-base-200",
                    @upload_busy? && "opacity-60 pointer-events-none"
                  ]}
                  data-role="dashboard-new-document-upload"
                  role="menuitem"
                >
                  <div class="text-base-content">
                    {dgettext("storage", "사설 계약서")}
                  </div>
                  <div class="text-xs text-base-content/50">
                    {dgettext("storage", "PDF · DOCX · HWP · HWPX 업로드")}
                  </div>
                </label>
              </div>
            </details>
          </div>
        </header>

        <%= if @uploads.contract_file.entries != [] do %>
          <ul class="text-xs text-base-content/70" data-role="dashboard-upload-entries">
            <li
              :for={entry <- @uploads.contract_file.entries}
              class="flex items-center gap-2"
            >
              <span>{entry.client_name}</span>
              <span>· {entry.progress}%</span>
              <button
                :if={!entry.done?}
                type="button"
                phx-click="cancel_upload"
                phx-value-ref={entry.ref}
                class="text-error"
                aria-label={dgettext("storage", "업로드 취소")}
              >
                ×
              </button>
            </li>
            <li
              :for={
                err <-
                  Enum.flat_map(@uploads.contract_file.entries, &upload_errors(@uploads.contract_file, &1))
              }
              class="text-error"
            >
              {upload_error_label(err)}
            </li>
          </ul>
        <% end %>

        <%!-- ------------------------------------------------------------ --%>
        <%!-- Tabs — visual filter only; the active tab governs the grid.  --%>
        <%!-- ------------------------------------------------------------ --%>
        <nav class="dashboard-v31__tabs" role="tablist">
          <button
            type="button"
            role="tab"
            aria-selected={to_string(@active_tab == :all)}
            phx-click="switch_tab"
            phx-value-tab="all"
            class={[
              "dashboard-v31__tab",
              @active_tab == :all && "dashboard-v31__tab--active"
            ]}
          >
            {dgettext("storage", "모든 문서")}
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={to_string(@active_tab == :favorites)}
            phx-click="switch_tab"
            phx-value-tab="favorites"
            class={[
              "dashboard-v31__tab",
              @active_tab == :favorites && "dashboard-v31__tab--active"
            ]}
          >
            {dgettext("storage", "즐겨찾기")}
          </button>
        </nav>

        <%!-- ------------------------------------------------------------ --%>
        <%!-- Document grid — Google-Docs-style cards with body preview     --%>
        <%!-- inside the thumb. Per-card hover lifts; the whole card is a   --%>
        <%!-- single navigation target, with the overflow menu opting out   --%>
        <%!-- via stopPropagation on the cell.                              --%>
        <%!-- ------------------------------------------------------------ --%>
        <%= cond do %>
          <% @active_tab == :favorites -> %>
            <section
              id="favorites-empty"
              class="dashboard-v31__empty"
              data-role="dashboard-favorites-empty"
            >
              {dgettext("storage", "즐겨찾기한 문서가 아직 없습니다.")}
            </section>
          <% @documents == [] -> %>
            <section
              id="documents-empty"
              class="dashboard-v31__empty"
              data-role="dashboard-documents-empty"
            >
              {dgettext(
                "storage",
                "아직 문서가 없습니다. ‘새 문서’로 시작하세요."
              )}
            </section>
          <% true -> %>
            <section id="document-grid" class="document-grid" data-role="document-grid">
              <.document_card :for={doc <- @documents} document={doc} />
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

  def document_card(assigns) do
    ~H"""
    <article
      id={"document-card-#{@document.document_id}"}
      class="document-card"
      data-role="document-card"
    >
      <.link
        navigate={~p"/documents/#{@document.document_id}"}
        class="absolute inset-0 z-0"
        aria-label={@document.title}
      >
      </.link>

      <div class="document-card__thumb" aria-hidden="true">
        <%= case @document.preview_lines do %>
          <% [] -> %>
            <img
              src={~p"/assets/icons/document.svg"}
              alt=""
              class="document-card__thumb-icon"
            />
          <% lines -> %>
            <div class="document-card__thumb--lines">
              <span
                :for={line <- lines}
                class={[
                  "document-card__thumb-line",
                  line.kind == :heading && "document-card__thumb-line--heading"
                ]}
              >
                {line.text}
              </span>
            </div>
            <div class="document-card__thumb-fade"></div>
        <% end %>

        <details
          class="document-card__menu"
          data-role="document-card-menu"
          onclick="event.stopPropagation()"
        >
          <summary
            class="list-none inline-flex h-full w-full items-center justify-center cursor-pointer"
            aria-label={dgettext("storage", "문서 메뉴")}
          >⋮</summary>
          <div
            class="absolute right-0 top-9 z-20 w-40 rounded-md border border-base-300 bg-base-100 shadow-lg py-1 text-sm"
            role="menu"
          >
            <button
              type="button"
              role="menuitem"
              phx-click="delete_document"
              phx-value-id={@document.document_id}
              data-role="document-card-delete"
              data-confirm={dgettext("storage", "이 문서를 삭제하시겠습니까?")}
              class="block w-full text-left px-3 py-1.5 text-error hover:bg-error/10"
            >
              {dgettext("storage", "삭제")}
            </button>
          </div>
        </details>
      </div>

      <div class="document-card__body relative z-10 pointer-events-none">
        <h2 class="document-card__title">{@document.title}</h2>
        <time class="document-card__updated">{format_date(@document.updated_at)}</time>
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

  # Standard (non-sentinel) types for the new-document picker. The
  # `custom_v1` "사설 계약서" type is reserved for upload-created
  # documents and must NEVER be pickable as a blank-document seed —
  # we filter it out here.
  defp standard_type_specs do
    ContractTypes.all()
    |> Enum.reject(&(&1.key == @custom_type_key))
    |> Enum.sort_by(& &1.key)
  end

  defp upload_error_label(:too_large),
    do: dgettext("storage", "파일이 너무 큽니다 (최대 50MB)")

  defp upload_error_label(:not_accepted),
    do: dgettext("storage", "지원하지 않는 형식입니다 (PDF · DOCX · HWP · HWPX)")

  defp upload_error_label(:too_many_files),
    do: dgettext("storage", "한 번에 한 파일만 업로드할 수 있습니다")

  defp upload_error_label(other), do: to_string(other)
end
