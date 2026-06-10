defmodule Ecrits.Local.IndexStore do
  @moduledoc """
  Ephemeral named index compatibility API.
  """

  @doc """
  Store one named index.
  """
  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(_root, name, index) when is_binary(name) and is_map(index) do
    _record = Map.put(index, "name", name)
    :ok
  end

  @doc """
  Fetch one named index.
  """
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(_root, name) when is_binary(name), do: {:error, :not_found}
end
