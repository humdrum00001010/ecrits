defmodule Contract.Documents.Document do
  @moduledoc """
  Ecto schema for a Document.

  A Document is the unit a Studio user edits. It belongs to a Matter
  (the ACL boundary) and references a contract type from
  `Contract.ContractTypes` via `type_key`.

  ## Variants

  When `Contract.Conversion.create_variant/2` produces a derived document
  from a source, the new row carries:

    * `:parent_document_id` — the source document.
    * `:variant_of_change_id` — the `:create_converted_variant` Change
      that spawned this variant.

  Lineage of individual fields is recorded in
  `Contract.Documents.FieldLineage`, NOT here.

  ## latest_revision

  Mirrors the highest `applied_revision` of any active Change for this
  document. `Contract.Store.append/3` calls
  `Contract.Documents.touch_revision/2` after each commit to keep this
  field in sync. It is advisory — `Store.latest_revision/1` is still the
  source of truth, this column is for cheap UI queries (e.g. dashboard
  lists).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "documents" do
    field :matter_id, :binary_id
    field :title, :string
    field :type_key, :string
    field :status, Ecto.Enum, values: [:active, :archived, :template], default: :active
    field :parent_document_id, :binary_id
    field :variant_of_change_id, :binary_id
    field :latest_revision, :integer, default: 0
    field :metadata, :map, default: %{}
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Changeset for inserting or updating a document.

  `:matter_id`, `:title`, and `:type_key` are required on insert.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :matter_id,
      :title,
      :type_key,
      :status,
      :parent_document_id,
      :variant_of_change_id,
      :latest_revision,
      :metadata
    ])
    |> validate_required([:matter_id, :title, :type_key])
    |> validate_length(:title, min: 1, max: 300)
  end
end
