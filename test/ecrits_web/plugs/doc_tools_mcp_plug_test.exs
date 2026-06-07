defmodule EcritsWeb.Plugs.DocToolsMCPPlugTest do
  @moduledoc """
  The per-agent MCP isolation seam (Phase 2): the plug at
  `/mcp/doc-tools/<agent_id>` must splice the url's agent id into a `tools/call`
  JSON-RPC body so it survives the process hop into the MCP handler (which only
  sees `params`). We assert on `conn.assigns[:raw_body]` — the cache the
  delegated `ExMCP.HttpPlug` reads instead of the consumed body.
  """
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias EcritsWeb.Plugs.DocToolsMCPPlug

  @opts DocToolsMCPPlug.init([])

  defp post(path, body) do
    conn(:post, path, Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2025-06-18")
    |> DocToolsMCPPlug.call(@opts)
  end

  test "a tools/call on the per-agent url injects _agent_id into the tool arguments" do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "tools/call",
      "params" => %{"name" => "doc.context", "arguments" => %{"foo" => "bar"}}
    }

    conn = post("/mcp/doc-tools/fg-abc123", body)

    assert is_binary(conn.assigns[:raw_body])
    decoded = Jason.decode!(conn.assigns.raw_body)
    args = decoded["params"]["arguments"]

    # The url's agent id is threaded in; the original arguments are preserved.
    assert args["_agent_id"] == "fg-abc123"
    assert args["foo"] == "bar"
  end

  test "a percent-encoded agent id segment is decoded before threading" do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{"name" => "doc.context", "arguments" => %{}}
    }

    conn = post("/mcp/doc-tools/fg%2Fweird", body)

    decoded = Jason.decode!(conn.assigns.raw_body)
    assert decoded["params"]["arguments"]["_agent_id"] == "fg/weird"
  end

  test "non tools/call messages (initialize) are not rewritten" do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "initialize",
      "params" => %{"protocolVersion" => "2025-06-18"}
    }

    conn = post("/mcp/doc-tools/fg-abc123", body)

    # Body is still stashed (so the delegated plug reads it) but carries no
    # injected _agent_id — initialize has no tool arguments.
    decoded = Jason.decode!(conn.assigns.raw_body)
    refute get_in(decoded, ["params", "arguments"])
  end

  test "the legacy bare mount (no agent id) does not inject an agent id" do
    body = %{
      "jsonrpc" => "2.0",
      "id" => 4,
      "method" => "tools/call",
      "params" => %{"name" => "doc.context", "arguments" => %{}}
    }

    conn = post("/mcp/doc-tools", body)

    # No agent id in the url → nothing to splice; the body is left untouched
    # (no raw_body cache written by us), so the delegated plug reads it normally.
    case conn.assigns[:raw_body] do
      nil ->
        :ok

      raw ->
        refute get_in(Jason.decode!(raw), ["params", "arguments", "_agent_id"])
    end
  end
end
