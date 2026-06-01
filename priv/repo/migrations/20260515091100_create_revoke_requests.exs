defmodule Contract.Repo.Migrations.CreateRevokeRequests do
  use Ecto.Migration

  def change do
    create table(:revoke_requests, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:document_id, :binary_id, null: false)
      add(:target_change_id, :binary_id, null: false)
      add(:overlap_changes, {:array, :binary_id}, default: [], null: false)

      add(:status, :string, null: false, default: "pending")
      add(:resolution_change_id, :binary_id)
      add(:requester_id, :binary_id)

      timestamps(type: :utc_datetime)
    end

    create(index(:revoke_requests, [:document_id]))
    create(index(:revoke_requests, [:status]))
    create(index(:revoke_requests, [:target_change_id]))
  end
end
