defmodule Contract.Repo.Migrations.AddWriteCompletedToDocuments do
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add(:write_completed_at, :utc_datetime)
      add(:write_completed_by_id, :binary_id)
      add(:write_completed_revision, :integer)
      add(:write_completed_snapshot_revision, :integer)
    end

    create(index(:documents, [:write_completed_by_id]))
  end
end
