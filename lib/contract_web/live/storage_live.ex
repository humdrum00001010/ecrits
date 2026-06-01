defmodule ContractWeb.StorageLive do
  @moduledoc """
  Authenticated packet library for 보관함.

  Storage is the packet entry point: create/open packets. Documents remain
  edited at `/documents/:id` and are managed from `/packets/:packet_id`.
  """
  use ContractWeb, :live_view

  alias Contract.Packets
  alias Contract.Packets.Packet

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, dgettext("storage", "Storage"))
     |> assign(:packet_form, packet_form())
     |> assign(:show_create_modal, false)
     |> assign(:editing_packet, nil)
     |> assign(:edit_packet_form, packet_form())
     |> assign(:deleting_packet, nil)
     |> load_packets()}
  end

  @impl true
  def handle_event("open_create_packet_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, true)}
  end

  def handle_event("close_create_packet_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:packet_form, packet_form())
     |> assign(:show_create_modal, false)}
  end

  def handle_event("validate_packet", %{"packet" => packet_params}, socket) do
    {:noreply, assign(socket, :packet_form, packet_form(packet_params))}
  end

  def handle_event("create_packet", %{"packet" => packet_params}, socket) do
    attrs = compact_blank_attrs(packet_params)

    case Packets.create_packet(socket.assigns.current_scope, attrs) do
      {:ok, packet} ->
        {:noreply, push_navigate(socket, to: ~p"/packets/#{packet_id(packet)}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:packet_form, to_form(changeset, action: :insert))
         |> assign(:show_create_modal, true)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "패킷을 만들 수 없습니다.")}
    end
  end

  def handle_event("open_packet_settings", %{"id" => packet_id}, socket) do
    case Packets.get_packet(socket.assigns.current_scope, packet_id) do
      {:ok, packet} ->
        {:noreply,
         socket
         |> assign(:editing_packet, packet)
         |> assign(:edit_packet_form, packet_form(%{"title" => packet_title(packet)}))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "패킷을 찾을 수 없습니다.")}
    end
  end

  def handle_event("close_packet_settings", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_packet, nil)
     |> assign(:edit_packet_form, packet_form())}
  end

  def handle_event("validate_edit_packet", %{"packet" => packet_params}, socket) do
    {:noreply, assign(socket, :edit_packet_form, packet_form(packet_params))}
  end

  def handle_event("update_packet", %{"packet" => packet_params}, socket) do
    case socket.assigns.editing_packet do
      %Packet{} = packet ->
        case Packets.update_packet(
               socket.assigns.current_scope,
               packet,
               packet_title_attrs(packet_params)
             ) do
          {:ok, _packet} ->
            {:noreply,
             socket
             |> assign(:editing_packet, nil)
             |> assign(:edit_packet_form, packet_form())
             |> load_packets()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :edit_packet_form, to_form(changeset, action: :update))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "패킷을 수정할 수 없습니다.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "패킷을 찾을 수 없습니다.")}
    end
  end

  def handle_event("open_delete_packet", %{"id" => packet_id}, socket) do
    case Packets.get_packet(socket.assigns.current_scope, packet_id) do
      {:ok, packet} ->
        {:noreply,
         socket
         |> assign(:editing_packet, nil)
         |> assign(:edit_packet_form, packet_form())
         |> assign(:deleting_packet, packet)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "패킷을 찾을 수 없습니다.")}
    end
  end

  def handle_event("close_delete_packet", _params, socket) do
    {:noreply, assign(socket, :deleting_packet, nil)}
  end

  def handle_event("delete_packet", _params, socket) do
    case socket.assigns.deleting_packet do
      %Packet{} = packet ->
        case Packets.delete_packet(socket.assigns.current_scope, packet) do
          {:ok, _packet} ->
            {:noreply,
             socket
             |> assign(:deleting_packet, nil)
             |> load_packets()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "패킷을 삭제할 수 없습니다.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "패킷을 찾을 수 없습니다.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="default">
      <main
        id="storage-root"
        data-storage="root"
        class="flex flex-col gap-4 py-6 text-base-content sm:py-10"
      >
        <header class="flex items-center justify-between gap-3">
          <h1 class="m-0 text-[clamp(22px,4vw,28px)] font-semibold tracking-tight text-base-content">
            보관함
          </h1>
          <button
            id="open-packet-create-modal"
            type="button"
            phx-click="open_create_packet_modal"
            class="btn btn-primary btn-sm"
          >
            생성
          </button>
        </header>

        <.table
          id="packets-table"
          rows={@packets}
          row_id={fn packet -> "packet-row-#{packet_id(packet)}" end}
          row_click={fn packet -> JS.navigate(~p"/packets/#{packet_id(packet)}") end}
        >
          <:col :let={packet} label="패킷">
            {packet_title(packet)}
          </:col>
          <:action :let={packet}>
            <div id={"packet-actions-#{packet_id(packet)}"} class="flex items-center gap-1">
              <button
                id={"packet-settings-#{packet_id(packet)}"}
                type="button"
                phx-click="open_packet_settings"
                phx-value-id={packet_id(packet)}
                class="btn btn-ghost btn-xs btn-square"
                aria-label="패킷 설정"
              >
                <.icon name="hero-cog-6-tooth" class="size-4" />
              </button>
            </div>
          </:action>
        </.table>

        <p
          :if={@packets == []}
          id="packets-empty"
          class="py-6 text-center text-sm text-base-content/55"
        >
          아직 패킷이 없습니다.
        </p>

        <div
          :if={@show_create_modal}
          id="packet-create-modal"
          class="modal modal-open"
          phx-window-keydown="close_create_packet_modal"
          phx-key="escape"
        >
          <div class="modal-box max-w-md">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-base font-semibold">패킷 생성</h2>
              <button
                id="close-packet-create-modal"
                type="button"
                phx-click="close_create_packet_modal"
                class="btn btn-ghost btn-sm btn-square"
                aria-label="닫기"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <.form
              for={@packet_form}
              id="packet-create-form"
              phx-change="validate_packet"
              phx-submit="create_packet"
              class="mt-4 space-y-4"
            >
              <.input
                field={@packet_form[:title]}
                type="text"
                label="패킷명"
                placeholder="예: 공급계약 검토"
                required
              />
              <div class="flex items-center justify-end gap-2">
                <button
                  type="button"
                  phx-click="close_create_packet_modal"
                  class="btn btn-ghost btn-sm"
                >
                  취소
                </button>
                <button id="packet-create-submit" type="submit" class="btn btn-primary btn-sm">
                  생성
                </button>
              </div>
            </.form>
          </div>
          <button
            type="button"
            phx-click="close_create_packet_modal"
            class="modal-backdrop"
            aria-label="닫기"
          >
            닫기
          </button>
        </div>

        <div
          :if={@editing_packet}
          id="packet-settings-modal"
          class="modal modal-open"
          phx-window-keydown="close_packet_settings"
          phx-key="escape"
        >
          <div class="modal-box max-w-md">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-base font-semibold">패킷 설정</h2>
              <button
                id="close-packet-settings-modal"
                type="button"
                phx-click="close_packet_settings"
                class="btn btn-ghost btn-sm btn-square"
                aria-label="닫기"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <.form
              for={@edit_packet_form}
              id="packet-edit-form"
              phx-change="validate_edit_packet"
              phx-submit="update_packet"
              class="mt-4 space-y-4"
            >
              <.input
                field={@edit_packet_form[:title]}
                type="text"
                label="패킷명"
                required
              />
              <div class="flex items-center justify-end gap-2">
                <button
                  type="button"
                  phx-click="close_packet_settings"
                  class="btn btn-ghost btn-sm"
                >
                  취소
                </button>
                <button id="packet-edit-submit" type="submit" class="btn btn-primary btn-sm">
                  저장
                </button>
              </div>
            </.form>

            <div class="mt-5 border-t border-base-300 pt-4">
              <h3 class="text-sm font-semibold text-error">삭제</h3>
              <p class="mt-1 text-sm text-base-content/65">
                다른 패킷이 참조하지 않는 문서는 함께 삭제됩니다.
              </p>
              <div class="mt-3 flex justify-end">
                <button
                  id="packet-settings-delete"
                  type="button"
                  phx-click="open_delete_packet"
                  phx-value-id={packet_id(@editing_packet)}
                  class="btn btn-error btn-sm"
                >
                  삭제 설정
                </button>
              </div>
            </div>
          </div>
          <button
            type="button"
            phx-click="close_packet_settings"
            class="modal-backdrop"
            aria-label="닫기"
          >
            닫기
          </button>
        </div>

        <div
          :if={@deleting_packet}
          id="packet-delete-modal"
          class="modal modal-open"
          phx-window-keydown="close_delete_packet"
          phx-key="escape"
        >
          <div class="modal-box max-w-md">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-base font-semibold">패킷 삭제</h2>
              <button
                id="close-packet-delete-modal"
                type="button"
                phx-click="close_delete_packet"
                class="btn btn-ghost btn-sm btn-square"
                aria-label="닫기"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <p class="mt-4 text-sm text-base-content/70">
              {packet_title(@deleting_packet)} 패킷을 삭제합니다. 다른 패킷이 참조하지 않는 문서는 함께 삭제됩니다.
            </p>

            <div class="mt-5 flex items-center justify-end gap-2">
              <button type="button" phx-click="close_delete_packet" class="btn btn-ghost btn-sm">
                취소
              </button>
              <button
                id="packet-delete-confirm"
                type="button"
                phx-click="delete_packet"
                class="btn btn-error btn-sm"
              >
                삭제
              </button>
            </div>
          </div>
          <button
            type="button"
            phx-click="close_delete_packet"
            class="modal-backdrop"
            aria-label="닫기"
          >
            닫기
          </button>
        </div>
      </main>
    </Layouts.app>
    """
  end

  defp load_packets(socket) do
    assign(
      socket,
      :packets,
      Packets.list_packets_for_scope(socket.assigns.current_scope)
    )
  end

  defp packet_form(attrs \\ %{"title" => ""}) do
    to_form(attrs, as: :packet)
  end

  defp compact_blank_attrs(attrs) do
    attrs
    |> Map.take(["title"])
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp packet_title_attrs(attrs) do
    Map.take(attrs, ["title"])
  end

  defp blank?(value), do: value in [nil, ""]

  defp packet_id(packet), do: field(packet, :id)
  defp packet_title(packet), do: field(packet, :title, "제목 없는 패킷")

  defp field(map, key, default \\ nil)

  defp field(nil, _key, default), do: default

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))
end
