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
     |> assign(:editing_project, nil)
     |> assign(:edit_project_form, project_form())
     |> assign(:deleting_project, nil)
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

  def handle_event("open_project_settings", %{"id" => project_id}, socket) do
    case Projects.get_project(socket.assigns.current_scope, project_id) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:editing_project, project)
         |> assign(:edit_project_form, project_form(%{"title" => project_title(project)}))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "프로젝트를 찾을 수 없습니다.")}
    end
  end

  def handle_event("close_project_settings", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_project, nil)
     |> assign(:edit_project_form, project_form())}
  end

  def handle_event("validate_edit_project", %{"project" => project_params}, socket) do
    {:noreply, assign(socket, :edit_project_form, project_form(project_params))}
  end

  def handle_event("update_project", %{"project" => project_params}, socket) do
    case socket.assigns.editing_project do
      %Contract.Projects.Project{} = project ->
        case Projects.update_project(
               socket.assigns.current_scope,
               project,
               project_title_attrs(project_params)
             ) do
          {:ok, _project} ->
            {:noreply,
             socket
             |> assign(:editing_project, nil)
             |> assign(:edit_project_form, project_form())
             |> load_projects()}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :edit_project_form, to_form(changeset, action: :update))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "프로젝트를 수정할 수 없습니다.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "프로젝트를 찾을 수 없습니다.")}
    end
  end

  def handle_event("open_delete_project", %{"id" => project_id}, socket) do
    case Projects.get_project(socket.assigns.current_scope, project_id) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:editing_project, nil)
         |> assign(:edit_project_form, project_form())
         |> assign(:deleting_project, project)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "프로젝트를 찾을 수 없습니다.")}
    end
  end

  def handle_event("close_delete_project", _params, socket) do
    {:noreply, assign(socket, :deleting_project, nil)}
  end

  def handle_event("delete_project", _params, socket) do
    case socket.assigns.deleting_project do
      %Contract.Projects.Project{} = project ->
        case Projects.delete_project(socket.assigns.current_scope, project) do
          {:ok, _project} ->
            {:noreply,
             socket
             |> assign(:deleting_project, nil)
             |> load_projects()}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "프로젝트를 삭제할 수 없습니다.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "프로젝트를 찾을 수 없습니다.")}
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
          <:action :let={project}>
            <div id={"project-actions-#{project_id(project)}"} class="flex items-center gap-1">
              <button
                id={"project-settings-#{project_id(project)}"}
                type="button"
                phx-click="open_project_settings"
                phx-value-id={project_id(project)}
                class="btn btn-ghost btn-xs btn-square"
                aria-label="프로젝트 설정"
              >
                <.icon name="hero-cog-6-tooth" class="size-4" />
              </button>
            </div>
          </:action>
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

        <div
          :if={@editing_project}
          id="project-settings-modal"
          class="modal modal-open"
          phx-window-keydown="close_project_settings"
          phx-key="escape"
        >
          <div class="modal-box max-w-md">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-base font-semibold">프로젝트 설정</h2>
              <button
                id="close-project-settings-modal"
                type="button"
                phx-click="close_project_settings"
                class="btn btn-ghost btn-sm btn-square"
                aria-label="닫기"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <.form
              for={@edit_project_form}
              id="project-edit-form"
              phx-change="validate_edit_project"
              phx-submit="update_project"
              class="mt-4 space-y-4"
            >
              <.input
                field={@edit_project_form[:title]}
                type="text"
                label="프로젝트명"
                required
              />
              <div class="flex items-center justify-end gap-2">
                <button
                  type="button"
                  phx-click="close_project_settings"
                  class="btn btn-ghost btn-sm"
                >
                  취소
                </button>
                <button id="project-edit-submit" type="submit" class="btn btn-primary btn-sm">
                  저장
                </button>
              </div>
            </.form>

            <div class="mt-5 border-t border-base-300 pt-4">
              <h3 class="text-sm font-semibold text-error">삭제</h3>
              <p class="mt-1 text-sm text-base-content/65">
                프로젝트만 삭제합니다. 연결된 문서는 삭제되지 않습니다.
              </p>
              <div class="mt-3 flex justify-end">
                <button
                  id="project-settings-delete"
                  type="button"
                  phx-click="open_delete_project"
                  phx-value-id={project_id(@editing_project)}
                  class="btn btn-error btn-sm"
                >
                  삭제 설정
                </button>
              </div>
            </div>
          </div>
          <button
            type="button"
            phx-click="close_project_settings"
            class="modal-backdrop"
            aria-label="닫기"
          >
            닫기
          </button>
        </div>

        <div
          :if={@deleting_project}
          id="project-delete-modal"
          class="modal modal-open"
          phx-window-keydown="close_delete_project"
          phx-key="escape"
        >
          <div class="modal-box max-w-md">
            <div class="flex items-center justify-between gap-3">
              <h2 class="text-base font-semibold">프로젝트 삭제</h2>
              <button
                id="close-project-delete-modal"
                type="button"
                phx-click="close_delete_project"
                class="btn btn-ghost btn-sm btn-square"
                aria-label="닫기"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>

            <p class="mt-4 text-sm text-base-content/70">
              {project_title(@deleting_project)} 프로젝트를 삭제합니다. 연결된 문서는 삭제되지 않습니다.
            </p>

            <div class="mt-5 flex items-center justify-end gap-2">
              <button type="button" phx-click="close_delete_project" class="btn btn-ghost btn-sm">
                취소
              </button>
              <button
                id="project-delete-confirm"
                type="button"
                phx-click="delete_project"
                class="btn btn-error btn-sm"
              >
                삭제
              </button>
            </div>
          </div>
          <button
            type="button"
            phx-click="close_delete_project"
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

  defp project_title_attrs(attrs) do
    Map.take(attrs, ["title"])
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
