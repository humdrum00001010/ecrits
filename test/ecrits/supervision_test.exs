defmodule Ecrits.SupervisionTest do
  use ExUnit.Case, async: true

  test "groups application children by runtime area" do
    assert Enum.map(Ecrits.Supervision.child_groups(), fn {group, _children} -> group end) == [
             :platform,
             :http_clients,
             :document_services,
             :web,
             :local_document_runtime,
             :local_agent_runtime
           ]
  end

  test "keeps root child ids stable for restart paths" do
    assert Ecrits.Supervision.child_ids() == [
             EcritsWeb.Telemetry,
             Phoenix.PubSub.Supervisor,
             DNSCluster,
             Swoosh.Finch,
             Ecrits.Finch.OpenAI,
             Ecrits.RhwpSnapshot.Materializer,
             Ecrits.Doc.Office.Instance,
             Ecrits.Doc.Pool,
             Ecrits.Fuse.OpenDocs,
             EcritsWeb.Endpoint,
             Ecrits.Document.Registry,
             Ecrits.Document.Supervisor,
             Ecrits.WorkspaceHandoff,
             Ecrits.AcpAgent.SessionRegistry,
             Ecrits.AcpAgent.SessionSupervisor,
             Ecrits.Workspace.SessionRegistry,
             Ecrits.Workspace.SessionSupervisor
           ]
  end
end
