defmodule EcritsWeb.Local.MountLive do
  @moduledoc """
  Unauthenticated local workspace mount screen.
  """

  use EcritsWeb, :live_view

  alias EcritsWeb.Local.DirectoryPicker
  alias EcritsWeb.Local.WorkspaceAdapter

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
    <Layouts.app flash={@flash} variant="default" show_footer={false}>
      <main id="local-mount-root" class="mount-screen">
        <section
          id="local-native-directory-picker"
          data-role="native-directory-picker"
          class="mount-panel"
          aria-label="Open workspace folder"
        >
          <%!-- Editor-style title bar: window controls + active "buffer" path. --%>
          <div class="mount-panel__bar">
            <span class="mount-panel__dots" aria-hidden="true">
              <span class="mount-panel__dot"></span>
              <span class="mount-panel__dot"></span>
              <span class="mount-panel__dot"></span>
            </span>
            <span class="mount-panel__crumb">
              <.icon name="hero-folder-micro" class="mount-panel__crumb-icon" />
              <span>no folder open</span>
            </span>
          </div>

          <div
            id="local-mount-picker-surface"
            data-role="mount-picker-surface"
            class="mount-panel__body"
          >
            <header class="mount-head">
              <h1 id="local-native-directory-status" class="mount-head__title">
                Open a workspace folder
              </h1>
              <p class="mount-head__sub">
                Point Ecrits at a folder on this machine to start editing. Everything
                stays on disk.
              </p>
            </header>

            <div
              id="local-mount-control-row"
              data-role="mount-control-row"
              class="mount-actions"
            >
              <%!-- Primary action: the native directory picker. --%>
              <button
                id="local-mount-choose"
                type="button"
                phx-click="choose_mount_directory"
                phx-disable-with="Opening picker…"
                class="mount-open"
              >
                <.icon name="hero-folder-open-micro" class="mount-open__icon" />
                <span>Open folder…</span>
              </button>

              <%!-- Secondary: type or paste a path, Enter to mount. --%>
              <.form
                for={@path_form}
                id="local-path-form"
                action={~p"/workspace"}
                method="get"
                class="mount-pathform"
              >
                <label for="local-path-input" class="mount-pathform__label">
                  or enter a path
                </label>
                <div class="mount-field">
                  <span class="mount-field__chevron" aria-hidden="true">&rsaquo;</span>
                  <.input
                    field={@path_form[:path]}
                    id="local-path-input"
                    name="path"
                    type="text"
                    autocomplete="off"
                    spellcheck="false"
                    placeholder="/Users/name/workspace"
                    class="mount-field__input"
                  />
                  <button
                    id="local-path-submit"
                    type="submit"
                    aria-label="Open path"
                    title="Open this path"
                    class="mount-field__submit"
                  >
                    <.icon name="hero-arrow-turn-down-left-micro" class="size-3.5" />
                    <span class="mount-field__submit-label">Open</span>
                  </button>
                </div>
              </.form>
            </div>

            <p
              :if={@mount_error}
              id="local-mount-error"
              role="alert"
              class="mount-error"
            >
              <.icon name="hero-exclamation-triangle-micro" class="mount-error__icon" />
              <span>{@mount_error}</span>
            </p>

            <footer class="mount-foot">
              <span class="mount-foot__item">
                <.icon name="hero-lock-closed-micro" class="mount-foot__icon" />
                <span>Local-first</span>
              </span>
              <span class="mount-foot__sep" aria-hidden="true">&middot;</span>
              <span class="mount-foot__item">Nothing leaves this device</span>
            </footer>
          </div>
        </section>
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
