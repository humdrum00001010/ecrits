import Config

# Playwright e2e: enables the `/test/personas/:p/sign_in` + `/test/reset`
# routes (gated by `Application.compile_env(:contract, :test_auth)`).
# Mirrored in `:dev`; explicitly `false` in `:prod`.
config :contract, :test_auth, true

# Tests assert on English msgid (source-of-truth) — override the
# config.exs Korean default so `mix test` matches the literal English
# strings embedded in gen.auth tests + dashboard / settings_hub tests.
config :contract, :ui_locale, "en"

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :contract, Contract.Repo,
  username: System.get_env("DB_USERNAME") || "contract",
  password: System.get_env("DB_PASSWORD") || "contract",
  hostname: System.get_env("DB_HOST") || "localhost",
  port: String.to_integer(System.get_env("DB_PORT") || "5432"),
  database:
    (System.get_env("DB_TEST_NAME") || "#{System.get_env("DB_NAME") || "contract"}_test") <>
      "#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Wallaby drives a real browser against the test endpoint, so the HTTP
# server must be running for `:browser`-tagged feature tests. Plain ConnTest
# / LiveViewTest cases don't need the server but tolerate `server: true`.
config :contract, ContractWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "fdSwy2CndhpkOt1n+miKuBzwIMBkBxzGfg7azoR3klip6hL9cvK0cL69X7pnOQLF",
  server: true

# Wallaby driver + Chromium.
#   * `:path`   — chromedriver executable. Wallaby PATH-resolves this, so
#                 a bare "chromedriver" works as long as it's on $PATH.
#                 Override via CHROMEDRIVER_PATH for pinned binaries.
#   * `:binary` — Chrome / Chromium executable. CHROMEDRIVER does NOT
#                 PATH-resolve `binary` — it passes the literal string to
#                 the underlying chrome process. So this must be an
#                 absolute path. Override via CHROME_BINARY_PATH.
#   * `:headless` — keep `true` for CI / sprite.
config :wallaby,
  driver: Wallaby.Chrome,
  chromedriver: [
    headless: true,
    path: System.get_env("CHROMEDRIVER_PATH") || "chromedriver",
    binary:
      System.get_env("CHROME_BINARY_PATH") ||
        (System.find_executable("chromium") ||
           System.find_executable("chrome") ||
           System.find_executable("google-chrome") ||
           "/usr/local/bin/chromium")
  ],
  otp_app: :contract,
  base_url: "http://localhost:4002"

# Mounts the Phoenix.Ecto.SQL.Sandbox plug under `/sandbox` so the real
# browser session can pin to the same Ecto sandbox owner as the test.
config :contract, :sql_sandbox, true

# In test we don't send emails
config :contract, Contract.Mailer, adapter: Swoosh.Adapters.Test

# Oban: disable queues + plugins; tests opt-in via Oban.Testing helpers.
config :contract, Oban, testing: :manual

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Provider stubs / fake credentials so config-time fetches succeed.
config :contract, :upstage,
  endpoint: "http://localhost:0/v1/document-ai/document-parse",
  api_key: "test-upstage-key"

config :contract, :openai,
  api_key: "test-openai-key",
  base_url: "http://localhost:0/v1",
  default_model: "gpt-5-mini",
  reasoning_effort: "high"

config :contract, :law_mcp,
  endpoint: "http://localhost:0/mcp",
  oc: "openapi"

config :contract, :r2,
  bucket: "test-bucket",
  account_id: "test-account",
  access_key_id: "test-access-key",
  secret_access_key: "test-secret",
  endpoint: "http://localhost:0"

# Mox-based OpenAI driver for the Agent runtime tests.
config :contract, :io_drivers,
  http: Contract.IO.HTTP.Req,
  openai: Contract.IO.OpenAIMock,
  upstage: Contract.IO.Upstage,
  law_mcp: Contract.IO.LawMCP,
  r2: Contract.IO.R2

config :ex_aws,
  access_key_id: "test-access-key",
  secret_access_key: "test-secret",
  region: "auto"

# External HWPX validator — used by `test/contract/export/hwpx_external_validator_test.exs`
# (tag `:external_hwpx`, excluded from the default suite).
#
# `pyhwpxlib` is a third-party Python CLI for parsing/validating HWPX files;
# the validator test shells out via `System.cmd/3` to confirm our writer's
# output is well-formed enough for an external parser to accept. On the
# sprite, install with:
#
#     python3 -m venv ~/.venvs/hwpx && ~/.venvs/hwpx/bin/pip install pyhwpxlib
#
# Override via `HWPX_VALIDATOR_CMD=/path/to/pyhwpxlib`.
config :contract,
       :hwpx_validator,
       System.get_env("HWPX_VALIDATOR_CMD", "/home/sprite/.venvs/hwpx/bin/pyhwpxlib")
