defmodule ContractWeb.Router do
  use ContractWeb, :router

  import ContractWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ContractWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug ContractWeb.Locale
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # External MCP / Slack ingress pipeline. No CSRF, no session — MCP and
  # Slack are API-only. SPEC.md §4 / §21.
  pipeline :mcp do
    plug :accepts, ["json", "event-stream"]
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
      get "/revoke_requests/:document_id", TestDbController, :revoke_requests
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

  scope "/", ContractWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Browser product flow is LiveView-only. The document-first product
  # routes live in the authenticated browser scope below, inside the
  # single `:require_authenticated_user` live_session.

  # Inbound MCP server (SPEC.md §4, §21). Streamable HTTP transport: accepts
  # JSON-RPC 2.0 bodies, returns either application/json or
  # text/event-stream based on the request Accept header. Auth is bearer
  # only (route_ref tokens or user api tokens) — no session, no CSRF.
  scope "/mcp", ContractWeb.MCP do
    pipe_through :mcp
    forward "/", MCPPlug
  end

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
        on_mount: [{ContractWeb.UserAuth, :mount_current_scope}] do
        live "/theme", Dev.ThemePreviewLive
      end
    end

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ContractWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", ContractWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [
        {ContractWeb.UserAuth, :require_authenticated},
        ContractWeb.Locale,
        {ContractWeb.DocumentScope, :assign_scope}
      ] do
      live "/storage", StorageLive
      live "/studio", StudioLive
      live "/studio/:document_id", StudioLive
      live "/documents/:document_id", StudioLive
      live "/documents/:document_id/review", StudioLive
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
      live "/settings", UserLive.SettingsHub, :index
      live "/settings/api-tokens", UserLive.ApiTokens, :index
      live "/settings/integrations", UserLive.Integrations, :index
    end

    get "/matters/:matter_id/documents/:document_id",
        LegacyRedirectController,
        :matter_document

    # /dashboard → /storage (Document library was renamed to "보관함"
    # 2026-05-17; old bookmarks/Slack unfurls must still resolve.)
    get "/dashboard", LegacyRedirectController, :dashboard

    get "/exports/:export_id/download", ExportDownloadController, :show

    post "/users/update-password", UserSessionController, :update_password

    # Slack OAuth user-token flow (Wave 6). OUTBOUND only — Slack ingress
    # at /slack/* stays at 501 per the project Slack-MCP memory.
    get "/auth/slack/start", SlackOAuthController, :start
    get "/auth/slack/callback", SlackOAuthController, :callback
    post "/auth/slack/disconnect", SlackOAuthController, :disconnect
  end

  scope "/", ContractWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{ContractWeb.UserAuth, :mount_current_scope}, ContractWeb.Locale] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
