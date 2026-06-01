defmodule Contract.Repo.Migrations.CreateSourceClaims do
  @moduledoc """
  SPEC.md v0.5 §7.4 — SourceClaim.

  Supervised, correctable interpretation of a SourceDocument region —
  "this looks like the effective date", "this clause appears to be a
  termination clause". User can confirm / correct / reject / link.
  """
  use Ecto.Migration

  def change do
    create_if_not_exists table(:source_claims, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:source_document_id, :binary_id, null: false)

      add(:region_id, :string)
      add(:proposed_kind, :string)
      add(:proposed_value, :text)
      add(:proposed_structured, :map, null: false, default: %{})

      add(:status, :string, null: false, default: "proposed")

      add(:user_value, :text)
      add(:user_structured, :map, null: false, default: %{})

      add(:linked_document_id, :binary_id)
      add(:linked_node_id, :string)

      add(:agent_run_id, :binary_id)
      add(:confidence, :decimal)
      add(:rationale, :text)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:source_claims, [:source_document_id]))
    create_if_not_exists(index(:source_claims, [:status]))
    create_if_not_exists(index(:source_claims, [:linked_document_id]))
  end
end
