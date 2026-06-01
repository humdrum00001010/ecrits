defmodule Contract.DataCase do
  @moduledoc """
  This module defines common helpers for data-shaped tests.

  You may define functions here to be used as helpers in
  your tests.

  The SQL Repo has been retired; legacy DB tests should move to local-first
  stores or stay excluded until rewritten.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :legacy_saas

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Contract.DataCase

      alias Contract.Repo
    end
  end

  setup tags do
    Contract.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Kept as a compatibility hook for older case templates.
  """
  def setup_sandbox(_tags), do: :ok

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
