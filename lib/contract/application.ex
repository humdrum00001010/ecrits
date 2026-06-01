defmodule Contract.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Fail fast in :prod if required env vars are missing; warn in :dev/:test.
    :ok = Contract.Config.assert_loaded!(env())

    children = [
      ContractWeb.Telemetry,
      {Phoenix.PubSub, name: Contract.PubSub},
      {DNSCluster, query: Application.get_env(:contract, :dns_cluster_query) || :ignore},
      # Finch pool used by Swoosh.ApiClient.Finch. openai_ex / req each
      # manage their own pools internally, so one pool here is enough.
      {Finch, name: Swoosh.Finch},
      # Dedicated pool for OpenAI Responses streaming. We override
      # OpenaiEx's default `OpenaiEx.Finch` (which uses
      # `conn_max_idle_time: :infinity`) because OpenAI's edge silently
      # closes HTTPS keepalive connections after ~60s, leaving dead
      # sockets in the pool. Re-using one triggers "Connection closed"
      # and forces the agent's retry path, adding hundreds of ms of
      # perceived latency to the first token. 30s is safely below
      # OpenAI's window.
      {Finch,
       name: Contract.Finch.OpenAI,
       pools: %{
         :default => [size: 10, count: 1, conn_max_idle_time: 30_000]
       }},
      Contract.RhwpSnapshot.Materializer,
      ContractWeb.Endpoint,
      # Agent runtime: one process per document scope, with per-run lookup
      # for PubSub/cancel/MCP handoff.
      {Registry, keys: :unique, name: Contract.Agent.Document.Registry},
      {Registry, keys: :unique, name: Contract.Agent.Document.RunRegistry},
      Contract.Agent.DocumentSupervisor,
      # Wave 2 Persistence runtime: per-document Session registry + transient supervisor.
      {Registry, keys: :unique, name: Contract.Session.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Contract.Session.Supervisor},
      # Localize document runtime: one session per mounted workspace file.
      {Registry, keys: :unique, name: Contract.Local.Document.Registry},
      Contract.Local.Document.Supervisor,
      # Local provider-agnostic agent endpoint runtime.
      {Registry, keys: :unique, name: Contract.Local.Agent.SessionRegistry},
      Contract.Local.Agent.SessionSupervisor,
      Contract.Local.ACP
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Contract.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ContractWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp env do
    Application.get_env(:contract, :env, :dev)
  end
end
