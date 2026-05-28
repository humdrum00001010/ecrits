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
     |> assign(:attached_documents, [])}
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
        />
      </main>
    </Layouts.app>
    """
  end

  attr :project, :any, required: true
  attr :attached_documents, :list, required: true

  def project_detail(assigns) do
    ~H"""
    <header class="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
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
    </header>

    <section id="project-documents-panel" class="space-y-3">
      <div class="flex flex-col gap-2 md:flex-row md:items-center md:justify-between">
        <h2 class="text-sm font-semibold text-base-content/80">문서들</h2>

        <div class="flex items-center gap-2">
          <button
            id="project-new-document"
            type="button"
            phx-click="create_document"
            class="btn btn-primary btn-sm"
          >
            새 문서
          </button>
        </div>
      </div>

      <.table
        id="project-documents-table"
        rows={@attached_documents}
        row_id={fn document -> "attached-document-#{document_id(document)}" end}
        row_click={fn document -> JS.navigate(~p"/documents/#{document_id(document)}") end}
      >
        <:col :let={document} label="문서">
          {document_title(document)}
        </:col>
      </.table>

      <p
        :if={@attached_documents == []}
        id="project-documents-empty"
        class="py-6 text-center text-sm text-base-content/55"
      >
        연결된 문서가 없습니다.
      </p>
    </section>
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

  defp field(map, key, default \\ nil)

  defp field(nil, _key, default), do: default

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))
end
