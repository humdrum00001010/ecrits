defmodule ContractWeb.UserLive.Settings do
  use ContractWeb, :live_view

  on_mount {ContractWeb.UserAuth, :require_sudo_mode}

  alias Contract.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="narrow">
      <div class="space-y-1 mb-8">
        <p class="text-xs font-medium tracking-wide uppercase text-base-content/50">
          {dgettext("settings", "Account")}
        </p>
        <h1 class="text-2xl font-semibold tracking-tight">{dgettext("settings", "Settings")}</h1>
        <p class="text-sm text-base-content/60">
          {dgettext(
            "settings",
            "Manage your email address and password. Sensitive changes require a fresh login."
          )}
        </p>
      </div>

      <section class="rounded-box border border-base-200 bg-base-100 p-6 space-y-4">
        <div>
          <h2 class="font-semibold tracking-tight">{dgettext("settings", "Email address")}</h2>
          <p class="text-sm text-base-content/60">
            {dgettext("settings", "Used for login, magic links, and audit-log attribution.")}
          </p>
        </div>
        <.form
          for={@email_form}
          id="email_form"
          phx-submit="update_email"
          phx-change="validate_email"
          class="space-y-3"
        >
          <.input
            field={@email_form[:email]}
            type="email"
            label={dgettext("settings", "Email")}
            autocomplete="username"
            spellcheck="false"
            required
          />
          <.button variant="primary" phx-disable-with={dgettext("settings", "Changing...")}>
            {dgettext("settings", "Change Email")}
          </.button>
        </.form>
      </section>

      <section class="rounded-box border border-base-200 bg-base-100 p-6 space-y-4 mt-6">
        <div>
          <h2 class="font-semibold tracking-tight">{dgettext("settings", "Password")}</h2>
          <p class="text-sm text-base-content/60">
            {dgettext(
              "settings",
              "Optional — you can keep using magic links. If you set a password, both methods work."
            )}
          </p>
        </div>
        <.form
          for={@password_form}
          id="password_form"
          action={~p"/users/update-password"}
          method="post"
          phx-change="validate_password"
          phx-submit="update_password"
          phx-trigger-action={@trigger_submit}
          class="space-y-3"
        >
          <input
            name={@password_form[:email].name}
            type="hidden"
            id="hidden_user_email"
            spellcheck="false"
            value={@current_email}
          />
          <.input
            field={@password_form[:password]}
            type="password"
            label={dgettext("settings", "New password")}
            autocomplete="new-password"
            spellcheck="false"
            required
          />
          <.input
            field={@password_form[:password_confirmation]}
            type="password"
            label={dgettext("settings", "Confirm new password")}
            autocomplete="new-password"
            spellcheck="false"
          />
          <.button variant="primary" phx-disable-with={dgettext("settings", "Saving...")}>
            {dgettext("settings", "Save Password")}
          </.button>
        </.form>
      </section>

      <p class="text-xs text-base-content/50 mt-8 text-center">
        {dgettext("settings", "Need help?")}
        <a href="mailto:support@contractstudio.example" class="underline hover:text-base-content">
          {dgettext("settings", "Email support")}
        </a>
      </p>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, dgettext("settings", "Email changed successfully."))

        {:error, _} ->
          put_flash(
            socket,
            :error,
            dgettext("settings", "Email change link is invalid or it has expired.")
          )
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:current_email, user.email)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info =
          dgettext(
            "settings",
            "A link to confirm your email change has been sent to the new address."
          )

        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end
end
