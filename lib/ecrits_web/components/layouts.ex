defmodule EcritsWeb.Layouts do
  @moduledoc """
  Layouts and shared chrome for Ecrits's web surface.

  The `app/1` component is the standard local-first frame used by the
  workspace mount and editor surfaces.
  """
  use EcritsWeb, :html

  alias EcritsWeb.Brand
  alias EcritsWeb.Components.Breadcrumbs
  alias EcritsWeb.Components.CommandPalette

  def static_asset_version(path) when is_binary(path) do
    app = :ecrits
    static_path = Path.join("priv/static", String.trim_leading(path, "/"))

    app
    |> Application.app_dir(static_path)
    |> File.stat(time: :posix)
    |> case do
      {:ok, %{mtime: mtime, size: size}} -> "#{mtime}-#{size}"
      _ -> app |> Application.spec(:vsn) |> to_string()
    end
  end

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
    doc: "the current Ecrits.Context — pass through from the LiveView/conn"

  attr :variant, :string, default: "default", values: ~w(default narrow split)
  attr :page_title, :string, default: nil
  attr :current_document_id, :any, default: nil
  attr :show_footer, :boolean, default: true

  attr :chrome, :string,
    default: "app",
    values: ~w(app landing),
    doc: "Navbar style: `app` (default local chrome) or `landing`."

  attr :breadcrumbs, :list,
    default: [],
    doc: "optional navigation trail rendered between the navbar and main content"

  slot :inner_block, required: true

  attr :fuse_mode, :any,
    default: nil,
    doc: "workspace doc-VFS state: nil hides the FUSE toggle; true/false shows it"

  def app(assigns) do
    ~H"""
    <div class="drawer">
      <%!-- Presentational drawer state toggle: operated only by the labelled
            open/close controls (for="mobile-nav-drawer"), never directly, so it
            is hidden from the a11y tree (no orphan unlabelled form control, and
            it stops being page content outside a landmark). --%>
      <input
        id="mobile-nav-drawer"
        type="checkbox"
        class="drawer-toggle"
        aria-hidden="true"
        tabindex="-1"
      />

      <div class="drawer-content flex flex-col min-h-screen pt-[60px]">
        <.top_nav current_scope={@current_scope} chrome={@chrome} fuse_mode={@fuse_mode} />

        <Breadcrumbs.breadcrumbs :if={@current_scope} trail={@breadcrumbs || []} />

        <main class={main_class(@variant)}>
          <div class={inner_class(@variant)}>
            {render_slot(@inner_block)}
          </div>
        </main>

        <.site_footer :if={@show_footer && @variant != "split"} />
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
  attr :fuse_mode, :any, default: nil

  @doc """
  Top navigation for the local workspace product.
  """
  def top_nav(assigns) do
    ~H"""
    <header class="navbar fixed top-0 left-0 right-0 z-40 h-14 min-h-[60px] flex-nowrap border-b border-base-300 bg-base-100 supports-[backdrop-filter]:backdrop-blur-md px-7 max-md:px-4">
      <div class="navbar-start gap-6 min-w-0">
        <.link
          navigate={~p"/"}
          class="link link-hover inline-flex items-center gap-2 min-w-0 text-sm font-semibold leading-none text-base-content/85 hover:text-base-content"
          aria-label="Ecrits"
        >
          <Brand.mark class="flex-none" />
          <span class="inline-flex h-[22px] items-center leading-none">Ecrits</span>
        </.link>
      </div>

      <div :if={@fuse_mode != nil} class="ml-auto flex items-center">
        <button
          id="fuse-mode-toggle"
          type="button"
          phx-click="toggle_fuse"
          aria-pressed={"#{@fuse_mode == true}"}
          aria-label={
            if(@fuse_mode == true,
              do: "Disable editable text mount (FUSE)",
              else: "Enable editable text mount (FUSE)"
            )
          }
          title="Mount this workspace's documents as editable text files (FUSE)"
          class={[
            "relative inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md border transition-colors duration-150",
            "focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--cs-blue)]",
            @fuse_mode == true &&
              "border-[color-mix(in_oklab,var(--cs-green)_42%,transparent)] bg-[color-mix(in_oklab,var(--cs-green)_12%,transparent)] text-[var(--cs-green)] hover:bg-[color-mix(in_oklab,var(--cs-green)_16%,transparent)]",
            @fuse_mode != true &&
              "border-transparent text-[var(--cs-muted)] hover:border-[color-mix(in_oklab,var(--cs-ink)_15%,transparent)] hover:bg-[color-mix(in_oklab,var(--cs-ink)_6%,transparent)] hover:text-[var(--cs-ink)]"
          ]}
        >
          <.icon name="hero-document-text" class="size-4" />
          <span
            class={[
              "absolute right-1 top-1 size-1.5 rounded-full border border-[var(--cs-bg)]",
              @fuse_mode == true && "bg-[var(--cs-green)]",
              @fuse_mode != true && "bg-[color-mix(in_oklab,var(--cs-ink)_24%,transparent)]"
            ]}
            aria-hidden="true"
          >
          </span>
        </button>
      </div>
    </header>
    """
  end

  attr :current_scope, :map,
    required: true,
    doc: "must contain `:user` with `:email`"

  @doc """
  Authenticated user-profile affordance retained only for compiled legacy
  components during the localize migration.
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

        <span class="block px-3 py-2 text-base-content/60">
          {dgettext("layouts", "Account routes retired")}
        </span>
      </div>
    </details>
    """
  end

  attr :current_scope, :map, default: nil

  @doc """
  Mobile drawer-side nav for local workspace chrome.
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

      <nav class="flex flex-col gap-1 text-sm">
        <.link navigate={~p"/"} class="px-3 py-2 rounded-box hover:bg-base-200">
          Mount workspace
        </.link>
      </nav>
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
        <p>Ecrits · Local workspace · 2026</p>

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
end
