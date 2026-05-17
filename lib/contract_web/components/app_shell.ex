defmodule ContractWeb.Components.AppShell do
  @moduledoc """
  Shared v33 Contract Studio shell — the single global chrome wrapping
  the three product surfaces (`LandingLive`, `DashboardLive`,
  `StudioLive`).

  See `docs/contract-studio-final-v33/SPEC.md` §4. The shell renders
  only:

    * brand mark + "Contract Studio" wordmark on the left, linking to `/`
    * topbar nav with `대시보드` link and `스튜디오` active-state span

  Anything else — dashboard actions (`새 문서`, `계약서 업로드`), theme
  switcher, account menu, breadcrumbs, footer — is intentionally OUT of
  this shell. Dashboard actions live in `DashboardLive`'s content (§6);
  auth and settings surfaces use `Layouts.app` with their own chrome.

  ## Why no `<.link>` for `스튜디오`?

  Studio is a per-document surface (`/studio/:document_id`). There is no
  "open Studio" action without a chosen document, so the nav item is a
  state indicator (`<span>`), not a navigable destination. To enter
  Studio the user opens a document from the dashboard. This is the
  intent of SPEC §0's "core loop" framing.

  ## Usage

      <.app_shell active="대시보드">
        <main class="dashboard-page">...</main>
      </.app_shell>

  Pass `active` matching one of `"대시보드"` / `"스튜디오"` / `"랜딩"`
  to set the active-state class.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ContractWeb.Endpoint,
    router: ContractWeb.Router,
    statics: ContractWeb.static_paths()

  attr :active, :string,
    default: nil,
    doc: "Current v33 surface label: 대시보드, 스튜디오, or 랜딩 (or nil for none)"

  slot :inner_block, required: true

  def app_shell(assigns) do
    ~H"""
    <div class="app-shell">
      <header class="topbar">
        <.link navigate={~p"/"} class="brand" aria-label="Contract Studio">
          <img src={~p"/assets/icons/brand-mark.svg"} alt="" class="brand__icon" />
          <span>Contract Studio</span>
        </.link>

        <nav class="topbar__nav" aria-label="Contract Studio">
          <.link navigate={~p"/dashboard"} class={[@active == "대시보드" && "is-active"]}>
            대시보드
          </.link>

          <span class={[@active == "스튜디오" && "is-active"]}>스튜디오</span>
        </nav>
      </header>

      {render_slot(@inner_block)}
    </div>
    """
  end
end
