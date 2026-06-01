defmodule Contract.Repo.Migrations.CreateChanges do
  use Ecto.Migration

  def change do
    create table(:changes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:matter_id, :binary_id)
      add(:document_id, :binary_id, null: false)
      add(:artifact_id, :binary_id)

      add(:action_kind, :string, null: false)

      add(:actor_type, :string, null: false)
      add(:actor_id, :binary_id)

      add(:base_revision, :integer)
      add(:applied_revision, :integer, null: false)
      add(:idempotency_key, :string)

      add(:ops, {:array, :map}, default: [], null: false)
      add(:marks, {:array, :map}, default: [], null: false)
      add(:message, :text)

      add(:affected_refs, {:array, :map}, default: [], null: false)
      add(:preimage, :map)
      add(:inverse_ops, {:array, :map}, default: [], null: false)

      add(:status, :string, null: false, default: "active")

      timestamps(type: :utc_datetime)
    end

    # Lookups by document.
    create(index(:changes, [:document_id]))

    # Idempotency must be unique per document.
    create(
      unique_index(:changes, [:document_id, :idempotency_key],
        where: "idempotency_key IS NOT NULL",
        name: :changes_document_id_idempotency_key_index
      )
    )

    # Sortable revision per document — fast ordered scans by applied_revision.
    create(index(:changes, [:document_id, :applied_revision]))

    create(index(:changes, [:matter_id]))
    create(index(:changes, [:status]))
  end
end
