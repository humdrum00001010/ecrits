defmodule ContractWeb.UserLive.Registration do
  use ContractWeb, :live_view

  alias Contract.Accounts
  alias Contract.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} variant="split">
      <.auth_split>
        <:aside>
          <h2 class="text-2xl font-semibold tracking-tight leading-snug">
            {dgettext("auth", "Closed beta for Korean lawyers.")}
          </h2>
          <p class="text-base-content/70 mt-3 leading-relaxed">
            {dgettext(
              "auth",
              "Registration is by invitation. We're working closely with a small group of solo lawyers and in-house counsel to shape the agent's questions, the type system, and the citation tooling."
            )}
          </p>
          <ul class="text-sm text-base-content/60 space-y-2 mt-6">
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" />
              {dgettext("auth", "Bilingual workspace, English-first.")}
            </li>
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" />
              {dgettext("auth", "법제처 cross-checking on every Korean-law citation.")}
            </li>
            <li class="flex gap-2">
              <.icon name="hero-check" class="size-4 text-primary shrink-0 mt-0.5" />
              {dgettext("auth", "Your data stays in a dedicated R2 bucket. No training on it.")}
            </li>
          </ul>
        </:aside>

        <:form>
          <div class="space-y-1">
            <h1 class="text-2xl font-semibold tracking-tight">
              {dgettext("auth", "Register for an account")}
            </h1>
            <p class="text-sm text-base-content/60">
              {dgettext("auth", "Already on the list?")}
              <.link navigate={~p"/users/log-in"} class="font-medium text-primary hover:underline">
                {dgettext("auth", "Log in")}
              </.link>
            </p>
          </div>

          <.form
            for={@form}
            id="registration_form"
            phx-submit="save"
            phx-change="validate"
            class="mt-6 space-y-3"
          >
            <.input
              field={@form[:email]}
              type="email"
              label={dgettext("auth", "Work email")}
              autocomplete="username"
              spellcheck="false"
              required
              phx-mounted={JS.focus()}
            />
            <.button
              phx-disable-with={dgettext("auth", "Creating account...")}
              class="btn btn-primary w-full"
            >
              {dgettext("auth", "Create my account")}
            </.button>
            <p class="text-xs text-base-content/50 pt-1">
              {dgettext(
                "auth",
                "We'll email a confirmation link. No password yet — you can add one later in Settings."
              )}
            </p>
          </.form>

          <p class="text-xs text-base-content/50 mt-8 text-center">
            {dgettext("auth", "Need help getting in?")}
            <a href="mailto:hello@contractstudio.example" class="underline hover:text-base-content">
              {dgettext("auth", "Email the team")}
            </a>
          </p>
        </:form>
      </.auth_split>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: ContractWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_email(%User{}, %{}, validate_unique: false)

    {:ok, assign_form(socket, changeset), temporary_assigns: [form: nil]}
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    case Accounts.register_user(user_params) do
      {:ok, user} ->
        {:ok, _} =
          Accounts.deliver_login_instructions(
            user,
            &url(~p"/users/log-in/#{&1}")
          )

        {:noreply,
         socket
         |> put_flash(
           :info,
           dgettext(
             "auth",
             "An email was sent to %{email}, please access it to confirm your account.",
             email: user.email
           )
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_email(%User{}, user_params, validate_unique: false)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    form = to_form(changeset, as: "user")
    assign(socket, form: form)
  end
end
