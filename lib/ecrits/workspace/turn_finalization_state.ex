defmodule Ecrits.Workspace.TurnFinalizationState do
  @moduledoc "Typed runtime state for serialized workspace turn finalization."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.Workspace.TurnFinalizationState.Active

  @primary_key false
  @fields [:finalizations, :order, :queue, :waiters]

  embedded_schema do
    field :finalizations, :any, virtual: true, default: %{}
    field :order, :any, virtual: true, default: []
    field :queue, :any, virtual: true, default: []
    field :waiters, :any, virtual: true, default: %{}
    embeds_one :active, Active, on_replace: :update
  end

  @type t :: %__MODULE__{}

  @spec cast(map() | t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(%__MODULE__{} = state), do: state |> Map.from_struct() |> cast()

  def cast(attrs) when is_map(attrs) do
    normalized = normalize_collections(attrs)

    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.cast(normalized, @fields, empty_values: [])
      |> validate_change(:waiters, &validate_waiters/2)
      |> cast_active(attrs)

    apply_action(changeset, :insert)
  end

  def cast(_attrs), do: cast(%{})

  @spec cast!(map() | t()) :: t()
  def cast!(attrs) do
    case cast(attrs) do
      {:ok, state} ->
        state

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp normalize_collections(attrs) do
    finalizations = attrs |> value(:finalizations, %{}) |> valid_finalizations()

    %{
      finalizations: finalizations,
      order: attrs |> value(:order, []) |> valid_keys(finalizations),
      queue: attrs |> value(:queue, []) |> valid_keys(finalizations),
      waiters: attrs |> value(:waiters, %{}) |> valid_waiters(finalizations)
    }
  end

  defp valid_finalizations(finalizations) when is_map(finalizations) do
    finalizations
    |> Enum.filter(fn {key, entry} -> valid_key?(key) and is_map(entry) end)
    |> Map.new()
  end

  defp valid_finalizations(_finalizations), do: %{}

  defp valid_keys(keys, finalizations) when is_list(keys) do
    keys
    |> Enum.filter(&(valid_key?(&1) and Map.has_key?(finalizations, &1)))
    |> Enum.uniq()
  end

  defp valid_keys(_keys, _finalizations), do: []

  defp valid_waiters(waiters, finalizations) when is_map(waiters) do
    waiters
    |> Enum.filter(fn {key, _pids} -> valid_key?(key) and Map.has_key?(finalizations, key) end)
    |> Map.new(fn {key, pids} -> {key, waiter_set(pids)} end)
  end

  defp valid_waiters(_waiters, _finalizations), do: %{}

  defp waiter_set(%MapSet{} = waiters), do: waiters
  defp waiter_set(waiters) when is_list(waiters), do: MapSet.new(waiters)
  defp waiter_set(waiter) when is_pid(waiter), do: MapSet.new([waiter])
  defp waiter_set(_waiters), do: MapSet.new([:invalid])

  defp validate_waiters(:waiters, waiters) do
    if Enum.all?(waiters, fn {_key, pids} -> Enum.all?(pids, &is_pid/1) end) do
      []
    else
      [waiters: "must contain only process ids"]
    end
  end

  defp cast_active(changeset, attrs) do
    case fetch(attrs, :active) do
      :error -> changeset
      {:ok, nil} -> changeset
      {:ok, active} -> put_cast_active(changeset, Active.cast(active))
    end
  end

  defp put_cast_active(changeset, {:ok, active}), do: put_embed(changeset, :active, active)

  defp put_cast_active(changeset, {:error, _active}),
    do: add_error(changeset, :active, "is invalid")

  defp valid_key?({agent_id, instance_id, turn_id}) do
    Enum.all?([agent_id, instance_id, turn_id], &(is_binary(&1) and &1 != ""))
  end

  defp valid_key?(_key), do: false

  defp value(attrs, key, default) do
    case fetch(attrs, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end
end
