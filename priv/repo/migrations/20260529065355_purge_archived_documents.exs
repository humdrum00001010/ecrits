defmodule Contract.Repo.Migrations.PurgeArchivedDocuments do
  use Ecto.Migration

  def up do
    execute("""
    DELETE FROM packet_documents
    WHERE document_id IN (SELECT id FROM documents WHERE status = 'archived')
    """)

    execute("""
    DELETE FROM chat_threads
    WHERE document_id IN (SELECT id FROM documents WHERE status = 'archived')
    """)

    execute("""
    DELETE FROM leases
    WHERE document_id IN (SELECT id FROM documents WHERE status = 'archived')
    """)

    execute("""
    DELETE FROM rhwp_snapshots
    WHERE document_id IN (SELECT id FROM documents WHERE status = 'archived')
    """)

    execute("""
    DELETE FROM snapshots
    WHERE document_id IN (SELECT id FROM documents WHERE status = 'archived')
    """)

    execute("""
    DELETE FROM changes
    WHERE document_id IN (SELECT id FROM documents WHERE status = 'archived')
    """)

    execute("DELETE FROM documents WHERE status = 'archived'")
  end

  def down, do: :ok
end
