defmodule Contract.Repo.Migrations.CreateBlobRefs do
  @moduledoc """
  SPEC.md v0.5 §19 — BlobRef.

  Single point of truth for opaque blob storage handles. Source uploads,
  parser snapshots, export outputs, generated images all reference rows
  here.
  """
  use Ecto.Migration

  def change do
    create_if_not_exists table(:blob_refs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, :binary_id, null: false)

      add(:bucket, :string, null: false)
      add(:object_key, :string, null: false)
      add(:mime_type, :string)
      add(:size_bytes, :integer)
      add(:sha256, :string)
      add(:kind, :string, null: false)
      add(:metadata, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(unique_index(:blob_refs, [:bucket, :object_key]))
    create_if_not_exists(index(:blob_refs, [:owner_id, :kind]))
  end
end
