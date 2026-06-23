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

  test "re-attach from the same LiveView pid with the SAME provider reuses the agent",
       %{path: path, ws: ws} do
    agent_id = ws.agent_id
    old_pid = AcpAgent.whereis(agent_id)

    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, agent_id, "hello from codex")
    Session.subscribe_agent(agent_id)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    # A same-LiveView re-attach with the SAME provider preserves that LiveView's
    # active rail and does not restart the provider thread.
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

  test "same workspace path isolates foreground agents by caller LiveView pid", %{path: path} do
    live_a = start_live_process()
    live_b = start_live_process()

    {:ok, ws_a} =
      attach_from(live_a, path,
        live_session_id: "same-browser-session",
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "reply a"}]
        ],
        workspace_root: path
      )

    {:ok, ws_b} =
      attach_from(live_b, path,
        live_session_id: "same-browser-session",
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "reply b"}]
        ],
        workspace_root: path
      )

    refute ws_a.agent_id == ws_b.agent_id

    pid_a = AcpAgent.whereis(ws_a.agent_id)
    pid_b = AcpAgent.whereis(ws_b.agent_id)
    assert is_pid(pid_a)
    assert is_pid(pid_b)
    refute pid_a == pid_b

    Session.subscribe_agent(ws_a.agent_id)
    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, ws_a.agent_id, "only session a")
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    assert [%{user: "only session a"}] = AcpAgent.agent_snapshot(ws_a.agent_id).transcript
    assert AcpAgent.agent_snapshot(ws_b.agent_id).transcript == []

    {:ok, ws_a2} =
      attach_from(live_a, path,
        live_session_id: "same-browser-session",
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "reply a"}]
        ],
        workspace_root: path
      )

    assert ws_a2.agent_id == ws_a.agent_id
    assert AcpAgent.whereis(ws_a.agent_id) == pid_a
    assert AcpAgent.agent_snapshot(ws_a.agent_id).transcript != []
  end

  test "new LiveView pid starts a fresh rail and keeps old browser-session chats in recents",
       %{path: path} do
    settings = [
      live_session_id: "browser-refresh",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        script: [{:text_delta, "reply"}]
      ],
      workspace_root: path
    ]

    live_1 = start_live_process()
    {:ok, ws1} = attach_from(live_1, path, settings)
    old_agent_pid = AcpAgent.whereis(ws1.agent_id)

    Session.subscribe_agent(ws1.agent_id)
    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, ws1.agent_id, "old rail")
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    stop_live_process(live_1)
    sync_session(path)

    assert AcpAgent.whereis(ws1.agent_id) == old_agent_pid

    live_2 = start_live_process()
    {:ok, ws2} = attach_from(live_2, path, settings)

    refute ws2.agent_id == ws1.agent_id
    assert AcpAgent.agent_snapshot(ws2.agent_id).transcript == []

    recents = Session.recent_foregrounds(ws2)
    assert Enum.any?(recents, &(&1.agent_id == ws2.agent_id and &1.active?))
    assert Enum.any?(recents, &(&1.agent_id == ws1.agent_id and not &1.active?))
  end

  test "same browser session can switch between recent foreground rails", %{path: path} do
    path = Path.join(path, "recents")
    File.mkdir_p!(path)

    settings = [
      live_session_id: "phx-session-recents",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        script: [{:text_delta, "reply"}]
      ],
      workspace_root: path
    ]

    {:ok, ws1} = Session.attach(path, settings)

    Session.subscribe_agent(ws1.agent_id)
    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, ws1.agent_id, "first rail")
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    {:ok, ws2} = Session.new_foreground(path, settings)

    refute ws2.agent_id == ws1.agent_id
    refute ws2.rail_key == ws1.rail_key
    assert AcpAgent.whereis(ws1.agent_id)
    assert AcpAgent.whereis(ws2.agent_id)

    assert [
             %{agent_id: agent2, active?: true, title: title2},
             %{agent_id: agent1, active?: false, title: "first rail"}
           ] = Session.recent_foregrounds(ws2)

    assert agent2 == ws2.agent_id
    assert agent1 == ws1.agent_id
    assert title2 in [nil, ""]

    {:ok, selected_ws} = Session.select_foreground(path, ws1.rail_key, settings)
    assert selected_ws.agent_id == ws1.agent_id

    assert [
             %{agent_id: ^agent1, active?: true},
             %{agent_id: ^agent2, active?: false}
           ] = Session.recent_foregrounds(selected_ws)

    {:ok, reattached_ws} = Session.attach(path, settings)
    assert reattached_ws.agent_id == ws1.agent_id
    assert AcpAgent.agent_snapshot(reattached_ws.agent_id).transcript != []
  end

  test "new foreground restarts the active empty rail in place instead of accumulating blanks",
       %{path: path, ws: ws} do
    settings = [
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        script: [{:text_delta, "reply"}]
      ],
      workspace_root: path
    ]

    old_pid = AcpAgent.whereis(ws.agent_id)
    assert is_pid(old_pid)
    assert AcpAgent.agent_snapshot(ws.agent_id).transcript == []

    {:ok, refreshed_ws} = Session.new_foreground(path, settings)

    assert refreshed_ws.agent_id == ws.agent_id
    assert refreshed_ws.rail_key == ws.rail_key

    new_pid = AcpAgent.whereis(refreshed_ws.agent_id)
    assert is_pid(new_pid)
    refute new_pid == old_pid
    refute Process.alive?(old_pid)

    assert [
             %{agent_id: agent_id, active?: true, title: title}
           ] = Session.recent_foregrounds(refreshed_ws)

    assert agent_id == refreshed_ws.agent_id
    assert title in [nil, ""]
  end

  test "first attach seeds document path but same-provider re-attach does not retarget it",
       %{path: path} do
    fresh_path = Path.join(path, "doc-seed")
    File.mkdir_p!(fresh_path)

    {:ok, seeded_ws} =
      Session.attach(fresh_path,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "seed reply"}]
        ],
        workspace_root: fresh_path,
        document_path: "first.hwp",
        pool_document_id: "d_hwp_first"
      )

    agent_id = seeded_ws.agent_id
    old_pid = AcpAgent.whereis(agent_id)

    assert {:ok, %{document_path: "first.hwp"}} = AcpAgent.status(nil, agent_id)

    {:ok, reattached_ws} =
      Session.attach(fresh_path,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "seed reply"}]
        ],
        workspace_root: fresh_path,
        document_path: "second.hwp",
        pool_document_id: "d_hwp_second"
      )

    assert reattached_ws.agent_id == agent_id
    assert AcpAgent.whereis(agent_id) == old_pid
    assert {:ok, %{document_path: "first.hwp"}} = AcpAgent.status(nil, agent_id)
  end

  defp start_live_process do
    pid =
      spawn(fn ->
        live_process_loop()
      end)

    on_exit(fn -> stop_live_process(pid) end)
    pid
  end

  defp live_process_loop do
    receive do
      {:attach, caller, ref, path, settings} ->
        send(caller, {ref, Session.attach(path, settings)})
        live_process_loop()

      :stop ->
        :ok
    end
  end

  defp attach_from(pid, path, settings) do
    ref = make_ref()
    send(pid, {:attach, self(), ref, path, settings})
    assert_receive {^ref, result}, 1_000
    result
  end

  defp stop_live_process(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    :ok
  end

  defp sync_session(path) do
    case Session.whereis(path) do
      pid when is_pid(pid) -> :sys.get_state(pid)
      nil -> :ok
    end
  end
end
