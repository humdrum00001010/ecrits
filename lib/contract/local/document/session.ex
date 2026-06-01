defmodule Contract.Local.Document.Session do
  @moduledoc """
  Active local document session backed by one workspace file.

  The session owns current bytes and revision metadata for a local document.
  Saves replace the canonical workspace file atomically; checkpoints only write
  `.contract` metadata.
  """

  use GenServer

  alias Contract.Local.Document
  alias Contract.Local.DocumentRegistry
  alias Contract.Local.Metadata
  alias Contract.Local.SnapshotStore

  @registry Contract.Local.Document.Registry

  def start_link(args) do
    document_id = Keyword.fetch!(args, :id)
    GenServer.start_link(__MODULE__, args, name: via(document_id))
  end

  def child_spec(args) do
    %{
      id: {__MODULE__, Keyword.fetch!(args, :id)},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def document(target), do: call(target, :document)
  def read(target), do: call(target, :read)
  def checkpoint(target, bytes, attrs \\ %{}), do: call(target, {:checkpoint, bytes, attrs})
  def save(target, bytes, attrs \\ %{}), do: call(target, {:save, bytes, attrs})
  def record_mutation(target, envelope), do: call(target, {:record_mutation, envelope})

  def close(target) do
    target
    |> resolve()
    |> case do
      pid when is_pid(pid) ->
        result = GenServer.stop(pid, :normal)
        _ = :sys.get_state(@registry)
        result

      nil ->
        {:error, :not_found}
    end
  end

  def whereis(document_id) when is_binary(document_id) do
    case Registry.lookup(@registry, document_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def whereis(_document_id), do: nil

  @impl true
  def init(args) do
    path = Keyword.fetch!(args, :path)

    with {:ok, bytes} <- File.read(path),
         {:ok, metadata} <- load_metadata(args) do
      document = Document.build(args, bytes, metadata.saved_revision)
      :ok = ensure_metadata(document, bytes, metadata)

      {:ok,
       %{
         args: args,
         document: document,
         bytes: bytes,
         latest_revision: metadata.latest_revision,
         saved_revision: metadata.saved_revision,
         snapshots: metadata.snapshots
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:document, _from, state) do
    {:reply, {:ok, state.document}, state}
  end

  def handle_call(:read, _from, state) do
    {:reply, {:ok, state.bytes}, state}
  end

  def handle_call({:checkpoint, bytes, attrs}, _from, state) when is_binary(bytes) do
    persist_snapshot(state, bytes, attrs, write_canonical?: false)
  end

  def handle_call({:checkpoint, _bytes, _attrs}, _from, state) do
    {:reply, {:error, :invalid_bytes}, state}
  end

  def handle_call({:save, bytes, attrs}, _from, state) when is_binary(bytes) do
    with :ok <-
           Contract.Local.FS.write(
             state.document.workspace_root,
             state.document.relative_path,
             bytes
           ) do
      persist_snapshot(state, bytes, attrs, write_canonical?: true)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:save, _bytes, _attrs}, _from, state) do
    {:reply, {:error, :invalid_bytes}, state}
  end

  def handle_call({:record_mutation, envelope}, _from, state) when is_map(envelope) do
    record = mutation_record(state.document, envelope)

    case Metadata.append_jsonl(
           state.document.workspace_root,
           mutation_log_path(state.document.id),
           record
         ) do
      :ok -> {:reply, {:ok, record}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_mutation, _envelope}, _from, state) do
    {:reply, {:error, :invalid_mutation}, state}
  end

  defp persist_snapshot(state, bytes, attrs, opts) do
    revision = state.latest_revision + 1
    saved? = Keyword.fetch!(opts, :write_canonical?)
    attrs = attrs |> Map.new() |> Map.put("kind", snapshot_kind(opts))
    projection = bytes_projection(bytes)
    snapshot = snapshot_record(state.document, bytes, revision, saved?, attrs)

    case persist_snapshot_files(state.document, bytes, revision, projection, attrs, snapshot) do
      :ok ->
        current_bytes = current_bytes(state, bytes, opts)
        document = Document.build(state.args, current_bytes, revision)
        snapshot = Metadata.envelope(snapshot)
        saved_revision = if saved?, do: revision, else: state.saved_revision
        snapshots = state.snapshots ++ [snapshot_summary(snapshot)]

        write_index(document, current_bytes, revision, saved_revision, snapshots)
        write_context(document, snapshot_context(attrs))

        state = %{
          state
          | document: document,
            bytes: current_bytes,
            latest_revision: revision,
            saved_revision: saved_revision,
            snapshots: snapshots
        }

        publish(document, snapshot)
        {:reply, {:ok, document, snapshot}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp call(target, message) do
    target
    |> resolve()
    |> case do
      pid when is_pid(pid) -> GenServer.call(pid, message)
      nil -> {:error, :not_found}
    end
  end

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(%Document{id: document_id}), do: whereis(document_id)
  defp resolve(document_id) when is_binary(document_id), do: whereis(document_id)
  defp resolve(_target), do: nil

  defp load_metadata(args) do
    root = Keyword.fetch!(args, :workspace_root)
    document_id = Keyword.fetch!(args, :id)

    case read_first_json(root, index_paths(document_id)) do
      {:ok, index} ->
        {:ok,
         %{
           latest_revision: int(index["latest_revision"]),
           saved_revision: int(index["saved_revision"]),
           snapshots: index["snapshots"] || []
         }}

      {:error, :not_found} ->
        {:ok, %{latest_revision: 0, saved_revision: 0, snapshots: []}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bytes_projection(bytes) do
    %{
      "content_encoding" => "base64",
      "content" => Base.encode64(bytes),
      "byte_size" => byte_size(bytes),
      "sha256" => Document.sha256(bytes)
    }
  end

  defp ensure_metadata(document, bytes, metadata) do
    paths = Document.metadata_paths(document)

    with :ok <- File.mkdir_p(paths.snapshots),
         :ok <-
           write_index(
             document,
             bytes,
             metadata.latest_revision,
             metadata.saved_revision,
             metadata.snapshots
           ),
         :ok <- ensure_context(document) do
      :ok
    end
  end

  defp write_index(document, bytes, latest_revision, saved_revision, snapshots) do
    index = %{
      "doc_id" => document.id,
      "relative_path" => document.relative_path,
      "format" => document.format,
      "latest_revision" => latest_revision,
      "saved_revision" => saved_revision,
      "canonical" => %{
        "path" => document.relative_path,
        "sha256" => Document.sha256(bytes),
        "byte_size" => byte_size(bytes)
      },
      "snapshots" => snapshots
    }

    with :ok <- write_all_json(document.workspace_root, index_paths(document.id), index) do
      DocumentRegistry.put(document.workspace_root, document.id, %{
        "path" => document.relative_path,
        "format" => document.format,
        "revision" => saved_revision,
        "latest_revision" => latest_revision,
        "sha256" => Document.sha256(bytes),
        "byte_size" => byte_size(bytes)
      })
    end
  end

  defp ensure_context(document) do
    case read_first_json(document.workspace_root, context_paths(document.id)) do
      {:ok, _context} -> :ok
      {:error, :not_found} -> write_context(document, %{})
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_context(document, context) do
    write_all_json(document.workspace_root, context_paths(document.id), %{
      "doc_id" => document.id,
      "context" => context || %{}
    })
  end

  defp persist_snapshot_files(document, bytes, revision, projection, attrs, snapshot) do
    path = Path.join(document.workspace_root, snapshot["path"])

    with :ok <- Contract.Local.FS.atomic_write(path, bytes),
         :ok <-
           SnapshotStore.put(
             document.workspace_root,
             document.id,
             revision,
             projection,
             attrs
           ) do
      :ok
    end
  end

  defp snapshot_record(document, bytes, revision, saved?, attrs) do
    attrs
    |> Map.new()
    |> Map.merge(%{
      "revision" => revision,
      "saved" => saved?,
      "path" => snapshot_relative_path(document, revision),
      "byte_size" => byte_size(bytes),
      "sha256" => Document.sha256(bytes)
    })
  end

  defp snapshot_summary(snapshot) do
    %{
      "revision" => snapshot["revision"],
      "saved" => snapshot["saved"],
      "path" => snapshot["path"],
      "sha256" => snapshot["sha256"]
    }
  end

  defp snapshot_context(attrs) do
    Map.get(attrs, :context) || Map.get(attrs, "context") || Map.get(attrs, :ir) ||
      Map.get(attrs, "ir") || %{}
  end

  defp mutation_record(%Document{} = document, envelope) do
    %{
      "document_id" => document.id,
      "relative_path" => document.relative_path,
      "revision" => document.revision,
      "event_id" => string_param(envelope, "eventId", "event_id"),
      "site_id" => string_param(envelope, "siteId", "site_id"),
      "lamport" => integer_param(envelope, "lamport"),
      "body" => map_param(envelope, "body"),
      "received_at_ms" => System.system_time(:millisecond)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp string_param(envelope, primary, fallback) do
    case Map.get(envelope, primary) || Map.get(envelope, fallback) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp integer_param(envelope, key) do
    case Map.get(envelope, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> nil
        end

      _value ->
        nil
    end
  end

  defp map_param(envelope, key) do
    case Map.get(envelope, key) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end

  defp current_bytes(_state, bytes, write_canonical?: true), do: bytes
  defp current_bytes(state, _bytes, write_canonical?: false), do: state.bytes

  defp snapshot_kind(write_canonical?: true), do: "save"
  defp snapshot_kind(write_canonical?: false), do: "checkpoint"

  defp publish(document, %{"saved" => true} = snapshot) do
    Phoenix.PubSub.broadcast(Contract.PubSub, Document.topic(document.id), {
      :local_document_saved,
      document,
      snapshot
    })
  end

  defp publish(document, snapshot) do
    Phoenix.PubSub.broadcast(Contract.PubSub, Document.topic(document.id), {
      :local_document_checkpointed,
      document,
      snapshot
    })
  end

  defp via(document_id), do: {:via, Registry, {@registry, document_id}}

  defp int(value) when is_integer(value) and value >= 0, do: value
  defp int(_value), do: 0

  defp index_paths(document_id) do
    [
      Path.join(["indexes", "document-#{document_id}.json"]),
      Path.join(["documents", document_id, "index.json"])
    ]
  end

  defp context_paths(document_id) do
    [
      Path.join(["contexts", "#{document_id}.json"]),
      Path.join(["documents", document_id, "context.json"])
    ]
  end

  defp mutation_log_path(document_id),
    do: Path.join(["operations", "document-#{document_id}.jsonl"])

  defp read_first_json(root, paths) do
    Enum.reduce_while(paths, {:error, :not_found}, fn path, _acc ->
      case Metadata.read_json(root, path) do
        {:ok, _} = ok -> {:halt, ok}
        {:error, :not_found} -> {:cont, {:error, :not_found}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_all_json(root, paths, record) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case Metadata.write_json(root, path, record) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp snapshot_relative_path(document, revision) do
    document
    |> Document.metadata_paths()
    |> Map.fetch!(:snapshots)
    |> Path.join("#{revision}.#{document.format}")
    |> Path.relative_to(document.workspace_root)
  end
end
