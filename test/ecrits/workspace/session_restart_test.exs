defmodule Ecrits.Workspace.SessionRestartTest do
  @moduledoc """
  Provider-switch contract: `Session.restart_foreground/2` must TERMINATE the
  current foreground agent (the ACP adapter is bound at start and cannot be
  swapped) and start a FRESH one under the same stable path-keyed id, with an
  EMPTY transcript + default title — a genuinely new conversation, no replay.

  Driven through the real `ExMCP.ACP` stack via `EcritsWeb.FakeAcpAdapter`.
  """

  use ExUnit.Case, async: false

  alias Ecrits.Local.AcpAgent
  alias Ecrits.Workspace.Session

  setup do
    path = "/tmp/ecrits-restart-test-" <> Integer.to_string(System.unique_integer([:positive]))
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)

    {:ok, ws} =
      Session.attach(path,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "codex reply"}]
        ],
        workspace_root: path
      )

    {:ok, path: path, ws: ws}
  end

  test "restart kills the old agent and starts a fresh, empty session under the same id",
       %{path: path, ws: ws} do
    agent_id = ws.agent_id
    old_pid = AcpAgent.whereis(agent_id)
    assert is_pid(old_pid)

    # Run a turn so the old session has a non-empty transcript + a derived title.
    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, agent_id, "hello from codex")
    Session.subscribe_agent(agent_id)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000
    assert AcpAgent.agent_snapshot(agent_id).transcript != []

    # Switch providers: restart with a Claude-shaped seed (a different fake script
    # standing in for the new adapter). The id is stable; the pid must change.
    {:ok, new_ws} =
      Session.restart_foreground(path,
        provider: "claude",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "claude reply"}]
        ],
        workspace_root: path
      )

    assert new_ws.agent_id == agent_id
    new_pid = AcpAgent.whereis(agent_id)
    assert is_pid(new_pid)

    # Different process: the old one was terminated, a fresh one started.
    refute new_pid == old_pid
    refute Process.alive?(old_pid)

    # Fresh session: empty transcript, default title, idle status.
    snapshot = AcpAgent.agent_snapshot(agent_id)
    assert snapshot.transcript == []
    assert snapshot.status == :idle

    # The restarted agent is the bound foreground agent.
    assert %{id: ^agent_id, pid: ^new_pid} = Session.foreground_agent(new_ws)

    # And it runs its OWN turns from a clean slate.
    {:ok, %{id: t2}} = AcpAgent.send_turn(nil, agent_id, "hello from claude")
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^t2}}, 2_000
    assert length(AcpAgent.agent_snapshot(agent_id).transcript) == 1
  end

  test "re-attach with a DIFFERENT provider restarts the agent (adapter is bound at start)",
       %{path: path, ws: ws} do
    agent_id = ws.agent_id
    old_pid = AcpAgent.whereis(agent_id)
    assert is_pid(old_pid)

    # Give the codex agent a non-empty transcript.
    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, agent_id, "hello from codex")
    Session.subscribe_agent(agent_id)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000
    assert AcpAgent.agent_snapshot(agent_id).transcript != []

    # A plain ATTACH (not restart) whose provider differs from the bound agent's —
    # this is the page-reload seam: the durable path-keyed agent was started under
    # codex, but the new mount requests claude. The ACP adapter cannot be swapped
    # live, so attach MUST restart rather than silently reuse the codex adapter.
    {:ok, ws2} =
      Session.attach(path,
        provider: "claude",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "claude reply"}]
        ],
        workspace_root: path
      )

    assert ws2.agent_id == agent_id
    new_pid = AcpAgent.whereis(agent_id)
    assert is_pid(new_pid)
    refute new_pid == old_pid, "attach with a new provider must restart the bound agent"
    refute Process.alive?(old_pid)

    # Fresh session under the same stable id: empty transcript, idle.
    snapshot = AcpAgent.agent_snapshot(agent_id)
    assert snapshot.transcript == []
    assert snapshot.status == :idle
  end

  test "re-attach with the SAME provider reuses the agent (refresh-survival is preserved)",
       %{path: path, ws: ws} do
    agent_id = ws.agent_id
    old_pid = AcpAgent.whereis(agent_id)

    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, agent_id, "hello from codex")
    Session.subscribe_agent(agent_id)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    # A browser refresh re-attaches with the SAME provider. The durable agent —
    # its pid, provider thread and transcript — must be preserved, NOT restarted.
    {:ok, ws2} =
      Session.attach(path,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "codex reply"}]
        ],
        workspace_root: path
      )

    assert ws2.agent_id == agent_id
    assert AcpAgent.whereis(agent_id) == old_pid
    assert Process.alive?(old_pid)
    assert AcpAgent.agent_snapshot(agent_id).transcript != []
  end
end
