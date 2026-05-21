defmodule ContractWeb.Plug.RateLimitMCP do
  @moduledoc """
  Per-bearer fixed-window rate limit for `/mcp`.

  This is a sanity cap, not a fairness mechanism: it exists so a buggy or
  runaway agent run cannot pin the BEAM by hammering `/mcp` with crypto-heavy
  bearer verifications. Legitimate per-(user, doc, agent_run) traffic — even
  for chatty tool sequences — sits well below the default 120 req/min.

  ## Bucket key

  Mount this plug ahead of `ContractWeb.MCP.MCPPlug` so we shed load BEFORE
  doing the route_ref crypto verify. Because we can't trust the bearer's
  payload yet (verification happens downstream), we don't decode the
  route_ref here — instead we hash the raw bearer to derive a stable bucket
  key. Same `(user, doc, agent_run)` ⇒ same route_ref token ⇒ same hash ⇒
  same bucket. Two agent runs against the same doc still get independent
  buckets because their route_ref tokens differ.

  Requests with no `Authorization` header fall back to the peer IP so an
  unauthenticated flood still gets capped.

  ## Storage

  An ETS table (`#{__MODULE__}.Bucket`) keyed by `{key, window_start}`.
  Window resolution is whole-second epoch divided by `:window_ms`. Old rows
  are not actively pruned — they're overwritten when a new window for the
  same key opens, and stale keys age out via natural traffic. For a single
  node this is enough; multi-node deploys should swap to a shared backend.

  The table is owned by `ContractWeb.Plug.RateLimitMCP.Bucket` (started in
  `Contract.Application`). Test setup can reset it via `reset/0`.

  ## Config

      config :contract, ContractWeb.Plug.RateLimitMCP,
        limit: 120,        # max requests per window per bucket
        window_ms: 60_000  # rolling window size

  Either knob can be overridden per-call via plug opts (`limit:` /
  `window_ms:`) — useful in tests that want to provoke a 429 cheaply.
  """

  @behaviour Plug

  import Plug.Conn

  alias ContractWeb.MCP.JSONRPC
  alias ContractWeb.Plug.RateLimitMCP.Bucket

  @default_limit 120
  @default_window_ms 60_000

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    limit = Keyword.get(opts, :limit) || config(:limit, @default_limit)
    window_ms = Keyword.get(opts, :window_ms) || config(:window_ms, @default_window_ms)

    key = bucket_key(conn)

    case Bucket.hit(key, limit, window_ms) do
      :ok ->
        conn

      {:error, retry_after_seconds} ->
        send_429(conn, retry_after_seconds)
    end
  end

  # ---------------------------------------------------------------------------
  # bucket key derivation
  # ---------------------------------------------------------------------------

  defp bucket_key(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when byte_size(token) > 0 ->
        # Hash the raw bearer so the key is stable per token but we never
        # stash the token itself in ETS. SHA-256 is overkill for a bucket
        # key but is already linked into BEAM crypto — no extra cost.
        digest = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
        "mcp:bearer:" <> binary_part(digest, 0, 16)

      _ ->
        "mcp:ip:" <> ip_string(conn)
    end
  end

  defp ip_string(%Plug.Conn{remote_ip: ip}) when is_tuple(ip) do
    ip |> :inet.ntoa() |> List.to_string()
  end

  defp ip_string(_), do: "unknown"

  # ---------------------------------------------------------------------------
  # 429 response — JSON-RPC error envelope so MCP clients can parse it
  # ---------------------------------------------------------------------------

  defp send_429(conn, retry_after_seconds) do
    body =
      Jason.encode!(
        JSONRPC.error_response(
          nil,
          # -32_005: app-defined "rate limited". Outside the standard
          # JSON-RPC reserved range; MCP clients treat unknown app codes
          # as transport-layer failures, which is the right semantics.
          -32_005,
          "Rate limit exceeded",
          %{"retry_after" => retry_after_seconds}
        )
      )

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
    |> put_resp_content_type("application/json")
    |> send_resp(429, body)
    |> halt()
  end

  # ---------------------------------------------------------------------------
  # config helper
  # ---------------------------------------------------------------------------

  defp config(key, default) do
    :contract
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key, default)
  end

  # ---------------------------------------------------------------------------
  # test helpers
  # ---------------------------------------------------------------------------

  @doc "Clear all buckets. Test-only."
  def reset, do: Bucket.reset()
end
