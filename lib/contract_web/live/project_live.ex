defmodule ContractWeb.ProjectLive do
  @moduledoc """
  Authenticated project surface.

  Projects sit above documents. This LiveView only handles project UI:
  listing, creating, opening, and attaching/detaching existing documents.
  """
  use ContractWeb, :live_view

  alias Contract.Projects

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:project, nil)
     |> assign(:attached_documents, [])
     |> assign(:deleting_document, nil)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load_project_detail(socket, params["project_id"])}
  end

  @impl true
  def handle_event("create_document", _params, socket) do
    project_id = field(socket.assigns.project, :id)

    {:noreply, push_navigate(socket, to: ~p"/studio?project_id=#{project_id}")}
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
    project_id = field(socket.assigns.project, :id)
    document_id = field(socket.assigns.deleting_document, :id)

    case Projects.detach_document(socket.assigns.current_scope, project_id, document_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:deleting_document, nil)
         |> load_project_detail(project_id)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "문서를 제거할 수 없습니다.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="default">
      <main
        id="projects-root"
        data-projects="root"
        class="flex flex-col gap-6 py-6 text-base-content sm:py-10"
      >
        <.project_detail
          project={@project}
          attached_documents={@attached_documents}
          deleting_document={@deleting_document}
        />
      </main>
    </Layouts.app>
    """
  end

  attr :project, :any, required: true
  attr :attached_documents, :list, required: true
  attr :deleting_document, :any, required: true

  def project_detail(assigns) do
    ~H"""
    <header class="flex items-center justify-between gap-3">
      <div class="space-y-2">
        <.link
          navigate={~p"/storage"}
          class="inline-flex items-center gap-1 text-sm text-base-content/55 hover:text-base-content"
        >
          <.icon name="hero-arrow-left" class="size-4" /> 보관함
        </.link>
        <div class="space-y-1">
          <h1 class="m-0 text-[clamp(22px,4vw,28px)] font-semibold tracking-tight">
            {project_title(@project)}
          </h1>
        </div>
      </div>

      <button
        id="project-new-document"
        type="button"
        phx-click="create_document"
        class="btn btn-primary btn-sm"
      >
        새 문서
      </button>
    </header>

    <section id="project-documents-panel" class="space-y-3">
      <.table
        id="project-documents-table"
        rows={@attached_documents}
        row_id={fn document -> "attached-document-#{document_id(document)}" end}
        row_click={fn document -> JS.navigate(~p"/documents/#{document_id(document)}") end}
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
        id="project-documents-empty"
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
          {document_title(@deleting_document)} 항목을 이 프로젝트에서 제거합니다.
        </p>
        <p class="mt-2 text-sm text-base-content/60">
          다른 프로젝트에 연결되어 있지 않으면 보관 처리됩니다.
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

  defp load_project_detail(socket, project_id) when is_binary(project_id) do
    case fetch_project(socket.assigns.current_scope, project_id) do
      {:ok, project} ->
        socket
        |> assign(:page_title, project_title(project))
        |> assign(:project, project)
        |> assign(:attached_documents, attached_documents(project))

      {:error, _reason} ->
        socket
        |> put_flash(:error, "프로젝트를 찾을 수 없습니다.")
        |> push_navigate(to: ~p"/storage")
    end
  end

  defp fetch_project(scope, project_id) do
    case Projects.get_project(scope, project_id) do
      {:ok, project} -> {:ok, project}
      {:error, reason} -> {:error, reason}
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  defp attached_documents(project) do
    project
    |> field(:documents, field(project, :attached_documents, []))
    |> case do
      %Ecto.Association.NotLoaded{} -> []
      documents when is_list(documents) -> documents
      _ -> []
    end
  end

  defp project_title(project), do: field(project, :title, "제목 없는 프로젝트")

  defp document_id(document), do: field(document, :id)
  defp document_title(document), do: field(document, :title, "제목 없는 문서")

  defp find_attached_document(documents, target_document_id) do
    Enum.find(documents, &(document_id(&1) == target_document_id))
  end

  defp field(map, key, default \\ nil)

  defp field(nil, _key, default), do: default

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))
end
