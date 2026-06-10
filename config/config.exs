# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

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

config :ecrits,
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :ecrits, :local_agent, provider: "codex"

# Default UI locale. Korean-primary for the public-facing surface
# (landing, storage, auth, settings). Tests override this back to
# "en" in `config/test.exs` so gen.auth's generated LiveViewTests
# continue to match English `msgid` strings (= source-of-truth).
config :ecrits, :ui_locale, "ko"

# Korean Law MCP — the surviving provider integration (used by the command
# palette law search). Reads env vars at runtime via `Application.fetch_env!/2`.
config :ecrits, :law_mcp,
  endpoint: System.get_env("LAW_MCP_URL", "https://korean-law-mcp.fly.dev/mcp"),
  oc: System.get_env("LAW_OC", "openapi")

# Configure the endpoint
config :ecrits, EcritsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EcritsWeb.ErrorHTML, json: EcritsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ecrits.PubSub,
  live_view: [signing_salt: "QfT/bbEN"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ecrits: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  ecrits: [
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

config :mime, :types, %{
  # DESIGN.md §4 — StorageLive accepts HWP / HWPX uploads. The MIME
  # registry needs these extensions before `allow_upload(accept: ~w(.hwp
  # .hwpx))` can validate them.
  "application/x-hwp" => ["hwp"],
  "application/vnd.hancom.hwpx" => ["hwpx"]
}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
