defmodule Contract.Repo.Migrations.CreateMatters do
  use Ecto.Migration

  def change do
    create table(:matters, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:name, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:tenant_id, :binary_id)
      add(:owner_id, :binary_id, null: false)
      add(:metadata, :map, default: %{})
      timestamps(type: :utc_datetime)
    end

    create(index(:matters, [:owner_id]))
    create(index(:matters, [:tenant_id]))
    create(index(:matters, [:status]))
  end
end
