defmodule Ecrits.Local.SnapshotStore do
  @moduledoc """
  Ephemeral snapshot and pre-save checkpoint compatibility API.
  """

  alias Ecrits.Local.FS
  alias Ecrits.Local.Metadata
  alias Ecrits.Local.Path, as: LocalPath

  @doc """
  Store a document snapshot.
  """
  @spec put(String.t(), String.t(), term(), map(), map()) :: :ok | {:error, term()}
  def put(_root, document_id, snapshot_id, projection, attrs \\ %{})
      when is_binary(document_id) and not is_nil(snapshot_id) and
             is_map(projection) and
             is_map(attrs) do
    _record =
      attrs
      |> Map.put("document_id", document_id)
      |> Map.put("snapshot_id", snapshot_id)
      |> Map.put("projection", projection)

    :ok
  end

  @doc """
  Fetch one snapshot.
  """
  @spec get(String.t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def get(_root, document_id, snapshot_id)
      when is_binary(document_id) and not is_nil(snapshot_id),
      do: {:error, :not_found}

  @doc """
  List snapshots for one document.
  """
  @spec list(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(_root, document_id) when is_binary(document_id), do: {:ok, []}

  @doc """
  Fetch latest snapshot for one document.
  """
  @spec latest(String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def latest(root, document_id) when is_binary(document_id) do
    with {:ok, snapshots} <- list(root, document_id) do
      {:ok, List.last(snapshots)}
    end
  end

  @doc """
  Save current workspace file contents before an overwrite.
  """
  @spec checkpoint(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def checkpoint(root, relative_path, attrs \\ %{})
      when is_binary(relative_path) and is_map(attrs) do
    with {:ok, normalized} <- LocalPath.normalize(relative_path),
         {:ok, contents} <- FS.read(root, normalized) do
      id = checkpoint_id()

      record =
        attrs
        |> Map.put("id", id)
        |> Map.put("path", normalized)
        |> Map.put("content_encoding", "base64")
        |> Map.put("content", Base.encode64(contents))
        |> Map.put("byte_size", byte_size(contents))

      {:ok, Metadata.envelope(record)}
    end
  end

  @doc """
  List checkpoints for a workspace file.
  """
  @spec list_checkpoints(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_checkpoints(_root, relative_path) when is_binary(relative_path), do: {:ok, []}

  defp checkpoint_id do
    system_ms = System.system_time(:millisecond)
    unique = System.unique_integer([:positive, :monotonic])
    "#{system_ms}-#{unique}"
  end
end
