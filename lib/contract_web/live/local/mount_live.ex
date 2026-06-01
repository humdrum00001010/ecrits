defmodule ContractWeb.Local.MountLive do
  @moduledoc """
  Unauthenticated local workspace mount screen.
  """

  use ContractWeb, :live_view

  alias ContractWeb.Local.DirectoryPicker
  alias ContractWeb.Local.WorkspaceAdapter

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Mount workspace")
     |> assign(:mount_error, nil)
     |> assign(:path_form, path_form())}
  end

  @impl true
  def handle_event("choose_mount_directory", _params, socket) do
    case DirectoryPicker.choose_folder() do
      {:ok, path} ->
        mount_workspace(socket, path)

      {:error, reason} ->
        {:noreply, assign(socket, :mount_error, error_message(reason))}
    end
  end

  def handle_event("mount_workspace", %{"local_path" => %{"path" => path}}, socket) do
    mount_workspace(socket, path)
  end

  def handle_event("mount_workspace", %{"path" => path}, socket) do
    mount_workspace(socket, path)
  end

  def handle_event("mount_workspace", _params, socket) do
    {:noreply,
     socket
     |> assign(:mount_error, "Choose a workspace folder.")
     |> assign(:path_form, path_form())}
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
           {:ok, workspace} <- WorkspaceAdapter.mount(path) do
        {:noreply,
         push_navigate(socket,
           to: ~p"/workspace?#{[path: Map.get(workspace, :root_path, path)]}"
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
    <Layouts.app flash={@flash} variant="narrow" show_footer={false}>
      <main id="local-mount-root" class="py-8">
        <div class="mb-6">
          <h1 class="text-2xl font-semibold tracking-tight text-base-content">
            Mount workspace
          </h1>
          <p class="mt-2 text-sm leading-6 text-base-content/65">
            Choose a local folder to use as the active contract workspace.
          </p>
        </div>

        <div id="local-mount-picker" class="space-y-3">
          <section
            id="local-native-directory-picker"
            data-role="native-directory-picker"
            class="rounded border border-base-300 bg-base-100 p-3 shadow-sm"
          >
            <div
              id="local-mount-picker-surface"
              data-role="mount-picker-surface"
              class="flex flex-col gap-3"
            >
              <p id="local-native-directory-status" class="text-sm font-medium text-base-content">
                Choose workspace folder
              </p>

              <div
                id="local-mount-control-row"
                data-role="mount-control-row"
                class="flex flex-col gap-2 sm:flex-row sm:items-end"
              >
                <button
                  id="local-mount-choose"
                  type="button"
                  phx-click="choose_mount_directory"
                  phx-disable-with="Opening..."
                  class="inline-flex h-10 w-full items-center justify-center gap-2 rounded-md border border-base-300 bg-base-100 px-3 text-sm font-medium text-base-content transition-colors hover:bg-base-200 focus:outline-none focus:ring-2 focus:ring-base-content/20 sm:mb-2 sm:w-auto"
                >
                  <.icon name="hero-folder-open" class="size-4" /> Choose folder
                </button>

                <.form
                  for={@path_form}
                  id="local-path-form"
                  action={~p"/workspace"}
                  method="get"
                  class="min-w-0 flex-1"
                >
                  <div class="flex flex-col gap-2 sm:flex-row sm:items-end">
                    <div class="min-w-0 flex-1">
                      <.input
                        field={@path_form[:path]}
                        id="local-path-input"
                        name="path"
                        type="text"
                        label="Folder path"
                        autocomplete="off"
                        placeholder="/Users/name/workspace"
                        class="h-10 w-full rounded-md border border-base-300 bg-base-100 px-3 text-sm text-base-content shadow-sm transition placeholder:text-base-content/40 focus:border-base-content/40 focus:outline-none focus:ring-2 focus:ring-base-content/10"
                      />
                    </div>

                    <button
                      id="local-path-submit"
                      type="submit"
                      aria-label="Open path"
                      title="Open path"
                      class="inline-flex size-10 shrink-0 items-center justify-center rounded-md bg-base-content text-base-100 transition-colors hover:bg-base-content/85 focus:outline-none focus:ring-2 focus:ring-base-content/20 sm:mb-2"
                    >
                      <.icon name="hero-arrow-turn-down-left" class="size-4" />
                    </button>
                  </div>
                </.form>
              </div>
            </div>
          </section>

          <p
            :if={@mount_error}
            id="local-mount-error"
            class="rounded-md border border-error/25 bg-error/10 px-3 py-2 text-sm text-error"
          >
            {@mount_error}
          </p>
        </div>
      </main>
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

  defp error_message({:invalid_path, message}) when is_binary(message), do: message
  defp error_message({:error, message}) when is_binary(message), do: message
  defp error_message(:cancelled), do: "Folder selection canceled."
  defp error_message({:native_picker_unavailable, message}) when is_binary(message), do: message
  defp error_message({:local_substrate_unavailable, message}) when is_binary(message), do: message
  defp error_message(message) when is_binary(message), do: message
  defp error_message(_reason), do: "Workspace could not be mounted."
end
