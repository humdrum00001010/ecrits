defmodule ContractWeb.MCP.MCPPlug do
  @moduledoc """
  Inbound MCP server. Speaks JSON-RPC 2.0 over Streamable HTTP per the MCP
  spec (single endpoint accepting both `application/json` and
  `text/event-stream`).

  Implements three JSON-RPC methods:

    * `initialize` — handshake, returns server info + capabilities.
    * `tools/list` — returns the tool descriptors from `Contract.Gateway`.
    * `tools/call` — dispatches to a tool by `params.name`.

  Tool dispatch is delegated to `Contract.Gateway.mcp_tool/3` so this plug
  contains no business logic. Tool handlers never see raw HTTP.

  ## Auth

  Every request MUST carry `Authorization: Bearer <token>`. The token is
  either a route_ref token (`Contract.Gateway.issue_route_ref/2`) or a
  user-API token (`Phoenix.Token.sign(endpoint, "api_token", user_id)`).
  Requests without a bearer get a 401 short-circuit before any JSON-RPC
  parsing.

  ## SSE

  When the client sends `Accept: text/event-stream`, the response is
  framed as `text/event-stream`, even for one-shot tools — a single
  `data: <json>\\n\\n` frame followed by stream end. This matches the MCP
  Streamable HTTP transport contract.
  """

  @behaviour Plug

  import Plug.Conn

  alias Contract.Accounts
  alias Contract.Context
  alias Contract.Gateway
  alias Contract.MCP
  alias Contract.RouteRef
  alias ContractWeb.MCP.JSONRPC

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    log_request(conn)

    case ensure_bearer(conn) do
      {:ok, conn, token_kind, principal} ->
        handle(conn, token_kind, principal)

      :error ->
        send_unauthorized(conn)
    end
  end

  # Diagnostic log so we can correlate OpenAI's hosted-MCP fetches with
  # the response we ship back. Logs at :info because the volume is low —
  # one per agent turn for tools/list (more if the cache misses).
  defp log_request(conn) do
    accept = conn |> get_req_header("accept") |> Enum.at(0, "")
    ua = conn |> get_req_header("user-agent") |> Enum.at(0, "")
    method_param = peek_method(conn)
    require Logger
    Logger.info("MCP req method=#{method_param} accept=#{accept} ua=#{ua}")
  end

  defp peek_method(conn) do
    body = Map.get(conn.assigns, :mcp_raw_body, "")

    case Jason.decode(body) do
      {:ok, %{"method" => m}} -> m
      _ -> "<unknown>"
    end
  end

  # ----------------------------------------------------------------------------
  # request handling
  # ----------------------------------------------------------------------------

  defp handle(conn, token_kind, principal) do
    body = Map.get(conn.assigns, :mcp_raw_body, "")

    case JSONRPC.parse_body(body) do
      {:ok, request} ->
        ctx = build_ctx(token_kind, principal)
        dispatch(conn, request, ctx)

      {:error, {code, message}} ->
        send_response(conn, JSONRPC.error_response(nil, code, message))
    end
  end

  defp dispatch(conn, %{method: "initialize", id: id, params: params}, _ctx) do
    send_response(conn, JSONRPC.success(id, MCP.initialize(params)))
  end

  defp dispatch(conn, %{method: "tools/list", id: id}, ctx) do
    route_ref = route_ref(ctx)
    send_response(conn, JSONRPC.success(id, MCP.list_tools(ctx, route_ref)))
  end

  defp dispatch(conn, %{method: "resources/list", id: id}, ctx) do
    route_ref = route_ref(ctx)
    send_response(conn, JSONRPC.success(id, MCP.list_resources(ctx, route_ref)))
  end

  defp dispatch(conn, %{method: "resources/read", id: id, params: params}, ctx) do
    route_ref = route_ref(ctx)
    uri = Map.get(params, "uri") || Map.get(params, :uri)

    if is_binary(uri) and uri != "" do
      case MCP.read_resource(ctx, route_ref, uri) do
        {:ok, payload} -> send_response(conn, JSONRPC.success(id, payload))
        {:error, reason} -> send_response(conn, JSONRPC.from_gateway_error(id, reason))
      end
    else
      send_response(
        conn,
        JSONRPC.error_response(id, JSONRPC.invalid_params_code(), "missing uri")
      )
    end
  end

  defp dispatch(conn, %{method: "tools/call", id: id, params: params}, ctx) do
    tool = Map.get(params, "name") || Map.get(params, :name)
    args = Map.get(params, "arguments") || Map.get(params, :arguments) || %{}

    cond do
      not is_binary(tool) or tool == "" ->
        send_response(
          conn,
          JSONRPC.error_response(id, JSONRPC.invalid_params_code(), "Missing tool name")
        )

      tool not in Gateway.tool_names() ->
        send_response(
          conn,
          JSONRPC.error_response(
            id,
            JSONRPC.method_not_found_code(),
            "Tool not found: #{tool}"
          )
        )

      true ->
        invoke_tool(conn, id, ctx, tool, args)
    end
  end

  defp dispatch(conn, %{method: method, id: id}, _ctx) do
    send_response(
      conn,
      JSONRPC.error_response(id, JSONRPC.method_not_found_code(), "Method not found: #{method}")
    )
  end

  # ----------------------------------------------------------------------------
  # tool invocation
  # ----------------------------------------------------------------------------

  defp invoke_tool(conn, id, ctx, tool, args) do
    result =
      try do
        Gateway.mcp_tool(ctx, tool, args)
      rescue
        e -> {:error, {:exception, Exception.message(e)}}
      end

    case result do
      {:ok, payload} ->
        send_response(conn, JSONRPC.success(id, render_tool_content(payload)))

      {:error, reason} ->
        send_response(conn, JSONRPC.from_gateway_error(id, reason))
    end
  end

  defp render_tool_content(payload) do
    text =
      case Jason.encode(payload, pretty: false) do
        {:ok, json} -> json
        {:error, _} -> inspect(payload)
      end

    %{
      "content" => [%{"type" => "text", "text" => text}],
      "isError" => false
    }
  end

  # ----------------------------------------------------------------------------
  # response framing — JSON vs SSE
  # ----------------------------------------------------------------------------

  defp send_response(conn, payload) do
    if sse?(conn) do
      send_sse(conn, payload)
    else
      send_json(conn, payload)
    end
  end

  defp send_json(conn, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload))
    |> halt()
  end

  defp send_sse(conn, payload) do
    json = Jason.encode!(payload)
    frame = "data: " <> json <> "\n\n"

    conn
    |> put_resp_content_type("text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_resp(200, frame)
    |> halt()
  end

  defp sse?(conn) do
    accept =
      conn
      |> get_req_header("accept")
      |> Enum.join(",")
      |> String.downcase()

    String.contains?(accept, "text/event-stream")
  end

  # ----------------------------------------------------------------------------
  # auth
  # ----------------------------------------------------------------------------

  @api_token_salt "api_token"
  @api_token_max_age 86_400 * 30

  defp ensure_bearer(conn) do
    with [auth] <- get_req_header(conn, "authorization"),
         "Bearer " <> token <- auth,
         {:ok, kind, principal} <- decode_bearer(token) do
      {:ok, conn, kind, principal}
    else
      _ -> :error
    end
  end

  defp decode_bearer(token) do
    case Gateway.verify_route_ref(nil, token) do
      {:ok, %RouteRef{} = ref} ->
        {:ok, :route_ref, ref}

      {:error, _} ->
        case Phoenix.Token.verify(ContractWeb.Endpoint, @api_token_salt, token,
               max_age: @api_token_max_age
             ) do
          {:ok, %{user_id: user_id} = payload} ->
            {:ok, :api_token, %{user_id: user_id, payload: payload}}

          {:ok, user_id} when is_binary(user_id) ->
            {:ok, :api_token, %{user_id: user_id, payload: %{user_id: user_id}}}

          {:error, _} ->
            :error
        end
    end
  end

  defp build_ctx(:route_ref, %RouteRef{} = ref) do
    %Context{
      user: user_for_route_ref(ref),
      perms: %{route_ref: ref, scopes: ref.scopes},
      now: DateTime.utc_now()
    }
  end

  defp build_ctx(:api_token, %{user_id: user_id} = principal) do
    user = Accounts.get_user!(user_id)

    %Context{
      user: user,
      perms: %{
        api_token: principal,
        user_id: user_id,
        scopes: Map.get(principal.payload, :scopes, [])
      },
      now: DateTime.utc_now()
    }
  rescue
    Ecto.NoResultsError -> %Context{perms: %{api_token: principal, user_id: user_id}}
  end

  defp route_ref(%Context{perms: %{route_ref: %RouteRef{} = ref}}), do: ref
  defp route_ref(_ctx), do: nil

  defp user_for_route_ref(%RouteRef{user_id: user_id}) when is_binary(user_id) do
    Accounts.get_user!(user_id)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp user_for_route_ref(_ref), do: nil

  defp send_unauthorized(conn) do
    body =
      Jason.encode!(JSONRPC.error_response(nil, JSONRPC.unauthorized_code(), "Unauthorized"))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end
