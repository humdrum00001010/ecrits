defmodule Ecrits.MixProject do
  use Mix.Project

  def project do
    [
      app: :ecrits,
      version: "0.1.0",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Ecrits.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:tidewave, "~> 0.5", only: [:dev]},
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.7"},
      {:ecto, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.23.0"},
      {:phoenix_html, "~> 4.1"},
      {:mdex, "~> 0.12"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:gen_smtp, "~> 1.2"},
      {:finch, "~> 0.18"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:file_system, "~> 1.0"},
      {:bandit, "~> 1.5"},
      # Fork of ex_mcp (upstream hex 0.10.0). The ACP Codex/Claude adapters forward
      # `mcpServers` into the agent launch config (codex app-server `-c mcp_servers.*`
      # + `features.rmcp_client`) and handle codex 0.137 server->client elicitation/
      # approval requests — none of which the published package does. `override: true`
      # because orchex pulls ex_mcp ~> 0.10.0.
      {:ex_mcp, git: "https://github.com/humdrum00001010/ex_mcp", branch: "main", override: true},
      # Headless HWP/HWPX NIF runtime backing `Ecrits.Doc.Rhwp` (the server arm of
      # the doc-editing MCP). Provides the `Ehwp` facade used by the `doc.*` tools.
      {:ehwp, git: "git@code.cloudxyz.org:IlYoung/ehwp.git", branch: "main"},
      # Headless docx/pptx NIF runtime backing `Ecrits.Doc.Office` (the server arm
      # for Office docs). Pure-UNO LibreOfficeKit bridge: the `uno_*` NIFs answer
      # the SAME `doc.*` surface as HWP. The UNO arm only BUILDS when the LOK
      # install/SDK env knobs are set (see config/dev.exs + DEV_SETUP below);
      # without them the NIFs return {:error, :uno_unavailable} and Office docs are
      # simply unsupported, so a checkout without a local LibreOffice build still
      # compiles.
      {:libreofficex, git: "git@code.cloudxyz.org:IlYoung/libreofficex.git", branch: "main"},
      {:orchex, git: "git@code.cloudxyz.org:IlYoung/Orchex.git", branch: "main"},
      # Markdown + TeX/TikZ composite renderer backing the .md document preview
      # (`EcritsWeb.Markdown.to_preview_html/1`). `Observex.render_body/1` emits
      # <tex-island> markup; the browser runtime installed by `mix assets.observex`
      # (served at /observex/) renders the islands with MathJax/TikZJax client-side.
      {:observex, git: "git@code.cloudxyz.org:IlYoung/observex.git", branch: "main"},
      # ecrits extra deps.
      {:openai_ex, "~> 0.9"},
      {:dotenvy, "~> 1.0"},
      {:toml, "~> 0.7"},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:bypass, "~> 2.1", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:wallaby, "~> 0.30", only: :test, runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": [
        "tailwind.install --if-missing",
        "esbuild.install --if-missing",
        "cmd npm ci --prefix assets",
        "assets.observex"
      ],
      # The rhwp_core WASM binary (`assets/vendor/rhwp/rhwp_bg.wasm`) is a vendored
      # build artifact (produced by `wasm-pack build --target web --out-dir
      # assets/vendor/rhwp <rhwp_core checkout>`). esbuild bundles the ES-module
      # glue (`rhwp.js`) into app.js, but the `.wasm` itself must be served as a
      # static file, so copy it under `priv/static/assets/rhwp/` where Plug.Static
      # (only: ~w(assets ...)) serves it at `/assets/rhwp/rhwp_bg.wasm`.
      # Sourced from the `ehwp` dep (delivered by `mix deps.get` + git-lfs), NOT a
      # manual cp from a local ~/Desktop checkout — so a fresh clone gets the wasm
      # and it is pinned lockstep with the NIF. esbuild bundles `rhwp.js` from
      # assets/vendor/rhwp; `rhwp_bg.wasm` is served static at /assets/rhwp/.
      "assets.rhwp_wasm": [
        ~s(cmd sh -c "mkdir -p assets/vendor/rhwp priv/static/assets/rhwp && cp deps/ehwp/priv/wasm/rhwp.js deps/ehwp/priv/wasm/rhwp.d.ts deps/ehwp/priv/wasm/rhwp_bg.wasm deps/ehwp/priv/wasm/rhwp_bg.wasm.d.ts assets/vendor/rhwp/ && cp deps/ehwp/priv/wasm/rhwp_bg.wasm priv/static/assets/rhwp/rhwp_bg.wasm")
      ],
      # The LibreOffice->WASM client editor (client-interactive arm of the office
      # dual-arch). The Emscripten build artifacts live under
      # `assets/vendor/office/` (gitignored, ~210MB, built from the LibreOffice
      # `core` checkout). Unlike rhwp's wasm-bindgen ES module, this is an
      # auto-running Emscripten module: the JS glue (`soffice.js`) is loaded as a
      # <script> tag at runtime (not bundled by esbuild) and fetches `soffice.wasm`
      # + `soffice.data` via `Module.locateFile`. All three are served statically
      # under `/assets/office/` (Plug.Static `only: ~w(assets ...)`). The copy is
      # best-effort (the shell loop skips missing files) so a checkout without the
      # (large, local-only) office artifacts still builds.
      # Sourced from the `libreofficex` dep (mix deps.get + git-lfs), NOT assets/vendor.
      "assets.office_wasm": [
        ~s(cmd sh -c "mkdir -p priv/static/assets/office && for f in soffice.js soffice.wasm soffice.data soffice.data.js.metadata; do src=deps/libreofficex/priv/wasm/$f; dst=priv/static/assets/office/$f; rm -f $dst $dst.br; if [ -f $src ]; then cp $src $dst; command -v brotli >/dev/null 2>&1 && brotli -f -q 11 $dst || true; fi; done")
      ],
      "assets.build": [
        "compile",
        "assets.rhwp_wasm",
        "assets.office_wasm",
        "tailwind ecrits",
        "esbuild ecrits"
      ],
      "assets.deploy": [
        "assets.rhwp_wasm",
        "assets.office_wasm",
        "tailwind ecrits --minify",
        "esbuild ecrits --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test test"],
      "test.pure": ["test --no-start"]
    ]
  end
end
