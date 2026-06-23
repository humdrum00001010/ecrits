defmodule Ecrits.IO.LawMCP do
  @moduledoc """
  Direct JSON-RPC client for the legal-rag MCP server.

  This is used by background jobs and server-side callers (e.g.
  citation verification batches) that don't go through the agent's
  OpenAI MCP-tool pipe.

  legal-rag is the structured-RAG layer (review_clause / search_rules /
  review_document) that also proxies `search_law`, `verify_citations`,
  `get_law_text`, and `search_decisions` through to korean-law-mcp, so the
  JSON-RPC contract this client speaks is unchanged from the direct
  korean-law-mcp integration.

  Endpoint: configured via `:law_mcp` (`LAW_MCP_URL`, defaults to
  `http://localhost:4001/mcp`) with `?oc=<LAW_OC>` appended. Transport is
  Streamable HTTP (the server accepts both `application/json` and
  `text/event-stream`).
  """

  @default_timeout 30_000

  @doc """
  Invokes any MCP tool by name. Returns the parsed JSON content payload.
  """
  @spec call(String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(tool_name, args, opts \\ []) when is_binary(tool_name) and is_map(args) do
    cfg = Application.fetch_env!(:ecrits, :law_mcp)
    endpoint = Keyword.get(opts, :endpoint) || cfg[:endpoint]
    oc = Keyword.get(opts, :oc) || cfg[:oc] || "openapi"
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    id = Keyword.get(opts, :id, System.unique_integer([:positive]))

    body = %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => tool_name, "arguments" => args}
    }

    url = "#{endpoint}?oc=#{oc}"

    request_opts =
      Keyword.merge(
        [
          headers: [
            {"accept", "application/json, text/event-stream"},
            {"content-type", "application/json"}
          ],
          json: body,
          receive_timeout: timeout
        ],
        Keyword.get(opts, :req_opts, [])
      )

    case Req.post(url, request_opts) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        response_body
        |> ensure_decoded()
        |> parse_response()

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:law_mcp_http, status, body}}

      {:error, reason} ->
        {:error, {:law_mcp_transport, reason}}
    end
  end

  defp ensure_decoded(body) when is_map(body), do: body

  defp ensure_decoded(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} -> map
      {:error, _} -> body
    end
  end

  defp ensure_decoded(body), do: body

  @doc """
  Convenience wrapper around `search_law`. Returns a list of law records
  (`law_id` / `mst` / title / score).
  """
  @spec search_law(String.t(), keyword()) :: {:ok, list()} | {:error, term()}
  def search_law(query, opts \\ []) when is_binary(query) do
    args =
      %{"query" => query}
      |> maybe_put("limit", Keyword.get(opts, :limit))

    case call("search_law", args, opts) do
      {:ok, result} -> {:ok, normalize_list(result)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Verifies citations inside legal text (e.g. `"민법 제390조에 따라..."` or a
  list of pre-extracted citations like `["민법 제390조", "상법 제42조"]`).

  The MCP `verify_citations` tool takes a `text` argument and parses
  citations out of it (per the tool's `inputSchema`). For convenience this
  function accepts either a string or a list of strings — lists are
  joined with newlines before being sent.

  Returns the parsed `result.content[0].text` payload (a list of
  `%{"citation", "valid"...}` maps when the server returns one).
  """
  @spec verify_citations(String.t() | [String.t()], keyword()) :: {:ok, list()} | {:error, term()}
  def verify_citations(text, opts \\ [])

  def verify_citations(text, opts) when is_binary(text) do
    args =
      %{"text" => text, "maxCitations" => Keyword.get(opts, :max_citations, 15)}

    case call("verify_citations", args, opts) do
      {:ok, result} -> {:ok, normalize_list(result)}
      {:error, _} = err -> err
    end
  end

  def verify_citations(citations, opts) when is_list(citations) do
    verify_citations(Enum.join(citations, "\n"), opts)
  end

  # --- Ecrits.IO façade entrypoints -----------------------------------

  @doc false
  def search_law(_ctx, query, opts) when is_binary(query), do: search_law(query, opts)

  @doc false
  def verify_citations(_ctx, citation, opts) when is_binary(citation),
    do: verify_citations([citation], opts)

  def verify_citations(_ctx, citations, opts) when is_list(citations),
    do: verify_citations(citations, opts)

  # --- internals --------------------------------------------------------

  defp parse_response(%{"error" => error}), do: {:error, {:law_mcp_rpc, error}}

  defp parse_response(%{"result" => %{"content" => [%{"text" => text} | _]}}) do
    case Jason.decode(text) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, text}
    end
  end

  defp parse_response(%{"result" => %{"content" => content}}) when is_list(content) do
    {:ok, content}
  end

  defp parse_response(%{"result" => result}), do: {:ok, result}

  defp parse_response(other), do: {:error, {:law_mcp_unparseable, other}}

  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(%{"items" => items}) when is_list(items), do: items
  defp normalize_list(%{"results" => items}) when is_list(items), do: items
  defp normalize_list(other), do: [other]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
