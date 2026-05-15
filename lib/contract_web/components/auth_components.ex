defmodule ContractWeb.AuthComponents do
  @moduledoc """
  Components used by the auth surface (login, register, settings,
  confirmation). The main one is `auth_split/1` — a two-column shell with
  a quiet brand panel on the left and the form on a card on the right.

  Pulled out of the auth LiveViews so the look stays consistent and a
  future redesign only touches one file.
  """
  use Phoenix.Component
  use Gettext, backend: ContractWeb.Gettext

  import ContractWeb.CoreComponents, only: [icon: 1]

  alias ContractWeb.Brand

  @doc """
  Two-column auth layout: a `:aside` slot for the brand panel (hidden on
  small screens) and a `:form` slot for the actual form card.

  ## Example

      <.auth_split>
        <:aside>
          <h2>Welcome back</h2>
        </:aside>
        <:form>
          <.form ...>
        </:form>
      </.auth_split>
  """
  slot :aside, required: false
  slot :form, required: true

  def auth_split(assigns) do
    ~H"""
    <div class="min-h-[calc(100vh-3.5rem)] grid lg:grid-cols-2">
      <aside class="hidden lg:flex flex-col justify-between p-10 xl:p-14 bg-base-200/40 border-r border-base-200">
        <div class="space-y-2">
          <Brand.wordmark size="lg" />
          <p class="text-xs text-base-content/50 tracking-wide uppercase">
            {dgettext("auth", "Legal-document studio for Korean lawyers")}
          </p>
        </div>

        <div class="space-y-6 max-w-md">
          {render_slot(@aside)}
        </div>

        <div class="space-y-2 text-xs text-base-content/50">
          <div class="flex items-center gap-2">
            <.icon name="hero-lock-closed-micro" class="size-3" />
            <span>
              {dgettext(
                "auth",
                "법제처 verification · provenance logged · no silent rewrites."
              )}
            </span>
          </div>
          <p>
            {dgettext("auth", "© %{year} Contract Studio", year: DateTime.utc_now().year)}
          </p>
        </div>
      </aside>

      <section class="flex items-center justify-center px-4 sm:px-8 py-12">
        <div class="w-full max-w-md">
          <div class="lg:hidden mb-8 flex justify-center">
            <Brand.wordmark size="lg" />
          </div>
          <div class="rounded-box border border-base-200 bg-base-100 p-6 sm:p-8">
            {render_slot(@form)}
          </div>
        </div>
      </section>
    </div>
    """
  end
end
