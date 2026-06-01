defmodule Contract.Repo.Migrations.CreateFieldLineages do
  use Ecto.Migration

  def change do
    create table(:field_lineages, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:document_id, :binary_id, null: false)
      add(:field_id, :string, null: false)
      add(:source_document_id, :binary_id)
      add(:source_field_id, :string)
      add(:strategy, :string, null: false)
      add(:justification, :text)
      timestamps(type: :utc_datetime)
    end

    # Append-only audit: composite for fast field lookups within a doc.
    create(index(:field_lineages, [:document_id, :field_id]))
    create(index(:field_lineages, [:source_document_id]))
  end
end
