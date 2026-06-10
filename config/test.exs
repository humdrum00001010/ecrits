import Config

# Playwright e2e: enables the `/test/personas/:p/sign_in` + `/test/reset`
# routes (gated by `Application.compile_env(:ecrits, :test_auth)`).
# Mirrored in `:dev`; explicitly `false` in `:prod`.
config :ecrits, :test_auth, true

# Tests assert on English msgid (source-of-truth) — override the
# config.exs Korean default so `mix test` matches the literal English
# strings embedded in gen.auth tests + dashboard / settings_hub tests.
config :ecrits, :ui_locale, "en"

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Wallaby drives a real browser against the test endpoint, so the HTTP
# server must be running for `:browser`-tagged feature tests. Plain ConnTest
# / LiveViewTest cases don't need the server but tolerate `server: true`.
config :ecrits, EcritsWeb.Endpoint,
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
  otp_app: :ecrits,
  base_url: "http://localhost:4002"

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

# Korean Law MCP stub endpoint so config-time fetches succeed.
config :ecrits, :law_mcp,
  endpoint: "http://localhost:0/mcp",
  oc: "openapi"

# External HWPX validator — used by `test/ecrits/export/hwpx_external_validator_test.exs`
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
config :ecrits,
       :hwpx_validator,
       System.get_env("HWPX_VALIDATOR_CMD", "/home/sprite/.venvs/hwpx/bin/pyhwpxlib")
