defmodule Ecrits.Local.OperationLog do
  @moduledoc """
  Ephemeral operation log compatibility API.
  """

  @doc """
  Append one operation event.
  """
  @spec append(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def append(_root, document_id, event) when is_binary(document_id) and is_map(event) do
    _record = Map.put(event, "document_id", document_id)
    :ok
  end

  @doc """
  Read operation events for one document.
  """
  @spec list(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(_root, document_id) when is_binary(document_id), do: {:ok, []}
end
