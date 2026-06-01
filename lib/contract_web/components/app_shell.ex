defmodule ContractWeb.Components.AppShell do
  @moduledoc """
  Shared v33 계약기계 shell — the single global chrome wrapping the
  product surfaces (`PageController` `:home` / `/`, `StorageLive`,
  `DocumentLive`).

  See `docs/contract-studio-final-v33/SPEC.md` §4. The shell renders:

    * brand mark + "계약기계" wordmark on the left, linking to `/`
    * topbar nav with the `문서들` link → `/storage`
    * a right-side account menu when the caller passes a signed-in
      `current_scope` (delegates to `ContractWeb.Layouts.user_menu/1` so
      the same affordance appears in `Layouts.app/1`-based pages too)

  Storage actions (`새 문서`, `계약서 업로드`) and breadcrumbs are
  intentionally OUT of this shell — they live in the per-surface
  content. The 2026-05-17 owner directive removed the topbar's
  `스튜디오` state span: Studio is reached by opening a document, so a
  topbar state indicator with no destination only added noise.

  ## Usage

      <.app_shell active="문서들" current_scope={@current_scope}>
        <main class="storage-page">...</main>
      </.app_shell>

  Pass `active` matching one of `"문서들"` / `"랜딩"` to set the
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
    doc: "Current v33 surface label: 문서들 or 랜딩 (or nil for none)"

  attr :current_scope, :map,
    default: nil,
    doc:
      "the current Contract.Context — pass through from the LiveView/conn so the topbar can render the account menu when signed in"

  attr :primary_nav_label, :string, default: "문서들"
  attr :primary_nav_path, :string, default: nil

  slot :inner_block, required: true

  def app_shell(assigns) do
    assigns = assign(assigns, :primary_nav_path, assigns.primary_nav_path || ~p"/storage")

    ~H"""
    <div class="min-h-screen pt-[60px] text-base-content bg-base-200">
      <header class="navbar fixed top-0 left-0 right-0 z-40 h-14 min-h-[60px] flex-nowrap border-b border-base-300 bg-base-200/90 supports-[backdrop-filter]:backdrop-blur-md px-7 max-md:px-4">
        <div class="navbar-start gap-6 min-w-0">
          <%!-- Brand mark + wordmark. When signed in, the brand takes
               the user back to their library at /storage rather than the
               marketing landing. --%>
          <.link
            navigate={if brand_link_signed_in?(@current_scope), do: ~p"/storage", else: ~p"/"}
            class="link link-hover inline-flex items-center gap-2 min-w-0 text-base-content text-sm font-semibold leading-none"
            aria-label="계약기계"
          >
            <img
              src={~p"/assets/icons/brand-mark.svg"}
              alt=""
              class="block w-[22px] h-[22px] flex-none dark:invert dark:brightness-110"
            />
            <span class="inline-flex h-[22px] items-center leading-none">계약기계</span>
          </.link>

          <ul class="menu menu-horizontal p-0 text-[13px]" aria-label="계약기계">
            <li>
              <.link
                navigate={@primary_nav_path}
                class={[
                  if(@active == @primary_nav_label,
                    do: "text-base-content font-semibold",
                    else: "text-base-content/55 font-medium"
                  )
                ]}
              >
                {@primary_nav_label}
              </.link>
            </li>
          </ul>
        </div>

        <div class="navbar-end gap-3">
          <Layouts.theme_toggle />
          <Layouts.user_menu :if={@current_scope} current_scope={@current_scope} />
        </div>
      </header>

      {render_slot(@inner_block)}
    </div>
    """
  end

  defp brand_link_signed_in?(%{user: %{}}), do: true
  defp brand_link_signed_in?(_), do: false
end
