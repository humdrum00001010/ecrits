defmodule EcritsWeb.Local.MountLive do
  @moduledoc """
  Unauthenticated local workspace mount screen.
  """

  use EcritsWeb, :live_view

  alias Ecrits.Local.WorkspaceHandoff
  alias EcritsWeb.Local.DirectoryPicker
  alias EcritsWeb.Local.WorkspaceAdapter

  @impl true
  def mount(_params, session, socket) do
    {:ok,
     socket
     |> assign(:local_live_session_id, local_live_session_id(session))
     |> assign(:page_title, "Mount workspace")
     |> assign(:mount_error, nil)
     |> assign(:picker_busy?, false)
     |> assign(:path_form, path_form())}
  end

  @impl true
  def handle_event("choose_mount_directory", _params, socket) do
    if socket.assigns.picker_busy? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:mount_error, nil)
       |> assign(:picker_busy?, true)
       |> start_async(:choose_mount_directory, fn -> DirectoryPicker.choose_folder() end)}
    end
  end

  @impl true
  def handle_event("open_path", %{"local_path" => %{"path" => path}}, socket) do
    mount_workspace(socket, path)
  end

  def handle_event("open_path", _params, socket) do
    mount_workspace(socket, "")
  end

  @impl true
  def handle_async(:choose_mount_directory, {:ok, {:ok, path}}, socket) do
    socket
    |> assign(:picker_busy?, false)
    |> mount_workspace(path)
  end

  def handle_async(:choose_mount_directory, {:ok, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:picker_busy?, false)
     |> assign(:mount_error, error_message(reason))}
  end

  def handle_async(:choose_mount_directory, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:picker_busy?, false)
     |> assign(:mount_error, "Native folder picker failed to open.")}
  end

  defp mount_workspace(socket, path) do
    path = String.trim(path)
    socket = assign(socket, :path_form, path_form(path))

    if path == "" do
      {:noreply,
       socket
       |> assign(:mount_error, "Choose a workspace folder.")}
    else
      path = Path.expand(path)

      with :ok <- validate_directory(path),
           {:ok, workspace} <- WorkspaceAdapter.mount(path),
           root_path = Map.get(workspace, :root_path, path),
           :ok <-
             WorkspaceHandoff.put_workspace_path(socket.assigns.local_live_session_id, root_path) do
        {:noreply,
         redirect(socket,
           to: ~p"/workspace"
         )}
      else
        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:mount_error, error_message(reason))}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} variant="default" show_footer={false}>
      <.workspace_mount_panel
        picker_busy?={@picker_busy?}
        path_form={@path_form}
        mount_error={@mount_error}
      />
    </Layouts.app>
    """
  end

  defp validate_directory(path) do
    cond do
      not File.exists?(path) -> {:error, {:invalid_path, "Workspace path does not exist."}}
      not File.dir?(path) -> {:error, {:invalid_path, "Workspace path is not a directory."}}
      true -> :ok
    end
  end

  defp path_form(path \\ "") do
    to_form(%{"path" => path}, as: :local_path)
  end

  defp local_live_session_id(session) when is_map(session) do
    case session["local_live_session_id"] || session[:local_live_session_id] do
      id when is_binary(id) and id != "" -> id
      _ -> Ecto.UUID.generate()
    end
  end

  defp local_live_session_id(_session), do: Ecto.UUID.generate()

  defp error_message({:invalid_path, message}) when is_binary(message), do: message
  defp error_message({:error, message}) when is_binary(message), do: message
  defp error_message(:cancelled), do: "Folder selection canceled."
  defp error_message({:native_picker_unavailable, message}) when is_binary(message), do: message
  defp error_message({:local_substrate_unavailable, message}) when is_binary(message), do: message
  defp error_message(message) when is_binary(message), do: message
  defp error_message(_reason), do: "Workspace could not be mounted."
end
