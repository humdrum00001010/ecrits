defmodule Contract.Local.OperationLog do
  @moduledoc """
  Append-only operation log in `.contract/operations`.
  """

  alias Contract.Local.Metadata

  @doc """
  Append one operation event.
  """
  @spec append(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def append(root, document_id, event) when is_binary(document_id) and is_map(event) do
    Metadata.append_jsonl(
      root,
      operation_path(document_id),
      Map.put(event, "document_id", document_id)
    )
  end

  @doc """
  Read operation events for one document.
  """
  @spec list(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(root, document_id) when is_binary(document_id) do
    Metadata.read_jsonl(root, operation_path(document_id))
  end

  defp operation_path(document_id) do
    Path.join("operations", "#{document_id}.jsonl")
  end
end
