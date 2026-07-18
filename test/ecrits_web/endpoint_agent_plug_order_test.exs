defmodule EcritsWeb.EndpointAgentPlugOrderTest do
  use ExUnit.Case, async: true

  @endpoint_source Path.expand("../../lib/ecrits_web/endpoint.ex", __DIR__)

  test "the doc-tools MCP plug runs before the dev code reloader" do
    # 2026-07-19 regression: a dep repin invalidated _build/dev, an agent's
    # doc.open_doc landed mid-recompile inside Phoenix.CodeReloader, and the
    # raw HTTP 500 CompileError killed the contract turn. Agent MCP traffic
    # must never absorb reloader failures — a briefly stale module beats a
    # dead transport, and the next browser request still recompiles.
    source = File.read!(@endpoint_source)

    mcp_at = index_of!(source, "plug EcritsWeb.Plugs.DocToolsMCPPlug")
    reloader_at = index_of!(source, "plug Phoenix.CodeReloader")

    assert mcp_at < reloader_at,
           "EcritsWeb.Plugs.DocToolsMCPPlug must be plugged before Phoenix.CodeReloader " <>
             "so agent tool calls never surface transient compile errors as HTTP 500s"
  end

  defp index_of!(source, fragment) do
    case :binary.match(source, fragment) do
      {index, _length} -> index
      :nomatch -> flunk("#{fragment} not found in endpoint.ex")
    end
  end
end
