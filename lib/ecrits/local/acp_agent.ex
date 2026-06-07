defmodule Ecrits.Local.AcpAgent do
  @moduledoc """
  The sole local chat-agent boundary, backed entirely by `ExMCP.ACP`.

  Provider routing, session lifecycle, provider-availability checks, and the
  PubSub event contract all live on the ex_mcp path — there is no bespoke
  fallback or safety-net. Providers map to a concrete ex_mcp ACP agent adapter
  (`ExMCP.ACP.Adapters.Codex` / `Claude`); a per-session
  `Ecrits.Local.AcpAgent.Session` GenServer drives `ExMCP.ACP.Client`.

  Each session is given the `doc.*` MCP server (served in-process over HTTP by
  `Ecrits.Doc.MCPServer`) via `new_session(..., mcp_servers: ...)`, so the agent
  discovers and calls `doc.list/open/read/edit/...` itself.
  """

  alias ExMCP.ACP.Adapters.Claude, as: ExMCPClaude
  alias ExMCP.ACP.Adapters.Codex, as: ExMCPCodex
  alias Ecrits.Local.AcpAgent.Session
  alias Ecrits.Local.AcpAgent.SessionSupervisor

  @providers [
    %{
      id: "codex",
      label: "Codex",
      icon: "local-agent-provider-codex",
      favicon_src: "/images/icons/openai-blossom.svg",
      exmcp_adapter: ExMCPCodex,
      executables: ["codex"]
    },
    %{
      id: "claude",
      label: "Claude",
      icon: "local-agent-provider-claude",
      favicon_src: "/images/icons/claude-favicon.ico",
      exmcp_adapter: ExMCPClaude,
      executables: ["claude"]
    }
  ]

  @doc_tools_mcp_name "doc"

  # ── provider metadata ──────────────────────────────────────────────

  @doc "Public provider metadata for the UI (id/label/icon/favicon)."
  def providers, do: Enum.map(@providers, &public_provider_metadata/1)
  def provider_metadata, do: providers()

  def supported_provider_ids, do: Enum.map(@providers, & &1.id)

  def default_provider_id do
    configured =
      :ecrits
      |> Application.get_env(:local_agent, [])
      |> Keyword.get(:provider, "codex")
      |> normalize_provider_id()

    if configured in supported_provider_ids(), do: configured, else: "codex"
  end

  def fetch_provider(id) do
    normalized = normalize_provider_id(id)

    case Enum.find(@providers, &(&1.id == normalized)) do
      nil -> {:error, {:unsupported_provider, id, supported_provider_ids()}}
      provider -> {:ok, provider}
    end
  end

  def public_provider_metadata(provider) when is_map(provider) do
    Map.take(provider, [:id, :label, :icon, :favicon_src])
  end

  @doc """
  Provider-availability rows (relocated from the deleted bespoke adapters):
  resolves each provider's CLI binary so the workspace UI can show ready/missing.
  """
  def integration_options do
    Enum.map(@providers, &integration_option/1)
  end

  defp integration_option(%{id: id, label: label, executables: executables}) do
    case resolve_executable(executables) do
      {:ok, %{command: command, path: path}} ->
        %{
          id: id,
          label: provider_integration_label(label),
          status: :ready,
          detail: "#{command} at #{path}"
        }

      {:error, {:executable_missing, candidates}} ->
        %{
          id: id,
          label: provider_integration_label(label),
          status: :missing,
          detail: "Install #{Enum.join(candidates, " or ")}"
        }
    end
  end

  defp provider_integration_label(label), do: "#{label} CLI/ACP"

  defp resolve_executable(candidates) do
    Enum.find_value(candidates, {:error, {:executable_missing, candidates}}, fn candidate ->
      case System.find_executable(candidate) do
        nil -> nil
        path -> {:ok, %{command: candidate, path: path}}
      end
    end)
  end

  # ── session lifecycle ──────────────────────────────────────────────

  def start_session(ctx, opts \\ []) when is_list(opts) do
    provider_id = Keyword.get(opts, :provider, default_provider_id())

    with {:ok, provider} <- fetch_provider(provider_id) do
      id = Keyword.get(opts, :id, Ecto.UUID.generate())
      adapter_opts = Keyword.get(opts, :adapter_opts, [])

      # The concrete ex_mcp ACP adapter is normally chosen by provider; tests may
      # inject a fake ex_mcp adapter via `adapter_opts[:exmcp_adapter]`.
      exmcp_adapter = Keyword.get(adapter_opts, :exmcp_adapter, provider.exmcp_adapter)

      args = [
        id: id,
        ctx: ctx,
        provider: public_provider_metadata(provider),
        exmcp_adapter: exmcp_adapter,
        adapter_opts: adapter_opts,
        workspace_root: Keyword.get(opts, :workspace_root),
        document_id: Keyword.get(opts, :document_id),
        pool_document_id: Keyword.get(opts, :pool_document_id),
        # Per-agent MCP url (design invariant 3): the agent's own id keys its
        # `/mcp/doc-tools/<id>` endpoint, so a tool call resolves back to THIS
        # agent and runs in its own doc context — never a shared global pool.
        mcp_servers: mcp_servers(id)
      ]

      case SessionSupervisor.start_session(args) do
        {:ok, pid} -> Session.snapshot(pid)
        {:ok, pid, _info} -> Session.snapshot(pid)
        {:error, {:already_started, pid}} -> Session.snapshot(pid)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def send_turn(ctx, session_id, input, opts \\ []) do
    with {:ok, pid} <- fetch_session(session_id) do
      Session.send_turn(pid, ctx, input, opts)
    end
  end

  def cancel(ctx, session_id, turn_id \\ nil) do
    with {:ok, pid} <- fetch_session(session_id) do
      Session.cancel(pid, ctx, turn_id)
    end
  end

  @doc """
  Flush the session's FIFO queue head immediately (Phase 5 re-Enter): cancel the
  in-flight turn and run the next queued message now.
  """
  def flush_queue(session_id, ctx \\ nil) do
    with {:ok, pid} <- fetch_session(session_id) do
      Session.flush_queue(pid, ctx)
    end
  end

  @doc """
  Terminate a session GenServer (and its provider subprocess). Needed for a
  GENUINE restart (provider/workspace switch): the Session is keyed by the stable
  per-browser `ws_id`, so the old one must be stopped before a fresh conversation
  starts under the same id — otherwise `start_session/2` just re-attaches to it
  via the `{:already_started, pid}` path.
  """
  def close(session_id) when is_binary(session_id) do
    case Session.whereis(session_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(SessionSupervisor, pid)
    end
  end

  def close(_session_id), do: :ok

  @doc """
  Live-updates a running session's turn parameters (access/approval mode,
  reasoning effort, same-provider model) in place — preserving the conversation
  — rather than recreating the session. The next turn starts from the merged
  options. Mirrors `session/set_mode` / `session/set_config_option` semantics
  (the ACP session is created per turn, so these are stored-for-next-turn).
  """
  def update_session_options(session_id, adapter_opts) when is_list(adapter_opts) do
    with {:ok, pid} <- fetch_session(session_id) do
      Session.update_options(pid, adapter_opts)
    end
  end

  def status(_ctx, session_id) do
    with {:ok, pid} <- fetch_session(session_id) do
      Session.snapshot(pid)
    end
  end

  @doc "Display-only `%{transcript, status, title}` for a refresh-time repaint."
  def agent_snapshot(session_id) when is_binary(session_id) do
    case Session.whereis(session_id) do
      pid when is_pid(pid) -> Session.agent_snapshot(pid)
      nil -> %{transcript: [], status: :offline, title: nil}
    end
  end

  @doc "The session's current chat title (nil when not yet derived)."
  def title(session_id) when is_binary(session_id) do
    case Session.whereis(session_id) do
      pid when is_pid(pid) -> Session.title(pid)
      nil -> nil
    end
  end

  @doc "Rename a session's chat thread (user edit)."
  def rename(session_id, title) when is_binary(session_id) and is_binary(title) do
    case Session.whereis(session_id) do
      pid when is_pid(pid) -> Session.rename(pid, title)
      nil -> {:error, :not_found}
    end
  end

  def subscribe(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(Ecrits.PubSub, topic(session_id))
  end

  def topic(session_id), do: Session.topic(session_id)
  def whereis(session_id), do: Session.whereis(session_id)

  # ── doc.* MCP server descriptor ────────────────────────────────────

  @doc """
  The `mcpServers` descriptor list passed to an ACP session — the in-process
  `doc.*` MCP server served over HTTP by the Phoenix endpoint, at the calling
  agent's OWN per-agent url (`/mcp/doc-tools/<agent_id>`). The agent id in the
  url is how a tool call resolves back to this agent (design invariant 3), so
  each agent's doc.* tools run isolated in its own document context.
  """
  def mcp_servers(agent_id) when is_binary(agent_id) and agent_id != "" do
    case doc_tools_mcp_url(agent_id) do
      nil -> []
      url -> [%{"name" => @doc_tools_mcp_name, "url" => url}]
    end
  end

  def mcp_servers(_agent_id), do: []

  @doc """
  Absolute per-agent URL of the locally-served `doc.*` MCP server (HTTP
  transport): `<base>/mcp/doc-tools/<agent_id>`. The trailing agent id is
  extracted by the router/plug and threaded to the tool call so it runs in that
  agent's context.
  """
  def doc_tools_mcp_url(agent_id) when is_binary(agent_id) and agent_id != "" do
    case endpoint_base_url() do
      nil -> nil
      base -> base <> "/mcp/doc-tools/" <> URI.encode(agent_id)
    end
  end

  def doc_tools_mcp_url(_agent_id), do: nil

  defp endpoint_base_url do
    case endpoint_http_port() do
      port when is_integer(port) -> "http://127.0.0.1:#{port}"
      _ -> nil
    end
  end

  # Prefer the live endpoint's bound port (authoritative once running); fall back
  # to configured http port, then Phoenix's default 4000.
  defp endpoint_http_port do
    runtime_port =
      try do
        EcritsWeb.Endpoint.config(:http)[:port]
      rescue
        _ -> nil
      catch
        _, _ -> nil
      end

    config_port =
      :ecrits
      |> Application.get_env(EcritsWeb.Endpoint, [])
      |> Keyword.get(:http, [])
      |> Keyword.get(:port)

    runtime_port || config_port || 4000
  end

  # ── helpers ─────────────────────────────────────────────────────────

  defp fetch_session(session_id) do
    case Session.whereis(session_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :not_found}
    end
  end

  defp normalize_provider_id(id) when is_atom(id),
    do: id |> Atom.to_string() |> normalize_provider_id()

  defp normalize_provider_id(id) when is_binary(id) do
    id
    |> String.trim()
    |> String.downcase()
    |> case do
      "codex_app_server" -> "codex"
      other -> other
    end
  end

  defp normalize_provider_id(id), do: id
end
