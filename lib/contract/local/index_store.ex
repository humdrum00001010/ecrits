defmodule Contract.Local.IndexStore do
  @moduledoc """
  Named local index storage in `.contract/indexes`.
  """

  alias Contract.Local.Metadata

  @doc """
  Store one named index.
  """
  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(root, name, index) when is_binary(name) and is_map(index) do
    Metadata.write_json(root, index_path(name), Map.put(index, "name", name))
  end

  @doc """
  Fetch one named index.
  """
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(root, name) when is_binary(name) do
    Metadata.read_json(root, index_path(name))
  end

  defp index_path(name) do
    Path.join("indexes", "#{name}.json")
  end
end
