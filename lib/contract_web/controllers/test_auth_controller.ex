if Application.compile_env(:contract, :test_auth, false) do
  defmodule ContractWeb.TestAuthController do
    @moduledoc """
    Playwright-only auth shim. Mints a persona user via
    `Contract.PersonaFactory`, then **sets a legacy session cookie** and responds
    JSON. Playwright takes the cookie back into its `BrowserContext` and
    behaves like a logged-in user for the rest of the spec.

    Gated behind `Application.compile_env(:contract, :test_auth, false)`:
    in `:prod` the entire module elides at compile time, so the routes
    that reference it 404.
    """

    use ContractWeb, :controller

    alias Contract.{Accounts, PersonaFactory, E2E}

    plug :gate_test_auth

    @doc """
    `POST /test/personas/:persona/sign_in` — builds a fresh persona user,
    issues a session token, sets the session cookie, and returns the
    persona, user id, and email so Playwright can echo back what it got.
    """
    def sign_in(conn, %{"persona" => persona_name}) do
      with {:ok, persona} <- safe_persona_atom(persona_name) do
        %{user: user} = PersonaFactory.build(persona)
        token = Accounts.generate_user_session_token(user)
        %{perms: perms} = PersonaFactory.spec(persona)

        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_session(:user_token, token)
        |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
        |> put_session(:user_perms, perms)
        |> json(%{
          ok: true,
          persona: persona_name,
          user_id: user.id,
          email: user.email,
          perms: Enum.map(perms, &Atom.to_string/1)
        })
      else
        :error ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{ok: false, error: "unknown_persona", persona: persona_name})
      end
    end

    @doc """
    `POST /test/reset` — clears the `e2e` matter scope. Idempotent.
    """
    def reset(conn, _params) do
      :ok = E2E.reset!()
      json(conn, %{ok: true})
    end

    defp safe_persona_atom(name) when is_binary(name) do
      # We can't use `String.to_existing_atom/1` here — the
      # `Contract.PersonaFactory` module may not be loaded yet on the
      # first request, so the atom keys for `@personas` are absent from
      # the runtime atom table. Instead, match `name` against the string
      # form of each known persona and project to the original atom.
      case Enum.find(PersonaFactory.personas(), fn p -> Atom.to_string(p) == name end) do
        nil -> :error
        atom -> {:ok, atom}
      end
    end

    defp safe_persona_atom(_), do: :error

    defp gate_test_auth(conn, _opts) do
      if Application.get_env(:contract, :test_auth, false) do
        conn
      else
        conn |> send_resp(404, "") |> halt()
      end
    end
  end
end
