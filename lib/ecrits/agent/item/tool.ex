defmodule Ecrits.Agent.Item.Tool do
  @moduledoc "Typed tool-call transcript item."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.Agent.Item

  @primary_key false
  @statuses [
    :pending,
    :running,
    :queued,
    :sent,
    :completed,
    :failed,
    :cancelled,
    :approval_required
  ]
  @fields [
    :role,
    :status,
    :body,
    :reason,
    :tool_call_id,
    :name,
    :title,
    :kind,
    :input,
    :output,
    :turn_id
  ]

  embedded_schema do
    field :role, Ecto.Enum, values: [:tool]
    field :status, Ecto.Enum, values: @statuses
    field :body, :any, virtual: true
    field :reason, :string
    field :tool_call_id, :string
    field :name, :string
    field :title, :string
    field :kind, :string
    field :input, :any, virtual: true
    field :output, :any, virtual: true
    field :turn_id, :string
    field :extensions, :map, virtual: true, default: %{}
    field :present_fields, :any, virtual: true, default: []
  end

  @type t :: %__MODULE__{}

  @spec cast(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(attrs) do
    %__MODULE__{}
    |> cast(Item.params(attrs, @fields), @fields ++ [:extensions, :present_fields],
      empty_values: []
    )
    |> validate_required([:role, :name])
    |> apply_action(:insert)
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = item), do: Item.dump_fields(item, @fields)
end
