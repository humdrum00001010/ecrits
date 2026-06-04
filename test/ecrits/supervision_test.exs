defmodule Ecrits.SupervisionTest do
  use ExUnit.Case, async: true

  test "groups application children by runtime area" do
    assert Enum.map(Ecrits.Supervision.child_groups(), fn {group, _children} -> group end) == [
             :platform,
             :http_clients,
             :storage,
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
             Ecrits.Repo,
             Ecrits.Loader,
             Ecrits.RhwpSnapshot.Materializer,
             Ecrits.Doc.Pool,
             EcritsWeb.Endpoint,
             Ecrits.Local.Document.Registry,
             Ecrits.Local.Document.Supervisor,
             Ecrits.Local.Agent.SessionRegistry,
             Ecrits.Local.Agent.SessionSupervisor,
             Ecrits.Local.ACP
           ]
  end
end
