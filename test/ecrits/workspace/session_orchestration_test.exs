defmodule Ecrits.Workspace.SessionOrchestrationTest do
  @moduledoc """
  Phase 5 orchestration spawn contract: an AgentLive (orchestrator) can spawn a
  BACKGROUND worker AgentLive in its workspace Session, observe it on its topic,
  and the worker is NEVER returned as the workspace's foreground agent.

  Driven through the real `ExMCP.ACP` stack via `EcritsWeb.FakeAcpAdapter`.
  """

  use ExUnit.Case, async: false

  alias Ecrits.Workspace.Session

  @fake_opts [
    provider: "codex",
    adapter_opts: [
      exmcp_adapter: EcritsWeb.FakeAcpAdapter,
      script: [{:text_delta, "worker reply"}]
    ]
  ]

  setup do
    path = "/tmp/ecrits-orch-test-" <> Integer.to_string(System.unique_integer([:positive]))
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    # Bind the foreground agent so the workspace has a real orchestrator.
    {:ok, ws} =
      Session.attach(path,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "fg reply"}]
        ],
        workspace_root: path
      )

    {:ok, path: path, ws: ws}
  end

  test "a spawned worker runs background, is observable, and is NOT the foreground", %{
    path: path,
    ws: ws
  } do
    orchestrator_id = ws.agent_id
    assert is_binary(orchestrator_id)

    # The orchestrator spawns a worker.
    {:ok, worker} =
      Session.spawn_worker(path, orchestrator_id, @fake_opts ++ [workspace_root: path])

    assert is_binary(worker.id)
    assert is_pid(worker.pid)
    assert Process.alive?(worker.pid)
    refute worker.id == orchestrator_id

    # Role tagging: worker is :background, orchestrator is :foreground.
    assert Session.agent_role(path, worker.id) == :background
    assert Session.agent_role(path, orchestrator_id) == :foreground

    # The worker is NOT the workspace's foreground agent.
    assert %{id: ^orchestrator_id} = Session.foreground_agent(ws)
    assert %{agent_id: ^orchestrator_id} = Session.foreground_ws(path)

    # ...but it IS listed as a worker.
    assert [%{id: worker_id, parent: ^orchestrator_id}] = Session.workers(path)
    assert worker_id == worker.id

    # The worker is OBSERVABLE on its own topic: subscribe, run a turn, see the
    # streamed events.
    :ok = Session.subscribe_agent(worker.id)
    {:ok, %{id: turn_id}} = Ecrits.AcpAgent.send_turn(nil, worker.id, "do the thing")

    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn_id}}, 2_000
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    # The foreground agent did NOT receive the worker's turn (isolation): its
    # transcript is empty (no fg turn was sent).
    assert Ecrits.AcpAgent.agent_snapshot(orchestrator_id).transcript == []
  end

  test "workers/1 drops a worker whose process has died", %{path: path, ws: ws} do
    {:ok, worker} =
      Session.spawn_worker(path, ws.agent_id, @fake_opts ++ [workspace_root: path])

    assert [%{id: _}] = Session.workers(path)

    Ecrits.AcpAgent.close(worker.id)
    # Give the supervisor a moment to reap it.
    Process.sleep(50)

    assert Session.workers(path) == []
  end
end
