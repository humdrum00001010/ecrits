defmodule Ecrits.Doc.MCPServerAgentContextTest do
  @moduledoc """
  The MCP-isolation resolution (Phase 2): `Ecrits.Doc.MCPServer.handle_call_tool/3`
  takes the `_agent_id` the per-agent url's plug splices into the tool arguments,
  resolves it via `Ecrits.Workspace.Session.fetch_agent/1` to the live AgentLive,
  and dispatches the tool in THAT agent's document context (its own active doc) —
  never a global `Pool.active`. An unknown/dead agent id is rejected.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.MCPServer
  alias Ecrits.Doc.Pool
  alias Ecrits.Local.AcpAgent.Session, as: AgentLive
  alias Ecrits.Test.FakeEhwpRuntime

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)
    on_exit(fn -> restore(:ehwp, :runtime, prev) end)
    :ok
  end

  # Start a headless AgentLive (no provider turn needed; we only read its
  # tool_context), bound to `pool_document_id`.
  defp start_agent(id, pool_document_id, opts \\ []) do
    start_supervised!(
      {AgentLive,
       id: id,
       ctx: nil,
       provider: %{id: "codex"},
       exmcp_adapter: EcritsWeb.FakeAcpAdapter,
       adapter_opts: [exmcp_adapter: EcritsWeb.FakeAcpAdapter],
       workspace_root: File.cwd!(),
       document_path: Keyword.get(opts, :document_path),
       pool_document_id: pool_document_id,
       mcp_servers: []},
      id: {:agent, id}
    )
  end

  defp call_tool(name, args) do
    {:ok, state} = MCPServer.init([])
    MCPServer.handle_call_tool(name, args, state)
  end

  test "an unknown agent id is rejected (agent_not_found), tool never runs" do
    assert {:ok, %{content: [content], isError: true}, _state} =
             call_tool("doc.context", %{"_agent_id" => "nope-not-real"})

    assert %{"error" => "agent_not_found", "agent_id" => "nope-not-real"} =
             Jason.decode!(content.text)
  end

  test "doc.context resolves to the calling agent's OWN active doc (no global active)" do
    # The (default-named, global) Pool has TWO docs open.
    {:ok, a} = Pool.open("ctx_a.hwp", kind: :hwp, open_opts: [__text__: "A"])
    {:ok, b} = Pool.open("ctx_b.hwp", kind: :hwp, open_opts: [__text__: "B"])
    on_exit(fn -> Enum.each([a, b], &Pool.close/1) end)

    # Two agents, each bound to a DIFFERENT doc.
    id1 = "fg-ctx-#{System.unique_integer([:positive])}"
    id2 = "fg-ctx-#{System.unique_integer([:positive])}"
    start_agent(id1, a)
    start_agent(id2, b)

    # The MCP call carries the agent id (as the plug would splice it); each agent
    # sees only ITS bound doc, never the global active.
    assert {:ok, %{content: [content1]} = response1, _} =
             call_tool("doc.context", %{"_agent_id" => id1})

    assert %{"current_document" => current1} = decoded1 = Jason.decode!(content1.text)
    assert Map.keys(decoded1) == ["current_document"]

    assert current1["document"] == a
    assert current1["name"] == "ctx_a.hwp"

    # Token economy: the result rides ONCE (the content text block) — no
    # `structuredContent` duplicate for the CLI agent to round-trip into the
    # model context.
    refute Map.has_key?(response1, :structuredContent)

    assert {:ok, %{content: [content2]}, _} = call_tool("doc.context", %{"_agent_id" => id2})

    assert %{"current_document" => current2} = decoded2 = Jason.decode!(content2.text)
    assert Map.keys(decoded2) == ["current_document"]

    assert current2["document"] == b
    assert current2["name"] == "ctx_b.hwp"
  end

  test "doc.context exposes the UI-selected document path even before a pool id is active" do
    id = "fg-path-#{System.unique_integer([:positive])}"
    start_agent(id, nil, document_path: "drafts/current.hwpx")

    assert {:ok, %{content: [content]}, _} = call_tool("doc.context", %{"_agent_id" => id})

    assert %{"current_document" => current} = decoded = Jason.decode!(content.text)
    assert Map.keys(decoded) == ["current_document"]

    assert current == %{
             "document" => "drafts/current.hwpx",
             "name" => "current.hwpx",
             "kind" => "hwpx",
             "path" => "drafts/current.hwpx",
             "backing" => nil,
             "active" => true
           }
  end

  test "an absent _agent_id keeps the legacy pool-only context (back-compat)" do
    {:ok, doc} = Pool.open("ctx_legacy.hwp", kind: :hwp, open_opts: [__text__: "L"])
    on_exit(fn -> Pool.close(doc) end)

    # A bare (agent-less) context has no active doc — the global active is gone.
    # The open-doc catalog belongs to doc.list, not doc.context.
    assert {:ok, %{content: [content]}, _} = call_tool("doc.context", %{})

    assert %{"current_document" => nil} = decoded = Jason.decode!(content.text)
    assert Map.keys(decoded) == ["current_document"]

    assert {:ok, %{content: [list_content]}, _} = call_tool("doc.list", %{})
    assert %{"documents" => docs} = Jason.decode!(list_content.text)
    assert Enum.any?(docs, &(&1["document"] == doc))
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
