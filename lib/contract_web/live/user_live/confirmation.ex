defmodule ContractWeb.UserLive.Confirmation do
  use ContractWeb, :live_view

  alias Contract.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="split">
      <.auth_split>
        <:aside>
          <h2 class="text-2xl font-semibold tracking-tight leading-snug">
            {dgettext("auth", "One last click and you're in.")}
          </h2>
          <p class="text-base-content/70 mt-3 leading-relaxed">
            {dgettext(
              "auth",
              "We pair every account with a magic link so the cold-start path doesn't require remembering a password. You can still add one later in Settings."
            )}
          </p>
        </:aside>

        <:form>
          <div class="space-y-1">
            <h1 class="text-2xl font-semibold tracking-tight">
              <%= if @user.confirmed_at do %>
                {dgettext("auth", "Welcome back")}
              <% else %>
                {dgettext("auth", "Confirm your account")}
              <% end %>
            </h1>
            <p class="text-sm text-base-content/60 break-all">
              {@user.email}
            </p>
          </div>

          <.form
            :if={!@user.confirmed_at}
            for={@form}
            id="confirmation_form"
            phx-mounted={JS.focus_first()}
            phx-submit="submit"
            action={~p"/users/log-in?_action=confirmed"}
            phx-trigger-action={@trigger_submit}
            class="mt-6 space-y-3"
          >
            <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
            <.button
              name={@form[:remember_me].name}
              value="true"
              phx-disable-with={dgettext("auth", "Confirming...")}
              class="btn btn-primary w-full"
            >
              {dgettext("auth", "Confirm and stay logged in")}
            </.button>
            <.button phx-disable-with={dgettext("auth", "Confirming...")} class="btn btn-ghost w-full">
              {dgettext("auth", "Confirm and log in only this time")}
            </.button>
          </.form>

          <.form
            :if={@user.confirmed_at}
            for={@form}
            id="login_form"
            phx-submit="submit"
            phx-mounted={JS.focus_first()}
            action={~p"/users/log-in"}
            phx-trigger-action={@trigger_submit}
            class="mt-6 space-y-3"
          >
            <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
            <%= if @current_scope do %>
              <.button
                phx-disable-with={dgettext("auth", "Logging in...")}
                class="btn btn-primary w-full"
              >
                {dgettext("auth", "Log in")}
              </.button>
            <% else %>
              <.button
                name={@form[:remember_me].name}
                value="true"
                phx-disable-with={dgettext("auth", "Logging in...")}
                class="btn btn-primary w-full"
              >
                {dgettext("auth", "Keep me logged in on this device")}
              </.button>
              <.button
                phx-disable-with={dgettext("auth", "Logging in...")}
                class="btn btn-ghost w-full"
              >
                {dgettext("auth", "Log me in only this time")}
              </.button>
            <% end %>
          </.form>

          <p :if={!@user.confirmed_at} class="alert alert-outline mt-8 text-sm">
            <.icon name="hero-key-micro" class="size-4" />
            {dgettext("auth", "Tip: prefer passwords? Enable one in Settings after you're in.")}
          </p>
        </:form>
      </.auth_split>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok, assign(socket, user: user, form: form, trigger_submit: false),
       temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, dgettext("auth", "Magic link is invalid or it has expired."))
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
