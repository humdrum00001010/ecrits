defmodule ContractWeb.Dev.ThemePreviewLive do
  @moduledoc """
  `/dev/theme` — colour + typography swatch for the DaisyUI `studio` theme.

  Mounted under a `:dev_only` route gate (see `ContractWeb.Router`) so it
  is unreachable in `:prod`. Lets the Web subagent sanity-check
  tokens before wiring full screens.
  """

  use ContractWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Studio theme preview")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-100 text-base-content p-6 font-sans">
      <header class="flex items-center justify-between mb-6">
        <div>
          <h1 class="text-2xl font-semibold">계약기계 — theme preview</h1>
          <p class="text-sm opacity-70">
            DaisyUI <code>studio</code> / <code>studio-dark</code> tokens
          </p>
        </div>
        <ContractWeb.Layouts.theme_toggle />
      </header>

      <section class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-3 mb-8">
        <.swatch name="primary" />
        <.swatch name="secondary" />
        <.swatch name="accent" />
        <.swatch name="neutral" />
        <.swatch name="success" />
        <.swatch name="warning" />
      </section>

      <section class="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <h2 class="card-title">Base surfaces</h2>
            <div class="space-y-2">
              <div class="p-3 rounded bg-base-100 border border-base-300">base-100</div>
              <div class="p-3 rounded bg-base-200 border border-base-300">base-200</div>
              <div class="p-3 rounded bg-base-300 border border-base-300">base-300</div>
            </div>
          </div>
        </div>

        <div class="card bg-base-200 border border-base-300">
          <div class="card-body">
            <h2 class="card-title">Status colours</h2>
            <div class="flex flex-col gap-2">
              <div class="alert alert-info">Info — Upstage import queued.</div>
              <div class="alert alert-success">Success — clause inserted.</div>
              <div class="alert alert-warning">Warning — citation unverified.</div>
              <div class="alert alert-error">Error — Korean Law MCP unreachable.</div>
            </div>
          </div>
        </div>
      </section>

      <section class="card bg-base-100 border border-base-300 mb-8">
        <div class="card-body">
          <h2 class="card-title">Typography</h2>
          <p class="font-sans text-base">
            <strong>Inter (chrome):</strong> The quick brown fox jumps over the lazy dog. 0123456789.
          </p>
          <p class="font-mono text-[15px] leading-[1.65] mt-4">
            <strong>Iosevka (contract-body):</strong>
            제1조 (목적) 본 계약은 갑과 을 간의 권리·의무를 명확히 함을 목적으로 한다. — The
            quick brown fox jumps over the lazy dog. 0123456789.
          </p>
        </div>
      </section>

      <section class="card bg-base-100 border border-base-300">
        <div class="card-body">
          <h2 class="card-title">Buttons</h2>
          <div class="flex flex-wrap gap-2">
            <button class="btn btn-primary">Primary</button>
            <button class="btn btn-secondary">Secondary</button>
            <button class="btn btn-accent">Accent</button>
            <button class="btn btn-neutral">Neutral</button>
            <button class="btn btn-ghost">Ghost</button>
            <button class="btn btn-outline">Outline</button>
            <button class="btn btn-error">Error</button>
          </div>
        </div>
      </section>
    </div>
    """
  end

  attr :name, :string, required: true

  defp swatch(assigns) do
    ~H"""
    <div class={"rounded-box p-4 bg-#{@name} text-#{@name}-content border border-base-300"}>
      <div class="text-xs uppercase tracking-wide opacity-80">{@name}</div>
      <div class="text-lg font-semibold">Aa Bb 가나</div>
    </div>
    """
  end
end
