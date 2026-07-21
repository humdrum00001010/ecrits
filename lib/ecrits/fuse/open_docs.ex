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
  `source_path` in metadata. Reads hit ETS directly from any process (the VFS
  handler or MCP tool). Staged generations and mutations of the accepted/raw +
  canonical-pending lifecycle are serialized through this GenServer, so exact
  terminal settlement can remove a stage and publish its accepted lifecycle
  without racing a newer stage, canonical echo, or native edit.
  """

  use GenServer

  @table :ecrits_fuse_open_docs
  @access_key :__vfs_access__
  @stage_key :__vfs_stage__
  @committed_key :__vfs_committed__
  @legacy_canonical_pending_key :__vfs_canonical_pending__
  @canonical_echo_key :__vfs_canonical_echo__
  @write_failure_key :__vfs_write_failure__
  @preview_publication_key :__vfs_preview_publication__

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{echo_monitors: %{}}}
  end

  @impl true
  def handle_call({:open, root, name, opts}, _from, state) do
    metadata = open_metadata(opts)

    {removed_echoes, state} =
      unless :ets.member(@table, {root, name}) do
        :ets.delete(@table, {@committed_key, root, name})
        :ets.delete(@table, {@legacy_canonical_pending_key, root, name})

        :ets.delete(
          @table,
          {@preview_publication_key, root, metadata_source_path(root, name, metadata)}
        )

        delete_canonical_echoes(root, name, state)
      else
        {[], state}
      end

    :ets.delete(@table, {@write_failure_key, root, name})
    :ets.insert(@table, {{root, name}, metadata})
    {:reply, {:ok, removed_echoes}, state}
  end

  def handle_call({:close, root, name}, _from, state) do
    source_path =
      case :ets.lookup(@table, {root, name}) do
        [{_key, metadata}] -> metadata_source_path(root, name, metadata)
        [] -> Path.join(root, name)
      end

    :ets.delete(@table, {root, name})
    :ets.delete(@table, {@stage_key, root, name})
    :ets.delete(@table, {@committed_key, root, name})
    :ets.delete(@table, {@legacy_canonical_pending_key, root, name})
    {removed_echoes, state} = delete_canonical_echoes(root, name, state)
    :ets.delete(@table, {@write_failure_key, root, name})
    :ets.delete(@table, {@preview_publication_key, root, source_path})
    {:reply, {:ok, removed_echoes}, state}
  end

  def handle_call({:begin_preview_publication, root, source_path, edit_id}, _from, state) do
    token = {System.unique_integer([:positive, :monotonic]), edit_id}
    key = {@preview_publication_key, root, source_path}

    queue =
      case :ets.lookup(@table, key) do
        [{^key, %{pending: pending, ready: ready}}] ->
          %{pending: pending ++ [token], ready: ready}

        [{^key, previous_token}] ->
          %{pending: [previous_token, token], ready: %{}}

        [] ->
          %{pending: [token], ready: %{}}
      end

    :ets.insert(@table, {key, queue})
    {:reply, token, state}
  end

  def handle_call(
        {:publish_preview_if_current, root, source_path, token, info},
        _from,
        state
      ) do
    key = {@preview_publication_key, root, source_path}

    reply =
      case :ets.lookup(@table, key) do
        [{^key, %{pending: pending, ready: ready} = queue}] ->
          cond do
            token not in pending ->
              :stale

            Map.has_key?(ready, token) ->
              :stale

            true ->
              queue = %{queue | ready: Map.put(ready, token, info)}
              queue = flush_ready_preview_publications(root, queue)

              if queue.pending == [] do
                :ets.delete(@table, key)
              else
                :ets.insert(@table, {key, queue})
              end

              :ok
          end

        [{^key, ^token}] ->
          :ets.delete(@table, key)
          publish_preview(root, info)
          :ok

        _other ->
          :stale
      end

    {:reply, reply, state}
  end

  def handle_call({:stage, root, name, bytes, reason, identity}, _from, state) do
    identity =
      (identity || %{})
      |> Map.put(
        :stage_generation,
        System.unique_integer([:positive, :monotonic])
      )

    :ets.insert(@table, {{@stage_key, root, name}, {bytes, reason, identity}})
    {:reply, :ok, state}
  end

  def handle_call({:unstage, root, name}, _from, state) do
    :ets.delete(@table, {@stage_key, root, name})
    {:reply, :ok, state}
  end

  def handle_call({:staged_identity, root, name}, _from, state) do
    {:reply, lookup_staged_identity(root, name), state}
  end

  def handle_call(
        {:settle_staged, root, name, bytes, reason, identity, settlement},
        _from,
        state
      ) do
    expected = {bytes, reason, identity}

    case :ets.lookup(@table, {@stage_key, root, name}) do
      [{_key, ^expected}] ->
        {reply, state} = settle_current_stage(root, name, settlement, state)
        {:reply, reply, state}

      [{_key, {_current_bytes, _current_reason, current_identity}}] ->
        {:reply, {:replaced, current_identity}, state}

      [{_key, {_current_bytes, _current_reason}}] ->
        {:reply, {:replaced, nil}, state}

      _other ->
        {:reply, :gone, state}
    end
  end

  def handle_call({:cache_committed, root, name, bytes}, _from, state) do
    put_lifecycle(root, name, clean_lifecycle(bytes, next_generation(root, name)))
    {:reply, :ok, state}
  end

  def handle_call({:uncache_committed, root, name}, _from, state) do
    :ets.delete(@table, {@committed_key, root, name})
    :ets.delete(@table, {@legacy_canonical_pending_key, root, name})
    {:reply, :ok, state}
  end

  def handle_call(
        {:accept_projection, root, name, accepted_bytes, canonical_bytes, metadata},
        _from,
        state
      ) do
    generation = next_generation(root, name)

    pending =
      canonical_entry(name, accepted_bytes, canonical_bytes, metadata, generation)

    lifecycle =
      accepted_lifecycle(name, accepted_bytes, pending, metadata, generation)

    put_lifecycle(root, name, lifecycle)
    {:reply, :ok, state}
  end

  def handle_call(
        {:accept_projection_retry, root, name, accepted_bytes, metadata},
        _from,
        state
      ) do
    generation = next_generation(root, name)

    lifecycle =
      name
      |> accepted_lifecycle(accepted_bytes, nil, metadata, generation)
      |> Map.put(:in_flight, canonical_stage_entry(name, accepted_bytes, metadata, generation))

    put_lifecycle(root, name, lifecycle)
    {:reply, :ok, state}
  end

  def handle_call({:clear_pending_canonical, root, name}, _from, state) do
    case lookup_lifecycle(root, name) do
      {:ok, lifecycle} -> put_lifecycle(root, name, %{lifecycle | pending: nil})
      :error -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:begin_canonical_stage, root, name, metadata}, _from, state) do
    reply =
      case lookup_lifecycle(root, name) do
        {:ok, lifecycle} ->
          generation = lifecycle.generation + 1

          in_flight =
            canonical_stage_entry(name, lifecycle.bytes, metadata, generation)

          dirty_owner = dirty_owner_entry(name, metadata, generation)

          put_lifecycle(root, name, %{
            lifecycle
            | dirty_owner: dirty_owner,
              generation: generation,
              in_flight: in_flight
          })

          {:ok, lifecycle.bytes, generation}

        :error ->
          :error
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:complete_canonical_stage, root, name, accepted_bytes, canonical_bytes, generation,
         metadata},
        _from,
        state
      ) do
    reply =
      case lookup_lifecycle(root, name) do
        {:ok,
         %{
           bytes: ^accepted_bytes,
           generation: ^generation,
           in_flight: %{accepted_bytes: ^accepted_bytes, generation: ^generation}
         } = lifecycle} ->
          pending =
            canonical_entry(name, accepted_bytes, canonical_bytes, metadata, generation)

          put_lifecycle(root, name, %{lifecycle | in_flight: nil, pending: pending})

        _stale ->
          {:error, :stale}
      end

    {:reply, reply, state}
  end

  def handle_call(
        {:begin_canonical_echo, root, name, temp_name, expected},
        {claimant, _tag},
        state
      ) do
    reply =
      case lookup_lifecycle(root, name) do
        {:ok,
         %{
           generation: generation,
           in_flight: nil,
           pending: ^expected
         } = lifecycle}
        when expected.generation == generation ->
          put_lifecycle(root, name, %{lifecycle | pending: nil})

          monitor_ref = Process.monitor(claimant)

          entry =
            expected
            |> Map.put(:temp_name, temp_name)
            |> Map.put(:claimant, claimant)
            |> Map.put(:monitor_ref, monitor_ref)

          :ets.insert(
            @table,
            {{@canonical_echo_key, root, temp_name}, entry}
          )

          {:ok, monitor_ref}

        {:ok, _lifecycle} ->
          {:error, :stale}

        :error ->
          {:error, :not_pending}
      end

    case reply do
      {:ok, monitor_ref} ->
        monitors = Map.put(Map.get(state, :echo_monitors, %{}), monitor_ref, {root, temp_name})
        {:reply, :ok, Map.put(state, :echo_monitors, monitors)}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call(
        {:complete_canonical_echo, root, temp_name, target_name, bytes},
        _from,
        state
      ) do
    echo = lookup_canonical_echo(root, temp_name)
    reply = do_complete_canonical_echo(root, temp_name, target_name, bytes)

    state =
      if reply == :ok do
        demonitor_echo(state, echo)
      else
        state
      end

    {:reply, reply, state}
  end

  def handle_call({:cancel_canonical_echo, root, temp_name}, _from, state) do
    taken = cancel_echo_claim(root, temp_name)
    {:reply, :ok, demonitor_echo(state, taken)}
  end

  def handle_call({:reclaim_dead_canonical_echoes, root, filters}, _from, state) do
    {reclaimed, state} =
      root
      |> canonical_echo_entries()
      |> Enum.filter(fn {_temp_name, entry} ->
        canonical_owner_matches?(entry, filters) and dead_echo_claimant?(entry)
      end)
      |> Enum.reduce({[], state}, fn {temp_name, _entry}, {reclaimed, state} ->
        taken = cancel_echo_claim(root, temp_name)

        {[temp_name | reclaimed], demonitor_echo(state, taken)}
      end)

    {:reply, Enum.reverse(reclaimed), state}
  end

  def handle_call({:promote_canonical_echo, root, temp_name}, _from, state) do
    echo = lookup_canonical_echo(root, temp_name)

    reply =
      with {:ok,
            %{
              name: name,
              bytes: bytes,
              accepted_bytes: accepted_bytes,
              generation: generation
            }} <-
             lookup_canonical_echo(root, temp_name),
           {:ok,
            %{
              bytes: ^accepted_bytes,
              generation: ^generation,
              in_flight: nil,
              pending: nil
            } = lifecycle} <- lookup_lifecycle(root, name) do
        put_lifecycle(root, name, %{lifecycle | bytes: bytes})
        :ets.delete(@table, {@canonical_echo_key, root, temp_name})
        :ok
      else
        :error -> {:error, :not_echo}
        {:ok, _other_lifecycle} -> {:error, :stale}
      end

    state =
      if reply == :ok do
        demonitor_echo(state, echo)
      else
        state
      end

    {:reply, reply, state}
  end

  def handle_call({:clear_dirty_owner, root, name, expected}, _from, state) do
    reply =
      case lookup_lifecycle(root, name) do
        {:ok, %{dirty_owner: ^expected} = lifecycle} ->
          put_lifecycle(root, name, %{lifecycle | dirty_owner: nil})

        {:ok, %{dirty_owner: nil}} ->
          {:error, :not_dirty}

        {:ok, _lifecycle} ->
          {:error, :stale}

        :error ->
          {:error, :not_open}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(Map.get(state, :echo_monitors, %{}), monitor_ref) do
      {{root, temp_name}, monitors} ->
        cancel_echo_claim(root, temp_name)
        remove_orphaned_echo_temp(root, temp_name)
        {:noreply, Map.put(state, :echo_monitors, monitors)}

      {nil, _monitors} ->
        {:noreply, state}
    end
  end

  def handle_info({:continue_staged_settlement, _stale_test_ref}, state) do
    {:noreply, state}
  end

  defp flush_ready_preview_publications(
         root,
         %{pending: [token | pending], ready: ready} = queue
       ) do
    case Map.pop(ready, token) do
      {nil, _ready} ->
        queue

      {info, ready} ->
        publish_preview(root, info)
        flush_ready_preview_publications(root, %{pending: pending, ready: ready})
    end
  end

  defp flush_ready_preview_publications(_root, %{pending: []} = queue), do: queue

  defp publish_preview(root, info) do
    Phoenix.PubSub.broadcast(Ecrits.PubSub, "doc_vfs:" <> root, {:vfs_doc_edited, info})
  end

  @doc "Register `name` as open under `root`."
  @spec open(String.t(), String.t(), keyword()) :: :ok
  def open(root, name, opts \\ []) do
    root = expand(root)

    case registry_call({:open, root, name, opts}, {:ok, []}) do
      {:ok, removed_echoes} ->
        Enum.each(removed_echoes, &remove_orphaned_echo_temp_now(root, &1))
        :ok

      :ok ->
        :ok
    end
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

  @doc "The ACP turn that opened `name` under `root`, when known."
  @spec owner_turn_id(String.t(), String.t()) :: String.t() | nil
  def owner_turn_id(root, name) do
    case :ets.lookup(@table, {expand(root), name}) do
      [{_key, %{turn_id: turn_id}}] when is_binary(turn_id) and turn_id != "" -> turn_id
      [{_key, %{"turn_id" => turn_id}}] when is_binary(turn_id) and turn_id != "" -> turn_id
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "The ACP turn that opened `source_path` under `root`, when known."
  @spec owner_turn_id_for_source(String.t(), String.t()) :: String.t() | nil
  def owner_turn_id_for_source(root, source_path) do
    case name_for_source(root, source_path) do
      {:ok, name} -> owner_turn_id(root, name)
      :error -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "The immutable owner tuple currently registered for mounted `name`."
  @spec owner_identity(String.t(), String.t()) :: map()
  def owner_identity(root, name) do
    case :ets.lookup(@table, {expand(root), name}) do
      [{_key, metadata}] when is_map(metadata) ->
        %{
          agent_id: metadata_value(metadata, :agent_id),
          agent_session: metadata_agent_session(metadata),
          instance_id: metadata_value(metadata, :instance_id),
          turn_id: metadata_value(metadata, :turn_id)
        }

      _other ->
        %{agent_id: nil, agent_session: nil, instance_id: nil, turn_id: nil}
    end
  rescue
    ArgumentError -> %{agent_id: nil, agent_session: nil, instance_id: nil, turn_id: nil}
  end

  @doc "The immutable owner tuple currently registered for `source_path`."
  @spec owner_identity_for_source(String.t(), String.t()) :: map()
  def owner_identity_for_source(root, source_path) do
    case name_for_source(root, source_path) do
      {:ok, name} -> owner_identity(root, name)
      :error -> %{agent_id: nil, agent_session: nil, instance_id: nil, turn_id: nil}
    end
  rescue
    ArgumentError -> %{agent_id: nil, agent_session: nil, instance_id: nil, turn_id: nil}
  end

  @doc "Unregister `name` under `root`."
  @spec close(String.t(), String.t()) :: :ok
  def close(root, name) do
    root = expand(root)

    case registry_call({:close, root, name}, {:ok, []}) do
      {:ok, removed_echoes} ->
        Enum.each(removed_echoes, &remove_orphaned_echo_temp_now(root, &1))
        :ok

      :ok ->
        :ok
    end
  end

  @doc """
  Unregister every open doc under `root` — the workspace-teardown sweep.

  A document's runtime state lives exactly as long as its workspace: teardown
  closes the Pool twins, and this clears the matching OpenDocs bookkeeping
  (entry, stage, committed cache, echoes, failure markers) in the same breath,
  so nothing lingers to be compensated for by the next open.
  """
  @spec close_root(String.t()) :: :ok
  def close_root(root) do
    Enum.each(list(root), &close(root, &1))
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
    stage(root, name, bytes, reason, nil)
  end

  @doc "Stage bytes together with the VFS edit identity pinned at first mutation."
  @spec stage(String.t(), String.t(), binary(), term(), map() | nil) :: :ok
  def stage(root, name, bytes, reason, identity)
      when is_binary(name) and is_binary(bytes) and (is_map(identity) or is_nil(identity)) do
    registry_call({:stage, expand(root), name, bytes, reason, identity}, :ok)
  end

  @doc "Fetch staged projected JSONL bytes for `name` under `root`."
  @spec staged(String.t(), String.t()) :: {:ok, binary(), term()} | :error
  def staged(root, name) when is_binary(name) do
    case :ets.lookup(@table, {@stage_key, expand(root), name}) do
      [{_key, {bytes, reason, _identity}}] when is_binary(bytes) -> {:ok, bytes, reason}
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
    |> :ets.select([{{{@stage_key, r, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn
      {name, {bytes, reason, _identity}} when is_binary(bytes) -> [{name, bytes, reason}]
      {name, {bytes, reason}} when is_binary(bytes) -> [{name, bytes, reason}]
      _other -> []
    end)
  rescue
    ArgumentError -> []
  end

  @doc "All staged buffers including the owner/edit identity and exact stage generation."
  @spec staged_with_identity(String.t()) :: [{String.t(), binary(), term(), map() | nil}]
  def staged_with_identity(root) do
    r = expand(root)

    @table
    |> :ets.select([{{{@stage_key, r, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn
      {name, {bytes, reason, identity}}
      when is_binary(bytes) and (is_map(identity) or is_nil(identity)) ->
        [{name, bytes, reason, identity}]

      {name, {bytes, reason}} when is_binary(bytes) ->
        [{name, bytes, reason, nil}]

      _other ->
        []
    end)
  rescue
    ArgumentError -> []
  end

  @doc "Remove staged projected JSONL bytes for `name` under `root`."
  @spec unstage(String.t(), String.t()) :: :ok
  def unstage(root, name) when is_binary(name) do
    registry_call({:unstage, expand(root), name}, :ok)
  end

  @doc "Discard one staged value only while its bytes, reason, identity, and stage generation still match."
  @spec discard_staged(String.t(), String.t(), binary(), term(), map() | nil) ::
          :ok | {:error, :stale}
  def discard_staged(root, name, bytes, reason, identity)
      when is_binary(name) and is_binary(bytes) and (is_map(identity) or is_nil(identity)) do
    case registry_call(
           {:settle_staged, expand(root), name, bytes, reason, identity, :discard},
           :gone
         ) do
      :settled -> :ok
      _stale -> {:error, :stale}
    end
  end

  @doc "Settle one exact staged generation and classify any stage queued during settlement."
  @spec settle_staged(
          String.t(),
          String.t(),
          binary(),
          term(),
          map() | nil,
          term(),
          keyword()
        ) :: :settled | :retained | :same_owner_replaced | :other_owner_or_gone
  def settle_staged(root, name, bytes, reason, identity, settlement, filters \\ [])
      when is_binary(name) and is_binary(bytes) and (is_map(identity) or is_nil(identity)) and
             is_list(filters) do
    root = expand(root)

    result =
      registry_call(
        {:settle_staged, root, name, bytes, reason, identity, settlement},
        :gone
      )

    # This registry read is a serialization barrier. A stage call that entered
    # the coordinator while exact settlement was publishing its lifecycle is
    # processed first, so the returned disposition cannot acknowledge a turn
    # while its newer same-owner generation is already queued.
    current = registry_call({:staged_identity, root, name}, :error)
    staged_settlement_disposition(result, current, identity, filters)
  end

  @doc "Fetch the identity of the currently staged generation through the registry barrier."
  @spec staged_identity(String.t(), String.t()) :: {:ok, map() | nil} | :error
  def staged_identity(root, name) when is_binary(name) do
    registry_call({:staged_identity, expand(root), name}, :error)
  end

  @doc "Cache the exact projected JSONL bytes accepted by a successful VFS write-back."
  @spec cache_committed(String.t(), String.t(), binary()) :: :ok
  def cache_committed(root, name, bytes) when is_binary(name) and is_binary(bytes) do
    registry_call({:cache_committed, expand(root), name, bytes}, :ok)
  end

  @doc "Fetch the exact projected JSONL bytes from the latest successful VFS write-back."
  @spec committed(String.t(), String.t()) :: {:ok, binary()} | :error
  def committed(root, name) when is_binary(name) do
    case lookup_lifecycle(expand(root), name) do
      {:ok, %{bytes: bytes}} -> {:ok, bytes}
      :error -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Remove the cached successful VFS write-back for `name` under `root`."
  @spec uncache_committed(String.t(), String.t()) :: :ok
  def uncache_committed(root, name) when is_binary(name) do
    registry_call({:uncache_committed, expand(root), name}, :ok)
  end

  @doc "Atomically expose accepted raw bytes while staging their canonical engine projection."
  @spec accept_projection(String.t(), String.t(), binary(), binary(), map()) :: :ok
  def accept_projection(root, name, accepted_bytes, canonical_bytes, metadata \\ %{})
      when is_binary(name) and is_binary(accepted_bytes) and is_binary(canonical_bytes) and
             is_map(metadata) do
    registry_call(
      {:accept_projection, expand(root), name, accepted_bytes, canonical_bytes, metadata},
      :ok
    )
  end

  @doc "Expose accepted raw bytes and retain a retryable canonical projection stage."
  @spec accept_projection_retry(String.t(), String.t(), binary(), map()) :: :ok
  def accept_projection_retry(root, name, accepted_bytes, metadata \\ %{})
      when is_binary(name) and is_binary(accepted_bytes) and is_map(metadata) do
    registry_call(
      {:accept_projection_retry, expand(root), name, accepted_bytes, metadata},
      :ok
    )
  end

  @doc "Claim the current mounted predecessor before projecting a native edit's canonical bytes."
  @spec begin_canonical_stage(String.t(), String.t(), map()) ::
          {:ok, binary(), non_neg_integer()} | :error
  def begin_canonical_stage(root, name, metadata \\ %{})
      when is_binary(name) and is_map(metadata) do
    registry_call(
      {:begin_canonical_stage, expand(root), name, metadata},
      :error
    )
  end

  @doc "Complete a native canonical projection only if its claimed generation is still current."
  @spec complete_canonical_stage(
          String.t(),
          String.t(),
          binary(),
          binary(),
          non_neg_integer(),
          map()
        ) :: :ok | {:error, :stale}
  def complete_canonical_stage(
        root,
        name,
        accepted_bytes,
        canonical_bytes,
        generation,
        metadata \\ %{}
      )
      when is_binary(name) and is_binary(accepted_bytes) and is_binary(canonical_bytes) and
             is_integer(generation) and generation >= 0 and is_map(metadata) do
    registry_call(
      {:complete_canonical_stage, expand(root), name, accepted_bytes, canonical_bytes, generation,
       metadata},
      {:error, :stale}
    )
  end

  @doc "Remove canonical bytes waiting for a fresh mounted-vnode publication boundary."
  @spec clear_pending_canonical(String.t(), String.t()) :: :ok
  def clear_pending_canonical(root, name) when is_binary(name) do
    registry_call({:clear_pending_canonical, expand(root), name}, :ok)
  end

  @doc "Fetch one canonical publication still pending for an opened document."
  @spec pending_canonical(String.t(), String.t()) :: {:ok, map()} | :error
  def pending_canonical(root, name) when is_binary(name) do
    case lookup_lifecycle(expand(root), name) do
      {:ok, %{generation: generation, in_flight: nil, pending: pending}}
      when is_map(pending) and pending.generation == generation ->
        {:ok, pending}

      _other ->
        :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "List canonical publications pending under `root`, optionally scoped to an ACP owner turn."
  @spec pending_canonical_entries(String.t(), keyword()) :: [map()]
  def pending_canonical_entries(root, filters \\ []) when is_list(filters) do
    r = expand(root)

    @table
    |> :ets.select([{{{@committed_key, r, :"$1"}, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn name ->
      case lookup_lifecycle(r, name) do
        {:ok, %{generation: generation, in_flight: nil, pending: pending}}
        when is_map(pending) and pending.generation == generation ->
          [pending]

        _lifecycle ->
          []
      end
    end)
    |> Enum.filter(&canonical_owner_matches?(&1, filters))
  rescue
    ArgumentError -> []
  end

  @doc "List retryable canonical projections currently in flight for an ACP owner turn."
  @spec in_flight_canonical_entries(String.t(), keyword()) :: [map()]
  def in_flight_canonical_entries(root, filters \\ []) when is_list(filters) do
    lifecycle_entries(root, :in_flight, filters)
  end

  @doc "List documents dirtied by the exact ACP owner turn that last changed each engine model."
  @spec dirty_owner_entries(String.t(), keyword()) :: [map()]
  def dirty_owner_entries(root, filters \\ []) when is_list(filters) do
    lifecycle_entries(root, :dirty_owner, filters)
  end

  @doc "Clear dirty ownership only when the caller still owns the exact lifecycle generation."
  @spec clear_dirty_owner(String.t(), String.t(), map()) :: :ok | {:error, atom()}
  def clear_dirty_owner(root, name, expected) when is_binary(name) and is_map(expected) do
    registry_call(
      {:clear_dirty_owner, expand(root), name, expected},
      {:error, :registry_unavailable}
    )
  end

  @doc "Claim one unchanged pending canonical value for a unique mounted sibling temp."
  @spec begin_canonical_echo(String.t(), String.t(), String.t(), map()) :: :ok | {:error, atom()}
  def begin_canonical_echo(root, name, temp_name, expected)
      when is_binary(name) and is_binary(temp_name) and is_map(expected) do
    registry_call(
      {:begin_canonical_echo, expand(root), name, temp_name, expected},
      {:error, :registry_unavailable}
    )
  end

  @doc "Whether `temp_name` is the internally registered fresh-vnode canonical publisher."
  @spec canonical_echo_temp?(String.t(), String.t()) :: boolean()
  def canonical_echo_temp?(root, temp_name) when is_binary(temp_name) do
    :ets.member(@table, {@canonical_echo_key, expand(root), temp_name})
  rescue
    ArgumentError -> false
  end

  @doc "Fetch the canonical publication claimed by an internal mounted sibling temp."
  @spec canonical_echo(String.t(), String.t()) :: {:ok, map()} | :error
  def canonical_echo(root, temp_name) when is_binary(temp_name) do
    case :ets.lookup(@table, {@canonical_echo_key, expand(root), temp_name}) do
      [{_key, entry}] when is_map(entry) -> {:ok, entry}
      _other -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Publish a canonical echo only when its target, bytes, and accepted raw predecessor still match."
  @spec complete_canonical_echo(String.t(), String.t(), String.t(), binary()) ::
          :ok | {:error, atom()}
  def complete_canonical_echo(root, temp_name, target_name, bytes)
      when is_binary(temp_name) and is_binary(target_name) and is_binary(bytes) do
    registry_call(
      {:complete_canonical_echo, expand(root), temp_name, target_name, bytes},
      {:error, :registry_unavailable}
    )
  end

  @doc "Cancel an echo and restore its claim only if no newer canonical publication replaced it."
  @spec cancel_canonical_echo(String.t(), String.t()) :: :ok
  def cancel_canonical_echo(root, temp_name) when is_binary(temp_name) do
    registry_call({:cancel_canonical_echo, expand(root), temp_name}, :ok)
  end

  @doc "Synchronously restore canonical claims whose monitored publisher is already dead."
  @spec reclaim_dead_canonical_echoes(String.t(), keyword()) :: [String.t()]
  def reclaim_dead_canonical_echoes(root, filters \\ []) when is_list(filters) do
    root = expand(root)

    reclaimed =
      registry_call(
        {:reclaim_dead_canonical_echoes, root, filters},
        []
      )

    # FSKit's unlink callback consults this registry. Remove the mounted temp
    # only after the coordinator has replied, otherwise a reclaim call can wait
    # on its own nested `cancel_canonical_echo` request.
    Enum.each(reclaimed, &remove_orphaned_echo_temp_now(root, &1))
    reclaimed
  end

  @doc "Promote a claimed echo while the old mount is detached, for the remount fallback."
  @spec promote_canonical_echo(String.t(), String.t()) :: :ok | {:error, atom()}
  def promote_canonical_echo(root, temp_name) when is_binary(temp_name) do
    registry_call(
      {:promote_canonical_echo, expand(root), temp_name},
      {:error, :registry_unavailable}
    )
  end

  @doc "Record an actual VFS/engine write failure for one currently opened document."
  @spec record_write_failure(String.t(), String.t(), term()) :: :ok
  def record_write_failure(root, name, reason) when is_binary(name) do
    :ets.insert(@table, {{@write_failure_key, expand(root), name}, reason})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Fetch the latest authoritative primary-surface write failure for a document."
  @spec write_failure(String.t(), String.t()) :: {:ok, term()} | :error
  def write_failure(root, name) when is_binary(name) do
    case :ets.lookup(@table, {@write_failure_key, expand(root), name}) do
      [{_key, reason}] -> {:ok, reason}
      [] -> :error
    end
  rescue
    ArgumentError -> :error
  end

  @doc "Clear a VFS/engine write failure before a new primary-surface attempt."
  @spec clear_write_failure(String.t(), String.t()) :: :ok
  def clear_write_failure(root, name) when is_binary(name) do
    :ets.delete(@table, {@write_failure_key, expand(root), name})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Reserve the next deferred preview publication for one canonical source path."
  @spec begin_preview_publication(String.t(), String.t(), String.t() | nil) :: term()
  def begin_preview_publication(root, source_path, edit_id)
      when is_binary(root) and is_binary(source_path) do
    root = expand(root)
    source_path = canonical_file_path(source_path)

    registry_call(
      {:begin_preview_publication, root, source_path, edit_id},
      {:registry_unavailable, make_ref()}
    )
  end

  @doc "Whether a deferred preview publication is still pending for this source path."
  @spec current_preview_publication?(String.t(), String.t(), term()) :: boolean()
  def current_preview_publication?(root, source_path, token)
      when is_binary(root) and is_binary(source_path) do
    key = {@preview_publication_key, expand(root), canonical_file_path(source_path)}

    case :ets.lookup(@table, key) do
      [{^key, %{pending: pending}}] -> token in pending
      [{^key, ^token}] -> true
      _other -> false
    end
  rescue
    ArgumentError -> false
  end

  @doc "Mark a deferred final preview ready and publish ready previews in save order."
  @spec publish_preview_if_current(String.t(), String.t(), term(), map()) :: :ok | :stale
  def publish_preview_if_current(root, source_path, token, info)
      when is_binary(root) and is_binary(source_path) and is_map(info) do
    registry_call(
      {:publish_preview_if_current, expand(root), canonical_file_path(source_path), token, info},
      :stale
    )
  end

  defp open_metadata(opts) do
    %{}
    |> maybe_put_agent_id(Keyword.get(opts, :agent_id))
    |> maybe_put_agent_session(Keyword.get(opts, :agent_session))
    |> maybe_put_instance_id(Keyword.get(opts, :instance_id))
    |> maybe_put_turn_id(Keyword.get(opts, :turn_id))
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

  defp maybe_put_agent_session(metadata, agent_session) when is_pid(agent_session),
    do: Map.put(metadata, :agent_session, agent_session)

  defp maybe_put_agent_session(metadata, _agent_session), do: metadata

  defp maybe_put_instance_id(metadata, instance_id)
       when is_binary(instance_id) and instance_id != "",
       do: Map.put(metadata, :instance_id, instance_id)

  defp maybe_put_instance_id(metadata, _instance_id), do: metadata

  defp maybe_put_turn_id(metadata, turn_id) when is_binary(turn_id) and turn_id != "",
    do: Map.put(metadata, :turn_id, turn_id)

  defp maybe_put_turn_id(metadata, _turn_id), do: metadata

  defp maybe_put_source_path(metadata, source_path)
       when is_binary(source_path) and source_path != "",
       do: Map.put(metadata, :source_path, canonical_file_path(source_path))

  defp maybe_put_source_path(metadata, _source_path), do: metadata

  defp metadata_value(metadata, key) when is_map(metadata) do
    case Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp metadata_agent_session(metadata) when is_map(metadata) do
    case Map.get(metadata, :agent_session) || Map.get(metadata, "agent_session") do
      value when is_pid(value) -> value
      _other -> nil
    end
  end

  defp metadata_source_path(_root, _name, %{source_path: source_path})
       when is_binary(source_path),
       do: canonical_file_path(source_path)

  defp metadata_source_path(_root, _name, %{"source_path" => source_path})
       when is_binary(source_path),
       do: canonical_file_path(source_path)

  defp metadata_source_path(root, name, _metadata), do: Path.join(root, name)

  defp canonical_metadata(metadata) do
    %{}
    |> maybe_put_canonical_field(:agent_id, metadata_value(metadata, :agent_id))
    |> maybe_put_canonical_field(:agent_session, metadata_agent_session(metadata))
    |> maybe_put_canonical_field(:instance_id, metadata_value(metadata, :instance_id))
    |> maybe_put_canonical_field(:turn_id, metadata_value(metadata, :turn_id))
    |> maybe_put_canonical_field(:edit_id, metadata_value(metadata, :edit_id))
    |> maybe_put_canonical_source(metadata_value(metadata, :source_path))
  end

  defp maybe_put_canonical_field(metadata, _key, nil), do: metadata
  defp maybe_put_canonical_field(metadata, key, value), do: Map.put(metadata, key, value)

  defp maybe_put_canonical_source(metadata, nil), do: metadata

  defp maybe_put_canonical_source(metadata, source_path),
    do: Map.put(metadata, :source_path, canonical_file_path(source_path))

  defp canonical_owner_matches?(entry, filters) do
    identity_matches? =
      Enum.all?([:agent_id, :instance_id, :turn_id], fn key ->
        case Keyword.get(filters, key) do
          value when is_binary(value) and value != "" -> Map.get(entry, key) == value
          _unscoped -> true
        end
      end)

    source_matches? =
      case Keyword.get(filters, :source_path) do
        value when is_binary(value) and value != "" ->
          Map.get(entry, :source_path) == canonical_file_path(value)

        _unscoped ->
          true
      end

    identity_matches? and source_matches?
  end

  defp canonical_entry(_name, accepted_bytes, accepted_bytes, _metadata, _generation),
    do: nil

  defp canonical_entry(name, accepted_bytes, canonical_bytes, metadata, generation) do
    metadata
    |> canonical_metadata()
    |> Map.merge(%{
      name: name,
      accepted_bytes: accepted_bytes,
      bytes: canonical_bytes,
      generation: generation
    })
  end

  defp canonical_stage_entry(name, accepted_bytes, metadata, generation) do
    metadata
    |> canonical_metadata()
    |> Map.merge(%{
      name: name,
      accepted_bytes: accepted_bytes,
      generation: generation
    })
  end

  defp dirty_owner_entry(name, metadata, generation) do
    metadata
    |> canonical_metadata()
    |> Map.drop([:edit_id])
    |> Map.merge(%{name: name, generation: generation})
  end

  defp accepted_lifecycle(name, accepted_bytes, pending, metadata, generation) do
    %{
      bytes: accepted_bytes,
      dirty_owner: dirty_owner_entry(name, metadata, generation),
      generation: generation,
      in_flight: nil,
      pending: pending
    }
  end

  defp clean_lifecycle(bytes, generation) do
    %{
      bytes: bytes,
      dirty_owner: nil,
      generation: generation,
      in_flight: nil,
      pending: nil
    }
  end

  defp do_complete_canonical_echo(root, temp_name, target_name, bytes) do
    with {:ok,
          %{
            name: ^target_name,
            bytes: ^bytes,
            accepted_bytes: accepted_bytes,
            generation: generation
          }} <- lookup_canonical_echo(root, temp_name),
         {:ok,
          %{
            bytes: ^accepted_bytes,
            generation: ^generation,
            in_flight: nil,
            pending: nil
          } = lifecycle} <- lookup_lifecycle(root, target_name) do
      put_lifecycle(root, target_name, %{lifecycle | bytes: bytes})
      :ets.delete(@table, {@canonical_echo_key, root, temp_name})
      :ok
    else
      :error -> {:error, :not_echo}
      {:ok, _other_lifecycle} -> {:error, :stale}
    end
  end

  defp put_lifecycle(root, name, lifecycle) do
    :ets.insert(@table, {{@committed_key, root, name}, lifecycle})
    :ok
  end

  defp lookup_staged_identity(root, name) do
    case :ets.lookup(@table, {@stage_key, root, name}) do
      [{_key, {_bytes, _reason, identity}}] when is_map(identity) or is_nil(identity) ->
        {:ok, identity}

      [{_key, {_bytes, _reason}}] ->
        {:ok, nil}

      _other ->
        :error
    end
  end

  defp staged_settlement_disposition(:current, {:ok, identity}, identity, _filters),
    do: :retained

  defp staged_settlement_disposition(_result, {:ok, current_identity}, _identity, filters) do
    if staged_owner_matches?(current_identity, filters),
      do: :same_owner_replaced,
      else: :other_owner_or_gone
  end

  defp staged_settlement_disposition(:settled, :error, _identity, _filters), do: :settled

  defp staged_settlement_disposition(_result, :error, _identity, _filters),
    do: :other_owner_or_gone

  defp staged_owner_matches?(_identity, []), do: true

  defp staged_owner_matches?(identity, filters) when is_map(identity) do
    Enum.all?(filters, fn {key, value} ->
      not (is_binary(value) and value != "") or Map.get(identity, key) == value
    end)
  end

  defp staged_owner_matches?(_identity, _filters), do: false

  defp settle_current_stage(_root, _name, :retain, state), do: {:current, state}

  defp settle_current_stage(root, name, :discard, state) do
    state = remove_current_stage(root, name, state)
    {:settled, state}
  end

  defp settle_current_stage(
         root,
         name,
         {:accept_projection, accepted_bytes, canonical_bytes, metadata},
         state
       )
       when is_binary(accepted_bytes) and is_binary(canonical_bytes) and is_map(metadata) do
    state = remove_current_stage(root, name, state)
    generation = next_generation(root, name)
    pending = canonical_entry(name, accepted_bytes, canonical_bytes, metadata, generation)
    lifecycle = accepted_lifecycle(name, accepted_bytes, pending, metadata, generation)
    put_lifecycle(root, name, lifecycle)
    {:settled, state}
  end

  defp settle_current_stage(
         root,
         name,
         {:accept_projection_retry, accepted_bytes, metadata},
         state
       )
       when is_binary(accepted_bytes) and is_map(metadata) do
    state = remove_current_stage(root, name, state)
    generation = next_generation(root, name)

    lifecycle =
      name
      |> accepted_lifecycle(accepted_bytes, nil, metadata, generation)
      |> Map.put(
        :in_flight,
        canonical_stage_entry(name, accepted_bytes, metadata, generation)
      )

    put_lifecycle(root, name, lifecycle)
    {:settled, state}
  end

  defp settle_current_stage(_root, _name, _unsupported, state), do: {:unsupported, state}

  defp remove_current_stage(root, name, state) do
    :ets.delete(@table, {@stage_key, root, name})
    maybe_pause_staged_settlement_for_test(state, root, name)
  end

  # Tests may install this one-shot state entry with `:sys.replace_state/2` to
  # prove a stage call queued after exact removal cannot enter the ETS table
  # before accepted lifecycle publication. Production state never contains it.
  defp maybe_pause_staged_settlement_for_test(state, root, name) do
    case Map.pop(state, :staged_settlement_test_hook) do
      {{test_pid, ref}, state} when is_pid(test_pid) and is_reference(ref) ->
        send(test_pid, {:staged_settlement_removed, ref, root, name})

        receive do
          {:continue_staged_settlement, ^ref} -> state
        after
          5_000 -> state
        end

      {nil, state} ->
        state
    end
  end

  defp next_generation(root, name) do
    case lookup_lifecycle(root, name) do
      {:ok, %{generation: generation}} -> generation + 1
      :error -> 1
    end
  end

  defp lookup_lifecycle(root, name) do
    case :ets.lookup(@table, {@committed_key, root, name}) do
      [{key, %{bytes: bytes, generation: generation, pending: pending} = lifecycle}]
      when is_binary(bytes) and is_integer(generation) and generation >= 0 and
             (is_map(pending) or is_nil(pending)) ->
        upgraded = upgrade_lifecycle(root, name, lifecycle)

        if upgraded != lifecycle do
          :ets.insert(@table, {key, upgraded})
        end

        {:ok, upgraded}

      # Upgrade an old in-memory row defensively during code reload. A new
      # runtime always writes the consolidated lifecycle shape directly.
      [{key, bytes}] when is_binary(bytes) ->
        lifecycle = upgrade_lifecycle(root, name, clean_lifecycle(bytes, 0))
        :ets.insert(@table, {key, lifecycle})
        {:ok, lifecycle}

      _other ->
        :error
    end
  end

  defp upgrade_lifecycle(root, name, lifecycle) do
    lifecycle =
      lifecycle
      |> Map.put_new(:in_flight, nil)
      |> Map.put_new(:dirty_owner, dirty_owner_from_pending(lifecycle.pending))

    case take_legacy_pending(root, name) do
      {:ok, legacy_pending} when is_nil(lifecycle.pending) ->
        generation = max(lifecycle.generation, Map.get(legacy_pending, :generation, 0))

        legacy_pending =
          legacy_pending
          |> Map.put_new(:name, name)
          |> Map.put_new(:accepted_bytes, lifecycle.bytes)
          |> Map.put(:generation, generation)

        lifecycle
        |> Map.put(:generation, generation)
        |> Map.put(:pending, legacy_pending)
        |> Map.put(
          :dirty_owner,
          lifecycle.dirty_owner || dirty_owner_from_pending(legacy_pending)
        )

      _none_or_already_consolidated ->
        lifecycle
    end
  end

  defp dirty_owner_from_pending(%{name: name, generation: generation} = pending)
       when is_binary(name) and is_integer(generation) and generation >= 0 do
    dirty_owner_entry(name, pending, generation)
  end

  defp dirty_owner_from_pending(_pending), do: nil

  defp take_legacy_pending(root, name) do
    key = {@legacy_canonical_pending_key, root, name}

    case :ets.take(@table, key) do
      [{^key, pending}] when is_map(pending) -> {:ok, pending}
      _other -> :error
    end
  end

  defp lifecycle_entries(root, field, filters) do
    r = expand(root)

    @table
    |> :ets.select([{{{@committed_key, r, :"$1"}, :_}, [], [:"$1"]}])
    |> Enum.flat_map(fn name ->
      case lookup_lifecycle(r, name) do
        {:ok, %{^field => entry}} when is_map(entry) -> [entry]
        _lifecycle -> []
      end
    end)
    |> Enum.filter(&canonical_owner_matches?(&1, filters))
  rescue
    ArgumentError -> []
  end

  defp lookup_canonical_echo(root, temp_name) do
    case :ets.lookup(@table, {@canonical_echo_key, root, temp_name}) do
      [{_key, entry}] when is_map(entry) -> {:ok, entry}
      _other -> :error
    end
  end

  defp canonical_echo_entries(root) do
    @table
    |> :ets.match_object({{@canonical_echo_key, root, :_}, :_})
    |> Enum.map(fn {{@canonical_echo_key, ^root, temp_name}, entry} -> {temp_name, entry} end)
  end

  defp dead_echo_claimant?(%{claimant: claimant}) when is_pid(claimant),
    do: not Process.alive?(claimant)

  defp dead_echo_claimant?(_entry), do: true

  defp registry_call(request, fallback) do
    GenServer.call(__MODULE__, request)
  catch
    :exit, _reason -> fallback
  end

  defp cancel_echo_claim(root, temp_name) do
    echo_key = {@canonical_echo_key, root, temp_name}
    taken = :ets.take(@table, echo_key)

    case taken do
      [
        {^echo_key, %{name: name, accepted_bytes: accepted_bytes, generation: generation} = entry}
      ] ->
        case lookup_lifecycle(root, name) do
          {:ok,
           %{
             bytes: ^accepted_bytes,
             generation: ^generation,
             in_flight: nil,
             pending: nil
           } = lifecycle} ->
            put_lifecycle(root, name, %{
              lifecycle
              | pending: canonical_pending_from_echo(entry)
            })

          _stale ->
            :ok
        end

      _other ->
        :ok
    end

    taken
  end

  defp canonical_pending_from_echo(entry) do
    Map.drop(entry, [:claimant, :monitor_ref, :temp_name])
  end

  defp demonitor_echo(state, {:ok, entry}), do: demonitor_echo(state, [entry])
  defp demonitor_echo(state, [{_key, entry}]), do: demonitor_echo(state, [entry])

  defp demonitor_echo(state, [entry]) when is_map(entry) do
    case Map.get(entry, :monitor_ref) do
      monitor_ref when is_reference(monitor_ref) ->
        Process.demonitor(monitor_ref, [:flush])

        Map.put(
          state,
          :echo_monitors,
          Map.delete(Map.get(state, :echo_monitors, %{}), monitor_ref)
        )

      _no_monitor ->
        state
    end
  end

  defp demonitor_echo(state, _entry), do: state

  defp delete_canonical_echoes(root, name, state) do
    echoes =
      :ets.select(@table, [
        {{{@canonical_echo_key, root, :_}, %{name: name}}, [], [:"$_"]}
      ])

    :ets.select_delete(@table, [
      {{{@canonical_echo_key, root, :_}, %{name: name}}, [], [true]}
    ])

    state =
      Enum.reduce(echoes, state, fn {_key, entry}, acc -> demonitor_echo(acc, [entry]) end)

    temp_names =
      Enum.map(echoes, fn {{@canonical_echo_key, ^root, temp_name}, _entry} -> temp_name end)

    {temp_names, state}
  end

  defp remove_orphaned_echo_temp(root, temp_name) do
    Task.start(fn ->
      root
      |> Ecrits.Fuse.DocMount.mount_point()
      |> Path.join(temp_name)
      |> File.rm()
    end)

    :ok
  end

  defp remove_orphaned_echo_temp_now(root, temp_name) do
    root
    |> Ecrits.Fuse.DocMount.mount_point()
    |> Path.join(temp_name)
    |> File.rm()

    :ok
  end

  defp canonical_file_path(path) when is_binary(path) do
    path = Path.expand(path)
    Path.join(Ecrits.Fuse.DocMount.canonical_root(Path.dirname(path)), Path.basename(path))
  end
end
