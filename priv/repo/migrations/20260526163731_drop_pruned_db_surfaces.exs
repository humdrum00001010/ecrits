defmodule Contract.Repo.Migrations.DropPrunedDbSurfaces do
  use Ecto.Migration

  def up do
    execute("DROP TABLE IF EXISTS tool_calls")
    execute("DROP TABLE IF EXISTS marks")
    execute("DROP TABLE IF EXISTS blob_refs")
    execute("DROP TABLE IF EXISTS source_claims")
    execute("DROP TABLE IF EXISTS source_documents")
    execute("DROP TABLE IF EXISTS evidence_snapshots")
    execute("DROP TABLE IF EXISTS field_lineages")
    execute("DROP TABLE IF EXISTS exports")
    execute("DROP TABLE IF EXISTS revoke_requests")
    execute("DROP TABLE IF EXISTS slack_tokens")
    execute("DROP TABLE IF EXISTS matters")
    execute("DROP TABLE IF EXISTS agent_runs")

    execute("DROP INDEX IF EXISTS changes_source_document_id_index")
    execute("DROP INDEX IF EXISTS changes_source_claim_id_index")

    alter table(:changes) do
      remove_if_exists(:source_document_id, :binary_id)
      remove_if_exists(:source_claim_id, :binary_id)
    end

    execute("DROP INDEX IF EXISTS documents_parent_document_id_index")

    alter table(:documents) do
      remove_if_exists(:parent_document_id, :binary_id)
      remove_if_exists(:variant_of_change_id, :binary_id)
      remove_if_exists(:state_snapshot, :map)
      remove_if_exists(:current_revision, :integer)
    end

    alter table(:document_types) do
      remove_if_exists(:source_url, :text)
      remove_if_exists(:spec, :map)
    end
  end

  def down do
    raise Ecto.MigrationError,
          "pruned DB surfaces are not reversible; recreate old migrations manually if needed"
  end
end
