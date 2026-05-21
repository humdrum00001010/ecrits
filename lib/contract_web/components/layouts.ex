defmodule ContractWeb.Layouts do
  @moduledoc """
  Layouts and shared chrome for Contract Studio's web surface.

  The `app/1` component is the standard "navbar + main + flash" frame used
  by every dead view (landing) and most LiveViews (auth, storage). It
  reads `@current_scope` and switches the right-side nav between
  signed-out (Log in / Get started) and signed-in (Storage / Settings /
  Log out) states.

  The Studio LiveView (Wave 3C1) is expected to render its own chrome and
  bypass `app/1` — see SPEC.md §10.
  """
  use ContractWeb, :html

  alias ContractWeb.Brand
  alias ContractWeb.Components.Breadcrumbs
  alias ContractWeb.Components.CommandPalette

  # Embed all files in layouts/* within this module.
  embed_templates "layouts/*"

  @doc """
  Renders the standard app layout: top navbar, flash, and a main slot.

  Accepts an optional `variant`:

    * `"default"` (default) — full-width main, used by the landing page
      and storage.
    * `"narrow"` — centered max-w container, used by auth pages and other
      single-column forms.
    * `"split"` — no main container; the caller renders its own
      two-column auth surface and gets only the chrome.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current Contract.Context — pass through from the LiveView/conn"

  attr :variant, :string, default: "default", values: ~w(default narrow split)
  attr :page_title, :string, default: nil
  attr :current_document_id, :any, default: nil

  attr :chrome, :string,
    default: "app",
    values: ~w(app landing),
    doc:
      "Navbar style: `app` (default, used by every LiveView — brand mark + 보관함 link + user_menu) or `landing` (marketing CTAs — only used by `/`)."

  attr :breadcrumbs, :list,
    default: [],
    doc: "optional navigation trail rendered between the navbar and main content"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="drawer">
      <input id="mobile-nav-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col min-h-screen pt-[60px]">
        <.top_nav current_scope={@current_scope} chrome={@chrome} />

        <Breadcrumbs.breadcrumbs :if={@current_scope} trail={@breadcrumbs || []} />

        <main class={main_class(@variant)}>
          <div class={inner_class(@variant)}>
            {render_slot(@inner_block)}
          </div>
        </main>

        <.site_footer :if={@variant != "split"} />
      </div>

      <div class="drawer-side z-40">
        <label
          for="mobile-nav-drawer"
          aria-label={dgettext("layouts", "Close menu")}
          class="drawer-overlay"
        >
        </label>
        <.mobile_nav current_scope={@current_scope} />
      </div>
    </div>

    <CommandPalette.mount_if_live
      current_scope={@current_scope}
      current_document_id={@current_document_id}
    />

    <.flash_group flash={@flash} />
    """
  end

  defp main_class("default"), do: "px-4 sm:px-6 lg:px-8"
  defp main_class("narrow"), do: "px-4 py-12 sm:px-6 lg:px-8"
  defp main_class("split"), do: ""

  defp inner_class("default"), do: "mx-auto max-w-7xl"
  defp inner_class("narrow"), do: "mx-auto w-full max-w-md"
  defp inner_class("split"), do: ""

  attr :current_scope, :map, default: nil
  attr :chrome, :string, default: "app", values: ~w(app landing)

  @doc """
  Top navigation. The navbar intentionally keeps the same structure on
  every page; auth state only swaps the right-side account actions.
  """
  def top_nav(assigns) do
    ~H"""
    <header class="navbar fixed top-0 left-0 right-0 z-40 h-14 min-h-[60px] flex-nowrap border-b border-base-300 bg-base-200/90 supports-[backdrop-filter]:backdrop-blur-md px-7 max-md:px-4">
      <div class="navbar-start gap-6 min-w-0">
        <.link
          navigate={if signed_in?(@current_scope), do: ~p"/storage", else: ~p"/"}
          class="link link-hover inline-flex items-center gap-2 min-w-0 text-base-content text-sm font-semibold leading-none"
          aria-label="계약기계"
        >
          <img
            src={~p"/assets/icons/brand-mark.svg"}
            alt=""
            class="block w-[22px] h-[22px] flex-none dark:invert dark:brightness-110"
          />
          <span class="inline-block leading-none">계약기계</span>
        </.link>

        <ul
          :if={signed_in?(@current_scope)}
          class="menu menu-horizontal p-0 text-[13px]"
          aria-label="계약기계"
        >
          <li>
            <.link navigate={~p"/storage"} class="font-semibold">
              보관함
            </.link>
          </li>
        </ul>
      </div>

      <div class="navbar-end gap-3">
        <.theme_toggle />
        <.user_menu :if={signed_in?(@current_scope)} current_scope={@current_scope} />

        <div :if={!signed_in?(@current_scope)} class="inline-flex items-center gap-2">
          <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm h-9 min-h-9">
            {dgettext("layouts", "Log in")}
          </.link>
          <.link navigate={~p"/users/register"} class="btn btn-primary btn-sm h-9 min-h-9">
            {dgettext("layouts", "Register")}
          </.link>
        </div>
      </div>
    </header>
    """
  end

  attr :current_scope, :map,
    required: true,
    doc: "must contain `:user` with `:email`"

  @doc """
  Authenticated user-profile affordance for the topbar. Renders an
  avatar-style `<details>` dropdown (no JS) with the user's email + a
  Settings link + a Log out action.
  """
  def user_menu(assigns) do
    email = assigns.current_scope.user.email
    assigns = assign(assigns, :email, email)
    assigns = assign(assigns, :initial, email |> String.first() |> String.upcase())

    ~H"""
    <details class="relative" data-role="user-menu">
      <summary
        class="list-none inline-flex items-center justify-center h-9 w-9 rounded-full bg-base-200 text-base-content/80 hover:bg-base-300 hover:text-base-content cursor-pointer font-semibold text-sm font-sans select-none"
        aria-label={dgettext("layouts", "Account menu for %{email}", email: @email)}
        title={@email}
      >
        <span aria-hidden="true">{@initial}</span>
      </summary>

      <div
        class="absolute right-0 mt-2 w-56 rounded-box border border-base-200 bg-base-100 shadow-lg z-40 p-2 text-sm"
        role="menu"
      >
        <p class="px-3 py-2 text-xs text-base-content/60">
          {dgettext("layouts", "Signed in as")}
        </p>
        <p class="px-3 pb-2 text-sm text-base-content/80 truncate" title={@email}>
          {@email}
        </p>

        <div class="border-t border-base-200 my-1" />

        <.link
          navigate={~p"/users/settings"}
          role="menuitem"
          class="block px-3 py-2 rounded-box hover:bg-base-200"
        >
          {dgettext("layouts", "Settings")}
        </.link>
        <.link
          href={~p"/users/log-out"}
          method="delete"
          role="menuitem"
          class="block px-3 py-2 rounded-box hover:bg-base-200 text-base-content/80"
        >
          {dgettext("layouts", "Log out")}
        </.link>
      </div>
    </details>
    """
  end

  attr :current_scope, :map, default: nil

  @doc """
  Mobile drawer-side nav. Renders the same link set as the top nav, in
  a vertical menu visible only when the user toggles the hamburger on
  `< lg` viewports.
  """
  def mobile_nav(assigns) do
    ~H"""
    <aside
      id="mobile-nav"
      class="min-h-full w-72 bg-base-100 border-r border-base-200 p-6 space-y-6 flex flex-col"
    >
      <div class="flex items-center justify-between">
        <Brand.wordmark size="base" />
        <label
          for="mobile-nav-drawer"
          class="btn btn-ghost btn-sm btn-square"
          aria-label={dgettext("layouts", "Close menu")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </label>
      </div>

      <%= if signed_in?(@current_scope) do %>
        <p class="text-xs uppercase tracking-wide text-base-content/50">
          {dgettext("layouts", "Account")}
        </p>
        <p class="text-sm text-base-content/80 truncate">{@current_scope.user.email}</p>

        <nav class="flex flex-col gap-1 text-sm">
          <.link navigate={~p"/storage"} class="px-3 py-2 rounded-box hover:bg-base-200">
            {dgettext("layouts", "Storage")}
          </.link>
          <.link navigate={~p"/studio"} class="px-3 py-2 rounded-box hover:bg-base-200">
            {dgettext("layouts", "Studio")}
          </.link>
          <.link navigate={~p"/users/settings"} class="px-3 py-2 rounded-box hover:bg-base-200">
            {dgettext("layouts", "Settings")}
          </.link>
        </nav>

        <div class="mt-auto pt-4 border-t border-base-200">
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="btn btn-ghost btn-sm w-full justify-start"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> {dgettext(
              "layouts",
              "Log out"
            )}
          </.link>
        </div>
      <% else %>
        <nav class="flex flex-col gap-1 text-sm">
          <a href="/#docs" class="px-3 py-2 rounded-box hover:bg-base-200">
            {dgettext("layouts", "Docs")}
          </a>
          <a href="/#changelog" class="px-3 py-2 rounded-box hover:bg-base-200">
            {dgettext("layouts", "Changelog")}
          </a>
        </nav>

        <div class="mt-auto pt-4 border-t border-base-200 flex flex-col gap-2">
          <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm w-full">
            {dgettext("layouts", "Log in")}
          </.link>
          <.link navigate={~p"/users/register"} class="btn btn-primary btn-sm w-full">
            {dgettext("layouts", "Register")}
          </.link>
        </div>
      <% end %>
    </aside>
    """
  end

  @doc """
  Site-wide footer with the same contact treatment as the landing page.
  """
  def site_footer(assigns) do
    ~H"""
    <footer class="border-t border-base-200 mt-24">
      <div class="mx-auto flex max-w-7xl flex-col gap-4 px-4 py-6 text-xs text-base-content/55 sm:flex-row sm:items-start sm:justify-between sm:px-6 lg:px-8">
        <p>Contract Studio · 비공개 베타 · 2026</p>

        <div class="space-y-1" aria-label="문의">
          <p class="font-semibold text-base-content/70">문의</p>
          <ul class="space-y-1">
            <li>
              <a href="mailto:ereignis@korea.ac.kr" class="hover:text-base-content">
                ereignis@korea.ac.kr
              </a>
            </li>
          </ul>
        </div>
      </div>
    </footer>
    """
  end

  defp signed_in?(%{user: %{}}), do: true
  defp signed_in?(_), do: false

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite" phx-hook=".SessionStaleToggle">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={dgettext("layouts", "We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {dgettext("layouts", "Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={dgettext("layouts", "Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {dgettext("layouts", "Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <%!-- Same look as #client-error / #server-error above, but driven
           by server-side push_event ("session-stale" / "session-recovered")
           from Studio's `:session_stale` handler (lease/Session lifecycle —
           NOT a WebSocket drop, which is what the two above cover). --%>
      <.flash
        id="session-stale"
        kind={:error}
        title={dgettext("layouts", "Reconnecting document session")}
        hidden
      >
        {dgettext("layouts", "Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".SessionStaleToggle">
        export default {
          mounted() {
            const el = () => document.getElementById("session-stale")
            this.onStale = () => {
              const n = el(); if (!n) return
              n.removeAttribute("hidden")
              n.classList.remove("hidden")
            }
            this.onRecovered = () => {
              const n = el(); if (!n) return
              n.setAttribute("hidden", "")
            }
            window.addEventListener("phx:session-stale", this.onStale)
            window.addEventListener("phx:session-recovered", this.onRecovered)
          },
          destroyed() {
            if (this.onStale) window.removeEventListener("phx:session-stale", this.onStale)
            if (this.onRecovered) window.removeEventListener("phx:session-recovered", this.onRecovered)
          }
        }
      </script>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="relative inline-flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full h-9">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=studio]_&]:left-1/3 [[data-theme=studio-dark]_&]:left-2/3 transition-[left]" />

      <button
        class="inline-flex items-center justify-center px-2 h-full cursor-pointer w-1/3 relative"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label={dgettext("layouts", "System theme")}
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="inline-flex items-center justify-center px-2 h-full cursor-pointer w-1/3 relative"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="studio"
        aria-label={dgettext("layouts", "Light theme")}
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="inline-flex items-center justify-center px-2 h-full cursor-pointer w-1/3 relative"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="studio-dark"
        aria-label={dgettext("layouts", "Dark theme")}
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
