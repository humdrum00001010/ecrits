defmodule Contract.Repo.Migrations.CreateMarks do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:marks, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:document_id, :binary_id, null: false)
      add(:evidence_snapshot_id, :binary_id, null: false)
      add(:field_path, {:array, :string}, null: false, default: [])
      add(:change_id, :binary_id)
      add(:type, :string, null: false, default: "evidence")
      add(:status, :string, null: false, default: "attached")
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:marks, [:document_id]))
    create_if_not_exists(index(:marks, [:evidence_snapshot_id]))
    create_if_not_exists(index(:marks, [:change_id]))
  end
end
