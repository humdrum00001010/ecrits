defmodule Ecrits.AcpAgent.CodexAdapter do
  @moduledoc false

  @behaviour ExMCP.ACP.Adapter

  alias ExMCP.ACP.Adapters.Codex

  @impl true
  defdelegate init(opts), to: Codex
  @impl true
  defdelegate command(opts), to: Codex
  @impl true
  defdelegate capabilities(), to: Codex
  @impl true
  defdelegate modes(), to: Codex
  @impl true
  defdelegate config_options(), to: Codex
  @impl true
  defdelegate post_connect(state), to: Codex
  @impl true
  defdelegate translate_outbound(message, state), to: Codex

  @impl true
  def translate_inbound(line, state) do
    case mcp_startup_update(line, state) do
      nil -> Codex.translate_inbound(line, state)
      update -> {:messages, [update], state}
    end
  end

  defp mcp_startup_update(line, state) when is_binary(line) do
    with {:ok,
          %{
            "method" => "mcpServer/startupStatus/updated",
            "params" => %{"name" => name, "status" => status} = params
          }} <- Jason.decode(line),
         session_id when is_binary(session_id) and session_id != "" <-
           params["threadId"] || Map.get(state, :thread_id) do
      %{
        "jsonrpc" => "2.0",
        "method" => "session/update",
        "params" => %{
          "sessionId" => session_id,
          "update" => %{
            "sessionUpdate" => "mcp_server_startup",
            "serverName" => name,
            "status" => status,
            "error" => params["error"] || params["failureReason"]
          }
        }
      }
    else
      _ -> nil
    end
  end

  defp mcp_startup_update(_line, _state), do: nil
end
