defmodule Contract.Repo.Migrations.CreateExports do
  use Ecto.Migration

  def change do
    create table(:exports, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(
        :document_id,
        references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:requester_id, :binary_id)
      add(:format, :string, null: false)
      add(:status, :string, null: false, default: "queued")
      add(:progress, :integer, null: false, default: 0)
      add(:key, :string)
      add(:download_url, :string)
      add(:content_type, :string)
      add(:byte_size, :integer)
      add(:error, :map, default: %{})
      add(:metadata, :map, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:exports, [:document_id, :inserted_at]))
    create(index(:exports, [:requester_id, :inserted_at]))
    create(index(:exports, [:status]))
  end
end
