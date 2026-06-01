defmodule Contract.Repo.Migrations.RenameProjectsToPackets do
  use Ecto.Migration

  def up do
    rename(table(:contract_projects), to: table(:contract_packets))
    rename(table(:project_documents), to: table(:packet_documents))
    rename(table(:packet_documents), :project_id, to: :packet_id)

    execute(
      "ALTER TABLE contract_packets RENAME CONSTRAINT contract_projects_pkey TO contract_packets_pkey"
    )

    execute(
      "ALTER TABLE packet_documents RENAME CONSTRAINT project_documents_pkey TO packet_documents_pkey"
    )

    execute(
      "ALTER TABLE packet_documents RENAME CONSTRAINT project_documents_project_id_fkey TO packet_documents_packet_id_fkey"
    )

    execute(
      "ALTER TABLE packet_documents RENAME CONSTRAINT project_documents_document_id_fkey TO packet_documents_document_id_fkey"
    )

    execute(
      "ALTER INDEX contract_projects_owner_id_status_index RENAME TO contract_packets_owner_id_status_index"
    )

    execute(
      "ALTER INDEX contract_projects_owner_id_updated_at_index RENAME TO contract_packets_owner_id_updated_at_index"
    )

    execute(
      "ALTER INDEX project_documents_project_id_document_id_index RENAME TO packet_documents_packet_id_document_id_index"
    )

    execute(
      "ALTER INDEX project_documents_document_id_index RENAME TO packet_documents_document_id_index"
    )

    execute(
      "ALTER INDEX project_documents_project_id_role_index RENAME TO packet_documents_packet_id_role_index"
    )

    execute(
      "ALTER INDEX project_documents_project_id_status_index RENAME TO packet_documents_packet_id_status_index"
    )
  end

  def down do
    execute(
      "ALTER TABLE contract_packets RENAME CONSTRAINT contract_packets_pkey TO contract_projects_pkey"
    )

    execute(
      "ALTER TABLE packet_documents RENAME CONSTRAINT packet_documents_pkey TO project_documents_pkey"
    )

    execute(
      "ALTER TABLE packet_documents RENAME CONSTRAINT packet_documents_packet_id_fkey TO project_documents_project_id_fkey"
    )

    execute(
      "ALTER TABLE packet_documents RENAME CONSTRAINT packet_documents_document_id_fkey TO project_documents_document_id_fkey"
    )

    execute(
      "ALTER INDEX contract_packets_owner_id_status_index RENAME TO contract_projects_owner_id_status_index"
    )

    execute(
      "ALTER INDEX contract_packets_owner_id_updated_at_index RENAME TO contract_projects_owner_id_updated_at_index"
    )

    execute(
      "ALTER INDEX packet_documents_packet_id_document_id_index RENAME TO project_documents_project_id_document_id_index"
    )

    execute(
      "ALTER INDEX packet_documents_document_id_index RENAME TO project_documents_document_id_index"
    )

    execute(
      "ALTER INDEX packet_documents_packet_id_role_index RENAME TO project_documents_project_id_role_index"
    )

    execute(
      "ALTER INDEX packet_documents_packet_id_status_index RENAME TO project_documents_project_id_status_index"
    )

    rename(table(:packet_documents), :packet_id, to: :project_id)
    rename(table(:packet_documents), to: table(:project_documents))
    rename(table(:contract_packets), to: table(:contract_projects))
  end
end
