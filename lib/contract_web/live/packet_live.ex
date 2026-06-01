defmodule ContractWeb.PacketLive do
  @moduledoc """
  Authenticated packet surface.

  Packets sit above documents. This LiveView only handles packet UI:
  listing, creating, opening, and attaching/detaching existing documents.
  """
  use ContractWeb, :live_view

  alias Contract.Packets
  alias Contract.Packets.Packet

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:packet, nil)
     |> assign(:packet_title_form, packet_title_form())
     |> assign(:attached_documents, [])
     |> assign(:deleting_document, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_packet_detail(socket, params["packet_id"])}
  end

  @impl true
  def handle_event("create_document", _params, socket) do
    packet_id = field(socket.assigns.packet, :id)

    {:noreply, push_navigate(socket, to: ~p"/studio?packet_id=#{packet_id}")}
  end

  def handle_event("rename_packet", %{"packet" => packet_params}, socket) do
    case socket.assigns.packet do
      %Packet{} = packet ->
        case Packets.update_packet(
               socket.assigns.current_scope,
               packet,
               packet_title_attrs(packet_params)
             ) do
          {:ok, updated_packet} ->
            {:noreply,
             socket
             |> assign(:packet, updated_packet)
             |> assign(
               :packet_title_form,
               packet_title_form(%{"title" => packet_title(updated_packet)})
             )
             |> assign(:page_title, packet_title(updated_packet))}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :packet_title_form, to_form(changeset, action: :update))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "패킷명을 수정할 수 없습니다.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "패킷을 찾을 수 없습니다.")}
    end
  end

  def handle_event("open_document_settings", %{"id" => document_id}, socket) do
    case find_attached_document(socket.assigns.attached_documents, document_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "문서를 찾을 수 없습니다.")}

      document ->
        {:noreply, assign(socket, :deleting_document, document)}
    end
  end

  def handle_event("close_document_settings", _params, socket) do
    {:noreply, assign(socket, :deleting_document, nil)}
  end

  def handle_event("delete_document", _params, socket) do
    packet_id = field(socket.assigns.packet, :id)
    document_id = field(socket.assigns.deleting_document, :id)

    case Packets.detach_document(socket.assigns.current_scope, packet_id, document_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:deleting_document, nil)
         |> load_packet_detail(packet_id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "문서를 제거할 수 없습니다.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="default">
      <main
        id="packets-root"
        data-packets="root"
        class="flex flex-col gap-6 py-6 text-base-content sm:py-10"
      >
        <.packet_detail
          packet={@packet}
          packet_title_form={@packet_title_form}
          attached_documents={@attached_documents}
          deleting_document={@deleting_document}
        />
      </main>
    </Layouts.app>
    """
  end

  attr :packet, :any, required: true
  attr :packet_title_form, :any, required: true
  attr :attached_documents, :list, required: true
  attr :deleting_document, :any, required: true

  def packet_detail(assigns) do
    ~H"""
    <header class="flex items-center justify-between gap-3">
      <div class="min-w-0">
        <.form
          for={@packet_title_form}
          id="packet-title-form"
          phx-change="rename_packet"
          phx-submit="rename_packet"
          class="min-w-0"
          phx-hook=".BlurPacketTitleOnSubmit"
        >
          <% title_value = Phoenix.HTML.Form.input_value(@packet_title_form, :title) || "" %>
          <input
            id="packet-title-input"
            type="text"
            name="packet[title]"
            value={title_value}
            size={packet_title_input_size(title_value)}
            aria-label="패킷명"
            autocomplete="off"
            spellcheck="false"
            phx-debounce="400"
            class="block h-9 min-w-0 max-w-full rounded-md border border-transparent bg-transparent px-1 py-0 text-[clamp(22px,4vw,28px)] font-semibold tracking-tight text-base-content outline-none transition-colors hover:border-base-content/20 focus:border-base-content/40 focus:bg-base-100 focus:ring-0"
          />
        </.form>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".BlurPacketTitleOnSubmit">
          export default {
            mounted() {
              this.titleInput = this.el.querySelector("input[name='packet[title]']")
              this.blurTitle = () => {
                setTimeout(() => this.titleInput?.blur(), 0)
                setTimeout(() => this.titleInput?.blur(), 120)
              }
              this.onSubmit = () => this.blurTitle()
              this.onKeyDown = event => {
                if (event.key !== "Enter") return
                event.preventDefault()
                this.el.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }))
                this.blurTitle()
              }
              this.el.addEventListener("submit", this.onSubmit)
              this.titleInput?.addEventListener("keydown", this.onKeyDown)
            },
            destroyed() {
              this.el.removeEventListener("submit", this.onSubmit)
              this.titleInput?.removeEventListener("keydown", this.onKeyDown)
            }
          }
        </script>
      </div>

      <button
        id="packet-new-document"
        type="button"
        phx-click="create_document"
        class="btn btn-primary btn-sm"
      >
        새 문서
      </button>
    </header>

    <section id="packet-documents-panel" class="space-y-3">
      <% current_packet_id = field(@packet, :id) %>
      <.table
        id="packet-documents-table"
        rows={@attached_documents}
        row_id={fn document -> "attached-document-#{document_id(document)}" end}
        row_click={
          fn document ->
            JS.navigate(~p"/documents/#{document_id(document)}?packet_id=#{current_packet_id}")
          end
        }
      >
        <:col :let={document} label="문서">
          {document_title(document)}
        </:col>
        <:action :let={document}>
          <div id={"document-actions-#{document_id(document)}"} class="flex items-center gap-1">
            <button
              id={"document-settings-#{document_id(document)}"}
              type="button"
              phx-click="open_document_settings"
              phx-value-id={document_id(document)}
              class="btn btn-ghost btn-xs btn-square"
              aria-label="문서 설정"
            >
              <.icon name="hero-cog-6-tooth" class="size-4" />
            </button>
          </div>
        </:action>
      </.table>

      <p
        :if={@attached_documents == []}
        id="packet-documents-empty"
        class="py-6 text-center text-sm text-base-content/55"
      >
        연결된 문서가 없습니다.
      </p>
    </section>

    <div
      :if={@deleting_document}
      id="document-settings-modal"
      class="modal modal-open"
      phx-window-keydown="close_document_settings"
      phx-key="escape"
    >
      <div class="modal-box max-w-md">
        <div class="flex items-center justify-between gap-3">
          <h2 class="text-base font-semibold">문서 설정</h2>
          <button
            id="close-document-settings-modal"
            type="button"
            phx-click="close_document_settings"
            class="btn btn-ghost btn-sm btn-square"
            aria-label="닫기"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <p class="mt-4 text-sm text-base-content/70">
          {document_title(@deleting_document)} 항목을 이 패킷에서 제거합니다.
        </p>
        <p class="mt-2 text-sm text-base-content/60">
          다른 패킷에 연결되어 있지 않으면 문서가 삭제됩니다.
        </p>

        <div class="mt-5 flex items-center justify-end gap-2">
          <button type="button" phx-click="close_document_settings" class="btn btn-ghost btn-sm">
            취소
          </button>
          <button
            id="document-delete-confirm"
            type="button"
            phx-click="delete_document"
            class="btn btn-error btn-sm"
          >
            삭제
          </button>
        </div>
      </div>
      <button
        type="button"
        phx-click="close_document_settings"
        class="modal-backdrop"
        aria-label="닫기"
      >
        닫기
      </button>
    </div>
    """
  end

  defp load_packet_detail(socket, packet_id) when is_binary(packet_id) do
    case fetch_packet(socket.assigns.current_scope, packet_id) do
      {:ok, packet} ->
        socket
        |> assign(:page_title, packet_title(packet))
        |> assign(:packet, packet)
        |> assign(:packet_title_form, packet_title_form(%{"title" => packet_title(packet)}))
        |> assign(:attached_documents, attached_documents(packet))

      {:error, _reason} ->
        socket
        |> put_flash(:error, "패킷을 찾을 수 없습니다.")
        |> push_navigate(to: ~p"/storage")
    end
  end

  defp fetch_packet(scope, packet_id) do
    case Packets.get_packet(scope, packet_id) do
      {:ok, packet} -> {:ok, packet}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
      packet -> {:ok, packet}
    end
  end

  defp attached_documents(packet) do
    packet
    |> field(:documents, field(packet, :attached_documents, []))
    |> case do
      %Ecto.Association.NotLoaded{} -> []
      documents when is_list(documents) -> documents
      _ -> []
    end
  end

  defp packet_title(packet), do: field(packet, :title, "제목 없는 패킷")

  defp document_id(document), do: field(document, :id)
  defp document_title(document), do: field(document, :title, "제목 없는 문서")

  defp find_attached_document(documents, target_document_id) do
    Enum.find(documents, &(document_id(&1) == target_document_id))
  end

  defp packet_title_form(attrs \\ %{"title" => ""}) do
    to_form(attrs, as: :packet)
  end

  defp packet_title_attrs(attrs) do
    Map.take(attrs, ["title"])
  end

  defp packet_title_input_size(title) when is_binary(title) do
    title
    |> String.graphemes()
    |> Enum.reduce(0, fn grapheme, acc ->
      if String.match?(grapheme, ~r/[\p{Han}\p{Hangul}\p{Hiragana}\p{Katakana}]/u),
        do: acc + 2,
        else: acc + 1
    end)
    |> Kernel.+(2)
    |> max(8)
    |> min(32)
  end

  defp packet_title_input_size(_title), do: 8

  defp field(map, key, default \\ nil)

  defp field(nil, _key, default), do: default

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))
end
