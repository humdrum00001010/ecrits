defmodule Contract.Documents.FieldLineage do
  @moduledoc """
  Append-only schema recording per-field provenance across
  type-conversion variants (SPEC.md §19 + invariant 14).

  Inserted by `Contract.Conversion.create_variant/2` for every field
  whose strategy preserved data (`:copy_once`, `:link_to_matter_field`,
  `:derive`, or `:reference_only`). Ignored / asked-user fields produce
  no row.

  Updates are deliberately not supported — lineage rows are immutable
  audit. Only inserts and reads via `Contract.Documents.list_lineage/2`
  / `Contract.Documents.get_lineage_for_field/3`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `field_id` / `source_field_id` are TypeSpec field ids (e.g.
  # "effective_date") — string keys, not UUIDs. The document_id columns
  # are UUIDs because they reference the documents.id PK.
  schema "field_lineages" do
    field :document_id, :binary_id
    field :field_id, :string
    field :source_document_id, :binary_id
    field :source_field_id, :string

    field :strategy, Ecto.Enum,
      values: [:copy_once, :link_to_matter_field, :derive, :reference_only]

    field :justification, :string
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Changeset for inserting a new lineage row. `:document_id`,
  `:field_id`, and `:strategy` are required.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(lineage, attrs) do
    lineage
    |> cast(attrs, [
      :document_id,
      :field_id,
      :source_document_id,
      :source_field_id,
      :strategy,
      :justification
    ])
    |> validate_required([:document_id, :field_id, :strategy])
  end
end
