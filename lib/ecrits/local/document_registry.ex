defmodule Ecrits.Local.DocumentRegistry do
  @moduledoc """
  Ephemeral document registry compatibility API.
  """

  @doc """
  Insert or replace one document record.
  """
  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(_root, document_id, attrs) when is_binary(document_id) and is_map(attrs) do
    _record = Map.put(attrs, "id", document_id)
    :ok
  end

  @doc """
  Fetch one document record.
  """
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(_root, document_id) when is_binary(document_id), do: {:error, :not_found}

  @doc """
  List document records sorted by id.
  """
  @spec list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(_root), do: {:ok, []}
end
