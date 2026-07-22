defmodule Ecrits.Workspace.TurnFinalizationState.Active do
  @moduledoc "Runtime process record for the currently executing workspace finalization."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields [:key, :pid, :ref, :attempts]

  embedded_schema do
    field :key, :any, virtual: true
    field :pid, :any, virtual: true
    field :ref, :any, virtual: true
    field :attempts, :integer, default: 0
  end

  @type t :: %__MODULE__{}

  @spec cast(map() | t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(%__MODULE__{} = active), do: active |> Map.from_struct() |> cast()

  def cast(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> Ecto.Changeset.cast(take_fields(attrs), @fields, empty_values: [])
    |> validate_required([:key, :pid, :ref, :attempts])
    |> validate_change(:key, &validate_key/2)
    |> validate_change(:pid, &validate_pid/2)
    |> validate_change(:ref, &validate_reference/2)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> apply_action(:insert)
  end

  def cast(_attrs), do: cast(%{})

  @spec cast!(map() | t()) :: t()
  def cast!(attrs) do
    case cast(attrs) do
      {:ok, active} ->
        active

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp take_fields(attrs) do
    Enum.reduce(@fields, %{}, fn field, params ->
      case fetch(attrs, field) do
        {:ok, value} -> Map.put(params, field, value)
        :error -> params
      end
    end)
  end

  defp validate_key(field, value) do
    if valid_key?(value), do: [], else: [{field, "must be an exact agent turn key"}]
  end

  defp validate_pid(field, value), do: if(is_pid(value), do: [], else: [{field, "must be a pid"}])

  defp validate_reference(field, value) do
    if is_reference(value), do: [], else: [{field, "must be a reference"}]
  end

  defp valid_key?({agent_id, instance_id, turn_id}) do
    Enum.all?([agent_id, instance_id, turn_id], &(is_binary(&1) and &1 != ""))
  end

  defp valid_key?(_key), do: false

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end
end
