defmodule Contract.Local.DocumentRegistry do
  @moduledoc """
  Document metadata registry in `.contract/documents`.
  """

  alias Contract.Local.Metadata
  alias Contract.Local.Path, as: LocalPath

  @doc """
  Insert or replace one document record.
  """
  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(root, document_id, attrs) when is_binary(document_id) and is_map(attrs) do
    Metadata.write_json(root, document_path(document_id), Map.put(attrs, "id", document_id))
  end

  @doc """
  Fetch one document record.
  """
  @spec get(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def get(root, document_id) when is_binary(document_id) do
    Metadata.read_json(root, document_path(document_id))
  end

  @doc """
  List document records sorted by id.
  """
  @spec list(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(root) do
    with {:ok, dir} <- LocalPath.metadata_join(root, "documents") do
      if File.exists?(dir) do
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
          case Metadata.read_json(root, Path.join("documents", file)) do
            {:ok, record} -> {:cont, {:ok, [record | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, records} -> {:ok, Enum.reverse(records)}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, []}
      end
    end
  end

  defp document_path(document_id) do
    Path.join("documents", "#{document_id}.json")
  end
end
