defmodule Ecrits.Metadata do
  @moduledoc """
  In-memory metadata helpers for local document snapshots and mutation records.
  """

  @schema_version 1

  @doc """
  Add schema metadata to a record.
  """
  @spec envelope(map()) :: map()
  def envelope(record) when is_map(record) do
    record
    |> stringify_keys()
    |> Map.put("schema_version", @schema_version)
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
