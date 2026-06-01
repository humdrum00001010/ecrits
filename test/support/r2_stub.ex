defmodule Contract.IO.R2Stub do
  @moduledoc """
  In-memory legacy object-store stand-in used by DB-backed Store/Session tests
  so they do not hit retired cloud storage.

  Uses a shared ETS table (`:r2_stub_objects`) so background tasks and
  GenServer processes spawned during a test still see the same object map.
  """

  @table :r2_stub_objects

  @doc "Ensures the ETS table exists. Idempotent."
  def setup do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc "Clear all stored objects + flags. Call from `setup` of each test."
  def reset do
    setup()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Toggle the next operation of the given kind to fail with the given reason."
  def fail_next(:put, reason) do
    setup()
    :ets.insert(@table, {{:flag, :fail_put}, reason})
    :ok
  end

  def fail_next(:delete, reason) do
    setup()
    :ets.insert(@table, {{:flag, :fail_delete}, reason})
    :ok
  end

  def block_next_delete(owner_pid \\ self()) when is_pid(owner_pid) do
    setup()
    ref = make_ref()
    :ets.insert(@table, {{:flag, :block_delete}, {owner_pid, ref}})
    ref
  end

  def calls do
    setup()

    @table
    |> :ets.match_object({{:call, :_}, :_})
    |> Enum.map(fn {{:call, _idx}, call} -> call end)
  end

  def objects do
    setup()

    @table
    |> :ets.match_object({{:obj, :_}, :_})
    |> Map.new(fn {{:obj, key}, body} -> {key, body} end)
  end

  def put(key, body, opts \\ []) do
    setup()
    record_call({:put, key, byte_size(body), opts})

    case :ets.lookup(@table, {:flag, :fail_put}) do
      [{_, reason}] ->
        :ets.delete(@table, {:flag, :fail_put})
        {:error, reason}

      [] ->
        :ets.insert(@table, {{:obj, key}, body})
        {:ok, %{key: key, etag: "\"stub\""}}
    end
  end

  def get(key, _opts \\ []) do
    setup()
    record_call({:get, key})

    case :ets.lookup(@table, {:obj, key}) do
      [{_, body}] -> {:ok, body}
      [] -> {:error, :not_found}
    end
  end

  def delete(key, _opts \\ []) do
    setup()
    record_call({:delete, key})
    maybe_block_delete(key)

    case :ets.lookup(@table, {:flag, :fail_delete}) do
      [{_, reason}] ->
        :ets.delete(@table, {:flag, :fail_delete})
        {:error, reason}

      [] ->
        :ets.delete(@table, {:obj, key})
        :ok
    end
  end

  def presigned_url(key, _opts \\ []) do
    {:ok, "https://stub.r2/#{key}"}
  end

  defp record_call(call) do
    idx = :erlang.unique_integer([:monotonic])
    :ets.insert(@table, {{:call, idx}, call})
  end

  defp maybe_block_delete(key) do
    case :ets.take(@table, {:flag, :block_delete}) do
      [{_, {owner_pid, ref}}] ->
        send(owner_pid, {:r2_delete_blocked, ref, key, self()})

        receive do
          {:r2_delete_continue, ^ref} -> :ok
        after
          5_000 -> exit({:r2_delete_block_timeout, key})
        end

      [] ->
        :ok
    end
  end
end
