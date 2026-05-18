defmodule ContractWeb.Components.AppShell do
  @moduledoc """
  Shared v33 계약기계 shell — the single global chrome wrapping the
  product surfaces (`PageController` `:home` / `/`, `StorageLive`,
  `StudioLive`).

  See `docs/contract-studio-final-v33/SPEC.md` §4. The shell renders:

    * brand mark + "계약기계" wordmark on the left, linking to `/`
    * topbar nav with the `보관함` link → `/storage`
    * a right-side account menu when the caller passes a signed-in
      `current_scope` (delegates to `ContractWeb.Layouts.user_menu/1` so
      the same affordance appears in `Layouts.app/1`-based pages too)

  Storage actions (`새 문서`, `계약서 업로드`) and breadcrumbs are
  intentionally OUT of this shell — they live in the per-surface
  content. The 2026-05-17 owner directive removed the topbar's
  `스튜디오` state span: Studio is reached by opening a document, so a
  topbar state indicator with no destination only added noise.

  ## Usage

      <.app_shell active="보관함" current_scope={@current_scope}>
        <main class="storage-page">...</main>
      </.app_shell>

  Pass `active` matching one of `"보관함"` / `"랜딩"` to set the
  active-state class. `current_scope` is optional; when nil (anonymous,
  e.g. the landing page before sign-in) the account menu is omitted and
  no error is raised.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ContractWeb.Endpoint,
    router: ContractWeb.Router,
    statics: ContractWeb.static_paths()

  alias ContractWeb.Layouts

  attr :active, :string,
    default: nil,
    doc: "Current v33 surface label: 보관함 or 랜딩 (or nil for none)"

  attr :current_scope, :map,
    default: nil,
    doc:
      "the current Contract.Context — pass through from the LiveView/conn so the topbar can render the account menu when signed in"

  slot :inner_block, required: true

  def app_shell(assigns) do
    ~H"""
    <div class="app-shell">
      <header class="topbar">
        <.link navigate={~p"/"} class="brand" aria-label="계약기계">
          <img src={~p"/assets/icons/brand-mark.svg"} alt="" class="brand__icon" />
          <span>계약기계</span>
        </.link>

        <div class="inline-flex items-center gap-3">
          <nav class="topbar__nav" aria-label="계약기계">
            <.link navigate={~p"/storage"} class={[@active == "보관함" && "is-active"]}>
              보관함
            </.link>
          </nav>

          <Layouts.user_menu :if={@current_scope} current_scope={@current_scope} />
        </div>
      </header>

      {render_slot(@inner_block)}
    </div>
    """
  end
end
