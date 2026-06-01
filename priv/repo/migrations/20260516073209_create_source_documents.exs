defmodule Contract.Repo.Migrations.CreateSourceDocuments do
  @moduledoc """
  SPEC.md v0.5 §7.3 — SourceDocument.

  Uploaded/imported document-shaped source (PDF, HWPX, DOCX, scanned
  contract, prior draft, counterparty draft). Distinct from arbitrary
  attachments or plain chat.
  """
  use Ecto.Migration

  def change do
    create_if_not_exists table(:source_documents, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, :binary_id, null: false)
      add(:chat_thread_id, :binary_id)
      add(:document_id, :binary_id)

      add(:blob_ref_id, :binary_id, null: false)
      add(:mime_type, :string)
      add(:original_filename, :string)
      add(:parser_snapshot_ref, :string)
      add(:regions, {:array, :map}, null: false, default: [])
      add(:status, :string, null: false, default: "uploaded")

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:source_documents, [:owner_id]))
    create_if_not_exists(index(:source_documents, [:chat_thread_id]))
    create_if_not_exists(index(:source_documents, [:document_id]))
    create_if_not_exists(index(:source_documents, [:status]))
  end
end
