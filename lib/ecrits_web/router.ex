defmodule EcritsWeb.Router do
  use EcritsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_live_session_id
    plug :fetch_live_flash
    plug :put_root_layout, html: {EcritsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug EcritsWeb.Locale
  end

  # Enable LiveDashboard and Swoosh mailbox preview in dev.
  if Application.compile_env(:ecrits, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: EcritsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/", EcritsWeb do
    pipe_through [:browser]

    live_session :local,
      on_mount: [EcritsWeb.Locale] do
      live "/", Workspace.MountLive, :index, container: {:div, class: "contents"}

      live "/local/agent-providers/:provider/setup", Workspace.AgentProviderSetupLive, :show,
        container: {:div, class: "contents"}

      live "/workspace", Workspace.WorkspaceLive, :show, container: {:div, class: "contents"}
    end

    # Read-only raw bytes of a local workspace HWP/HWPX document, gated to the
    # workspace path. The browser rhwp_core WASM engine fetches these to render
    # + hit-test locally (the server keeps the bytes as source of truth).
    get "/document-bytes", WorkspaceDocumentBytesController, :show

    # Inline previews for doc.render outputs (PNG files in the render scratch
    # dir) — the chat rail swaps the render tool-call chip body for the image.
    get "/render-preview", WorkspaceRenderPreviewController, :show
  end

  defp put_live_session_id(conn, _opts) do
    case get_session(conn, :live_session_id) do
      id when is_binary(id) and id != "" ->
        conn

      _ ->
        put_session(conn, :live_session_id, Ecto.UUID.generate())
    end
  end
end
