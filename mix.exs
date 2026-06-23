defmodule Ecrits.MixProject do
  use Mix.Project

  def project do
    [
      app: :ecrits,
      version: "0.1.2",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
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
      # Elixir-over-FUSE library backing the document VFS (Ecrits.Fuse.*). Pure
      # source over https; its `:exfuse_rust` mix compiler cargo-builds the
      # `priv/exfuse_port` locally (needs cargo + macFUSE). See AGENTS.md
      # "exfuse dep" + docs/plans/2026-06-23-exfuse-doc-vfs-migration.md.
      {:exfuse, git: "https://github.com/humdrum00001010/exfuse", branch: "main"},
      # ecrits extra deps.
      {:openai_ex, "~> 0.9"},
      {:dotenvy, "~> 1.0"},
      {:toml, "~> 0.7"},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:bypass, "~> 2.1", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:wallaby, "~> 0.30", only: :test, runtime: false},
      {:burrito,
       github: "burrito-elixir/burrito",
       ref: "8fa7eda03deabb74956f5f16027f540cb2df5385",
       runtime: false}
    ]
  end

  defp releases do
    [
      ecrits: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          debug: false,
          targets: [
            macos_silicon: [os: :darwin, cpu: :aarch64],
            linux_aarch64: [os: :linux, cpu: :aarch64]
          ]
        ]
      ]
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
      # The HWP wasm-bindgen ES module and `rhwp_bg.wasm` are served directly
      # from the canonical `:ehwp` dependency priv/wasm directory. Keep retired
      # copied app-static and vendor scratch output out of releases.
      "assets.rhwp_wasm": [
        ~s(cmd sh -c "set -eu; rm -rf priv/static/assets/rhwp assets/vendor/rhwp")
      ],
      # The LibreOffice->WASM client editor is served directly from the canonical
      # `:libreofficex` priv/wasm directory. Keep retired app-static/vendor
      # scratch output and stale local `.br` siblings out of releases.
      "assets.office_wasm": [
        ~s(cmd sh -c "set -eu; rm -rf priv/static/assets/office assets/vendor/office; env=${MIX_ENV:-dev}; wasm_dir=_build/$env/lib/libreofficex/priv/wasm; if [ ! -d $wasm_dir ]; then echo >&2 missing-wasm-dir:$wasm_dir; exit 1; fi; rm -f $wasm_dir/soffice.js.br $wasm_dir/soffice.wasm.br $wasm_dir/soffice.data.br $wasm_dir/soffice.data.js.metadata.br")
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
