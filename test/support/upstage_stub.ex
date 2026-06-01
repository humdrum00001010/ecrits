defmodule Contract.IO.UpstageStub do
  @moduledoc """
  In-memory stand-in for `Contract.IO.Upstage` used by `FtcSeedJob`
  tests so we don't hit the Upstage Document Parse API.

  Mirrors the `parse/2` shape exposed by `Contract.IO.Upstage`. The
  caller pre-loads a canned response via `set_response/1` (or fails
  the next call via `fail_next/1`); each `parse/2` invocation pops
  the recorded call so tests can assert on it.

  Implementation note: `Mox` would be the cleaner answer, but
  Wave 5's worker reads its driver out of `:io_drivers` (the same
  Application-env swap used by legacy object-store stubs — Mox needs
  `Contract.IO.Upstage` to grow a `@behaviour`, which the Wave-5
  hard constraint "DON'T touch Engine/IO module bodies" forbids.
  """

  @table :upstage_stub

  def setup do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  def reset do
    setup()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc "Seed the response that the next `parse/2` call returns."
  def set_response(map) when is_map(map) do
    setup()
    :ets.insert(@table, {:response, map})
    :ok
  end

  def fail_next(reason) do
    setup()
    :ets.insert(@table, {:fail, reason})
    :ok
  end

  def calls do
    setup()

    @table
    |> :ets.match_object({{:call, :_}, :_})
    |> Enum.map(fn {{:call, _idx}, call} -> call end)
  end

  # ------------------------------------------------------------------
  # Driver surface — matches Contract.IO.Upstage.parse/2
  # ------------------------------------------------------------------

  def parse(file_or_path, opts \\ []) do
    setup()
    record_call({:parse, file_or_path, opts})

    case :ets.lookup(@table, :fail) do
      [{_, reason}] ->
        :ets.delete(@table, :fail)
        {:error, reason}

      [] ->
        case :ets.lookup(@table, :response) do
          [{_, response}] -> {:ok, response}
          [] -> {:ok, %{elements: [], content: %{}, raw: %{}}}
        end
    end
  end

  def normalize_elements(list), do: Contract.IO.Upstage.normalize_elements(list)

  defp record_call(call) do
    idx = :erlang.unique_integer([:monotonic])
    :ets.insert(@table, {{:call, idx}, call})
  end
end
