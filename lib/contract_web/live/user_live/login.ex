defmodule ContractWeb.UserLive.Login do
  use ContractWeb, :live_view

  alias Contract.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="split">
      <.auth_split>
        <:aside>
          <h2 class="text-2xl font-semibold tracking-tight leading-snug">
            {dgettext("auth", "Drafting that asks before it edits.")}
          </h2>
          <p class="text-base-content/70 mt-3 leading-relaxed">
            {dgettext(
              "auth",
              "Pick up where you left off. The agent's pending questions, your matter timeline, and every uncommitted edit are right where you parked them."
            )}
          </p>
          <ul class="text-sm text-base-content/60 space-y-2 mt-6">
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" />
              {dgettext("auth", "법제처 citations verified before they hit the page.")}
            </li>
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" />
              {dgettext("auth", "No silent rewrites. Every change is a row.")}
            </li>
          </ul>
        </:aside>

        <:form>
          <div class="space-y-1">
            <h1 class="text-2xl font-semibold tracking-tight">
              <%= if @current_scope do %>
                {dgettext("auth", "Re-authenticate")}
              <% else %>
                {dgettext("auth", "Log in")}
              <% end %>
            </h1>
            <p class="text-sm text-base-content/60">
              <%= if @current_scope do %>
                {dgettext(
                  "auth",
                  "You need to reauthenticate to perform sensitive actions on your account."
                )}
              <% else %>
                {dgettext("auth", "New here?")}
                <.link
                  navigate={~p"/users/register"}
                  class="font-medium text-primary hover:underline"
                  phx-no-format
                >{dgettext("auth", "Sign up")}</.link>
                {dgettext("auth", "— Contract Studio is invite-only for the closed beta.")}
              <% end %>
            </p>
          </div>

          <div :if={local_mail_adapter?()} class="alert alert-info mt-4">
            <.icon name="hero-information-circle" class="size-5 shrink-0" />
            <div>
              <p class="font-medium">{dgettext("auth", "Local mail adapter is active.")}</p>
              <p class="text-sm">
                {dgettext("auth", "Magic links land in")}
                <.link href="/dev/mailbox" class="underline">
                  {dgettext("auth", "the dev mailbox")}
                </.link>
                {dgettext("auth", ", not real email.")}
              </p>
            </div>
          </div>

          <div class="mt-6 space-y-6">
            <.form
              :let={f}
              for={@form}
              id="login_form_magic"
              action={~p"/users/log-in"}
              phx-submit="submit_magic"
              class="space-y-3"
            >
              <.input
                readonly={!!@current_scope}
                field={f[:email]}
                type="email"
                label={dgettext("auth", "Email")}
                autocomplete="username"
                spellcheck="false"
                required
                phx-mounted={JS.focus()}
              />
              <.button class="btn btn-primary w-full">
                {dgettext("auth", "Log in with email")} <span aria-hidden="true">→</span>
              </.button>
              <p class="text-xs text-base-content/50">
                {dgettext("auth", "We'll send a one-time link. No password required.")}
              </p>
            </.form>

            <div class="divider text-xs text-base-content/40">
              {dgettext("auth", "or use a password")}
            </div>

            <.form
              :let={f}
              for={@form}
              id="login_form_password"
              action={~p"/users/log-in"}
              phx-submit="submit_password"
              phx-trigger-action={@trigger_submit}
              class="space-y-3"
            >
              <.input
                readonly={!!@current_scope}
                field={f[:email]}
                type="email"
                label={dgettext("auth", "Email")}
                autocomplete="username"
                spellcheck="false"
                required
              />
              <.input
                field={@form[:password]}
                type="password"
                label={dgettext("auth", "Password")}
                autocomplete="current-password"
                spellcheck="false"
              />
              <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
                {dgettext("auth", "Log in and stay logged in")} <span aria-hidden="true">→</span>
              </.button>
              <.button class="btn btn-ghost w-full">
                {dgettext("auth", "Log in only this time")}
              </.button>
            </.form>
          </div>

          <p class="text-xs text-base-content/50 mt-8 text-center">
            {dgettext("auth", "Trouble signing in?")}
            <a href="mailto:support@contractstudio.example" class="underline hover:text-base-content">
              {dgettext("auth", "Email support")}
            </a>
          </p>
        </:form>
      </.auth_split>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      dgettext(
        "auth",
        "If your email is in our system, you will receive instructions for logging in shortly."
      )

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:contract, Contract.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
