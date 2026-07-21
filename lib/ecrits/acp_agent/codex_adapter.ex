defmodule Ecrits.AcpAgent.CodexAdapter do
  @moduledoc false

  @behaviour ExMCP.ACP.Adapter

  alias ExMCP.ACP.Adapters.Codex

  @impl true
  defdelegate init(opts), to: Codex
  @impl true
  def command(opts) do
    explicit_path = Keyword.get(opts, :codex_path) || System.get_env("CODEX_PATH")
    search_path = Keyword.get(opts, :codex_search_path, System.get_env("PATH", ""))

    opts =
      opts
      |> Keyword.delete(:codex_search_path)
      |> maybe_put_codex_path(explicit_path || resolve_codex_path(search_path))

    Codex.command(opts)
  end

  @doc false
  def resolve_codex_path(search_path \\ System.get_env("PATH", "")) do
    candidates =
      search_path
      |> String.split(path_separator(), trim: true)
      |> Enum.uniq()
      |> Enum.flat_map(&codex_candidates/1)
      |> Enum.filter(&executable?/1)

    Enum.find(candidates, &(not transient_package_shim?(&1))) || List.first(candidates)
  end

  @impl true
  defdelegate capabilities(), to: Codex
  @impl true
  defdelegate auth_methods(opts), to: Codex
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

  defp maybe_put_codex_path(opts, nil), do: opts
  defp maybe_put_codex_path(opts, path), do: Keyword.put(opts, :codex_path, path)

  defp codex_candidates(dir) do
    names =
      if match?({:win32, _}, :os.type()), do: ["codex.exe", "codex.cmd", "codex"], else: ["codex"]

    Enum.map(names, &Path.join(dir, &1))
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %{type: :regular, mode: mode}} ->
        match?({:win32, _}, :os.type()) or Bitwise.band(mode, 0o111) != 0

      _stat ->
        false
    end
  end

  defp transient_package_shim?(path) do
    normalized = String.replace(path, "\\", "/")
    String.contains?(normalized, "/node_modules/.bin/")
  end

  defp path_separator do
    if match?({:win32, _}, :os.type()), do: ";", else: ":"
  end
end
