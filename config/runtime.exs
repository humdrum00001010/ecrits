import Config

if config_env() == :prod do
  load_env_file = fn path ->
    if is_binary(path) and File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.each(fn line ->
        line =
          if String.starts_with?(line, "export "),
            do: String.trim_leading(line, "export "),
            else: line

        case String.split(line, "=", parts: 2) do
          [key, value] ->
            key = String.trim(key)

            value =
              value
              |> String.trim()
              |> String.trim_leading("\"")
              |> String.trim_trailing("\"")
              |> String.trim_leading("'")
              |> String.trim_trailing("'")

            if key != "" and System.get_env(key) in [nil, ""] do
              System.put_env(key, value)
            end

          _ ->
            :ok
        end
      end)
    end
  end

  [
    System.get_env("ECRITS_PROD_ENV"),
    System.get_env("__BURRITO_BIN_PATH") &&
      Path.join(Path.dirname(System.fetch_env!("__BURRITO_BIN_PATH")), ".env.prod"),
    System.get_env("RELEASE_ROOT") && Path.join(System.fetch_env!("RELEASE_ROOT"), ".env.prod"),
    Path.expand(".env.prod"),
    Path.expand(".env.prod", __DIR__)
  ]
  |> Enum.reject(&is_nil/1)
  |> Enum.uniq()
  |> Enum.each(load_env_file)
end

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

# ---------------------------------------------------------------------------
# Headless Office (docx/pptx) editing — LibreOfficeKit UNO arm
# ---------------------------------------------------------------------------
# `Ecrits.Doc.Office` (the server arm for docx/pptx, mirroring `Ecrits.Doc.Rhwp`)
# boots LibreOffice in-process via the `libreofficex` UNO NIF. It needs the LOK
# *install dir* — the `…/LibreOffice.app/Contents/Frameworks` directory holding
# `libsofficeapp.dylib`. We surface it WITHOUT hardcoding any developer's home:
#
#   * `LOK_INSTALL_DIR` (env, the SAME knob the NIF's build.rs reads) wins;
#   * else `Ecrits.Doc.Office` discovers it at runtime under
#     `~/Desktop/core/instdir/…` (System.user_home()-relative — see the module).
#
# Set it explicitly only when LibreOffice lives elsewhere. When neither the env
# nor the discovery path exists, Office docs are simply unsupported (open returns
# an error) and the rest of the app is unaffected. The same `~/Desktop/core`
# tree also drives the NIF's UNO-arm BUILD via LOK_INCLUDE_DIR / LOK_CONFIG_HOST /
# LOK_INSTALL_DIR / LOK_SDK_DIR (defaults match `~/Desktop/core`); see DEV_SETUP.
if System.get_env("LOK_INSTALL_DIR") not in [nil, ""] do
  config :ecrits, Ecrits.Doc.Office, install_dir: System.get_env("LOK_INSTALL_DIR")
end

# Stash the current Mix env so Ecrits.Application can branch on it
# (the `/dev/theme` LiveView route gate reads this).
config :ecrits, :env, config_env()

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
