defmodule Contract.Repo.Migrations.CreateEvidenceSnapshots do
  @moduledoc """
  SPEC.md v0.5 §7.8 — EvidenceSnapshot.

  IMMUTABLE record of a single provider call (law-MCP, statute lookup,
  case search, ...). Append-only — no `updated_at`. `result_hash` is the
  content-addressed key used to dedupe identical responses per owner.
  """
  use Ecto.Migration

  def change do
    create_if_not_exists table(:evidence_snapshots, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, :binary_id, null: false)

      add(:chat_thread_id, :binary_id)
      add(:document_id, :binary_id)
      add(:source_document_id, :binary_id)

      add(:provider, :string, null: false)
      add(:query, :map, null: false, default: %{})
      add(:result, :map, null: false, default: %{})
      add(:result_hash, :string, null: false)

      add(:captured_at, :utc_datetime, null: false)

      # Append-only: inserted_at only, no updated_at (SPEC §7.8).
      add(:inserted_at, :utc_datetime, null: false)
    end

    create_if_not_exists(unique_index(:evidence_snapshots, [:result_hash, :owner_id]))
    create_if_not_exists(index(:evidence_snapshots, [:chat_thread_id]))
    create_if_not_exists(index(:evidence_snapshots, [:document_id]))
    create_if_not_exists(index(:evidence_snapshots, [:source_document_id]))
    create_if_not_exists(index(:evidence_snapshots, [:provider]))
  end
end
