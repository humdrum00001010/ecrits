defmodule Contract.Repo.Migrations.CreateRhwpSnapshots do
  use Ecto.Migration

  def up do
    create table(:rhwp_snapshots, primary_key: false) do
      add(:document_id, :binary_id, primary_key: true, null: false)
      add(:revision, :integer, primary_key: true, null: false)
      add(:format, :string, null: false)
      add(:content_type, :string, null: false)
      add(:r2_key, :string, null: false)
      add(:ir_r2_key, :string, null: false)
      add(:projection, :map, null: false)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(:rhwp_snapshots, [:document_id, :revision]))
    create(index(:rhwp_snapshots, [:document_id, :format]))
    create(unique_index(:rhwp_snapshots, [:r2_key]))
    create(unique_index(:rhwp_snapshots, [:ir_r2_key]))

    execute("""
    INSERT INTO rhwp_snapshots (
      document_id,
      revision,
      format,
      content_type,
      r2_key,
      ir_r2_key,
      projection,
      inserted_at
    )
    SELECT
      document_id,
      revision,
      CASE
        WHEN r2_key LIKE '%.hwp' THEN 'hwp'
        ELSE 'hwpx'
      END,
      CASE
        WHEN r2_key LIKE '%.hwp' THEN 'application/x-hwp'
        ELSE 'application/hwp+zip'
      END,
      r2_key,
      regexp_replace(r2_key, '\\.(hwp|hwpx)$', '.ir.json'),
      projection,
      inserted_at
    FROM snapshots
    WHERE r2_key LIKE '%.hwp' OR r2_key LIKE '%.hwpx'
    ON CONFLICT (document_id, revision) DO NOTHING
    """)
  end

  def down do
    drop(table(:rhwp_snapshots))
  end
end
