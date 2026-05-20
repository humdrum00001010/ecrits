defmodule Contract.Repo.Migrations.CreateDocumentTypes do
  use Ecto.Migration

  def up do
    execute "CREATE EXTENSION IF NOT EXISTS pgcrypto", ""

    create table(:document_types, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :family, :string, null: false, default: "other"
      add :name_en, :string, null: false
      add :name_ko, :string
      add :version, :string, null: false, default: "legacy"
      add :source, :string, null: false, default: "custom"
      add :source_url, :text
      add :template_hwp_path, :text
      add :template_hwpx_path, :text
      add :spec, :map, null: false, default: %{}
      add :default_matching_book, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:document_types, [:key])

    alter table(:documents) do
      add :document_type_id, references(:document_types, type: :binary_id, on_delete: :restrict)
    end

    create index(:documents, [:document_type_id])

    flush()

    execute """
    INSERT INTO document_types (
      id,
      key,
      name_en,
      version,
      source,
      default_matching_book,
      spec,
      inserted_at,
      updated_at
    )
    SELECT
      gen_random_uuid(),
      keys.key,
      keys.key,
      'legacy',
      'custom',
      COALESCE(matching_books.matching_book, '{}'::jsonb),
      '{}'::jsonb,
      NOW(),
      NOW()
    FROM (
      SELECT DISTINCT type_key AS key
      FROM documents
      WHERE type_key IS NOT NULL AND type_key <> ''
      UNION
      SELECT DISTINCT type_key AS key
      FROM contract_type_matching_books
      WHERE type_key IS NOT NULL AND type_key <> ''
    ) AS keys
    LEFT JOIN contract_type_matching_books AS matching_books
      ON matching_books.type_key = keys.key
    ON CONFLICT (key) DO NOTHING
    """

    execute """
    UPDATE documents AS documents
    SET document_type_id = document_types.id
    FROM document_types
    WHERE documents.document_type_id IS NULL
      AND documents.type_key = document_types.key
    """

    drop_if_exists table(:contract_type_matching_books)
  end

  def down do
    create_if_not_exists table(:contract_type_matching_books, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :type_key, :string, null: false
      add :matching_book, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists unique_index(:contract_type_matching_books, [:type_key])

    flush()

    execute """
    INSERT INTO contract_type_matching_books (
      id,
      type_key,
      matching_book,
      inserted_at,
      updated_at
    )
    SELECT
      gen_random_uuid(),
      key,
      default_matching_book,
      NOW(),
      NOW()
    FROM document_types
    WHERE default_matching_book IS NOT NULL
      AND default_matching_book <> '{}'::jsonb
    ON CONFLICT (type_key) DO UPDATE
    SET matching_book = EXCLUDED.matching_book,
        updated_at = NOW()
    """

    drop_if_exists index(:documents, [:document_type_id])

    alter table(:documents) do
      remove :document_type_id
    end

    drop table(:document_types)
  end
end
