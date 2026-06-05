defmodule Ecrits.Doc.MCPServer do
  @moduledoc """
  MCP server that exposes `Ecrits.Doc.Tools` (`doc.context/list/open/inspect/
  outline/read/find/get/set/edit/apply_style/save`) over the Model Context
  Protocol. `doc.read` is incremental (≤30 paragraphs/call); `doc.inspect`/
  `doc.get`/`doc.set` are the reflective property-IR surface.

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

  @impl true
  def handle_call_tool(name, arguments, state) do
    # Strip the protocol `_meta` envelope ex_mcp folds into arguments.
    {_meta, args} = Map.pop(arguments || %{}, "_meta")

    case Tools.call(tool_context(), name, args) do
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

  # The doc tools operate against the default-named `Ecrits.Doc.Pool`.
  defp tool_context, do: %{pool: Ecrits.Doc.Pool}

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
