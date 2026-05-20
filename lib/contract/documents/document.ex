defmodule Contract.Documents.Document do
  @moduledoc """
  Ecto schema for a Document.

  A Document is the primary user-facing object in Contract Studio
  (SPEC.md v0.5 §7.1). It is owned by a single user via `:owner_id`;
  the Matter container is gone in v1.

  ## Untyped documents (SPEC.md §18)

  `type_key` is nullable: per SPEC.md §18 the contract type is set
  AFTER the document is created — either by the user via Cmd+K or by
  the agent once it has read enough of the document. A freshly-created
  document therefore has `type_key: nil`; `Command(:set_contract_type)`
  fills it in later.

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
    field :owner_id, :binary_id
    field :title, :string
    field :type_key, :string
    belongs_to :document_type, Contract.ContractTypes.DocumentType

    field :status, Ecto.Enum,
      values: [:draft, :importing, :editing, :reviewing, :export_ready, :archived],
      default: :draft

    field :parent_document_id, :binary_id
    field :variant_of_change_id, :binary_id
    field :latest_revision, :integer, default: 0
    field :metadata, :map, default: %{}

    # SPEC.md v0.5 §7.1 — state_snapshot is the materialized document
    # state at :current_revision.
    field :state_snapshot, :map, default: %{}
    field :current_revision, :integer, default: 0
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Changeset for inserting or updating a document.

  `:owner_id` and `:title` are required on insert. `:owner_id` is derived
  from `ctx.user.id` by the Documents context. `:type_key` is
  optional — SPEC.md §18 sets it later via `Command(:set_contract_type)`.

  v0.5: `:matter_id` is silently dropped from `attrs` if present —
  Matter is gone in the product model.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(document, attrs) do
    document
    |> cast(attrs, [
      :owner_id,
      :title,
      :type_key,
      :document_type_id,
      :status,
      :parent_document_id,
      :variant_of_change_id,
      :latest_revision,
      :metadata,
      :state_snapshot,
      :current_revision
    ])
    |> validate_required([:owner_id, :title])
    |> validate_length(:title, min: 1, max: 300)
    |> foreign_key_constraint(:document_type_id)
  end
end
