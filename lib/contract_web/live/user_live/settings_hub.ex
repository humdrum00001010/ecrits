defmodule ContractWeb.UserLive.SettingsHub do
  @moduledoc """
  `/settings` index / hub.

  This is the **navigation surface** for all user-level settings. It does
  NOT own the existing account-email + password form (that lives at
  `/users/settings`, owned by gen.auth + restyled by Wave 3C0). Instead,
  this hub renders a left-sidebar of categories and a welcome panel on
  the right, and lets the user navigate to whichever sub-page they need.

  Categories rendered in the sidebar:

    * Account → `/users/settings` (existing)
    * API tokens → `/settings/api-tokens` (Wave 3C0-B)
    * Appearance → `/settings/appearance` (route NOT yet defined; rendered
      as disabled "Coming soon")
    * Workspace → disabled "Coming soon" (Wave 4+)
    * Notifications → disabled "Coming soon" (Wave 4+)

  The same sidebar / chrome is shared by `ContractWeb.UserLive.ApiTokens`
  via the `settings_layout/1` and `settings_sidebar/1` function
  components defined here.
  """
  use ContractWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, dgettext("settings", "Settings"))
      |> assign(:active_item, :hub)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="default">
      <.settings_layout active_item={@active_item}>
        <section id="settings-hub-welcome" class="space-y-6">
          <div class="space-y-1">
            <p class="text-xs font-medium tracking-wide uppercase text-base-content/50">
              {dgettext("settings", "Settings")}
            </p>
            <h1 class="text-2xl font-semibold tracking-tight">
              {dgettext("settings", "Your account")}
            </h1>
            <p class="text-sm text-base-content/60">
              {dgettext("settings", "Signed in as")}
              <span class="text-base-content/90">{@current_scope.user.email}</span>.
              {dgettext("settings", "Pick a category on the left, or jump in below.")}
            </p>
          </div>

          <div id="settings-quick-grid" class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.quick_card
              title={dgettext("settings", "Account")}
              description={dgettext("settings", "Email address, password, and login methods.")}
              icon="hero-user-circle"
              navigate={~p"/users/settings"}
            />
            <.quick_card
              title={dgettext("settings", "API tokens")}
              description={dgettext("settings", "Issue and revoke MCP route_ref tokens.")}
              icon="hero-key"
              navigate={~p"/settings/api-tokens"}
            />
            <.quick_card_disabled
              title={dgettext("settings", "Appearance")}
              description={dgettext("settings", "Theme & density. Coming soon.")}
              icon="hero-paint-brush"
            />
            <.quick_card_disabled
              title={dgettext("settings", "Workspace")}
              description={dgettext("settings", "Team-scoped defaults. Coming soon.")}
              icon="hero-building-office"
            />
          </div>
        </section>
      </.settings_layout>
    </Layouts.app>
    """
  end

  # ---------------------------------------------------------------------------
  # Shared chrome: settings_layout + settings_sidebar
  #
  # These are exported as function components so the sibling LiveView
  # (ApiTokens) can render the same 2-col shell + sidebar with a different
  # active_item highlighted.
  # ---------------------------------------------------------------------------

  attr :active_item, :atom, required: true
  slot :inner_block, required: true

  @doc """
  Two-column settings shell. Sidebar on desktop (>= md), stacked on mobile.
  """
  def settings_layout(assigns) do
    ~H"""
    <div class="py-8">
      <div class="grid grid-cols-1 md:grid-cols-[14rem_1fr] gap-8">
        <.settings_sidebar active_item={@active_item} />
        <div class="min-w-0">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  attr :active_item, :atom, required: true

  @doc """
  Sidebar nav for the settings cluster. Active item picks up an emerald
  left border + bold text.
  """
  def settings_sidebar(assigns) do
    ~H"""
    <nav
      id="settings-sidebar"
      aria-label={dgettext("settings", "Settings navigation")}
      class="md:sticky md:top-20"
    >
      <p class="text-xs font-medium tracking-wide uppercase text-base-content/50 px-3 mb-2">
        {dgettext("settings", "Settings")}
      </p>
      <ul class="space-y-0.5 text-sm">
        <.sidebar_item
          label={dgettext("settings", "Account")}
          icon="hero-user-circle-mini"
          navigate={~p"/users/settings"}
          active?={@active_item == :account}
        />
        <.sidebar_item
          label={dgettext("settings", "API tokens")}
          icon="hero-key-mini"
          navigate={~p"/settings/api-tokens"}
          active?={@active_item == :api_tokens}
        />
        <.sidebar_item_disabled
          label={dgettext("settings", "Appearance")}
          icon="hero-paint-brush-mini"
        />
        <.sidebar_item_disabled
          label={dgettext("settings", "Workspace")}
          icon="hero-building-office-mini"
        />
        <.sidebar_item_disabled
          label={dgettext("settings", "Notifications")}
          icon="hero-bell-mini"
        />
      </ul>
    </nav>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :navigate, :string, required: true
  attr :active?, :boolean, default: false

  defp sidebar_item(assigns) do
    ~H"""
    <li>
      <.link
        navigate={@navigate}
        class={[
          "flex items-center gap-2 px-3 py-2 rounded-md border-l-2 transition-colors",
          if(@active?,
            do: "border-emerald-500 bg-base-200/60 font-semibold text-base-content",
            else: "border-transparent text-base-content/70 hover:text-base-content hover:bg-base-200/40"
          )
        ]}
        aria-current={if @active?, do: "page", else: "false"}
      >
        <.icon name={@icon} class="size-4 shrink-0 opacity-70" />
        <span>{@label}</span>
      </.link>
    </li>
    """
  end

  attr :label, :string, required: true
  attr :icon, :string, required: true

  defp sidebar_item_disabled(assigns) do
    ~H"""
    <li>
      <div
        class="flex items-center gap-2 px-3 py-2 rounded-md border-l-2 border-transparent text-base-content/40 cursor-not-allowed"
        aria-disabled="true"
      >
        <.icon name={@icon} class="size-4 shrink-0 opacity-50" />
        <span>{@label}</span>
        <span class="ml-auto text-[0.65rem] uppercase tracking-wide text-base-content/40">
          {dgettext("settings", "Soon")}
        </span>
      </div>
    </li>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :icon, :string, required: true
  attr :navigate, :string, required: true

  defp quick_card(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class="rounded-box border border-base-200 bg-base-100 p-5 hover:border-primary/60 hover:bg-base-200/30 transition-colors group"
    >
      <div class="flex items-start gap-3">
        <.icon name={@icon} class="size-5 text-primary/80 mt-0.5" />
        <div class="min-w-0">
          <p class="font-semibold tracking-tight group-hover:text-primary">
            {@title}
          </p>
          <p class="text-sm text-base-content/60 mt-1">
            {@description}
          </p>
        </div>
      </div>
    </.link>
    """
  end

  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :icon, :string, required: true

  defp quick_card_disabled(assigns) do
    ~H"""
    <div
      class="rounded-box border border-dashed border-base-300 bg-base-200/20 p-5 cursor-not-allowed"
      aria-disabled="true"
    >
      <div class="flex items-start gap-3">
        <.icon name={@icon} class="size-5 text-base-content/40 mt-0.5" />
        <div class="min-w-0">
          <p class="font-semibold tracking-tight text-base-content/60">
            {@title}
            <span class="ml-2 text-[0.65rem] uppercase tracking-wide text-base-content/40">
              {dgettext("settings", "Soon")}
            </span>
          </p>
          <p class="text-sm text-base-content/50 mt-1">
            {@description}
          </p>
        </div>
      </div>
    </div>
    """
  end
end
