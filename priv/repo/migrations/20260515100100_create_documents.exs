defmodule Contract.Repo.Migrations.CreateDocuments do
  use Ecto.Migration

  def change do
    create table(:documents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :matter_id, :binary_id, null: false
      add :title, :string, null: false
      add :type_key, :string, null: false
      add :status, :string, null: false, default: "active"
      add :parent_document_id, :binary_id
      add :variant_of_change_id, :binary_id
      add :latest_revision, :integer, null: false, default: 0
      add :metadata, :map, default: %{}
      timestamps(type: :utc_datetime)
    end

    create index(:documents, [:matter_id, :status])
    create index(:documents, [:parent_document_id])
    create index(:documents, [:type_key])
  end
end
