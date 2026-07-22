defmodule Ecrits.AcpAgent.Content.Text do
  @moduledoc "Typed ACP text input block."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.AcpAgent.Content.Block

  @primary_key false
  @fields [:type, :text]

  embedded_schema do
    field :type, Ecto.Enum, values: [:text]
    field :text, :string
  end

  @type t :: %__MODULE__{}

  def cast(attrs) do
    %__MODULE__{}
    |> cast(Block.params(attrs, @fields), @fields, empty_values: [])
    |> validate_required(@fields)
    |> apply_action(:insert)
  end

  def dump(%__MODULE__{} = block), do: Block.dump_fields(block, @fields)
end
