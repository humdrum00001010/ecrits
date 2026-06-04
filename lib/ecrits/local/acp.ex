defmodule Ecrits.Local.ACP do
  @moduledoc """
  Registered ACP boundary for local agent provider config and sessions.
  """

  use GenServer

  alias Ecrits.Local.Agent.Adapters.ClaudeCLI
  alias Ecrits.Local.Agent.Adapters.CodexAppServer
  alias Ecrits.Local.Agent.Adapters.ExMCPACP
  alias Ecrits.Local.Agent.Adapters.Fake
  alias Ecrits.Local.Agent.Adapters.Unavailable
  alias ExMCP.ACP.Adapters.Claude, as: ExMCPClaude
  alias ExMCP.ACP.Adapters.Codex, as: ExMCPCodex
  alias Ecrits.Local.Agent.OrchexAdapter
  alias Ecrits.Local.Agent.Session
  alias Ecrits.Local.Agent.SessionSupervisor

  @name __MODULE__

  # Provider routing now drives the maintained ExMCP.ACP stack via
  # `Ecrits.Local.Agent.Adapters.ExMCPACP`, selecting the matching ACP agent
  # adapter per provider (Codex / Claude). The bespoke `CodexAppServer` /
  # `ClaudeCLI` adapters remain available for fallback/override but are no longer
  # the default producer for the chat rail.
  @providers [
    %{
      id: "codex",
      label: "Codex",
      icon: "local-agent-provider-codex",
      favicon_src: "/images/icons/openai-blossom.svg",
      adapter: ExMCPACP,
      adapter_opts: [exmcp_adapter: ExMCPCodex]
    },
    %{
      id: "claude",
      label: "Claude",
      icon: "local-agent-provider-claude",
      favicon_src: "/images/icons/claude-favicon.ico",
      adapter: ExMCPACP,
      adapter_opts: [exmcp_adapter: ExMCPClaude]
    },
    %{
      id: "external",
      label: "External ACP",
      icon: "local-agent-provider-external",
      favicon_src: "/favicon.ico",
      adapter: Unavailable,
      adapter_opts: [
        provider: "external",
        reason: "External ACP adapter is registered but not configured."
      ]
    }
  ]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def providers(server \\ @name) do
    call_or_fallback(server, :providers, &default_provider_metadata/0)
  end

  def provider_metadata(server \\ @name), do: providers(server)

  def supported_provider_ids(server \\ @name) do
    call_or_fallback(server, :supported_provider_ids, &default_provider_ids/0)
  end

  def fetch_provider(id, server \\ @name) do
    call_or_fallback(server, {:fetch_provider, id}, fn ->
      fetch_provider_from_state(default_state(), id)
    end)
  end

  def default_provider_id(server \\ @name) do
    call_or_fallback(server, :default_provider_id, fn ->
      configured_default_provider_id(default_state())
    end)
  end

  def integration_options(server \\ @name) do
    call_or_fallback(server, :integration_options, &build_integration_options/0)
  end

  def start_session(ctx, opts \\ [], server \\ @name) when is_list(opts) do
    call_or_fallback(server, {:start_session, ctx, opts}, fn -> {:error, :acp_unavailable} end)
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

  def approve_tool_call(ctx, session_id, tool_call_id) do
    with {:ok, pid} <- fetch_session(session_id) do
      Session.approve_tool_call(pid, ctx, tool_call_id)
    end
  end

  def reject_tool_call(ctx, session_id, tool_call_id) do
    with {:ok, pid} <- fetch_session(session_id) do
      Session.reject_tool_call(pid, ctx, tool_call_id)
    end
  end

  def status(_ctx, session_id) do
    with {:ok, pid} <- fetch_session(session_id) do
      Session.snapshot(pid)
    end
  end

  def subscribe(session_id) when is_binary(session_id) do
    Phoenix.PubSub.subscribe(Ecrits.PubSub, topic(session_id))
  end

  def topic(session_id), do: Session.topic(session_id)
  def whereis(session_id), do: Session.whereis(session_id)

  def public_provider_metadata(provider) when is_map(provider) do
    %{
      id: provider.id,
      label: provider.label,
      icon: provider.icon,
      favicon_src: provider.favicon_src
    }
  end

  @impl true
  def init(opts) do
    providers = Keyword.get(opts, :providers, @providers)
    :ok = Orchex.configure(OrchexAdapter.config(providers))

    {:ok, default_state(providers)}
  end

  @impl true
  def handle_call(:providers, _from, state) do
    {:reply, Enum.map(state.providers, &public_provider_metadata/1), state}
  end

  def handle_call(:supported_provider_ids, _from, state) do
    {:reply, state.provider_ids, state}
  end

  def handle_call({:fetch_provider, id}, _from, state) do
    {:reply, fetch_provider_from_state(state, id), state}
  end

  def handle_call(:default_provider_id, _from, state) do
    {:reply, configured_default_provider_id(state), state}
  end

  def handle_call(:integration_options, _from, state) do
    {:reply, build_integration_options(), state}
  end

  def handle_call({:start_session, ctx, opts}, _from, state) do
    result =
      with {:ok, provider} <-
             fetch_provider_from_state(
               state,
               Keyword.get(opts, :provider, configured_default_provider_id(state))
             ),
           :ok <- validate_adapter_override(Keyword.get(opts, :adapter)) do
        start_provider_session(ctx, opts, provider)
      end

    {:reply, result, state}
  end

  defp start_provider_session(ctx, opts, provider) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    adapter = Keyword.get(opts, :adapter, provider.adapter)
    adapter_opts = Keyword.merge(provider.adapter_opts, Keyword.get(opts, :adapter_opts, []))

    args =
      opts
      |> Keyword.put(:id, id)
      |> Keyword.put(:ctx, ctx)
      |> Keyword.put(:provider, public_provider_metadata(provider))
      |> Keyword.put(:adapter, adapter)
      |> Keyword.put(:adapter_opts, adapter_opts)

    case SessionSupervisor.start_session(args) do
      {:ok, pid} -> Session.snapshot(pid)
      {:ok, pid, _info} -> Session.snapshot(pid)
      {:error, {:already_started, pid}} -> Session.snapshot(pid)
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_provider_from_state(state, id) do
    normalized = normalize_provider_id(id)

    case Enum.find(state.providers, &(&1.id == normalized)) do
      nil -> {:error, {:unsupported_provider, id, state.provider_ids}}
      provider -> {:ok, provider}
    end
  end

  defp call_or_fallback(server, request, fallback) when is_function(fallback, 0) do
    with :ok <- ensure_server_started(server) do
      GenServer.call(server, request)
    else
      {:error, _reason} -> fallback.()
    end
  catch
    :exit, {:noproc, _} -> fallback.()
    :exit, {:normal, _} -> fallback.()
    :exit, {:shutdown, _} -> fallback.()
  end

  defp ensure_server_started(@name) do
    case Process.whereis(@name) do
      pid when is_pid(pid) -> :ok
      nil -> start_registered_server()
    end
  end

  defp ensure_server_started(server) when is_pid(server) do
    if Process.alive?(server), do: :ok, else: {:error, :server_unavailable}
  end

  defp ensure_server_started(server) when is_atom(server) do
    case Process.whereis(server) do
      pid when is_pid(pid) -> :ok
      nil -> {:error, :server_unavailable}
    end
  end

  defp ensure_server_started(_server), do: :ok

  defp start_registered_server do
    case Process.whereis(Ecrits.Supervisor) do
      pid when is_pid(pid) ->
        case Supervisor.start_child(Ecrits.Supervisor, __MODULE__) do
          {:error, :already_present} -> restart_registered_server()
          result -> normalize_supervisor_start(result)
        end

      nil ->
        {:error, :supervisor_unavailable}
    end
  end

  defp restart_registered_server do
    Ecrits.Supervisor
    |> Supervisor.restart_child(__MODULE__)
    |> normalize_supervisor_start()
  end

  defp normalize_supervisor_start({:ok, _pid}), do: :ok
  defp normalize_supervisor_start({:ok, _pid, _info}), do: :ok
  defp normalize_supervisor_start({:error, {:already_started, _pid}}), do: :ok
  defp normalize_supervisor_start({:error, :running}), do: :ok
  defp normalize_supervisor_start({:error, reason}), do: {:error, reason}

  defp default_state(providers \\ @providers) do
    %{
      providers: providers,
      provider_ids: Enum.map(providers, & &1.id)
    }
  end

  defp default_provider_metadata do
    Enum.map(@providers, &public_provider_metadata/1)
  end

  defp default_provider_ids do
    Enum.map(@providers, & &1.id)
  end

  defp configured_default_provider_id(state) do
    configured =
      :ecrits
      |> Application.get_env(:local_agent, [])
      |> Keyword.get(:provider, "codex")
      |> normalize_provider_id()

    if configured in state.provider_ids, do: configured, else: "codex"
  end

  defp validate_adapter_override(nil), do: :ok
  defp validate_adapter_override(Fake), do: validate_fake_adapter_override()
  defp validate_adapter_override(_adapter), do: :ok

  defp validate_fake_adapter_override do
    if Application.get_env(:ecrits, :env) == :test do
      :ok
    else
      {:error, {:adapter_unavailable, Fake}}
    end
  end

  defp fetch_session(session_id) do
    case Session.whereis(session_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> {:error, :not_found}
    end
  end

  defp build_integration_options do
    [
      codex_integration(),
      claude_integration(),
      external_acp_integration()
    ]
  end

  defp codex_integration do
    case CodexAppServer.resolve_executable() do
      {:ok, %{command: command, path: path}} ->
        %{
          id: "codex",
          label: "Codex CLI/app-server",
          status: :ready,
          detail: "#{command} at #{path}"
        }

      {:error, {:codex_executable_missing, candidates}} ->
        %{
          id: "codex",
          label: "Codex CLI/app-server",
          status: :missing,
          detail: "Install #{Enum.join(candidates, " or ")}"
        }
    end
  end

  defp claude_integration do
    case ClaudeCLI.resolve_executable() do
      {:ok, %{command: command, path: path}} ->
        %{id: "claude", label: "Claude CLI/ACP", status: :ready, detail: "#{command} at #{path}"}

      {:error, {:claude_executable_missing, candidates}} ->
        %{
          id: "claude",
          label: "Claude CLI/ACP",
          status: :missing,
          detail: "Install #{Enum.join(candidates, " or ")}"
        }
    end
  end

  defp external_acp_integration do
    case external_acp_endpoint() do
      nil ->
        %{
          id: "external",
          label: "External ACP endpoint",
          status: :missing,
          detail: "Set external_acp_endpoint"
        }

      endpoint ->
        %{id: "external", label: "External ACP endpoint", status: :ready, detail: endpoint}
    end
  end

  defp external_acp_endpoint do
    local_agent_ui = Application.get_env(:ecrits, :local_agent_ui, [])
    local_agent = Application.get_env(:ecrits, :local_agent, [])

    Keyword.get(local_agent_ui, :external_acp_endpoint) ||
      Keyword.get(local_agent, :external_acp_endpoint)
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
