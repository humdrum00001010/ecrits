defmodule Ecrits.AcpAgent.ClaudeAdapter do
  @moduledoc false

  @behaviour ExMCP.ACP.Adapter

  alias ExMCP.ACP.Adapters.ClaudeSDK

  @impl true
  def init(opts), do: opts |> normalize_opts() |> ClaudeSDK.init()

  @impl true
  def command(opts), do: opts |> normalize_opts() |> ClaudeSDK.command()

  @impl true
  def env(opts), do: opts |> normalize_opts() |> ClaudeSDK.env()

  @impl true
  defdelegate capabilities(), to: ClaudeSDK

  @impl true
  defdelegate post_connect(state), to: ClaudeSDK

  @impl true
  defdelegate modes(), to: ClaudeSDK

  @impl true
  defdelegate config_options(), to: ClaudeSDK

  @impl true
  def auth_methods(opts), do: opts |> normalize_opts() |> ClaudeSDK.auth_methods()

  @impl true
  def auth_methods(opts, state), do: opts |> normalize_opts() |> ClaudeSDK.auth_methods(state)

  @impl true
  defdelegate list_sessions(params, state), to: ClaudeSDK

  @impl true
  defdelegate fork_session(params, state), to: ClaudeSDK

  @impl true
  defdelegate translate_outbound(message, state), to: ClaudeSDK

  @impl true
  defdelegate translate_inbound(line, state), to: ClaudeSDK

  defp normalize_opts(opts) do
    Keyword.update(opts, :mcp_servers, %{}, &normalize_mcp_servers/1)
  end

  defp normalize_mcp_servers(servers) when is_map(servers), do: servers

  defp normalize_mcp_servers(servers) when is_list(servers) do
    Map.new(servers, fn server ->
      server = stringify_keys(server)
      name = Map.fetch!(server, "name")

      config =
        server
        |> Map.delete("name")
        |> infer_transport_type()

      {name, config}
    end)
  end

  defp infer_transport_type(%{"type" => _type} = server), do: server
  defp infer_transport_type(%{"url" => _url} = server), do: Map.put(server, "type", "http")
  defp infer_transport_type(server), do: server

  defp stringify_keys(server) when is_map(server) do
    Map.new(server, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end
end
