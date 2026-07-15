defmodule Ecrits.Fuse.OpenDocs do
  @moduledoc """
  Per-workspace registry of documents the agent has explicitly opened for the
  doc VFS (`Ecrits.Fuse.DocFs`). The mount projects exactly this set — a document
  appears under `<workspace>/.ecrits/` only after the agent calls the
  `doc.open_doc` MCP tool, and disappears on `doc.close_doc`.

  Backed by a single public, named ETS set owned by this GenServer (started in
  the supervision tree). Keys are `{canonical_root, name}` where `name` is the
  flat mounted source name. Root-level documents keep their basename; nested
  workspace documents use a flat, collision-safe mount name and carry their real
  `source_path` in metadata. Reads/writes hit ETS directly from any process (the
  VFS handler, the MCP tool) — no GenServer call on the hot path — and degrade to
  empty/no-op if the table is somehow absent.
  """

  use GenServer

  @table :ecrits_fuse_open_docs
  @access_key :__vfs_access__
  @stage_key :__vfs_stage__
  @committed_key :__vfs_committed__

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Register `name` as open under `root`."
  @spec open(String.t(), String.t(), keyword()) :: :ok
  def open(root, name, opts \\ []) do
    root = expand(root)

    unless :ets.member(@table, {root, name}) do
      :ets.delete(@table, {@committed_key, root, name})
    end

    :ets.insert(@table, {{root, name}, open_metadata(opts)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The agent that opened `name` under `root`, when known."
  @spec owner_agent_id(String.t(), String.t()) :: String.t() | nil
  def owner_agent_id(root, name) do
    case :ets.lookup(@table, {expand(root), name}) do
      [{_key, %{agent_id: agent_id}}] when is_binary(agent_id) and agent_id != "" -> agent_id
      [{_key, %{"agent_id" => agent_id}}] when is_binary(agent_id) and agent_id != "" -> agent_id
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "The agent that opened `source_path` under `root`, when known."
  @spec owner_agent_id_for_source(String.t(), String.t()) :: String.t() | nil
  def owner_agent_id_for_source(root, source_path) do
    case name_for_source(root, source_path) do
      {:ok, name} -> owner_agent_id(root, name)
      :error -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Unregister `name` under `root`."
  @spec close(String.t(), String.t()) :: :ok
  def close(root, name) do
    root = expand(root)
    :ets.delete(@table, {root, name})
    :ets.delete(@table, {@stage_key, root, name})
    :ets.delete(@table, {@committed_key, root, name})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "All open document names under `root`."
  @spec list(String.t()) :: [String.t()]
  def list(root) do
    r = expand(root)
    :ets.select(@table, [{{{r, :"$1"}, :_}, [], [:"$1"]}])
  rescue
    ArgumentError -> []
  end

  @doc "The mounted source name for an opened `source_path` under `root`."
  @spec name_for_source(String.t(), String.t()) :: {:ok, String.t()} | :error
  def name_for_source(root, source_path) do
    r = expand(root)
    source = canonical_file_path(source_path)

    @table
    |> :ets.select([{{{r, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.find_value(:error, fn {name, metadata} ->
      if metadata_source_path(r, name, metadata) == source, do: {:ok, name}, else: false
    end)
  rescue
    ArgumentError -> :error
  end

  @doc "The real source path for mounted `name` under `root`."
  @spec source_path(String.t(), String.t()) :: {:ok, String.t()} | :error
  def source_path(root, name) when is_binary(name) do
    r = expand(root)

    case :ets.lookup(@table, {r, name}) do
      [{_key, metadata}] -> {:ok, metadata_source_path(r, name, metadata)}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Whether `name` is open under `root`."
  @spec member?(String.t(), String.t()) :: boolean()
  def member?(root, name) do
    :ets.member(@table, {expand(root), name})
  rescue
    ArgumentError -> false
  end

  # Per-workspace write policy for the doc VFS. The mounted `.jsonl` is read-only
  # UNLESS the workspace's agent access is "full-workspace" — a direct file write
  # is the agent modifying the workspace, so it honours the same gate as the MCP
  # tools. Key is namespaced by @access_key so it never collides with open-doc
  # entries (whose key first element is a path string).
  @doc "Set whether the doc VFS at `root` accepts writes (default: not writable)."
  @spec set_writable(String.t(), boolean()) :: :ok
  def set_writable(root, writable?) when is_boolean(writable?) do
    :ets.insert(@table, {{@access_key, expand(root)}, writable?})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Whether the doc VFS at `root` accepts writes. Defaults to false (safe)."
  @spec writable?(String.t()) :: boolean()
  def writable?(root) do
    case :ets.lookup(@table, {@access_key, expand(root)}) do
      [{_key, writable?}] -> writable?
      _ -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Stage uncommitted projected JSONL bytes for `name` under `root`."
  @spec stage(String.t(), String.t(), binary(), term()) :: :ok
  def stage(root, name, bytes, reason) when is_binary(name) and is_binary(bytes) do
    :ets.insert(@table, {{@stage_key, expand(root), name}, {bytes, reason}})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Fetch staged projected JSONL bytes for `name` under `root`."
  @spec staged(String.t(), String.t()) :: {:ok, binary(), term()} | :error
  def staged(root, name) when is_binary(name) do
    case :ets.lookup(@table, {@stage_key, expand(root), name}) do
      [{_key, {bytes, reason}}] when is_binary(bytes) -> {:ok, bytes, reason}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "All staged projected JSONL buffers under `root`."
  @spec staged(String.t()) :: [{String.t(), binary(), term()}]
  def staged(root) do
    r = expand(root)

    @table
    |> :ets.select([{{{@stage_key, r, :"$1"}, {:"$2", :"$3"}}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.filter(fn {_name, bytes, _reason} -> is_binary(bytes) end)
  rescue
    ArgumentError -> []
  end

  @doc "Remove staged projected JSONL bytes for `name` under `root`."
  @spec unstage(String.t(), String.t()) :: :ok
  def unstage(root, name) when is_binary(name) do
    :ets.delete(@table, {@stage_key, expand(root), name})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Cache the exact projected JSONL bytes accepted by a successful VFS write-back."
  @spec cache_committed(String.t(), String.t(), binary()) :: :ok
  def cache_committed(root, name, bytes) when is_binary(name) and is_binary(bytes) do
    :ets.insert(@table, {{@committed_key, expand(root), name}, bytes})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Fetch the exact projected JSONL bytes from the latest successful VFS write-back."
  @spec committed(String.t(), String.t()) :: {:ok, binary()} | :error
  def committed(root, name) when is_binary(name) do
    case :ets.lookup(@table, {@committed_key, expand(root), name}) do
      [{_key, bytes}] when is_binary(bytes) -> {:ok, bytes}
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Remove the cached successful VFS write-back for `name` under `root`."
  @spec uncache_committed(String.t(), String.t()) :: :ok
  def uncache_committed(root, name) when is_binary(name) do
    :ets.delete(@table, {@committed_key, expand(root), name})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp open_metadata(opts) do
    %{}
    |> maybe_put_agent_id(Keyword.get(opts, :agent_id))
    |> maybe_put_source_path(Keyword.get(opts, :source_path))
    |> case do
      metadata when metadata == %{} -> true
      metadata -> metadata
    end
  end

  defp expand(root), do: Ecrits.Fuse.DocMount.canonical_root(root)

  defp maybe_put_agent_id(metadata, agent_id) when is_binary(agent_id) and agent_id != "",
    do: Map.put(metadata, :agent_id, agent_id)

  defp maybe_put_agent_id(metadata, _agent_id), do: metadata

  defp maybe_put_source_path(metadata, source_path)
       when is_binary(source_path) and source_path != "",
       do: Map.put(metadata, :source_path, canonical_file_path(source_path))

  defp maybe_put_source_path(metadata, _source_path), do: metadata

  defp metadata_source_path(_root, _name, %{source_path: source_path})
       when is_binary(source_path),
       do: canonical_file_path(source_path)

  defp metadata_source_path(_root, _name, %{"source_path" => source_path})
       when is_binary(source_path),
       do: canonical_file_path(source_path)

  defp metadata_source_path(root, name, _metadata), do: Path.join(root, name)

  defp canonical_file_path(path) when is_binary(path) do
    path = Path.expand(path)
    Path.join(Ecrits.Fuse.DocMount.canonical_root(Path.dirname(path)), Path.basename(path))
  end
end
