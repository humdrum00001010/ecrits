defmodule Ecrits.Supervision do
  @moduledoc """
  Declarative application supervision topology.

  `Ecrits.Application` owns startup policy; this module owns the runtime
  grouping and child-spec order. Keep leaf child IDs stable unless the caller
  code that restarts those children is moved to the same abstraction.

  This tree is the app's runtime map:

    * platform services make the BEAM/Phoenix host usable;
    * storage opens the local ~/.ecrits SQLite store;
    * document services own cross-cutting document materialization;
    * local document runtime owns open workspace-document sessions;
    * local agent runtime owns ACP sessions and the agent-visible MCP tool loop.

  The important boundary is that LiveViews should not own document truth. A
  LiveView mounts a document session and renders it; supervised document
  processes own revisions, snapshots, and agent-addressable identity. Agents
  should reach documents through the local agent runtime and `doc.*` tools, not
  by bypassing the editor with raw filesystem access.
  """

  @type child_group :: {atom(), [Supervisor.child_spec()]}

  @spec children(keyword()) :: [Supervisor.child_spec()]
  def children(opts \\ []) do
    opts
    |> child_groups()
    |> Enum.flat_map(fn {_group, children} -> children end)
  end

  @spec child_groups(keyword()) :: [child_group()]
  def child_groups(_opts \\ []) do
    [
      # Host/runtime substrate. These must be available before app-specific
      # workers publish, subscribe, or make HTTP calls.
      {:platform, platform_children()},
      {:http_clients, http_client_children()},
      # Local durable app state — the only persistence boundary now that the
      # legacy SaaS Postgres repo is retired.
      {:storage, storage_children()},
      # Format/runtime services that are shared by user editing and agent edits.
      {:document_services, document_service_children()},
      # Phoenix endpoint starts after shared services so LiveViews can mount
      # document and agent sessions immediately.
      {:web, web_children()},
      # Local editor runtimes: document sessions first, ACP/agent sessions after,
      # because agents bind to the active document session by id.
      {:local_document_runtime, local_document_runtime_children()},
      {:local_agent_runtime, local_agent_runtime_children()}
    ]
  end

  @spec child_ids(keyword()) :: [term()]
  def child_ids(opts \\ []) do
    opts
    |> children()
    |> Enum.map(&Supervisor.child_spec(&1, []).id)
  end

  defp platform_children do
    [
      EcritsWeb.Telemetry,
      {Phoenix.PubSub, name: Ecrits.PubSub},
      {DNSCluster, query: Application.get_env(:ecrits, :dns_cluster_query) || :ignore}
    ]
  end

  defp http_client_children do
    [
      {Finch, name: Swoosh.Finch},
      # OpenAI streaming should not reuse sockets past the edge keepalive window.
      {Finch,
       name: Ecrits.Finch.OpenAI,
       pools: %{
         :default => [size: 10, count: 1, conn_max_idle_time: 30_000]
       }}
    ]
  end

  defp storage_children do
    [
      Ecrits.Repo,
      Ecrits.Loader
    ]
  end

  defp document_service_children do
    [
      Ecrits.RhwpSnapshot.Materializer,
      # Multi-document MCP registry: one Editor per open document, browser/server
      # backing, revision/rebase. See `Ecrits.Doc.Pool` (doc-editing MCP design §4.3).
      Ecrits.Doc.Pool
    ] ++ office_warmer_children()
  end

  # Pre-warm LibreOffice at boot so the first office-document open is fast.
  # Skipped under :test (no soffice dependency in the suite) and when explicitly
  # disabled via config.
  defp office_warmer_children do
    env = Application.get_env(:ecrits, :env, :dev)
    enabled? = Application.get_env(:ecrits, :office_warm_on_boot, env != :test)

    if enabled?, do: [Ecrits.Local.OfficeWarmer], else: []
  end

  defp web_children do
    [
      EcritsWeb.Endpoint
    ]
  end

  defp local_document_runtime_children do
    [
      {Registry, keys: :unique, name: Ecrits.Local.Document.Registry},
      Ecrits.Local.Document.Supervisor,
      # LibreOfficeKit (LOK) in-process office editing sessions: one transient
      # child per open editable office document, owned by the LiveView that
      # started it (the session monitors its owner and frees the LOK document on
      # owner death). Read-only office rendering does not use this tree.
      {DynamicSupervisor, strategy: :one_for_one, name: Ecrits.Local.OfficeEditSupervisor}
    ]
  end

  defp local_agent_runtime_children do
    [
      {Registry, keys: :unique, name: Ecrits.Local.Agent.SessionRegistry},
      Ecrits.Local.Agent.SessionSupervisor,
      Ecrits.Local.ACP
    ]
  end
end
