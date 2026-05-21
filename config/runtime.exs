import Config

# config/runtime.exs is executed for all environments, including during
# releases. It runs after compilation and before the system starts, so
# it's the right place to pull secrets from .env / the process environment.
#
# `config/config.exs` already hydrates System env vars from `.env` via
# Contract.Env semantics, so `System.get_env/1` here works identically
# in dev/test/prod.

# ---------------------------------------------------------------------------
# Endpoint binding
# ---------------------------------------------------------------------------
if System.get_env("PHX_SERVER") do
  config :contract, ContractWeb.Endpoint, server: true
end

# Port override is dev/prod only. The `:test` env pins :4002 in
# `config/test.exs` so Wallaby + the Phoenix.Ecto.SQL.Sandbox plug can
# target a stable endpoint, regardless of whatever SERVER_PORT/PORT
# happens to be set in `.env` for the dev sprite.
if config_env() != :test do
  config :contract, ContractWeb.Endpoint,
    http: [
      port: String.to_integer(System.get_env("SERVER_PORT") || System.get_env("PORT") || "4000")
    ]
end

# Public-facing URL used by `Phoenix.VerifiedRoutes.url/1` (i.e. the absolute
# URLs embedded in gen.auth confirmation / magic-link / update-email emails).
# Without this, `ContractWeb.Endpoint`'s `:url` defaults to `localhost`
# (set in `config/config.exs`), which leaks into outbound emails when the
# app is running behind a per-sprite hostname like
# `https://contract-studio-v7zk.sprites.app`.
#
# Test env is intentionally skipped — gen.auth's generated tests and the
# Wallaby browser tests pin `localhost:4002` explicitly.
if config_env() != :test do
  app_base_url = System.fetch_env!("APP_BASE_URL")
  %URI{scheme: scheme, host: host, port: port} = URI.parse(app_base_url)
  scheme = scheme || "https"
  endpoint_port = port || if(scheme == "https", do: 443, else: 80)

  config :contract, ContractWeb.Endpoint, url: [host: host, port: endpoint_port, scheme: scheme]
end

# ---------------------------------------------------------------------------
# Repo (env-driven, dev + prod alike)
# ---------------------------------------------------------------------------
if config_env() != :test do
  config :contract, Contract.Repo,
    hostname: System.get_env("DB_HOST", "localhost"),
    port: String.to_integer(System.get_env("DB_PORT", "5432")),
    database: System.get_env("DB_NAME", "contract"),
    username: System.get_env("DB_USERNAME", "contract"),
    password: System.get_env("DB_PASSWORD", ""),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
    show_sensitive_data_on_connection_error: config_env() != :prod
end

# ---------------------------------------------------------------------------
# Mailer — Swoosh SMTP, Worksmobile (port 465 implicit TLS), OTP-28 hardened
# ---------------------------------------------------------------------------
# SMTP is `:prod`-only. `:dev` always uses Swoosh.Adapters.Local so that
# `/dev/mailbox` works on a plain `mix phx.server` boot (even with MAIL_HOST
# in .env). `:test` always uses Swoosh.Adapters.Test (set in config/test.exs).
if config_env() == :prod and System.get_env("MAIL_HOST") not in [nil, ""] do
  config :contract, Contract.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: System.fetch_env!("MAIL_HOST"),
    port: String.to_integer(System.fetch_env!("MAIL_PORT")),
    ssl: true,
    tls: :never,
    auth: :always,
    username: System.fetch_env!("MAIL_USERNAME"),
    password: System.fetch_env!("MAIL_PASSWORD"),
    retries: 2,
    no_mx_lookups: true,
    sockopts: [
      versions: [:"tlsv1.2", :"tlsv1.3"],
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      server_name_indication: System.fetch_env!("MAIL_HOST") |> String.to_charlist()
    ]

  config :swoosh, :api_client, Swoosh.ApiClient.Finch
  config :swoosh, local: false
end

if System.get_env("MAIL_FROM_ADDRESS") not in [nil, ""] do
  config :contract,
         :mail_from,
         {System.get_env("MAIL_FROM_NAME", "계약기계"), System.fetch_env!("MAIL_FROM_ADDRESS")}
end

# ---------------------------------------------------------------------------
# Cloudflare R2 (via ex_aws + ex_aws_s3)
# ---------------------------------------------------------------------------
if System.get_env("R2_ACCESS_KEY_ID") not in [nil, ""] do
  config :ex_aws,
    access_key_id: System.fetch_env!("R2_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("R2_SECRET_ACCESS_KEY"),
    region: System.get_env("R2_REGION", "auto"),
    json_codec: Jason

  config :ex_aws, :s3,
    scheme: "https://",
    host: URI.parse(System.fetch_env!("R2_ENDPOINT")).host,
    port: 443,
    region: System.get_env("R2_REGION", "auto")

  config :contract, :r2,
    bucket: System.fetch_env!("R2_BUCKET"),
    endpoint: System.fetch_env!("R2_ENDPOINT"),
    force_path_style: System.get_env("R2_FORCE_PATH_STYLE", "true") == "true"
end

# ---------------------------------------------------------------------------
# OpenAI / Upstage / Korean Law MCP
# ---------------------------------------------------------------------------
# Model + effort are runtime-only so swapping them never trips the dev
# `config.exs` compile reloader. The api_key block stays gated on the env
# var being present (so test/CI without keys still boots cleanly).
config :contract, :openai,
  default_model: System.get_env("OPENAI_MODEL", "gpt-5.5"),
  reasoning_effort: System.get_env("OPENAI_REASONING_EFFORT", "low")

if System.get_env("OPENAI_API_KEY") not in [nil, ""] do
  config :contract, :openai, api_key: System.fetch_env!("OPENAI_API_KEY")
end

if System.get_env("UPSTAGE_API_KEY") not in [nil, ""] do
  config :contract, :upstage,
    api_key: System.fetch_env!("UPSTAGE_API_KEY"),
    endpoint: "https://api.upstage.ai/v1/document-ai/document-parse"
end

if System.get_env("LAW_OC") not in [nil, ""] do
  config :contract, :law_mcp,
    oc: System.fetch_env!("LAW_OC"),
    server_url: "https://korean-law-mcp.fly.dev/mcp",
    server_label: "korean-law"
end

# Stash the current Mix env so Contract.Application can branch on it
# (the `/dev/theme` LiveView route gate reads this).
config :contract, :env, config_env()

# ---------------------------------------------------------------------------
# Production-only: endpoint URL + secret_key_base + DATABASE_URL override
# ---------------------------------------------------------------------------
if config_env() == :prod do
  database_url = System.get_env("DATABASE_URL")

  if database_url do
    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :contract, Contract.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      socket_options: maybe_ipv6
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  config :contract, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Note: `:url` is wired above (from APP_BASE_URL) for all non-test envs.
  config :contract, ContractWeb.Endpoint,
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end

# ---------------------------------------------------------------------------
# Export binaries (Chromium-for-Testing → PDF, pandoc → DOCX)
# ---------------------------------------------------------------------------
# Wired in every environment (including :test) so the format modules can
# resolve a path before falling back to PATH lookup. The format-specific
# tests that actually shell out are tagged `:requires_chromium` /
# `:requires_pandoc` and excluded from the default suite.
config :contract,
  chromium_path: System.get_env("CHROMIUM_PATH", "/usr/local/bin/chromium"),
  pandoc_path: System.get_env("PANDOC_PATH", "/usr/bin/pandoc")
