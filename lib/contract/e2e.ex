if Application.compile_env(:contract, :test_auth, false) do
  defmodule Contract.E2E do
    @moduledoc """
    Test-only cleanup helpers for Playwright e2e runs against the public
    sprite URL. The Playwright runner calls `POST /test/reset` between
    scenarios (route gated by `Application.compile_env(:contract, :test_auth)`),
    which delegates here.

    The reset is idempotent and removes rows tagged as E2E documents by the
    test DB seeder. Persona users created by `Contract.PersonaFactory` are not
    deleted by default — each test mints fresh users with unique emails so they
    don't collide.
    """

    alias Contract.Repo

    @e2e_documents """
    SELECT id FROM documents WHERE metadata->>'e2e' = 'true'
    """

    @doc """
    Deletes rows scoped to documents tagged with E2E metadata. This cleanup is
    document-first and skips persistence tables that have been pruned.
    """
    @spec reset!() :: :ok
    def reset! do
      safe_query!("DELETE FROM snapshots WHERE document_id IN (#{@e2e_documents})")
      safe_query!("DELETE FROM changes WHERE document_id IN (#{@e2e_documents})")
      safe_query!("DELETE FROM documents WHERE id IN (#{@e2e_documents})")

      :ok
    end

    @doc """
    Wipes all user rows created by the persona factory in the public-URL
    e2e run. Only called explicitly (not part of `reset!/0`) since most
    scenarios prefer to keep the actor user alive across the spec.
    """
    @spec reset_personas!() :: :ok
    def reset_personas! do
      safe_query!(
        "DELETE FROM users_tokens WHERE user_id IN (SELECT id FROM users WHERE email ~ '^(lawyer|paralegal|agent-sup|viewer|admin)-[0-9]+@example\\.com$')"
      )

      safe_query!(
        "DELETE FROM users WHERE email ~ '^(lawyer|paralegal|agent-sup|viewer|admin)-[0-9]+@example\\.com$'"
      )

      :ok
    end

    defp safe_query!(sql) do
      try do
        Repo.query!(sql)
        :ok
      rescue
        _ -> :ok
      end
    end
  end
end
