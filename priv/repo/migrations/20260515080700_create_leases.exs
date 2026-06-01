defmodule Contract.Repo.Migrations.CreateLeases do
  use Ecto.Migration

  def change do
    create table(:leases, primary_key: false) do
      add(:document_id, :binary_id, primary_key: true)
      add(:owner_ref, :text, null: false)
      add(:fencing_token, :bigserial, null: false)
      add(:expires_at, :timestamptz, null: false)
    end

    create(index(:leases, [:expires_at]))
  end
end
