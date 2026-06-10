defmodule Ecrits.Supervision do
  @moduledoc """
  Declarative application supervision topology.

  `Ecrits.Application` owns startup policy; this module owns the runtime
  grouping and child-spec order. Keep leaf child IDs stable unless the caller
  code that restarts those children is moved to the same abstraction.

  This tree is the app's runtime map:

    * platform services make the BEAM/Phoenix host usable;
    * document services own cross-cutting document materialization;
    * local document runtime owns open workspace-document sessions;
    * local agent runtime owns ACP sessions and the agent-visible MCP tool loop.

  The important boundary is that LiveViews should not own document truth. A
  LiveView mounts a document session and renders it; supervised document
  processes own versions, snapshots, and agent-addressable identity. Agents
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

  defp document_service_children do
    [
      Ecrits.RhwpSnapshot.Materializer,
      # The single serializing governor for the in-process LibreOffice UNO NIF
      # (one LO instance, SolarMutex-serialised, crash-coupled). ALL office ops
      # route through its mailbox; it caps simultaneously-materialised UNO docs
      # with an LRU budget (save-then-close eviction, transparent reopen). HWP/
      # ehwp is cheap-per-doc and parallel, so it is NOT routed through here.
      Ecrits.Doc.Office.Instance,
      # Multi-document MCP registry: one Editor per open document, browser/server
      # backing. See `Ecrits.Doc.Pool` (doc-editing MCP design §4.3).
      Ecrits.Doc.Pool
    ]
  end

  defp web_children do
    [
      EcritsWeb.Endpoint
    ]
  end

  defp local_document_runtime_children do
    [
      {Registry, keys: :unique, name: Ecrits.Local.Document.Registry},
      Ecrits.Local.Document.Supervisor
    ]
  end

  defp local_agent_runtime_children do
    [
      {Registry, keys: :unique, name: Ecrits.Local.AcpAgent.SessionRegistry},
      Ecrits.Local.AcpAgent.SessionSupervisor,
      # Per-workspace Session directory (keyed by canonical path, cookieless).
      # Durable: survives the workspace LiveView dying / a browser refresh, so
      # re-attaching by path returns the same foreground agent (same provider
      # thread + transcript + title). Replaces the cookie `ws_id` + ShellStore.
      {Registry, keys: :unique, name: Ecrits.Workspace.SessionRegistry},
      Ecrits.Workspace.SessionSupervisor
    ]
  end
end
