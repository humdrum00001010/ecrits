defmodule Ecrits.Fuse.OpenDocs do
  @moduledoc """
  Per-workspace registry of documents the agent has explicitly opened for the
  doc VFS (`Ecrits.Fuse.DocFs`). The mount projects exactly this set — a document
  appears under `<workspace>/.ecrits/mount/` only after the agent calls the
  `doc.open_doc` MCP tool, and disappears on `doc.close_doc`.

  Backed by a single public, named ETS set owned by this GenServer (started in
  the supervision tree). Keys are `{canonical_root, name}` where `name` is the
  document's basename (the flat VFS is root-level). Reads/writes hit ETS directly
  from any process (the VFS handler, the MCP tool) — no GenServer call on the
  hot path — and degrade to empty/no-op if the table is somehow absent.
  """

  use GenServer

  @table :ecrits_fuse_open_docs
  @access_key :__vfs_access__
  @stage_key :__vfs_stage__

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Register `name` (basename) as open under `root`."
  @spec open(String.t(), String.t()) :: :ok
  def open(root, name) do
    :ets.insert(@table, {{expand(root), name}, true})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Unregister `name` under `root`."
  @spec close(String.t(), String.t()) :: :ok
  def close(root, name) do
    root = expand(root)
    :ets.delete(@table, {root, name})
    :ets.delete(@table, {@stage_key, root, name})
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

  defp expand(root), do: Ecrits.Fuse.DocMount.canonical_root(root)
end
