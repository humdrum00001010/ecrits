defmodule Ecrits.AcpAgent.Content.DocumentRef do
  @moduledoc "Typed reference to a workspace document."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.AcpAgent.Content.Block

  @primary_key false
  @fields [:type, :document_id, :ref]

  embedded_schema do
    field :type, Ecto.Enum, values: [:doc_ref]
    field :document_id, :string
    field :ref, :string
  end

  @type t :: %__MODULE__{}

  def cast(attrs) do
    %__MODULE__{}
    |> cast(Block.params(attrs, @fields), @fields, empty_values: [])
    |> validate_required([:type, :document_id])
    |> apply_action(:insert)
  end

  def dump(%__MODULE__{} = block), do: Block.dump_fields(block, @fields)
end
