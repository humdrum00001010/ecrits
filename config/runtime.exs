import Config

# config/runtime.exs is executed for all environments, including during
# releases. It runs after compilation and before the system starts, so
# it's the right place to pull secrets from .env / the process environment.
#
# `config/config.exs` already hydrates System env vars from `.env` via
# Ecrits.Env semantics, so `System.get_env/1` here works identically
# in dev/test/prod.

# ---------------------------------------------------------------------------
# Endpoint binding
# ---------------------------------------------------------------------------
if System.get_env("PHX_SERVER") do
  config :ecrits, EcritsWeb.Endpoint, server: true
end

# Port override is dev/prod only. The `:test` env pins :4002 in
# `config/test.exs` so browser tests target a stable endpoint, regardless
# of whatever SERVER_PORT/PORT happens to be set in `.env` for the dev sprite.
if config_env() != :test do
  config :ecrits, EcritsWeb.Endpoint,
    http: [
      port: String.to_integer(System.get_env("SERVER_PORT") || System.get_env("PORT") || "4000")
    ]
end

# Public-facing URL used by `Phoenix.VerifiedRoutes.url/1` (i.e. the absolute
# URLs embedded in gen.auth confirmation / magic-link / update-email emails).
# Without this, `EcritsWeb.Endpoint`'s `:url` defaults to `localhost`
# (set in `config/config.exs`), which leaks into outbound emails when the
# app is running behind a per-sprite hostname like
# `https://ecrits-studio-v7zk.sprites.app`.
#
# Test env is intentionally skipped — gen.auth's generated tests and the
# Wallaby browser tests pin `localhost:4002` explicitly.
if config_env() != :test do
  app_base_url = System.fetch_env!("APP_BASE_URL")
  %URI{scheme: scheme, host: host, port: port} = URI.parse(app_base_url)
  scheme = scheme || "https"
  endpoint_port = port || if(scheme == "https", do: 443, else: 80)

  config :ecrits, EcritsWeb.Endpoint, url: [host: host, port: endpoint_port, scheme: scheme]
end

# ---------------------------------------------------------------------------
# Korean Law MCP
# ---------------------------------------------------------------------------
# The SaaS OpenAI/Upstage/SMTP-mailer stack was retired with the legacy DB.
# Only the Korean Law MCP integration survives (command-palette law search).
if System.get_env("LAW_OC") not in [nil, ""] do
  config :ecrits, :law_mcp,
    oc: System.fetch_env!("LAW_OC"),
    server_url: "https://korean-law-mcp.fly.dev/mcp",
    server_label: "korean-law"
end

# Stash the current Mix env so Ecrits.Application can branch on it
# (the `/dev/theme` LiveView route gate reads this).
config :ecrits, :env, config_env()

# ---------------------------------------------------------------------------
# Local ecrits SQLite store
# ---------------------------------------------------------------------------
if config_env() != :test do
  ecrits_home = System.get_env("ECRITS_HOME", "~/.ecrits")
  ecrits_database = System.get_env("ECRITS_DB_PATH", Path.join(ecrits_home, "ecrits.sqlite3"))

  config :ecrits, Ecrits.Repo,
    database: ecrits_database,
    pool_size: 1,
    busy_timeout: 5_000
end

# ---------------------------------------------------------------------------
# Production-only: endpoint URL + secret_key_base
# ---------------------------------------------------------------------------
if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :ecrits, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Note: `:url` is wired above (from APP_BASE_URL) for all non-test envs.
  config :ecrits, EcritsWeb.Endpoint,
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
