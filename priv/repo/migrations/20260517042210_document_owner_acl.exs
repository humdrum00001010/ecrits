defmodule Contract.Repo.Migrations.DocumentOwnerAcl do
  @moduledoc """
  SPEC.md v0.5: Document is the primary user-facing object.

  `documents.owner_id` replaces Matter as the ownership/ACL boundary. The
  legacy `matter_id` column is dropped from documents; the `matters` table and
  durable `changes.matter_id` column are left in place for legacy data cleanup
  in a later wave.
  """
  use Ecto.Migration

  def up do
    alter table(:documents) do
      add_if_not_exists(:owner_id, :binary_id)
    end

    execute("""
    UPDATE documents AS d
    SET owner_id = m.owner_id
    FROM matters AS m
    WHERE d.owner_id IS NULL AND d.matter_id = m.id
    """)

    execute("UPDATE documents SET status = 'draft' WHERE status IN ('active', 'template')")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM documents WHERE owner_id IS NULL) THEN
        RAISE EXCEPTION 'document_owner_acl: owner_id backfill left ownerless documents';
      END IF;
    END $$;
    """)

    drop_if_exists(index(:documents, [:matter_id, :status]))

    alter table(:documents) do
      remove(:matter_id)
      modify(:owner_id, :binary_id, null: false)
      modify(:status, :string, null: false, default: "draft")
    end

    create_if_not_exists(index(:documents, [:owner_id, :status]))
  end

  def down do
    drop_if_exists(index(:documents, [:owner_id, :status]))

    alter table(:documents) do
      add_if_not_exists(:matter_id, :binary_id)
      remove(:owner_id)
      modify(:status, :string, null: false, default: "active")
    end

    execute(
      "UPDATE documents SET status = 'active' WHERE status IN ('draft', 'importing', 'editing', 'reviewing', 'export_ready')"
    )

    create_if_not_exists(index(:documents, [:matter_id, :status]))
  end
end
