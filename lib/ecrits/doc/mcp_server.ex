defmodule Ecrits.Doc.MCPServer do
  @moduledoc """
  MCP server that exposes `Ecrits.Doc.Tools` (`doc.context/list/open/create/
  read/find/get/set/edit/save` — ten tools) over the Model Context Protocol.
  `doc.read` is incremental (≤30 paragraphs/call); `doc.get` (type + current
  values + settable property names + children) and `doc.set` (universal property
  setter, incl. char formatting) are the reflective property-IR surface.

  This is the ACP-native bridge: rather than a bespoke tool loop, the document
  abstraction is published as a standard MCP server (ex_mcp's core competency)
  and handed to the ACP session via `ExMCP.ACP.Client.new_session(client, cwd,
  mcp_servers: [...])`. The coding agent (codex / claude, over ACP) then
  *discovers* and *calls* these tools itself; ex_mcp routes each call here, we
  delegate to `Ecrits.Doc.Tools.call/3`, and the agent's `tool_call` /
  `tool_call_update` `session/update`s render in the chat-rail tool_call block.

  Served over HTTP via `ExMCP.HttpPlug` (mounted in `EcritsWeb.Endpoint`), so an
  external provider subprocess can reach this in-process BEAM server through a
  streamable-HTTP MCP transport.
  """

  use ExMCP.Server.Handler

  alias Ecrits.Doc.Tools
  alias Ecrits.Local.AcpAgent.Session, as: AgentLive
  alias Ecrits.Workspace.Session, as: WorkspaceSession

  @server_name "ecrits-doc-tools"
  @server_version "0.1.0"

  @impl true
  def init(_args), do: {:ok, %{}}

  @impl true
  def handle_initialize(_params, state) do
    {:ok,
     %{
       protocolVersion: "2025-06-18",
       serverInfo: %{name: @server_name, version: @server_version},
       capabilities: capabilities()
     }, state}
  end

  # `ExMCP.HttpPlug`'s message-processor `initialize` path calls
  # `handler.get_capabilities/0` *directly* (an artifact of the `use ExMCP.Server`
  # DSL style), bypassing the `handle_initialize/2` callback this `Handler`
  # module implements. Without it that path raises `UndefinedFunctionError` and
  # the MCP handshake intermittently fails. Provide it so both initialize paths
  # report the same capability set.
  def get_capabilities, do: capabilities()

  defp capabilities, do: %{tools: %{}}

  @impl true
  def handle_list_tools(_cursor, state) do
    {:ok, Enum.map(Tools.tools(), &to_mcp_tool/1), nil, state}
  end

  # Codex's MCP connection manager probes `resources/list` on *every* server
  # right after `initialize` (before it builds the per-turn tool list). The
  # `ExMCP.Server.Handler` default answers it with a JSON-RPC error
  # (`-32603 "Resources not implemented"`), which codex logs as a WARN and which
  # makes the freshly-connected server look partially-broken during the exact
  # window when codex is deciding whether the doc tools are ready for the turn.
  # We expose no resources, so answer the probe cleanly with an empty list — the
  # server then presents as fully healthy the instant `initialize` completes,
  # so codex reliably includes the 12 `doc.*` tools in the turn's tool list.
  @impl true
  def handle_list_resources(_cursor, state), do: {:ok, [], nil, state}

  @impl true
  def handle_call_tool(name, arguments, state) do
    # Strip the protocol `_meta` envelope ex_mcp folds into arguments, and the
    # `_agent_id` the per-agent MCP url's plug splices in (the isolation seam).
    {_meta, args} = Map.pop(arguments || %{}, "_meta")
    {agent_id, args} = Map.pop(args, "_agent_id")

    case resolve_tool_context(agent_id) do
      {:ok, ctx} ->
        run_tool(ctx, name, args, state)

      {:error, reason} ->
        {:ok, %{content: [json_content(reason)], isError: true}, state}
    end
  end

  defp run_tool(ctx, name, args, state) do
    case Tools.call(ctx, name, args) do
      {:ok, result} ->
        {:ok, %{content: [json_content(result)], structuredContent: result}, state}

      {:error, %{} = structured} ->
        # Tool-level error the agent should act on (conflict, capability gap):
        # surface as an error *result* (isError), not a protocol error.
        {:ok, %{content: [json_content(structured)], isError: true}, state}

      {:error, reason} ->
        {:ok, %{content: [text_content(format_error(reason))], isError: true}, state}
    end
  end

  # Build the doc.* tool context (design invariant 3). The agent id from the
  # per-agent MCP url resolves — via `Workspace.Session.fetch_agent/1` — to the
  # live AgentLive; we read ITS doc context (`active_doc` = the doc this agent is
  # bound to) and dispatch the tool there. The result is `%{pool, agent_id,
  # active_doc}`: `doc.context` returns THIS agent's active doc, and
  # `doc.open`/`doc.edit` honour per-agent ownership — never a global
  # `Pool.active`.
  #
  # An absent agent id (legacy bare mount, or a non-agent caller in a test) keeps
  # the prior pool-only context so direct `Tools.call(%{pool: …}, …)` behaviour is
  # preserved. An agent id that does NOT resolve (dead/unknown) is rejected so a
  # tool never silently runs against the wrong context.
  defp resolve_tool_context(nil), do: {:ok, %{pool: Ecrits.Doc.Pool}}

  defp resolve_tool_context(agent_id) when is_binary(agent_id) do
    case WorkspaceSession.fetch_agent(agent_id) do
      {:ok, pid} ->
        %{active_doc: active_doc, workspace_root: workspace_root} = AgentLive.tool_context(pid)

        {:ok,
         %{
           pool: Ecrits.Doc.Pool,
           agent_id: agent_id,
           active_doc: active_doc,
           # The workspace path that keys this agent's `Ecrits.Workspace.Session`,
           # so the doc.* tools reach Session for per-doc ownership (invariant 2),
           # the human-viewer registry, and the wasm/NIF routing decision — the
           # real home of what Phase 2 parked in the global Pool.
           session_path: workspace_root
         }}

      :error ->
        {:error, %{"error" => "agent_not_found", "agent_id" => agent_id}}
    end
  end

  defp to_mcp_tool(%{"namespace" => ns, "name" => name} = tool) do
    %{
      name: ns <> "." <> name,
      description: tool["description"],
      inputSchema: tool["inputSchema"] || %{"type" => "object"},
      annotations: tool["annotations"] || %{}
    }
  end

  defp json_content(value) do
    %{type: "text", text: Jason.encode!(value)}
  end

  defp text_content(text) do
    %{type: "text", text: to_string(text)}
  end

  defp format_error({:unknown_tool, name}), do: "Unknown tool: #{name}"
  defp format_error({:invalid_params, message}), do: "Invalid params: #{message}"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
