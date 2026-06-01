defmodule Contract.RhwpSnapshot.Record do
  @moduledoc """
  Legacy hosted RHWP visual snapshot row.

  Runtime state snapshots stay in `Contract.Snapshot`. This schema is only
  retained for old DB-backed hosted state; active local HWP/HWPX snapshots
  live under `.contract`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  @foreign_key_type :binary_id

  schema "rhwp_snapshots" do
    field :document_id, :binary_id, primary_key: true
    field :revision, :integer, primary_key: true
    field :format, :string
    field :content_type, :string
    field :r2_key, :string
    field :ir_r2_key, :string
    field :projection, :map

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(record, attrs) do
    record
    |> cast(attrs, [
      :document_id,
      :revision,
      :format,
      :content_type,
      :r2_key,
      :ir_r2_key,
      :projection
    ])
    |> validate_required([
      :document_id,
      :revision,
      :format,
      :content_type,
      :r2_key,
      :ir_r2_key,
      :projection
    ])
    |> validate_inclusion(:format, ["hwp", "hwpx"])
    |> validate_number(:revision, greater_than_or_equal_to: 0)
  end
end
