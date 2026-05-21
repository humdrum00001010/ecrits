# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :contract, :scopes,
  user: [
    default: true,
    module: Contract.Context,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Contract.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

# Load .env (if present) before reading System.get_env in env-specific configs.
# Hand-rolled to avoid bootstrapping deps at config-compile time.
if File.exists?(Path.expand("../.env", __DIR__)) do
  Path.expand("../.env", __DIR__)
  |> File.stream!()
  |> Stream.map(&String.trim/1)
  |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)
        value = value |> String.trim() |> String.trim_leading("\"") |> String.trim_trailing("\"")

        if System.get_env(key) in [nil, ""] do
          System.put_env(key, value)
        end

      _ ->
        :ok
    end
  end)
end

config :contract,
  ecto_repos: [Contract.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Default UI locale. Korean-primary for the public-facing surface
# (landing, storage, auth, settings). Tests override this back to
# "en" in `config/test.exs` so gen.auth's generated LiveViewTests
# continue to match English `msgid` strings (= source-of-truth).
config :contract, :ui_locale, "ko"

# Provider IO + Agent runtime. Each block reads the matching env vars at
# runtime via `Application.fetch_env!/2`; tests override these in `config/test.exs`.
config :contract, :upstage,
  endpoint: "https://api.upstage.ai/v1/document-ai/document-parse",
  api_key: System.get_env("UPSTAGE_API_KEY")

config :contract, :openai,
  api_key: System.get_env("OPENAI_API_KEY"),
  base_url: System.get_env("OPENAI_BASE_URL", "https://api.openai.com/v1")

# NOTE: `default_model` + `reasoning_effort` live in `config/runtime.exs`,
# not here. Putting them in `config.exs` makes the Phoenix dev code
# reloader 500 every HTTP request when they change (you must restart the
# whole VM for compile-time config edits). runtime.exs is re-read on each
# boot, doesn't trip the reloader, and is also where env-var overrides
# (OPENAI_MODEL, OPENAI_REASONING_EFFORT) get wired in.

# Public base URL for our MCP server. OpenAI Responses MCP calls back into
# this URL during a run, so it must be reachable from OpenAI's edge. Local
# tunnel: cloudflared `main` → :4000 (see ~/.cloudflared/main.yml).
config :contract, :mcp,
  public_base_url: System.get_env("MCP_PUBLIC_BASE_URL", "https://contract.cloudxyz.org")

# Per-bearer rate limit for /mcp. Sanity cap, not fairness — see
# `ContractWeb.Plug.RateLimitMCP`. Both knobs are runtime-readable so
# config/runtime.exs or tests can override without recompiling.
config :contract, ContractWeb.Plug.RateLimitMCP,
  limit: 120,
  window_ms: 60_000

config :contract, :law_mcp,
  endpoint: System.get_env("LAW_MCP_URL", "https://korean-law-mcp.fly.dev/mcp"),
  oc: System.get_env("LAW_OC", "openapi")

config :contract, :r2,
  bucket: System.get_env("R2_BUCKET", "contract-studio-prod"),
  account_id: System.get_env("R2_ACCOUNT_ID"),
  access_key_id: System.get_env("R2_ACCESS_KEY_ID"),
  secret_access_key: System.get_env("R2_SECRET_ACCESS_KEY"),
  endpoint: System.get_env("R2_ENDPOINT")

# Driver overrides — tests swap these for mock implementations.
config :contract, :io_drivers,
  http: Contract.IO.HTTP.Req,
  openai: Contract.IO.OpenAI,
  upstage: Contract.IO.Upstage,
  law_mcp: Contract.IO.LawMCP,
  r2: Contract.IO.R2

# Configure the endpoint
config :contract, ContractWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ContractWeb.ErrorHTML, json: ContractWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Contract.PubSub,
  live_view: [signing_salt: "QfT/bbEN"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :contract, Contract.Mailer, adapter: Swoosh.Adapters.Local

# Oban background jobs. Queue capacities are tuned for Contract Studio
# workloads per SPEC.md §6 (Upstage parse, DOCX/PDF export, async OpenAI
# turns, system jobs).
config :contract, Oban,
  repo: Contract.Repo,
  queues: [
    import: 5,
    export: 3,
    agent: 8,
    system: 2,
    mailer: 4
  ],
  plugins: [Oban.Plugins.Pruner, {Oban.Plugins.Cron, crontab: []}]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  contract: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  contract: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Register the SSE MIME type so the `/mcp` pipeline's `:accepts ["json",
# "event-stream"]` filter can negotiate `text/event-stream` requests. See
# SPEC.md §21.
config :mime, :types, %{
  "text/event-stream" => ["event-stream"],
  # DESIGN.md §4 — StorageLive accepts HWP / HWPX uploads. The MIME
  # registry needs these extensions before `allow_upload(accept: ~w(.hwp
  # .hwpx))` can validate them.
  "application/x-hwp" => ["hwp"],
  "application/vnd.hancom.hwpx" => ["hwpx"]
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
