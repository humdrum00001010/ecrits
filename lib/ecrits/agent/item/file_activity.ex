defmodule Ecrits.Agent.Item.FileActivity do
  @moduledoc "Typed file-operation transcript item."

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
    :file_operation_id,
    :tool_call_id,
    :operation,
    :name,
    :kind,
    :input,
    :output,
    :turn_id,
    :path,
    :relative_path,
    :query
  ]

  embedded_schema do
    field :role, Ecto.Enum, values: [:file_activity]
    field :status, Ecto.Enum, values: @statuses
    field :body, :any, virtual: true
    field :reason, :string
    field :file_operation_id, :string
    field :tool_call_id, :string
    field :operation, :string
    field :name, :string
    field :kind, :string
    field :input, :any, virtual: true
    field :output, :any, virtual: true
    field :turn_id, :string
    field :path, :string
    field :relative_path, :string
    field :query, :string
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
    |> validate_required([:role, :file_operation_id, :operation])
    |> apply_action(:insert)
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = item), do: Item.dump_fields(item, @fields)
end
