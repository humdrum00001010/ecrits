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
    attrs = canonical_attrs(attrs)

    %__MODULE__{}
    |> cast(Item.params(attrs, @fields), @fields ++ [:extensions, :present_fields],
      empty_values: []
    )
    |> validate_required([:role, :file_operation_id, :operation])
    |> apply_action(:insert)
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = item), do: Item.dump_fields(item, @fields)

  defp canonical_attrs(attrs) do
    operation = field(attrs, :operation) || field(attrs, :name)
    file_operation_id = field(attrs, :file_operation_id) || field(attrs, :tool_call_id)
    input = file_activity_input(attrs)
    path = field(attrs, :path) || field(input, :path)
    query = field(attrs, :query) || field(input, :query)
    reason = failure_reason(attrs)

    attrs
    |> Map.put(:role, :file_activity)
    |> Map.put(:file_operation_id, file_operation_id)
    |> Map.put(:tool_call_id, file_operation_id)
    |> Map.put(:operation, operation)
    |> Map.put(:name, operation)
    |> put_present(:path, path)
    |> put_present(:query, query)
    |> put_present(:reason, reason)
    |> put_present(:body, reason)
  end

  defp file_activity_input(item) do
    [:arguments, :args, :input]
    |> Enum.find_value(%{}, fn key ->
      case decode_map(field(item, key)) do
        map when map != %{} -> map
        _empty -> nil
      end
    end)
  end

  defp decode_map(value) when is_map(value), do: value

  defp decode_map(value) when is_binary(value) do
    value = String.trim(value)

    with {:error, _reason} <- Jason.decode(value),
         [input] <-
           Regex.run(~r/(?:^|\n)Input:\n(.*?)(?:\n\nOutput:|\z)/s, value, capture: :all_but_first),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(String.trim(input)) do
      decoded
    else
      {:ok, decoded} when is_map(decoded) -> decoded
      _invalid -> %{}
    end
  end

  defp decode_map(_value), do: %{}

  defp failure_reason(item) do
    if field(item, :status) in [:failed, "failed"] do
      field(item, :reason) ||
        text(field(item, :output)) ||
        body_output(field(item, :body)) ||
        text(field(item, :body))
    end
  end

  defp body_output(body) when is_binary(body) do
    case Regex.run(~r/(?:^|\n)Output:\n(.*)\z/s, body, capture: :all_but_first) do
      [output] -> text(output)
      _missing -> nil
    end
  end

  defp body_output(_body), do: nil

  defp text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp text(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp text(nil), do: nil
  defp text(value), do: inspect(value)

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
