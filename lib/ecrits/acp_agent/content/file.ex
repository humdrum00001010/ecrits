defmodule Ecrits.AcpAgent.Content.File do
  @moduledoc "Typed ACP file resource block."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.AcpAgent.Content.Block

  @primary_key false
  @fields [:type, :uri, :name, :mime_type]

  embedded_schema do
    field :type, Ecto.Enum, values: [:file]
    field :uri, :string
    field :name, :string
    field :mime_type, :string
  end

  @type t :: %__MODULE__{}

  def cast(attrs) do
    %__MODULE__{}
    |> cast(Block.params(attrs, @fields), @fields, empty_values: [])
    |> validate_required([:type, :uri])
    |> apply_action(:insert)
  end

  def dump(%__MODULE__{} = block), do: Block.dump_fields(block, @fields)
end
