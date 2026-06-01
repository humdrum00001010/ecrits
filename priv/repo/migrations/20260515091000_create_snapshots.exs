defmodule Contract.Repo.Migrations.CreateSnapshots do
  use Ecto.Migration

  def change do
    create table(:snapshots, primary_key: false) do
      add(:document_id, :binary_id, primary_key: true, null: false)
      add(:revision, :integer, primary_key: true, null: false)
      add(:projection, :map, null: false)
      add(:r2_key, :string, null: false)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(:snapshots, [:document_id, :revision]))
  end
end
