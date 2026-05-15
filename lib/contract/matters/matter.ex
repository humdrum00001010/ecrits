defmodule Contract.Matters.Matter do
  @moduledoc """
  Ecto schema for a Matter.

  A Matter is the unit of scope that holds documents, evidence, and agent
  runs for a single client engagement (SPEC.md §3 / §15). It owns the
  ACL boundary: every Document, Change, and FieldLineage belongs to a
  Matter, and `Contract.Matters` is the only module that gates
  visibility based on `Context.tenant`/`Context.user.id`.

  ## Fields

    * `:name` — display name. Required.
    * `:status` — `:active` (default) or `:archived`. Archived matters
      are filtered out of `list_for_scope/1` but remain fetchable via
      `get/2`.
    * `:tenant_id` — nullable. When `nil`, the matter is "single-tenant"
      and any scope can read it. When set, it MUST match the scope's
      `tenant` for the ACL gate to pass.
    * `:owner_id` — the user who created the matter. Required. Only the
      owner can archive the matter (SPEC.md §15 ACL invariant).
    * `:metadata` — free-form JSONB. The schema does not validate shape.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "matters" do
    field :name, :string
    field :status, Ecto.Enum, values: [:active, :archived], default: :active
    field :tenant_id, :binary_id
    field :owner_id, :binary_id
    field :metadata, :map, default: %{}
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc """
  Build a changeset for inserting or updating a Matter.

  `:name` and `:owner_id` are required on insert. `:status`,
  `:tenant_id`, and `:metadata` are optional.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(matter, attrs) do
    matter
    |> cast(attrs, [:name, :status, :tenant_id, :owner_id, :metadata])
    |> validate_required([:name, :owner_id])
    |> validate_length(:name, min: 1, max: 200)
  end
end
