defmodule Ecrits.Agent.Item.Text do
  @moduledoc "Typed user, agent, and thinking transcript text."

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
  @fields [:role, :status, :body, :reason, :segment, :turn_id, :name, :title, :picks]

  embedded_schema do
    field :role, Ecto.Enum, values: [:user, :agent, :thinking]
    field :status, Ecto.Enum, values: @statuses
    field :body, :string
    field :reason, :string
    field :segment, :integer
    field :turn_id, :string
    field :name, :string
    field :title, :string
    field :picks, :any, virtual: true
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
    |> validate_required([:role])
    |> apply_action(:insert)
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = item), do: Item.dump_fields(item, @fields)
end
