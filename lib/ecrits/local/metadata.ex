defmodule Ecrits.Local.Metadata do
  @moduledoc """
  Retired local metadata boundary.

  The app no longer persists workspace metadata into `.ecrits`. The functions
  remain as compatibility shims for callers that still expect the old API.
  """

  @schema_version 1

  @doc """
  Current local metadata schema version.
  """
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Compatibility no-op. Does not create `.ecrits`.
  """
  @spec ensure(String.t()) :: :ok | {:error, term()}
  def ensure(_root), do: :ok

  @doc """
  Add schema metadata to a record.
  """
  @spec envelope(map()) :: map()
  def envelope(record) when is_map(record) do
    record
    |> stringify_keys()
    |> Map.put("schema_version", @schema_version)
  end

  @doc """
  Compatibility no-op. Does not write `.ecrits`.
  """
  @spec write_json(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def write_json(_root, _relative, record) when is_map(record), do: :ok

  @doc """
  Compatibility read. `.ecrits` is not a persistence source anymore.
  """
  @spec read_json(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_json(_root, _relative), do: {:error, :not_found}

  @doc """
  Compatibility no-op. Does not write `.ecrits`.
  """
  @spec append_jsonl(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def append_jsonl(_root, _relative, record) when is_map(record), do: :ok

  @doc """
  Compatibility read. `.ecrits` is not a persistence source anymore.
  """
  @spec read_jsonl(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def read_jsonl(_root, _relative), do: {:ok, []}

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
