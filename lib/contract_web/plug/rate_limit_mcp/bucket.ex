defmodule ContractWeb.Plug.RateLimitMCP.Bucket do
  @moduledoc false
  # ETS-backed fixed-window counter. One ETS table; rows keyed by
  # `{bucket_key, window_start_ms}`. `hit/3` increments atomically via
  # `:ets.update_counter/4` (with a default tuple) and returns either `:ok`
  # or `{:error, retry_after_seconds}` once the count exceeds `limit`.
  #
  # The GenServer's only job is to own the table so it survives across
  # plug invocations. It otherwise has no state.

  use GenServer

  @table __MODULE__

  # ---------------------------------------------------------------------------
  # public API
  # ---------------------------------------------------------------------------

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Record one hit against `key` with the given `limit` per `window_ms`.

  Returns `:ok` if the request is within budget, `{:error, retry_after}`
  (seconds, ≥ 1) once the budget for the current window is exhausted.
  """
  @spec hit(String.t(), pos_integer(), pos_integer()) ::
          :ok | {:error, pos_integer()}
  def hit(key, limit, window_ms)
      when is_binary(key) and is_integer(limit) and limit > 0 and
             is_integer(window_ms) and window_ms > 0 do
    now_ms = System.system_time(:millisecond)
    window_start = div(now_ms, window_ms) * window_ms
    ets_key = {key, window_start}

    count =
      try do
        :ets.update_counter(@table, ets_key, {2, 1}, {ets_key, 0})
      rescue
        # Table missing (eg. in unit tests that don't boot the app) — fail
        # open rather than rejecting traffic.
        ArgumentError -> 1
      end

    if count > limit do
      retry_after_ms = window_start + window_ms - now_ms
      {:error, max(1, div(retry_after_ms, 1000) + 1)}
    else
      :ok
    end
  end

  @doc "Clear the entire bucket table. Test-only."
  def reset do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    # `:public` so any plug invocation (across any scheduler) can write
    # without round-tripping through this process. `read_concurrency` /
  # `write_concurrency` because every `/mcp` request touches it.
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end
end
