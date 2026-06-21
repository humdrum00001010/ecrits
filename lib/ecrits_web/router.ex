defmodule EcritsWeb.Router do
  use EcritsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_local_live_session_id
    plug :fetch_live_flash
    plug :put_root_layout, html: {EcritsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug EcritsWeb.Locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Slack ingress remains a 501 stub for this build (Slack track is out of
  # scope for Wave 3C2 per user directive 2026-05-15).
  scope "/slack" do
    pipe_through :api
    post "/events", EcritsWeb.NotImplementedPlug, label: "/slack/events"
    post "/actions", EcritsWeb.NotImplementedPlug, label: "/slack/actions"
    post "/commands", EcritsWeb.NotImplementedPlug, label: "/slack/commands"
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

    # Hosted SaaS browser routes (storage / dashboard / studio / documents /
    # auth / settings) are retired. They respond 410 Gone so old links do not
    # render stale product surfaces.
    get "/storage", RetiredController, :gone
    get "/dashboard", RetiredController, :gone
    get "/packets/:packet_id", RetiredController, :gone
    get "/studio", RetiredController, :gone
    get "/studio/:document_id", RetiredController, :gone

    put "/documents/direct-upload", RetiredController, :gone
    get "/documents/:document_id/rhwp-snapshots/:snapshot_id", RetiredController, :gone
    get "/documents/:document_id/review", RetiredController, :gone
    get "/documents/:document_id", RetiredController, :gone

    get "/settings", RetiredController, :gone
    get "/settings/api-tokens", RetiredController, :gone

    get "/users/register", RetiredController, :gone
    get "/users/log-in", RetiredController, :gone
    get "/users/log-in/:token", RetiredController, :gone
    post "/users/log-in", RetiredController, :gone
    delete "/users/log-out", RetiredController, :gone
    get "/users/settings", RetiredController, :gone
    get "/users/settings/confirm-email/:token", RetiredController, :gone
    post "/users/update-password", RetiredController, :gone

    live_session :local,
      on_mount: [EcritsWeb.Locale] do
      live "/", Local.MountLive, :index
      live "/local/agent-providers/:provider/setup", Local.AgentProviderSetupLive, :show
      live "/workspace", Local.WorkspaceLive, :show
    end

    # Read-only raw bytes of a local workspace HWP/HWPX document, gated to the
    # workspace path. The browser rhwp_core WASM engine fetches these to render
    # + hit-test locally (the server keeps the bytes as source of truth).
    get "/local/document-bytes", LocalDocumentBytesController, :show

    # Inline previews for doc.render outputs (PNG files in the render scratch
    # dir) — the chat rail swaps the render tool-call chip body for the image.
    get "/local/render-preview", LocalRenderPreviewController, :show
  end

  defp put_local_live_session_id(conn, _opts) do
    case get_session(conn, :local_live_session_id) do
      id when is_binary(id) and id != "" ->
        conn

      _ ->
        put_session(conn, :local_live_session_id, Ecto.UUID.generate())
    end
  end
end
