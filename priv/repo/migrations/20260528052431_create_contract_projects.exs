defmodule Contract.Repo.Migrations.CreateContractProjects do
  use Ecto.Migration

  def change do
    create table(:contract_projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_id, :binary_id, null: false
      add :title, :string, null: false
      add :counterparty, :string
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:contract_projects, [:owner_id, :status])
    create index(:contract_projects, [:owner_id, :updated_at])

    create table(:project_documents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :project_id,
          references(:contract_projects, type: :binary_id, on_delete: :delete_all),
          null: false

      add :document_id, references(:documents, type: :binary_id, on_delete: :delete_all),
        null: false

      add :role, :string, null: false, default: "primary"
      add :status, :string, null: false, default: "active"
      add :required, :boolean, null: false, default: true
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:project_documents, [:project_id, :document_id])
    create index(:project_documents, [:document_id])
    create index(:project_documents, [:project_id, :role])
    create index(:project_documents, [:project_id, :status])
  end
end
