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
      <%!-- A plain <div>, not <main>: Layouts.app already wraps the slot in the
            page's single <main> landmark; a nested second <main> here tripped the
            duplicate / non-top-level main landmark rules. --%>
      <div id="local-mount-root" class="mount-screen">
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
                disabled={@picker_busy?}
                aria-busy={to_string(@picker_busy?)}
                data-busy={to_string(@picker_busy?)}
                class="mount-open"
              >
                <%= if @picker_busy? do %>
                  <.icon name="hero-arrow-path-micro" class="mount-open__icon animate-spin" />
                  <span>Opening picker…</span>
                <% else %>
                  <.icon name="hero-folder-open-micro" class="mount-open__icon" />
                  <span>Open folder…</span>
                <% end %>
              </button>

              <%!-- Secondary: type or paste a path, Enter to mount. --%>
              <.form
                for={@path_form}
                id="local-path-form"
                phx-submit="open_path"
                class="mount-pathform"
              >
                <label for="local-path-input" class="mount-pathform__label">
                  or enter a path
                </label>
                <div class="mount-field">
                  <span class="mount-field__chevron" aria-hidden="true">&rsaquo;</span>
                  <%!-- Bare <input>, NOT <.input>: the core component wraps the
                       field in a `div.fieldset > label` whose flex/padding nests
                       the control and knocks it out of vertical alignment with the
                       chevron and submit button. .mount-field is a flat 3-item flex
                       row (chevron / input / submit), so the input is a direct
                       child styled by .mount-field__input. --%>
                  <input
                    id="local-path-input"
                    name={@path_form[:path].name}
                    type="text"
                    value={Phoenix.HTML.Form.normalize_value("text", @path_form[:path].value)}
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
          </div>
        </section>
      </div>
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
