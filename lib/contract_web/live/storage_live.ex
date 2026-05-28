defmodule ContractWeb.StorageLive do
  @moduledoc """
  Authenticated project library for 보관함.

  Storage is the project entry point: create/open projects. Documents remain
  edited at `/documents/:id` and are managed from `/projects/:project_id`.
  """
  use ContractWeb, :live_view

  alias Contract.Projects

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, dgettext("storage", "Storage"))
     |> assign(:project_form, project_form())
     |> assign(:show_create_modal, false)
     |> load_projects()}
  end

  @impl true
  def handle_event("open_create_project_modal", _params, socket) do
    {:noreply, assign(socket, :show_create_modal, true)}
  end

  def handle_event("close_create_project_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:project_form, project_form())
     |> assign(:show_create_modal, false)}
  end

  def handle_event("validate_project", %{"project" => project_params}, socket) do
    {:noreply, assign(socket, :project_form, project_form(project_params))}
  end

  def handle_event("create_project", %{"project" => project_params}, socket) do
    attrs = compact_blank_attrs(project_params)

    case Projects.create_project(socket.assigns.current_scope, attrs) do
      {:ok, project} ->
        {:noreply, push_navigate(socket, to: ~p"/projects/#{project_id(project)}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:project_form, to_form(changeset, action: :insert))
         |> assign(:show_create_modal, true)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "프로젝트를 만들 수 없습니다.")}
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
            id="open-project-create-modal"
            type="button"
            phx-click="open_create_project_modal"
            class="btn btn-primary btn-sm"
          >
            생성
          </button>
        </header>

        <.table
          id="projects-table"
          rows={@projects}
          row_id={fn project -> "project-row-#{project_id(project)}" end}
          row_click={fn project -> JS.navigate(~p"/projects/#{project_id(project)}") end}
        >
          <:col :let={project} label="프로젝트">
            {project_title(project)}
          </:col>
          <:col :let={project} label="수정일">{format_date(field(project, :updated_at))}</:col>
        </.table>

        <p
          :if={@projects == []}
          id="projects-empty"
          class="py-6 text-center text-sm text-base-content/55"
        >
          아직 프로젝트가 없습니다.
        </p>

        <div
          :if={@show_create_modal}
          id="project-create-modal"
          class="modal modal-open"
          phx-window-keydown="close_create_project_modal"
          phx-key="escape"
        >
          <div class="modal-box max-w-md">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-base font-semibold">프로젝트 생성</h2>
              <button
                id="close-project-create-modal"
                type="button"
                phx-click="close_create_project_modal"
                class="btn btn-ghost btn-sm btn-square"
                aria-label="닫기"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <.form
              for={@project_form}
              id="project-create-form"
              phx-change="validate_project"
              phx-submit="create_project"
              class="mt-4 space-y-4"
            >
              <.input
                field={@project_form[:title]}
                type="text"
                label="프로젝트명"
                placeholder="예: 공급계약 검토"
                required
              />
              <div class="flex items-center justify-end gap-2">
                <button
                  type="button"
                  phx-click="close_create_project_modal"
                  class="btn btn-ghost btn-sm"
                >
                  취소
                </button>
                <button id="project-create-submit" type="submit" class="btn btn-primary btn-sm">
                  생성
                </button>
              </div>
            </.form>
          </div>
          <button
            type="button"
            phx-click="close_create_project_modal"
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

  defp load_projects(socket) do
    assign(
      socket,
      :projects,
      Projects.list_projects_for_scope(socket.assigns.current_scope)
    )
  end

  defp project_form(attrs \\ %{"title" => ""}) do
    to_form(attrs, as: :project)
  end

  defp compact_blank_attrs(attrs) do
    attrs
    |> Map.take(["title"])
    |> Enum.reject(fn {_key, value} -> blank?(value) end)
    |> Map.new()
  end

  defp blank?(value), do: value in [nil, ""]

  defp project_id(project), do: field(project, :id)
  defp project_title(project), do: field(project, :title, "제목 없는 프로젝트")

  defp format_date(nil), do: ""
  defp format_date(%DateTime{} = t), do: Calendar.strftime(t, "%Y.%m.%d")

  defp format_date(%NaiveDateTime{} = t),
    do: t |> DateTime.from_naive!("Etc/UTC") |> format_date()

  defp format_date(%Date{} = d), do: Calendar.strftime(d, "%Y.%m.%d")
  defp format_date(_), do: ""

  defp field(map, key, default \\ nil)

  defp field(nil, _key, default), do: default

  defp field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))
end
