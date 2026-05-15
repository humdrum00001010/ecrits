defmodule ContractWeb.Layouts do
  @moduledoc """
  Layouts and shared chrome for Contract Studio's web surface.

  The `app/1` component is the standard "navbar + main + flash" frame used
  by every dead view (landing) and most LiveViews (auth, dashboard). It
  reads `@current_scope` and switches the right-side nav between
  signed-out (Log in / Get started) and signed-in (Dashboard / Settings /
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
      and dashboard.
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

  attr :breadcrumbs, :list,
    default: [],
    doc: "optional navigation trail rendered between the navbar and main content"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="drawer">
      <input id="mobile-nav-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col min-h-screen">
        <.top_nav current_scope={@current_scope} />

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
          aria-label={gettext("Close menu")}
          class="drawer-overlay"
        >
        </label>
        <.mobile_nav current_scope={@current_scope} />
      </div>
    </div>

    <CommandPalette.mount_if_live current_scope={@current_scope} />

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

  @doc """
  Top navigation. Renders a public set of links + Log in / Get started
  when anonymous; switches to a Dashboard / persona / Settings / Log out
  cluster once `@current_scope.user` is present.
  """
  def top_nav(assigns) do
    ~H"""
    <header class="border-b border-base-200 bg-base-100/85 backdrop-blur sticky top-0 z-30">
      <div class="mx-auto max-w-7xl flex items-center gap-3 sm:gap-6 px-4 sm:px-6 lg:px-8 h-14">
        <label
          for="mobile-nav-drawer"
          class="btn btn-ghost btn-sm btn-square lg:hidden"
          aria-label="Open menu"
          aria-controls="mobile-nav-drawer"
        >
          <.icon name="hero-bars-3" class="size-5" />
        </label>

        <.link
          navigate={~p"/"}
          class="flex items-center gap-2 shrink-0"
          aria-label="Contract Studio home"
        >
          <Brand.wordmark size="base" />
        </.link>

        <nav
          :if={!signed_in?(@current_scope)}
          class="hidden lg:flex items-center gap-6 text-sm text-base-content/70"
        >
          <a href="#docs" class="hover:text-base-content">Docs</a>
          <a href="#changelog" class="hover:text-base-content">Changelog</a>
        </nav>

        <nav
          :if={signed_in?(@current_scope)}
          class="hidden lg:flex items-center gap-6 text-sm text-base-content/70"
        >
          <.link navigate={~p"/dashboard"} class="hover:text-base-content">Dashboard</.link>
          <.link navigate={~p"/studio"} class="hover:text-base-content">Studio</.link>
        </nav>

        <div class="flex-1" />

        <div class="flex items-center gap-2">
          <.theme_toggle />

          <%= if signed_in?(@current_scope) do %>
            <div class="dropdown dropdown-end">
              <div tabindex="0" role="button" class="btn btn-ghost btn-sm gap-2">
                <Brand.mark size="sm" />
                <span class="hidden sm:inline text-sm text-base-content/80">
                  {persona_label(@current_scope)}
                </span>
                <.icon name="hero-chevron-down-micro" class="size-3 opacity-60" />
              </div>
              <ul
                tabindex="0"
                class="dropdown-content menu menu-sm bg-base-100 rounded-box border border-base-200 shadow-sm mt-2 w-56 p-2"
              >
                <li class="px-2 py-1.5 text-xs text-base-content/60">
                  Signed in as
                  <div class="text-base-content/90 truncate">{@current_scope.user.email}</div>
                </li>
                <li><.link navigate={~p"/dashboard"}>Dashboard</.link></li>
                <li><.link navigate={~p"/users/settings"}>Settings</.link></li>
                <div class="divider my-1" />
                <li><.link href={~p"/users/log-out"} method="delete">Log out</.link></li>
              </ul>
            </div>
          <% else %>
            <.link navigate={~p"/users/log-in"} class="hidden sm:inline-flex btn btn-ghost btn-sm">
              Log in
            </.link>
            <.link navigate={~p"/users/register"} class="btn btn-primary btn-sm">
              Register
            </.link>
          <% end %>
        </div>
      </div>
    </header>
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
          aria-label="Close menu"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </label>
      </div>

      <%= if signed_in?(@current_scope) do %>
        <p class="text-xs uppercase tracking-wide text-base-content/50">Account</p>
        <p class="text-sm text-base-content/80 truncate">{@current_scope.user.email}</p>

        <nav class="flex flex-col gap-1 text-sm">
          <.link navigate={~p"/dashboard"} class="px-3 py-2 rounded-box hover:bg-base-200">
            Dashboard
          </.link>
          <.link navigate={~p"/studio"} class="px-3 py-2 rounded-box hover:bg-base-200">
            Studio
          </.link>
          <.link navigate={~p"/users/settings"} class="px-3 py-2 rounded-box hover:bg-base-200">
            Settings
          </.link>
        </nav>

        <div class="mt-auto pt-4 border-t border-base-200">
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="btn btn-ghost btn-sm w-full justify-start"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> Log out
          </.link>
        </div>
      <% else %>
        <nav class="flex flex-col gap-1 text-sm">
          <a href="/#docs" class="px-3 py-2 rounded-box hover:bg-base-200">Docs</a>
          <a href="/#changelog" class="px-3 py-2 rounded-box hover:bg-base-200">Changelog</a>
        </nav>

        <div class="mt-auto pt-4 border-t border-base-200 flex flex-col gap-2">
          <.link navigate={~p"/users/log-in"} class="btn btn-ghost btn-sm w-full">
            Log in
          </.link>
          <.link navigate={~p"/users/register"} class="btn btn-primary btn-sm w-full">
            Register
          </.link>
        </div>
      <% end %>
    </aside>
    """
  end

  @doc """
  Site-wide footer. Anchors the page on long landing scrolls and gives
  legal/security/status links a permanent home. Language switcher is a
  placeholder — wiring is Wave 3C2's job.
  """
  def site_footer(assigns) do
    ~H"""
    <footer class="border-t border-base-200 mt-24 bg-base-100">
      <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-10 grid gap-8 md:grid-cols-4 text-sm">
        <div class="space-y-3">
          <Brand.wordmark size="base" />
          <p class="text-base-content/60 leading-relaxed">
            A legal-document studio for Korean lawyers. Built to be precise, auditable, and quiet.
          </p>
        </div>
        <div>
          <p class="font-semibold text-base-content/90 mb-3">Product</p>
          <ul class="space-y-2 text-base-content/60">
            <li><a href="#docs" class="hover:text-base-content">Documentation</a></li>
            <li><a href="#changelog" class="hover:text-base-content">Changelog</a></li>
            <li><a href="#security" class="hover:text-base-content">Security</a></li>
          </ul>
        </div>
        <div>
          <p class="font-semibold text-base-content/90 mb-3">Company</p>
          <ul class="space-y-2 text-base-content/60">
            <li><a href="#about" class="hover:text-base-content">About</a></li>
            <li><a href="#contact" class="hover:text-base-content">Contact</a></li>
            <li><a href="#status" class="hover:text-base-content">Status</a></li>
            <li><a href="#security" class="hover:text-base-content">Security &amp; Privacy</a></li>
          </ul>
        </div>
        <div>
          <p class="font-semibold text-base-content/90 mb-3">Language</p>
          <div class="join" role="group" aria-label="Language switcher (placeholder)">
            <button type="button" class="btn btn-sm join-item btn-active" aria-current="true">
              EN
            </button>
            <button type="button" class="btn btn-sm join-item gap-1">
              <Brand.flag class="h-3 w-auto" /> KO
            </button>
          </div>
          <p class="text-xs text-base-content/50 mt-2">
            Korean UI lands with Wave 3C2.
          </p>
        </div>
      </div>
      <div class="border-t border-base-200">
        <div class="mx-auto max-w-7xl px-4 sm:px-6 lg:px-8 py-4 flex flex-col sm:flex-row items-start sm:items-center justify-between gap-2 text-xs text-base-content/50">
          <p>© {DateTime.utc_now().year} Contract Studio. All rights reserved.</p>
          <p>
            <a href="#terms" class="hover:text-base-content">Terms</a>
            <span class="mx-2">·</span>
            <a href="#privacy" class="hover:text-base-content">Privacy</a>
            <span class="mx-2">·</span>
            <a href="#status" class="hover:text-base-content">Status</a>
          </p>
        </div>
      </div>
    </footer>
    """
  end

  defp signed_in?(%{user: %{}}), do: true
  defp signed_in?(_), do: false

  defp persona_label(%{user: %{email: email}}) when is_binary(email) do
    email |> String.split("@") |> List.first()
  end

  defp persona_label(_), do: "Account"

  @doc """
  Shows the flash group with standard titles and content.
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=studio]_&]:left-1/3 [[data-theme=studio-dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="studio"
        aria-label="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="studio-dark"
        aria-label="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
