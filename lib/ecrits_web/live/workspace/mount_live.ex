defmodule EcritsWeb.Workspace.MountLive do
  @moduledoc """
  Unauthenticated local workspace mount screen.
  """

  use EcritsWeb, :live_view

  alias Ecrits.WorkspaceHandoff
  alias EcritsWeb.Workspace.DirectoryPicker
  alias EcritsWeb.Workspace.Adapter
  alias Ecrits.WorkspaceMount

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:local_live_session_id, local_live_session_id(session))
     |> assign(:page_title, "Mount workspace")
     |> assign(:workspace_mount, WorkspaceMount.new())}
  end

  @impl true
  def handle_event("workspace.directory_picker.open", _params, socket) do
    if socket.assigns.workspace_mount.picker_busy? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> update(:workspace_mount, &WorkspaceMount.start_picker/1)
       |> start_async(:choose_mount_directory, fn -> DirectoryPicker.choose_folder() end)}
    end
  end

  @impl true
  def handle_event("workspace.path.open", %{"local_path" => %{"path" => path}}, socket) do
    mount_workspace(socket, path)
  end

  def handle_event("workspace.path.open", _params, socket) do
    mount_workspace(socket, "")
  end

  @impl true
  def handle_async(:choose_mount_directory, {:ok, {:ok, path}}, socket) do
    socket
    |> update(:workspace_mount, &WorkspaceMount.picker_selected(&1, path))
    |> mount_workspace(path)
  end

  def handle_async(:choose_mount_directory, {:ok, {:error, reason}}, socket) do
    {:noreply, update(socket, :workspace_mount, &WorkspaceMount.picker_failed(&1, reason))}
  end

  def handle_async(:choose_mount_directory, {:exit, _reason}, socket) do
    {:noreply,
     update(socket, :workspace_mount, fn state ->
       WorkspaceMount.picker_failed(state, "Native folder picker failed to open.")
     end)}
  end

  defp mount_workspace(socket, path) do
    socket = update(socket, :workspace_mount, &WorkspaceMount.submit(&1, path))

    case WorkspaceMount.validate_path(socket.assigns.workspace_mount) do
      {:ok, path} ->
        with {:ok, workspace} <- Adapter.mount(path),
             root_path = Map.get(workspace, :root_path, path),
             :ok <-
               WorkspaceHandoff.put_workspace_path(
                 socket.assigns.local_live_session_id,
                 root_path
               ) do
          {:noreply, redirect(socket, to: ~p"/workspace")}
        else
          {:error, reason} ->
            {:noreply, update(socket, :workspace_mount, &WorkspaceMount.put_error(&1, reason))}
        end

      {:error, reason} ->
        {:noreply, update(socket, :workspace_mount, &WorkspaceMount.put_error(&1, reason))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant="default" show_footer={false}>
      <.workspace_mount_panel workspace_mount={@workspace_mount} />
    </Layouts.app>
    """
  end

  defp local_live_session_id(session) when is_map(session) do
    case session["local_live_session_id"] || session[:local_live_session_id] do
      id when is_binary(id) and id != "" -> id
      _ -> Ecto.UUID.generate()
    end
  end

  defp local_live_session_id(_session), do: Ecto.UUID.generate()
end
