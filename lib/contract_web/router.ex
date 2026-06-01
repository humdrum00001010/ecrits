defmodule ContractWeb.Router do
  use ContractWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ContractWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug ContractWeb.Locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # DEV ONLY: rhwp IR debug endpoint — POST {ir: {...}} → 200 with rendered text.
  if Mix.env() == :dev do
    scope "/__dev__", ContractWeb do
      pipe_through :api

      post "/render-ir", DevController, :render_ir
    end
  end

  # Playwright-only auth shim. Routes 404 at compile time in :prod because
  # `Application.compile_env(:contract, :test_auth, false)` is false there
  # (the controller module won't exist). Uses a bespoke pipeline that
  # fetches the session (so we can write the user_token cookie) but skips
  # CSRF so Playwright's bare `POST /test/personas/.../sign_in` succeeds
  # without an HTML round-trip.
  if Application.compile_env(:contract, :test_auth, false) do
    pipeline :test_auth do
      plug :accepts, ["json"]
      plug :fetch_session
    end

    scope "/test", ContractWeb do
      pipe_through :test_auth
      post "/personas/:persona/sign_in", TestAuthController, :sign_in
      post "/reset", TestAuthController, :reset
    end

    # Test-only DB inspection: Playwright reads Studio rows over HTTPS to
    # assert backend state. Same compile-time gating as the auth shim —
    # the controller module elides in :prod and the routes 404.
    scope "/test/db", ContractWeb do
      pipe_through :test_auth
      get "/changes/:document_id", TestDbController, :changes
      get "/documents", TestDbController, :documents
      get "/oban_jobs", TestDbController, :oban_jobs
      post "/documents", TestDbController, :seed_document
    end

    # Test/dev-only Studio browser QA helpers. Compile-gated with the same
    # `:test_auth` flag as persona and DB helpers, so this route does not
    # exist in production builds.
    scope "/test/studio", ContractWeb do
      pipe_through :test_auth
      post "/operation_blocks", TestStudioController, :operation_blocks
    end
  end

  # Browser product flow is local-first LiveView-only. Hosted SaaS browser
  # routes are kept as 410 responses during the migration so old links do not
  # render stale product surfaces.

  # Slack ingress remains a 501 stub for this build (Slack track is out of
  # scope for Wave 3C2 per user directive 2026-05-15).
  scope "/slack" do
    pipe_through :api
    post "/events", ContractWeb.NotImplementedPlug, label: "/slack/events"
    post "/actions", ContractWeb.NotImplementedPlug, label: "/slack/actions"
    post "/commands", ContractWeb.NotImplementedPlug, label: "/slack/commands"
  end

  # Enable LiveDashboard, Swoosh mailbox preview, and the theme swatch in dev.
  if Application.compile_env(:contract, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev", ContractWeb do
      pipe_through :browser

      live_session :dev_only,
        on_mount: [ContractWeb.Locale] do
        live "/theme", Dev.ThemePreviewLive
      end
    end

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ContractWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  scope "/", ContractWeb do
    pipe_through [:browser]

    get "/storage", RetiredController, :gone
    get "/dashboard", RetiredController, :gone
    get "/packets/:packet_id", RetiredController, :gone
    get "/studio", RetiredController, :gone
    get "/studio/:document_id", RetiredController, :gone

    put "/documents/direct-upload", RetiredController, :gone
    get "/documents/:document_id/rhwp-snapshots/:revision", RetiredController, :gone
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
      on_mount: [ContractWeb.Locale] do
      live "/", Local.MountLive, :index
      live "/workspace", Local.WorkspaceLive, :show
    end
  end
end
