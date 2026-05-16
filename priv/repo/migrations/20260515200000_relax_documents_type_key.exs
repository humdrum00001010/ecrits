defmodule Contract.Repo.Migrations.RelaxDocumentsTypeKey do
  @moduledoc """
  Per SPEC.md §18: contract type is a key that is set AFTER document
  creation, either by the user via Cmd+K or by the agent once it
  understands the document context. Relax `documents.type_key` to allow
  NULL so a document can be created untyped and have its type set later
  via `Action(:set_contract_type)`.

  Existing typed documents stay typed — this is forward-compat only.
  """
  use Ecto.Migration

  def change do
    alter table(:documents) do
      modify :type_key, :string, null: true
    end
  end
end
