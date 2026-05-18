defmodule ContractWeb.UserSessionController do
  use ContractWeb, :controller

  alias Contract.Accounts
  alias ContractWeb.UserAuth
  alias ContractWeb.AuthEmailURL

  # Default perm set for confirmed production users. Mirrors what
  # `Contract.PersonaFactory.spec(:lawyer)` ships for the Playwright
  # `:lawyer` persona, minus `:agent_run` (gated server-side until billing
  # lands). `DocumentScope` threads this into `current_scope.perms` so
  # Studio writes / revokes / exports / conversions are unlocked for
  # real (non-Persona) users.
  #
  # A future role-based pass will refine this (tenant_admin, viewer,
  # billing-gated agent_run, …). For now every confirmed user gets the
  # standard lawyer-set.
  @default_perms ~w(read write commit revoke export type_change)a

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params, %{user_perms: production_perms_for(user)})

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => %{"email" => email, "password" => password} = user_params}, info) do
    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params, %{user_perms: production_perms_for(user)})
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  # magic link request fallback for non-LiveView form posts
  defp create(conn, %{"user" => %{"email" => email}}, _info) when is_binary(email) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &AuthEmailURL.login_url/1
      )
    end

    # Avoid account enumeration: the response is identical whether the email exists.
    conn
    |> put_flash(
      :info,
      "If your email is in our system, you will receive instructions for logging in shortly."
    )
    |> put_flash(:email, String.slice(email, 0, 160))
    |> redirect(to: ~p"/users/log-in")
  end

  # Per-user perm derivation. Today every confirmed user gets the
  # standard lawyer-set so the merged sprite has writeable Studio for
  # real (non-Persona) logins. A future role-based pass will refine
  # this — see SPEC §6.
  defp production_perms_for(%Accounts.User{}), do: @default_perms
  defp production_perms_for(_), do: @default_perms

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, "Password updated successfully!")
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
