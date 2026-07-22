defmodule Ecrits.AcpAgent.Content.Media do
  @moduledoc "Typed ACP image or audio input block."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.AcpAgent.Content.Block

  @primary_key false
  @fields [:type, :mime_type, :data, :uri]

  embedded_schema do
    field :type, Ecto.Enum, values: [:image, :audio]
    field :mime_type, :string
    field :data, :string
    field :uri, :string
  end

  @type t :: %__MODULE__{}

  def cast(attrs) do
    %__MODULE__{}
    |> cast(Block.params(attrs, @fields), @fields, empty_values: [])
    |> validate_required([:type])
    |> validate_payload()
    |> apply_action(:insert)
  end

  def dump(%__MODULE__{data: data, mime_type: mime_type} = block)
      when is_binary(data) and data != "" and is_binary(mime_type) and mime_type != "" do
    Block.dump_fields(block, @fields)
  end

  def dump(%__MODULE__{} = block), do: Block.dump_fields(block, [:type, :uri, :mime_type])

  defp validate_payload(changeset) do
    data = get_field(changeset, :data)
    mime_type = get_field(changeset, :mime_type)
    uri = get_field(changeset, :uri)

    if present?(uri) or (present?(data) and present?(mime_type)) do
      changeset
    else
      add_error(changeset, :data, "requires mime_type or a non-empty uri")
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
