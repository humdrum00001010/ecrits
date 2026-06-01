defmodule Contract.Local.SnapshotStore do
  @moduledoc """
  Local snapshot and pre-save checkpoint storage.
  """

  alias Contract.Local.FS
  alias Contract.Local.Metadata
  alias Contract.Local.Path, as: LocalPath

  @doc """
  Store a document snapshot.
  """
  @spec put(String.t(), String.t(), non_neg_integer(), map(), map()) :: :ok | {:error, term()}
  def put(root, document_id, revision, projection, attrs \\ %{})
      when is_binary(document_id) and is_integer(revision) and revision >= 0 and
             is_map(projection) and
             is_map(attrs) do
    record =
      attrs
      |> Map.put("document_id", document_id)
      |> Map.put("revision", revision)
      |> Map.put("projection", projection)

    Metadata.write_json(root, snapshot_path(document_id, revision), record)
  end

  @doc """
  Fetch one snapshot.
  """
  @spec get(String.t(), String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  def get(root, document_id, revision) when is_binary(document_id) and is_integer(revision) do
    Metadata.read_json(root, snapshot_path(document_id, revision))
  end

  @doc """
  List snapshots for one document sorted by revision.
  """
  @spec list(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(root, document_id) when is_binary(document_id) do
    with {:ok, dir} <- LocalPath.metadata_join(root, Path.join("snapshots", document_id)) do
      if File.exists?(dir) do
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort_by(&revision_from_file/1)
        |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
          revision = revision_from_file(file)

          case get(root, document_id, revision) do
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
      encoded_path = Base.url_encode64(normalized, padding: false)

      record =
        attrs
        |> Map.put("id", id)
        |> Map.put("path", normalized)
        |> Map.put("content_encoding", "base64")
        |> Map.put("content", Base.encode64(contents))
        |> Map.put("byte_size", byte_size(contents))

      with :ok <- Metadata.write_json(root, checkpoint_path(encoded_path, id), record) do
        {:ok, Metadata.envelope(record)}
      end
    end
  end

  @doc """
  List checkpoints for a workspace file.
  """
  @spec list_checkpoints(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_checkpoints(root, relative_path) when is_binary(relative_path) do
    with {:ok, normalized} <- LocalPath.normalize(relative_path),
         {:ok, dir} <-
           LocalPath.metadata_join(
             root,
             Path.join("checkpoints", Base.url_encode64(normalized, padding: false))
           ) do
      if File.exists?(dir) do
        dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
          case Metadata.read_json(
                 root,
                 Path.join(["checkpoints", Base.url_encode64(normalized, padding: false), file])
               ) do
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

  defp snapshot_path(document_id, revision) do
    Path.join(["snapshots", document_id, "#{revision}.json"])
  end

  defp checkpoint_path(encoded_path, id) do
    Path.join(["checkpoints", encoded_path, "#{id}.json"])
  end

  defp revision_from_file(file) do
    file
    |> Path.rootname()
    |> String.to_integer()
  end

  defp checkpoint_id do
    system_ms = System.system_time(:millisecond)
    unique = System.unique_integer([:positive, :monotonic])
    "#{system_ms}-#{unique}"
  end
end
