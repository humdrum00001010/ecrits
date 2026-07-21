defmodule Ecrits.Workspace.SessionRestartTest do
  @moduledoc """
  Provider-switch contract: `Session.restart_foreground/2` must TERMINATE the
  current foreground agent (the ACP adapter is bound at start and cannot be
  swapped) and start a FRESH one under the same stable path-keyed id, with an
  EMPTY transcript + default title — a genuinely new conversation, no replay.

  Driven through the real `ExMCP.ACP` stack via `EcritsWeb.FakeAcpAdapter`.
  """

  use ExUnit.Case, async: false

  alias Ecrits.AcpAgent
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

    assert_receive {:workspace_foreground_rebound, ^ws}, 1_000

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
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000
    assert AcpAgent.agent_snapshot(agent_id).transcript != []

    # Switch providers: restart with a Claude-shaped seed (a different fake script
    # standing in for the new adapter). The id is stable; the pid must change.
    new_ws =
      Session.restart_foreground(path,
        provider: "claude",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "claude reply"}]
        ],
        workspace_root: path
      )
      |> await_foreground_transition()

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
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^t2}}, 2_000
    assert length(AcpAgent.agent_snapshot(agent_id).transcript) == 1
  end

  test "provider restart fences the exact active turn before replacing its instance", %{
    path: root
  } do
    path = Path.join(root, "provider-restart-fence")
    File.mkdir_p!(path)
    test_pid = self()

    settings = [
      live_session_id: "provider-restart-fence",
      chat_rail_id: "stable-tab",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        wait_for: :release_provider_restart,
        test_pid: test_pid,
        script: [{:text_delta, "late old reply"}]
      ],
      workspace_root: path
    ]

    {:ok, fenced_ws} = Session.attach(path, settings)
    :ok = Session.subscribe_file_events(path)
    :ok = Session.subscribe_agent(fenced_ws.agent_id)
    assert_receive {:workspace_foreground_rebound, ^fenced_ws}, 1_000

    assert {:ok, %{id: turn_id, status: :running}} =
             Session.send_turn(fenced_ws, "active provider turn")

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    agent_id = fenced_ws.agent_id
    old_pid = AcpAgent.whereis(agent_id)
    %{current: %{task_pid: old_turn_task_pid}} = :sys.get_state(old_pid)
    old_instance_id = AcpAgent.agent_snapshot(agent_id).instance_id
    key = {agent_id, old_instance_id, turn_id}
    session_pid = Session.whereis(path)
    pool_pid = Process.whereis(Ecrits.Doc.Pool)
    :ok = :sys.suspend(pool_pid)

    assert {:pending, pending_ws} =
             Session.restart_foreground(path, Keyword.put(settings, :provider, "claude"))

    assert pending_ws.agent_id == agent_id
    assert pending_ws.rail_key == fenced_ws.rail_key

    try do
      assert %{
               foreground_transitions: %{
                 ^key => %{operation: :restart, rail_key: rail_key}
               },
               turn_finalization_active: %{key: ^key, pid: finalizer_pid}
             } =
               await_workspace_state(session_pid, fn state ->
                 match?(
                   %{
                     foreground_transitions: %{^key => %{operation: :restart}},
                     turn_finalization_active: %{key: ^key}
                   },
                   state
                 )
               end)

      assert rail_key == fenced_ws.rail_key
      refute Process.alive?(old_turn_task_pid)
      assert AcpAgent.whereis(agent_id) == old_pid
      assert Process.alive?(old_pid)

      assert {:error, :foreground_transition_in_progress} =
               Session.send_turn(fenced_ws, "must not enter the old queue")

      assert %{pending: 0, queued: [], current_turn: nil} =
               AcpAgent.agent_snapshot(agent_id)

      wrong_key = {agent_id, Ecto.UUID.generate(), turn_id}

      send(
        session_pid,
        {:workspace_turn_finalization_finished, wrong_key, finalizer_pid,
         successful_finalizer_result()}
      )

      assert %{
               foreground_transitions: %{^key => %{operation: :restart}},
               turn_finalization_active: %{key: ^key, pid: ^finalizer_pid}
             } = :sys.get_state(session_pid)

      assert AcpAgent.whereis(agent_id) == old_pid
    after
      :ok = :sys.resume(pool_pid)
    end

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: ^agent_id,
                      instance_id: ^old_instance_id,
                      turn_id: ^turn_id,
                      summary: %{successful?: true}
                    }},
                   2_000

    expected_rail_key = fenced_ws.rail_key
    expected_path = fenced_ws.path

    assert_receive {:workspace_foreground_rebound,
                    %{path: ^expected_path, rail_key: ^expected_rail_key} = restarted_ws},
                   2_000

    assert restarted_ws.agent_id == agent_id

    new_pid = AcpAgent.whereis(agent_id)
    assert is_pid(new_pid)
    refute new_pid == old_pid
    refute Process.alive?(old_pid)

    assert %{instance_id: new_instance_id, pending: 0, queued: [], current_turn: nil} =
             AcpAgent.agent_snapshot(agent_id)

    refute new_instance_id == old_instance_id
    assert :sys.get_state(session_pid).foreground_transitions == %{}
  end

  # 2026-07-19 live crash: a Session hot-reloaded across the thread-recap
  # upgrade still carried a state map WITHOUT :thread_covers_from — dot access
  # crashed the send and the exit cascaded into the workspace coordinator.
  # New state fields must tolerate pre-upgrade state maps.
  test "a send survives a session whose state predates the thread-gap field", %{ws: ws} do
    agent_id = ws.agent_id
    Session.subscribe_agent(agent_id)

    pid = AcpAgent.whereis(agent_id)
    :sys.replace_state(pid, &Map.delete(&1, :thread_covers_from))

    assert {:ok, %{id: turn_id}} = Session.send_turn(ws, "hot-upgraded state")
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000
  end

  test "workspace delegated send never synchronously registers back through a stale workspace root",
       %{path: root, ws: ws} do
    stale_path = Path.join(root, "stale-workspace-root")
    File.mkdir_p!(stale_path)

    {:ok, stale_ws} =
      Session.attach(stale_path,
        live_session_id: "stale-workspace-root",
        chat_rail_id: "stale-workspace-root",
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "stale reply"}]
        ],
        workspace_root: stale_path
      )

    assert_receive {:workspace_foreground_rebound, ^stale_ws}, 1_000

    stale_workspace_pid = Session.whereis(stale_path)
    agent_pid = AcpAgent.whereis(ws.agent_id)
    original_agent_state = :sys.get_state(agent_pid)

    :sys.replace_state(agent_pid, &%{&1 | workspace_root: stale_path})
    :sys.suspend(stale_workspace_pid)

    started_at = System.monotonic_time(:millisecond)

    result =
      try do
        Session.send_turn(ws, "must not deadlock")
      catch
        :exit, reason -> {:exit, reason}
      end

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    :sys.resume(stale_workspace_pid)
    :sys.replace_state(agent_pid, fn _state -> original_agent_state end)

    assert {:ok, %{status: :running}} = result
    assert elapsed_ms < 1_000
  end

  # 2026-07-19 field bug (#464): when a resume lands on a DIFFERENT provider
  # thread, every earlier transcript row is invisible to the agent ("he can't
  # find the ruby shell cmd"). The session must record the gap and seed a
  # one-time bounded recap of the uncovered rows into the next prompt.
  test "a thread change seeds a one-time recap of rows the new thread never saw", %{path: root} do
    path = Path.join(root, "thread-recap")
    File.mkdir_p!(path)

    settings = [
      live_session_id: "thread-recap",
      chat_rail_id: "recap-tab",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        report_prompts: true,
        test_pid: self(),
        # The provider answers the resume with a DIFFERENT thread id (rollout
        # lost/partially recovered) — the recap trigger.
        resume_session_id: "recovered-on-another-thread",
        script: [{:text_delta, "reply"}]
      ],
      workspace_root: path
    ]

    {:ok, ws} = Session.attach(path, settings)
    assert_receive {:workspace_foreground_rebound, ^ws}, 1_000
    agent_id = ws.agent_id
    Session.subscribe_agent(agent_id)

    {:ok, %{id: t1}} = Session.send_turn(ws, "우측 상단 셸 명령을 실행해줘")
    assert_receive {:fake_acp_prompt, _sid, p1}, 2_000
    refute p1 =~ "<conversation-recap>"
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^t1}}, 2_000

    old_pid = AcpAgent.whereis(agent_id)
    ref = Process.monitor(old_pid)
    :ok = GenServer.stop(old_pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, _reason}, 2_000

    # Turn 2 revives and resumes onto the OTHER thread: the gap is recorded
    # mid-turn, so this prompt is still clean...
    assert {:ok, %{id: t2}} = send_when_ready(ws, "그 다음 작업")
    assert_receive {:fake_acp_prompt, _sid, p2}, 2_000
    refute p2 =~ "<conversation-recap>"
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^t2}}, 2_000

    # ...and turn 3 carries the one-time recap, including the uncovered row.
    assert {:ok, %{id: t3}} = send_when_ready(ws, "그 명령 다시 실행해줘")
    assert_receive {:fake_acp_prompt, _sid, p3}, 2_000
    assert p3 =~ "<conversation-recap>"
    assert p3 =~ "우측 상단 셸 명령"
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^t3}}, 2_000

    # Seeded once: the next prompt is clean again.
    assert {:ok, %{id: t4}} = send_when_ready(ws, "마지막 확인")
    assert_receive {:fake_acp_prompt, _sid, p4}, 2_000
    refute p4 =~ "<conversation-recap>"
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^t4}}, 2_000
  end

  defp send_when_ready(ws, input) do
    Enum.reduce_while(1..40, {:error, :foreground_transition_in_progress}, fn _i, _acc ->
      case Session.send_turn(ws, input) do
        {:error, :foreground_transition_in_progress} = busy ->
          Process.sleep(50)
          {:cont, busy}

        other ->
          {:halt, other}
      end
    end)
  end

  # 2026-07-19 field bug ("session's gone"): a dead rail Session whose durable
  # transcript remains used to surface {:error, :not_found} as a rail error
  # banner on the next send. A dead process is a lifecycle event — the send
  # must revive the agent in place, on the rail's remembered attach settings,
  # and run the turn on the restored conversation.
  test "a send after the session process died revives the agent on the same conversation",
       %{ws: ws} do
    agent_id = ws.agent_id
    Session.subscribe_agent(agent_id)

    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, agent_id, "before the death")
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000
    rows_before = length(AcpAgent.agent_snapshot(agent_id).transcript)
    assert rows_before > 0

    old_pid = AcpAgent.whereis(agent_id)
    ref = Process.monitor(old_pid)
    :ok = GenServer.stop(old_pid, :normal)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, _reason}, 2_000

    # The death may briefly overlap the finished turn's crash-recovery window;
    # :foreground_transition_in_progress is the transient the composer absorbs
    # by keeping the message. The send after that window must revive, never
    # surface :not_found.
    result =
      Enum.reduce_while(1..40, {:error, :foreground_transition_in_progress}, fn _i, _acc ->
        case Session.send_turn(ws, "after the revive") do
          {:error, :foreground_transition_in_progress} = busy ->
            Process.sleep(50)
            {:cont, busy}

          other ->
            {:halt, other}
        end
      end)

    assert {:ok, %{id: revived_turn}} = result

    # The revive rebinds attached LiveViews: the revived agent runs a NEW
    # instance and LVs fence events per instance, so without this message the
    # rail would drop every event of the revived turn as stale.
    assert_receive {:workspace_foreground_rebound, %{agent_id: ^agent_id}}, 2_000

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^revived_turn}}, 2_000

    new_pid = AcpAgent.whereis(agent_id)
    assert is_pid(new_pid)
    refute new_pid == old_pid

    # Same conversation, not a fresh one: the durable transcript carried over
    # and the revived turn appended to it.
    transcript = AcpAgent.agent_snapshot(agent_id).transcript
    assert length(transcript) > rows_before
  end

  test "graceful cancel reaches the provider worker before the brutal-kill timeout", %{
    path: root
  } do
    path = Path.join(root, "guardian-cancel-forwarding")
    File.mkdir_p!(path)

    settings = [
      live_session_id: "guardian-cancel-forwarding",
      chat_rail_id: "stable-tab",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        wait_for: :never_release_cancelled_worker,
        test_pid: self(),
        script: [{:text_delta, "must not be emitted"}]
      ],
      workspace_root: path
    ]

    {:ok, ws} = Session.attach(path, settings)
    :ok = Session.subscribe_file_events(path)

    assert {:ok, %{id: turn_id, status: :running}} =
             Session.send_turn(ws, "cancel through guardian")

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    agent_pid = AcpAgent.whereis(ws.agent_id)

    assert %{
             current: %{
               task_pid: guardian_pid,
               worker_pid: provider_worker_pid,
               turn_id: ^turn_id
             },
             instance_id: instance_id
           } = :sys.get_state(agent_pid)

    key = {ws.agent_id, instance_id, turn_id}

    assert %{agent_turn_owners: %{^key => %{worker_pid: ^provider_worker_pid}}} =
             await_workspace_state(Session.whereis(path), fn state ->
               match?(
                 %{agent_turn_owners: %{^key => %{worker_pid: ^provider_worker_pid}}},
                 state
               )
             end)

    guardian_monitor = Process.monitor(guardian_pid)
    worker_monitor = Process.monitor(provider_worker_pid)
    started_at = System.monotonic_time(:millisecond)

    assert {:ok, %{id: ^turn_id, status: :cancelled}} = Session.cancel(ws, turn_id)

    assert_receive {:DOWN, ^worker_monitor, :process, ^provider_worker_pid, :normal}, 1_000
    worker_elapsed_ms = System.monotonic_time(:millisecond) - started_at
    assert worker_elapsed_ms < 1_000

    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian_pid, :normal}, 1_000

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: agent_id,
                      instance_id: ^instance_id,
                      turn_id: ^turn_id,
                      summary: %{successful?: true}
                    }},
                   2_000

    assert agent_id == ws.agent_id
  end

  test "exact cancel timeout kills a late-registered suspended worker before finalization", %{
    path: root
  } do
    path = Path.join(root, "late-worker-hard-cancel")
    File.mkdir_p!(path)

    settings = [
      live_session_id: "late-worker-hard-cancel",
      chat_rail_id: "stable-tab",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        wait_for: :never_release_hard_cancelled_worker,
        test_pid: self(),
        script: [{:text_delta, "must not be emitted"}]
      ],
      workspace_root: path
    ]

    {:ok, ws} = Session.attach(path, settings)
    :ok = Session.subscribe_file_events(path)

    assert {:ok, %{id: turn_id, status: :running}} =
             Session.send_turn(ws, "hard cancel late worker")

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    agent_pid = AcpAgent.whereis(ws.agent_id)

    assert %{
             current: %{
               task_pid: guardian_pid,
               worker_pid: provider_worker_pid,
               worker_ref: original_worker_ref,
               turn_id: ^turn_id
             },
             instance_id: instance_id
           } = :sys.get_state(agent_pid)

    key = {ws.agent_id, instance_id, turn_id}
    session_pid = Session.whereis(path)

    assert %{agent_turn_owners: %{^key => %{worker_pid: ^provider_worker_pid}}} =
             await_workspace_state(session_pid, fn state ->
               match?(
                 %{agent_turn_owners: %{^key => %{worker_pid: ^provider_worker_pid}}},
                 state
               )
             end)

    :erlang.suspend_process(provider_worker_pid)
    pool_pid = Process.whereis(Ecrits.Doc.Pool)
    :ok = :sys.suspend(pool_pid)

    try do
      # Recreate the only ordering that matters here: cancellation moved the
      # current turn into its fence before the guardian's worker identity
      # message reached the owning Session.
      :sys.replace_state(agent_pid, fn state ->
        Process.demonitor(original_worker_ref, [:flush])
        current = Map.drop(state.current, [:worker_pid, :worker_ref])
        %{state | current: current}
      end)

      guardian_monitor = Process.monitor(guardian_pid)
      provider_worker_monitor = Process.monitor(provider_worker_pid)

      assert {:ok, %{id: ^turn_id, status: :cancelled}} = Session.cancel(ws, turn_id)

      assert %{
               cancellation_fence: %{
                 task_pid: ^guardian_pid,
                 worker_pid: nil,
                 worker_down?: true,
                 token: timeout_token
               },
               terminal_finalization: nil
             } = await_agent_state(agent_pid, &is_map(&1.cancellation_fence))

      assert Process.alive?(guardian_pid)
      assert Process.alive?(provider_worker_pid)
      refute Map.has_key?(:sys.get_state(session_pid).turn_finalizations, key)

      send(
        agent_pid,
        {:guarded_turn_worker_started, turn_id, guardian_pid, provider_worker_pid}
      )

      assert %{
               cancellation_fence: %{
                 token: ^timeout_token,
                 worker_pid: ^provider_worker_pid,
                 worker_ref: late_worker_ref,
                 worker_down?: false
               },
               terminal_finalization: nil
             } =
               await_agent_state(agent_pid, fn state ->
                 match?(
                   %{
                     cancellation_fence: %{
                       worker_pid: ^provider_worker_pid,
                       worker_down?: false
                     }
                   },
                   state
                 )
               end)

      assert is_reference(late_worker_ref)
      assert Process.alive?(provider_worker_pid)
      refute Map.has_key?(:sys.get_state(session_pid).turn_finalizations, key)

      # Fire the exact timeout identity rather than sleeping five seconds. A
      # stale token or task pid would be ignored by the production handler.
      send(agent_pid, {:force_kill_turn, timeout_token, guardian_pid})

      assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian_pid, :killed}, 1_000

      assert_receive {:DOWN, ^provider_worker_monitor, :process, ^provider_worker_pid, :killed},
                     1_000

      refute Process.alive?(guardian_pid)
      refute Process.alive?(provider_worker_pid)

      assert %{terminal_finalization: %{key: ^key}} =
               await_agent_state(agent_pid, &match?(%{key: ^key}, &1.terminal_finalization))

      assert %{turn_finalization_active: %{key: ^key}} =
               await_workspace_state(
                 session_pid,
                 &match?(%{turn_finalization_active: %{key: ^key}}, &1)
               )
    after
      if Process.info(provider_worker_pid, :status) == {:status, :suspended},
        do: :erlang.resume_process(provider_worker_pid)

      :ok = :sys.resume(pool_pid)
    end

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: agent_id,
                      instance_id: ^instance_id,
                      turn_id: ^turn_id,
                      summary: %{successful?: true}
                    }},
                   2_000

    assert agent_id == ws.agent_id
  end

  test "owning session kill finalizes once without a LiveView before replacement binds", %{
    path: root
  } do
    path = Path.join(root, "owning-session-kill")
    File.mkdir_p!(path)
    test_pid = self()

    settings = [
      live_session_id: "owning-session-kill",
      chat_rail_id: "stable-tab",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        turn_cancel_grace_ms: 250,
        wait_for: :release_owner_crash,
        test_pid: test_pid,
        script: [{:text_delta, "must never survive owner death"}]
      ],
      workspace_root: path
    ]

    live_process = start_live_process()
    {:ok, ws} = attach_from(live_process, path, settings)
    stop_live_process(live_process)

    session_pid = Session.whereis(path)

    assert %{foreground_live_views: foreground_live_views} =
             await_workspace_state(session_pid, &(&1.foreground_live_views == %{}))

    assert foreground_live_views == %{}
    :ok = Session.subscribe_file_events(path)
    :ok = Session.subscribe_agent(ws.agent_id)

    # Bypass the Workspace facade after the only attached browser process is
    # gone. The owning ACP Session must synchronously register its exact lease.
    assert {:ok, %{id: turn_id, status: :running}} =
             AcpAgent.send_turn(nil, ws.agent_id, "active without a LiveView")

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    old_agent_pid = AcpAgent.whereis(ws.agent_id)

    assert %{
             current: %{task_pid: guarded_task_pid, turn_id: ^turn_id},
             instance_id: instance_id
           } = :sys.get_state(old_agent_pid)

    key = {ws.agent_id, instance_id, turn_id}

    assert %{
             agent_turn_owners: %{
               ^key => %{
                 owner_ref: old_owner_ref,
                 worker_pid: provider_worker_pid,
                 worker_ref: old_worker_ref
               }
             }
           } = await_workspace_state(session_pid, &Map.has_key?(&1.agent_turn_owners, key))

    pool_pid = Process.whereis(Ecrits.Doc.Pool)
    :erlang.suspend_process(provider_worker_pid)
    :ok = :sys.suspend(pool_pid)

    old_task_ref =
      try do
        old_agent_monitor = Process.monitor(old_agent_pid)
        guarded_task_monitor = Process.monitor(guarded_task_pid)
        provider_worker_monitor = Process.monitor(provider_worker_pid)
        Process.exit(old_agent_pid, :kill)

        assert_receive {:DOWN, ^old_agent_monitor, :process, ^old_agent_pid, :killed}, 2_000

        assert %{
                 agent_turn_owners: %{
                   ^key => %{status: :awaiting_task_down, task_ref: old_task_ref}
                 },
                 turn_finalization_active: nil
               } =
                 await_workspace_state(session_pid, fn state ->
                   match?(
                     %{
                       agent_turn_owners: %{^key => %{status: :awaiting_task_down}},
                       turn_finalization_active: nil
                     },
                     state
                   )
                 end)

        assert Process.alive?(provider_worker_pid)
        assert Process.alive?(guarded_task_pid)
        refute Map.has_key?(:sys.get_state(session_pid).turn_finalizations, key)

        assert_receive {:DOWN, ^provider_worker_monitor, :process, ^provider_worker_pid, :killed},
                       2_000

        assert_receive {:DOWN, ^guarded_task_monitor, :process, ^guarded_task_pid, :normal},
                       2_000

        assert %{
                 agent_turn_owners: %{
                   ^key => %{
                     status: :crashed,
                     shutdown_ack?: true,
                     worker_down?: true
                   }
                 }
               } =
                 await_workspace_state(session_pid, fn state ->
                   match?(
                     %{
                       agent_turn_owners: %{
                         ^key => %{status: :crashed, shutdown_ack?: true, worker_down?: true}
                       }
                     },
                     state
                   )
                 end)

        refute Process.alive?(provider_worker_pid)
        refute Process.alive?(guarded_task_pid)

        assert {:pending, pending_ws} = Session.attach(path, settings)
        assert pending_ws.agent_id == ws.agent_id

        assert %{
                 agent_turn_owners: %{^key => %{status: :crashed}},
                 foreground_transitions: %{^key => %{operation: :start}},
                 turn_finalization_active: %{key: ^key}
               } =
                 await_workspace_state(session_pid, fn state ->
                   match?(
                     %{
                       agent_turn_owners: %{^key => %{status: :crashed}},
                       foreground_transitions: %{^key => %{operation: :start}},
                       turn_finalization_active: %{key: ^key}
                     },
                     state
                   )
                 end)

        assert AcpAgent.whereis(ws.agent_id) == nil

        assert {:error, :foreground_transition_in_progress} =
                 Session.send_turn(pending_ws, "must remain fenced")

        old_task_ref
      after
        if Process.info(provider_worker_pid, :status) == {:status, :suspended},
          do: :erlang.resume_process(provider_worker_pid)

        :ok = :sys.resume(pool_pid)
      end

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: agent_id,
                      instance_id: ^instance_id,
                      turn_id: ^turn_id,
                      summary: %{successful?: true}
                    }},
                   2_000

    assert agent_id == ws.agent_id

    assert_receive {:workspace_foreground_rebound, rebound_ws}, 2_000
    assert rebound_ws.agent_id == ws.agent_id

    new_agent_pid = AcpAgent.whereis(ws.agent_id)
    assert is_pid(new_agent_pid)
    refute new_agent_pid == old_agent_pid

    assert %{instance_id: new_instance_id, current_turn: nil} =
             AcpAgent.agent_snapshot(ws.agent_id)

    refute new_instance_id == instance_id

    assert %{
             agents: %{^agent_id => %{pid: ^new_agent_pid}},
             agent_turn_owners: owners,
             foreground_transitions: %{},
             turn_finalizations: %{^key => %{status: :completed}}
           } = :sys.get_state(session_pid)

    assert agent_id == ws.agent_id
    refute Map.has_key?(owners, key)

    # A delayed duplicate DOWN from the old instance is identity-scoped and
    # cannot remove, restart, or otherwise relabel the replacement instance.
    send(session_pid, {:DOWN, old_owner_ref, :process, old_agent_pid, :killed})
    send(session_pid, {:DOWN, old_task_ref, :process, guarded_task_pid, :killed})
    send(session_pid, {:DOWN, old_worker_ref, :process, provider_worker_pid, :killed})
    send(session_pid, {:agent_turn_guardian_stopped, key, guarded_task_pid})
    _ = :sys.get_state(session_pid)
    assert AcpAgent.whereis(ws.agent_id) == new_agent_pid
    assert Process.alive?(new_agent_pid)

    assert %{agents: %{^agent_id => %{pid: ^new_agent_pid}}, agent_turn_owners: stale_owners} =
             :sys.get_state(session_pid)

    refute Map.has_key?(stale_owners, key)
    assert %{instance_id: ^new_instance_id} = AcpAgent.agent_snapshot(ws.agent_id)

    refute_receive {:workspace_turn_finalized, %{turn_id: ^turn_id}}, 100
  end

  test "new chat waits for the old active turn and starts no overlapping rail", %{path: root} do
    path = Path.join(root, "new-chat-fence")
    File.mkdir_p!(path)
    test_pid = self()

    settings = [
      live_session_id: "new-chat-fence",
      chat_rail_id: "stable-tab",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        wait_for: :release_new_chat,
        test_pid: test_pid,
        script: [{:text_delta, "late old reply"}]
      ]
    ]

    {:ok, old_ws} = Session.attach(path, settings)
    :ok = Session.subscribe_file_events(path)
    :ok = Session.subscribe_agent(old_ws.agent_id)
    assert_receive {:workspace_foreground_rebound, ^old_ws}, 1_000

    assert {:ok, %{id: turn_id, status: :running}} =
             Session.send_turn(old_ws, "active old chat")

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    assert {:ok, %{id: queued_turn_id, status: :queued}} =
             Session.send_turn(old_ws, "queued on the old chat")

    assert_receive {:agent_event, %{type: :turn_queued, turn_id: ^queued_turn_id}}, 1_000

    old_agent_id = old_ws.agent_id
    old_pid = AcpAgent.whereis(old_agent_id)
    assert {:ok, %{workspace_root: workspace_root}} = AcpAgent.status(nil, old_agent_id)
    assert workspace_root == Session.canonical_path(path)
    %{current: %{task_pid: old_turn_task_pid}} = :sys.get_state(old_pid)
    old_instance_id = AcpAgent.agent_snapshot(old_agent_id).instance_id
    key = {old_agent_id, old_instance_id, turn_id}
    session_pid = Session.whereis(path)
    pool_pid = Process.whereis(Ecrits.Doc.Pool)
    :ok = :sys.suspend(pool_pid)

    assert {:pending, pending_ws} = Session.new_foreground(path, settings)
    refute pending_ws.agent_id == old_agent_id
    refute pending_ws.rail_key == old_ws.rail_key

    assert {:pending, ^pending_ws} = Session.new_foreground(path, settings)

    try do
      assert %{
               foreground_transitions: %{^key => %{operation: :start}},
               turn_finalization_active: %{key: ^key}
             } =
               await_workspace_state(session_pid, fn state ->
                 match?(
                   %{
                     foreground_transitions: %{^key => %{operation: :start}},
                     turn_finalization_active: %{key: ^key}
                   },
                   state
                 )
               end)

      assert AcpAgent.whereis(old_agent_id) == old_pid
      assert Process.alive?(old_pid)
      refute Process.alive?(old_turn_task_pid)
      assert [%{agent_id: ^old_agent_id, active?: true}] = Session.recent_foregrounds(old_ws)

      assert {:error, :foreground_transition_in_progress} =
               Session.send_turn(old_ws, "must not overlap the new chat")

      assert {:error, :foreground_transition_in_progress} = Session.flush_queue(old_ws)

      assert {:error, :foreground_transition_in_progress} =
               Session.restart_foreground(path, Keyword.put(settings, :provider, "claude"))

      assert {:error, :foreground_transition_in_progress} =
               Session.select_foreground(path, old_ws.rail_key, settings)

      assert {:error, :foreground_transition_in_progress} =
               Session.update_options(old_ws, model: "must-not-win")

      assert %{pending: 1, queued: [%{turn_id: ^queued_turn_id}], current_turn: nil} =
               AcpAgent.agent_snapshot(old_agent_id)
    after
      :ok = :sys.resume(pool_pid)
    end

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: ^old_agent_id,
                      instance_id: ^old_instance_id,
                      turn_id: ^turn_id,
                      summary: %{successful?: true}
                    }},
                   2_000

    expected_agent_id = pending_ws.agent_id
    expected_rail_key = pending_ws.rail_key
    expected_path = pending_ws.path

    assert_receive {:workspace_foreground_rebound,
                    %{
                      path: ^expected_path,
                      agent_id: ^expected_agent_id,
                      rail_key: ^expected_rail_key
                    } = new_ws},
                   2_000

    refute new_ws.agent_id == old_agent_id
    refute new_ws.rail_key == old_ws.rail_key
    assert AcpAgent.whereis(old_agent_id) == old_pid
    assert Process.alive?(old_pid)

    assert %{pending: 1, queued: [%{turn_id: ^queued_turn_id}], current_turn: nil} =
             AcpAgent.agent_snapshot(old_agent_id)

    refute_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn_id}}, 100

    assert %{transcript: [], pending: 0, queued: [], current_turn: nil} =
             AcpAgent.agent_snapshot(new_ws.agent_id)

    recents = Session.recent_foregrounds(new_ws)
    assert Enum.any?(recents, &(&1.agent_id == old_agent_id and not &1.active?))
    assert Enum.any?(recents, &(&1.agent_id == new_ws.agent_id and &1.active?))
    assert :sys.get_state(session_pid).foreground_transitions == %{}
  end

  test "replacement workspace reclaims an exact terminal barrier after a coordinator crash", %{
    path: root
  } do
    path = Path.join(root, "workspace-crash-recovery")
    File.mkdir_p!(path)
    test_pid = self()

    settings = [
      live_session_id: "workspace-crash-recovery",
      chat_rail_id: "stable-tab",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        wait_for: :release_workspace_crash,
        test_pid: test_pid,
        script: [{:text_delta, "late old reply"}]
      ]
    ]

    {:ok, ws} = Session.attach(path, settings)
    assert_receive {:workspace_foreground_rebound, ^ws}, 1_000
    :ok = Session.subscribe_file_events(path)
    :ok = Session.subscribe_agent(ws.agent_id)

    assert {:ok, %{id: turn_id, status: :running}} =
             Session.send_turn(ws, "active before workspace crash")

    assert_receive {:agent_adapter_waiting, _adapter_pid}, 2_000

    assert {:ok, %{id: queued_turn_id, status: :queued}} =
             Session.send_turn(ws, "held across workspace crash")

    agent_id = ws.agent_id
    old_agent_pid = AcpAgent.whereis(agent_id)
    instance_id = AcpAgent.agent_snapshot(agent_id).instance_id
    key = {agent_id, instance_id, turn_id}
    old_session_pid = Session.whereis(path)
    pool_pid = Process.whereis(Ecrits.Doc.Pool)
    :ok = :sys.suspend(pool_pid)

    replacement_settings = Keyword.put(settings, :provider, "claude")

    {pending_ws, replacement_session_pid} =
      try do
        assert {:pending, _pending_ws} = Session.restart_foreground(path, replacement_settings)

        assert %{turn_finalization_active: %{key: ^key, pid: old_finalizer_pid}} =
                 await_workspace_state(old_session_pid, fn state ->
                   match?(%{turn_finalization_active: %{key: ^key}}, state)
                 end)

        old_session_ref = Process.monitor(old_session_pid)
        old_finalizer_ref = Process.monitor(old_finalizer_pid)
        Process.exit(old_session_pid, :kill)

        assert_receive {:DOWN, ^old_session_ref, :process, ^old_session_pid, :killed}, 2_000

        assert_receive {:DOWN, ^old_finalizer_ref, :process, ^old_finalizer_pid, _reason},
                       2_000

        assert {:pending, pending_ws} = Session.attach(path, replacement_settings)
        pending_rail_key = pending_ws.rail_key

        replacement_session_pid = Session.whereis(path)
        refute replacement_session_pid == old_session_pid

        assert %{
                 foregrounds: %{
                   ^pending_rail_key => %{agent_id: ^agent_id, provider: "codex"}
                 },
                 foreground_transitions: %{^key => %{operation: :restart}},
                 turn_finalization_active: %{key: ^key, pid: replacement_finalizer_pid}
               } =
                 await_workspace_state(replacement_session_pid, fn state ->
                   match?(
                     %{
                       foreground_transitions: %{^key => %{operation: :restart}},
                       turn_finalization_active: %{key: ^key}
                     },
                     state
                   )
                 end)

        refute replacement_finalizer_pid == old_finalizer_pid
        assert AcpAgent.whereis(agent_id) == old_agent_pid
        assert Process.alive?(old_agent_pid)
        assert AcpAgent.agent_snapshot(agent_id).provider == "codex"

        assert %{pending: 1, queued: [%{turn_id: ^queued_turn_id}], current_turn: nil} =
                 AcpAgent.agent_snapshot(agent_id)

        refute_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn_id}},
                       100

        {pending_ws, replacement_session_pid}
      after
        :ok = :sys.resume(pool_pid)
      end

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: ^agent_id,
                      instance_id: ^instance_id,
                      turn_id: ^turn_id,
                      summary: %{successful?: true}
                    }},
                   2_000

    expected_path = pending_ws.path
    expected_agent_id = pending_ws.agent_id
    expected_rail_key = pending_ws.rail_key

    assert_receive {:workspace_foreground_rebound,
                    %{
                      path: ^expected_path,
                      agent_id: ^expected_agent_id,
                      rail_key: ^expected_rail_key
                    } = rebound_ws},
                   2_000

    assert rebound_ws.agent_id == agent_id
    new_agent_pid = AcpAgent.whereis(agent_id)
    assert is_pid(new_agent_pid)
    refute new_agent_pid == old_agent_pid
    refute Process.alive?(old_agent_pid)

    assert %{
             provider: "claude",
             instance_id: new_instance_id,
             pending: 0,
             queued: [],
             current_turn: nil
           } = AcpAgent.agent_snapshot(agent_id)

    refute new_instance_id == instance_id
    pending_rail_key = pending_ws.rail_key

    assert %{
             foregrounds: %{
               ^pending_rail_key => %{agent_id: ^agent_id, provider: "claude"}
             },
             foreground_transitions: %{}
           } = :sys.get_state(replacement_session_pid)

    refute_receive {:agent_event, %{type: :turn_started, turn_id: ^queued_turn_id}}, 100
    refute_receive {:workspace_turn_finalized, %{turn_id: ^turn_id}}, 100
  end

  test "re-attach with a DIFFERENT provider restarts the agent (adapter is bound at start)",
       %{path: path, ws: ws} do
    agent_id = ws.agent_id
    old_pid = AcpAgent.whereis(agent_id)
    assert is_pid(old_pid)

    # Give the codex agent a non-empty transcript.
    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, agent_id, "hello from codex")
    Session.subscribe_agent(agent_id)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000
    assert AcpAgent.agent_snapshot(agent_id).transcript != []

    # A plain ATTACH (not restart) whose provider differs from the bound agent's —
    # this is the page-reload seam: the durable path-keyed agent was started under
    # codex, but the new mount requests claude. The ACP adapter cannot be swapped
    # live, so attach MUST restart rather than silently reuse the codex adapter.
    ws2 =
      Session.attach(path,
        provider: "claude",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "claude reply"}]
        ],
        workspace_root: path
      )
      |> await_foreground_transition()

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
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

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
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

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
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

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

  test "a stable chat rail id reattaches the same agent across LiveView pids", %{path: path} do
    settings = [
      live_session_id: "browser-refresh",
      chat_rail_id: "tab-a",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        script: [{:text_delta, "reply"}]
      ],
      workspace_root: path
    ]

    live_1 = start_live_process()
    {:ok, ws1} = attach_from(live_1, path, settings)

    Session.subscribe_agent(ws1.agent_id)
    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, ws1.agent_id, "persist me")
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    stop_live_process(live_1)
    sync_session(path)

    live_2 = start_live_process()
    {:ok, ws2} = attach_from(live_2, path, settings)

    assert ws2.rail_key == ws1.rail_key
    assert ws2.agent_id == ws1.agent_id
    assert [%{user: "persist me"}] = AcpAgent.agent_snapshot(ws2.agent_id).transcript
    assert [%{agent_id: agent_id, active?: true}] = Session.recent_foregrounds(ws2)
    assert agent_id == ws1.agent_id

    stop_live_process(live_2)
  end

  test "simultaneous LiveViews share one stable tab rail and monitor each pid once", %{
    path: root
  } do
    path = Path.join(root, "stable-tab-concurrent")
    File.mkdir_p!(path)

    settings = [
      live_session_id: "stable-tab-concurrent",
      chat_rail_id: "tab-a",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        script: [{:text_delta, "reply"}]
      ],
      workspace_root: path
    ]

    live_a = start_live_process()
    {:ok, ws_a} = attach_from(live_a, path, settings)

    {:ok, repeated_ws} = attach_from(live_a, path, settings)
    assert repeated_ws.rail_key == ws_a.rail_key
    assert repeated_ws.agent_id == ws_a.agent_id

    assert :ok =
             call_from(live_a, fn ->
               Session.attach_viewer(path, "monitor-dedup-document", live_a)
             end)

    assert :ok =
             call_from(live_a, fn ->
               Session.attach_viewer(path, "monitor-dedup-document", live_a)
             end)

    session_pid = Session.whereis(path)
    assert {:monitors, monitors} = Process.info(session_pid, :monitors)
    assert Enum.count(monitors, &(&1 == {:process, live_a})) == 1

    live_b = start_live_process()
    {:ok, ws_b} = attach_from(live_b, path, settings)

    assert ws_b.rail_key == ws_a.rail_key
    assert ws_b.agent_id == ws_a.agent_id
    assert Process.alive?(live_a)
    assert Process.alive?(live_b)

    state = path |> Session.whereis() |> :sys.get_state()

    assert %{
             ^live_a => "tab-" <> stable_key,
             ^live_b => "tab-" <> stable_key
           } = state.foreground_live_views

    assert {:monitors, monitors} = Process.info(session_pid, :monitors)
    assert Enum.count(monitors, &(&1 == {:process, live_a})) == 1
    assert Enum.count(monitors, &(&1 == {:process, live_b})) == 1

    Session.subscribe_agent(ws_a.agent_id)

    assert {:ok, %{id: turn_a}} =
             call_from(live_a, fn -> Session.send_turn(ws_a, "from live a") end)

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_a}}, 2_000

    assert {:ok, %{id: turn_b}} =
             call_from(live_b, fn -> Session.send_turn(ws_b, "from live b") end)

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_b}}, 2_000

    assert [%{user: "from live a"}, %{user: "from live b"}] =
             AcpAgent.agent_snapshot(ws_b.agent_id).transcript

    document_id = "stable-concurrent-owned-document"

    assert :ok =
             call_from(live_a, fn ->
               Session.claim_owner(path, document_id, ws_a.agent_id)
             end)

    stop_live_process(live_b)
    sync_session(path)

    assert Session.owner(path, document_id) == ws_a.agent_id
    assert Process.alive?(live_a)

    state = :sys.get_state(session_pid)
    assert %{^live_a => "tab-" <> ^stable_key} = state.foreground_live_views

    stop_live_process(live_a)
    sync_session(path)

    assert Session.owner(path, document_id) == nil

    replacement = start_live_process()
    {:ok, replacement_ws} = attach_from(replacement, path, settings)

    assert replacement_ws.rail_key == ws_a.rail_key
    assert replacement_ws.agent_id == ws_a.agent_id

    assert [%{user: "from live a"}, %{user: "from live b"}] =
             AcpAgent.agent_snapshot(replacement_ws.agent_id).transcript

    stop_live_process(replacement)
  end

  test "shared stable-tab create and select rebind every sibling and route stale sends to the current rail",
       %{path: root} do
    path = Path.join(root, "stable-tab-rebind")
    File.mkdir_p!(path)

    settings = [
      live_session_id: "stable-tab-rebind",
      chat_rail_id: "shared-tab",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        script: [{:text_delta, "reply"}]
      ],
      workspace_root: path
    ]

    live_a = start_live_process()
    live_b = start_live_process()
    {:ok, old_ws} = attach_from(live_a, path, settings)
    {:ok, sibling_old_ws} = attach_from(live_b, path, settings)
    assert sibling_old_ws.agent_id == old_ws.agent_id

    Session.subscribe_agent(old_ws.agent_id)

    assert {:ok, %{id: seed_turn}} =
             call_from(live_a, fn -> Session.send_turn(old_ws, "seed old rail") end)

    assert_receive {:agent_event,
                    %{type: :turn_completed, turn_id: ^seed_turn, session_id: old_agent_id}},
                   2_000

    assert old_agent_id == old_ws.agent_id

    session_pid = Session.whereis(path)
    dead_live_view = spawn(fn -> :ok end)
    dead_ref = Process.monitor(dead_live_view)
    assert_receive {:DOWN, ^dead_ref, :process, ^dead_live_view, :normal}

    :sys.replace_state(session_pid, fn state ->
      live_view_key = Map.fetch!(state.foreground_live_views, live_b)

      state
      |> Map.put(:superseded_foreground_live_views, MapSet.new([live_b]))
      |> Map.update!(:foreground_live_views, &Map.put(&1, dead_live_view, live_view_key))
    end)

    new_ws =
      live_a
      |> call_from(fn -> Session.new_foreground(path, settings) end)
      |> await_live_foreground_transition(live_a)

    refute new_ws.agent_id == old_ws.agent_id
    refute new_ws.rail_key == old_ws.rail_key

    assert %{agent_id: new_agent_id, rail_key: new_rail_key} = last_rebind(live_a)
    assert new_agent_id == new_ws.agent_id
    assert new_rail_key == new_ws.rail_key
    assert %{agent_id: ^new_agent_id, rail_key: ^new_rail_key} = last_rebind(live_b)

    refute Map.has_key?(:sys.get_state(session_pid), :superseded_foreground_live_views)
    refute Map.has_key?(:sys.get_state(session_pid).foreground_live_views, dead_live_view)

    Session.subscribe_agent(new_agent_id)

    # B still holds the ws returned before A created the rail. Sending through
    # the Session must resolve B's shared stable key at call time.
    assert {:ok, %{id: sibling_turn}} =
             call_from(live_b, fn -> Session.send_turn(sibling_old_ws, "B uses current rail") end)

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      turn_id: ^sibling_turn,
                      session_id: ^new_agent_id
                    }},
                   2_000

    new_agent_pid = AcpAgent.whereis(new_agent_id)

    assert %{terminal_finalization: nil} =
             await_agent_state(new_agent_pid, fn state ->
               state.terminal_finalization == nil
             end)

    assert [%{user: "B uses current rail"}] = AcpAgent.agent_snapshot(new_agent_id).transcript

    test_pid = self()

    assert :ok =
             call_from(live_b, fn ->
               Session.update_options(sibling_old_ws,
                 test_pid: test_pid,
                 wait_for: :release_shared_turn
               )
             end)

    assert :ok =
             call_from(live_b, fn ->
               Session.rename(sibling_old_ws, "Current shared rail")
             end)

    assert AcpAgent.agent_snapshot(new_agent_id).title == "Current shared rail"
    refute AcpAgent.agent_snapshot(old_agent_id).title == "Current shared rail"

    assert {:ok, %{id: running_turn, status: :running}} =
             call_from(live_b, fn ->
               Session.send_turn(sibling_old_ws, "blocking current rail")
             end)

    assert_receive {:agent_adapter_waiting, _first_adapter}, 2_000

    assert {:ok, %{id: queued_turn, status: :queued}} =
             call_from(live_b, fn ->
               Session.send_turn(sibling_old_ws, "queued current rail")
             end)

    assert {:ok, %{id: ^running_turn, status: :cancelled}} =
             call_from(live_b, fn ->
               Session.cancel(sibling_old_ws, running_turn)
             end)

    assert {:ok, %{id: ^queued_turn, status: :queued}} =
             call_from(live_b, fn -> Session.flush_queue(sibling_old_ws) end)

    assert_receive {:agent_adapter_waiting, second_adapter}, 2_000
    send(second_adapter, :release_shared_turn)

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      turn_id: ^queued_turn,
                      session_id: ^new_agent_id
                    }},
                   2_000

    document_id = "owned-by-shared-current-rail"
    assert :ok = Session.claim_owner(path, document_id, new_agent_id)

    stop_live_process(live_a)
    sync_session(path)

    assert Process.alive?(live_b)
    assert Session.owner(path, document_id) == new_agent_id

    assert {:ok, selected_ws} =
             call_from(live_b, fn ->
               Session.select_foreground(path, old_ws.rail_key, settings)
             end)

    assert selected_ws.agent_id == old_ws.agent_id
    assert %{agent_id: ^old_agent_id, rail_key: old_rail_key} = last_rebind(live_b)
    assert old_rail_key == old_ws.rail_key

    # The stale new-ws value now routes to the re-selected old rail as well.
    assert {:ok, %{id: selected_turn}} =
             call_from(live_b, fn -> Session.send_turn(new_ws, "B uses selected rail") end)

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      turn_id: ^selected_turn,
                      session_id: ^old_agent_id
                    }},
                   2_000

    assert [%{user: "seed old rail"}, %{user: "B uses selected rail"}] =
             AcpAgent.agent_snapshot(old_agent_id).transcript

    stop_live_process(live_b)
  end

  test "stable tab DOWN releases liveness and ownership but preserves its rail", %{path: root} do
    path = Path.join(root, "stable-tab-liveness")
    File.mkdir_p!(path)

    settings = fn tab_id ->
      [
        live_session_id: "stable-tab-liveness",
        chat_rail_id: tab_id,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "reply"}]
        ],
        workspace_root: path
      ]
    end

    live_a = start_live_process()
    {:ok, ws_a} = attach_from(live_a, path, settings.("tab-a"))

    Session.subscribe_agent(ws_a.agent_id)
    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, ws_a.agent_id, "keep tab a")
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    document_id = "stable-tab-owned-document"
    assert :ok = Session.claim_owner(path, document_id, ws_a.agent_id)
    assert Session.owner(path, document_id) == ws_a.agent_id

    stop_live_process(live_a)
    sync_session(path)

    assert Session.owner(path, document_id) == nil
    assert [%{agent_id: agent_a, active?: false}] = Session.recent_foregrounds(ws_a)
    assert agent_a == ws_a.agent_id

    live_b = start_live_process()
    {:ok, ws_b} = attach_from(live_b, path, settings.("tab-b"))
    refute ws_b.agent_id == ws_a.agent_id
    assert :ok = Session.claim_owner(path, document_id, ws_b.agent_id)
    assert Session.owner(path, document_id) == ws_b.agent_id

    stop_live_process(live_b)
    sync_session(path)
    assert Session.owner(path, document_id) == nil

    live_a_reconnected = start_live_process()
    {:ok, restored_ws_a} = attach_from(live_a_reconnected, path, settings.("tab-a"))

    assert restored_ws_a.rail_key == ws_a.rail_key
    assert restored_ws_a.agent_id == ws_a.agent_id
    assert [%{user: "keep tab a"}] = AcpAgent.agent_snapshot(restored_ws_a.agent_id).transcript

    recents = Session.recent_foregrounds(restored_ws_a)
    assert Enum.any?(recents, &(&1.agent_id == ws_a.agent_id and &1.active?))
    assert Enum.any?(recents, &(&1.agent_id == ws_b.agent_id and not &1.active?))
  end

  test "workspace session crash restores every rail for the same browser session", %{path: root} do
    path = Path.join(root, "crash-restored-chat-rails")
    File.mkdir_p!(path)
    live = start_live_process()

    settings = [
      live_session_id: "crash-restored-browser-session",
      chat_rail_id: "crash-restored-tab",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        script: [{:text_delta, "reply"}]
      ],
      workspace_root: path
    ]

    {:ok, first_ws} = attach_from(live, path, settings)
    :ok = Session.subscribe_agent(first_ws.agent_id)

    assert {:ok, %{id: first_turn_id}} =
             AcpAgent.send_turn(nil, first_ws.agent_id, "first durable rail")

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^first_turn_id}}, 2_000

    second_ws =
      live
      |> call_from(fn -> Session.new_foreground(path, settings) end)
      |> await_live_foreground_transition(live)

    assert Enum.map(Session.recent_foregrounds(second_ws), & &1.agent_id) == [
             second_ws.agent_id,
             first_ws.agent_id
           ]

    old_session_pid = Session.whereis(path)
    old_session_ref = Process.monitor(old_session_pid)
    Process.exit(old_session_pid, :kill)

    assert_receive {:DOWN, ^old_session_ref, :process, ^old_session_pid, :killed}, 2_000

    {:ok, restored_ws} = attach_from(live, path, settings)

    assert restored_ws.rail_key == second_ws.rail_key
    assert restored_ws.agent_id == second_ws.agent_id

    assert Enum.map(Session.recent_foregrounds(restored_ws), & &1.agent_id) == [
             second_ws.agent_id,
             first_ws.agent_id
           ]

    assert [%{user: "first durable rail"}] =
             AcpAgent.agent_snapshot(first_ws.agent_id).transcript
  end

  test "the first stable tab id adopts an inactive legacy pid rail", %{path: path} do
    legacy_settings = [
      live_session_id: "upgrade-session",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        script: [{:text_delta, "legacy reply"}]
      ],
      workspace_root: path
    ]

    live_1 = start_live_process()
    {:ok, legacy_ws} = attach_from(live_1, path, legacy_settings)

    Session.subscribe_agent(legacy_ws.agent_id)
    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, legacy_ws.agent_id, "legacy chat")
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    stop_live_process(live_1)
    sync_session(path)

    live_2 = start_live_process()

    {:ok, stable_ws} =
      attach_from(live_2, path, Keyword.put(legacy_settings, :chat_rail_id, "stable-tab"))

    assert stable_ws.rail_key == legacy_ws.rail_key
    assert stable_ws.agent_id == legacy_ws.agent_id
    assert [%{user: "legacy chat"}] = AcpAgent.agent_snapshot(stable_ws.agent_id).transcript

    stop_live_process(live_2)
  end

  test "viewing a recent rail does not reorder durable chat history", %{path: path} do
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
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    document_id = "document-owned-by-first-rail"
    assert :ok = Session.claim_owner(path, document_id, ws1.agent_id)
    assert Session.owner(path, document_id) == ws1.agent_id

    ws2 = path |> Session.new_foreground(settings) |> await_foreground_transition()

    assert Session.owner(path, document_id) == nil

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
             %{agent_id: ^agent2, active?: false},
             %{agent_id: ^agent1, active?: true}
           ] = Session.recent_foregrounds(selected_ws)

    {:ok, reattached_ws} = Session.attach(path, settings)
    assert reattached_ws.agent_id == ws1.agent_id
    assert AcpAgent.agent_snapshot(reattached_ws.agent_id).transcript != []

    assert [
             %{agent_id: ^agent2, active?: false},
             %{agent_id: ^agent1, active?: true}
           ] = Session.recent_foregrounds(reattached_ws)
  end

  test "recent foregrounds are capped per browser session without cross-session crowding",
       %{path: root} do
    path = Path.join(root, "per-session-bounded-recents")
    File.mkdir_p!(path)

    live_rails =
      Enum.map(1..13, fn index ->
        live_a = start_live_process()

        settings_a = [
          live_session_id: "bounded-session-a",
          chat_rail_id: "bounded-a-#{index}",
          provider: "codex",
          adapter_opts: [
            exmcp_adapter: EcritsWeb.FakeAcpAdapter,
            script: [{:text_delta, "reply a #{index}"}]
          ],
          workspace_root: path
        ]

        {:ok, ws_a} = attach_from(live_a, path, settings_a)

        live_b = start_live_process()

        settings_b = [
          live_session_id: "bounded-session-b",
          chat_rail_id: "bounded-b-#{index}",
          provider: "codex",
          adapter_opts: [
            exmcp_adapter: EcritsWeb.FakeAcpAdapter,
            script: [{:text_delta, "reply b #{index}"}]
          ],
          workspace_root: path
        ]

        {:ok, ws_b} = attach_from(live_b, path, settings_b)
        {{live_a, ws_a}, {live_b, ws_b}}
      end)

    session_a = Enum.map(live_rails, fn {rail_a, _rail_b} -> rail_a end)
    session_b = Enum.map(live_rails, fn {_rail_a, rail_b} -> rail_b end)
    {_live_a, newest_a} = List.last(session_a)
    {_live_b, newest_b} = List.last(session_b)

    expected_a = session_a |> Enum.reverse() |> Enum.take(12) |> Enum.map(&elem(&1, 1).rail_key)
    expected_b = session_b |> Enum.reverse() |> Enum.take(12) |> Enum.map(&elem(&1, 1).rail_key)

    recents_a = Session.recent_foregrounds(newest_a)
    recents_b = Session.recent_foregrounds(newest_b)

    assert length(recents_a) == 12
    assert length(recents_b) == 12
    assert Enum.map(recents_a, & &1.rail_key) == expected_a
    assert Enum.map(recents_b, & &1.rail_key) == expected_b

    expected_global_order =
      live_rails
      |> Enum.reverse()
      |> Enum.flat_map(fn {{_live_a, ws_a}, {_live_b, ws_b}} ->
        [ws_b.rail_key, ws_a.rail_key]
      end)

    state = path |> Session.whereis() |> :sys.get_state()
    assert state.foreground_order == expected_global_order
  end

  test "capped old rail reattach and select preserve history while the selected rail still routes",
       %{path: root} do
    path = Path.join(root, "bounded-recents")
    File.mkdir_p!(path)
    live_session_id = "bounded-recents-session"

    live_rails =
      Enum.map(1..13, fn index ->
        live = start_live_process()

        settings = [
          live_session_id: live_session_id,
          chat_rail_id: "bounded-tab-#{index}",
          provider: "codex",
          adapter_opts: [
            exmcp_adapter: EcritsWeb.FakeAcpAdapter,
            script: [{:text_delta, "reply #{index}"}]
          ],
          workspace_root: path
        ]

        {:ok, ws} = attach_from(live, path, settings)
        {live, ws, settings}
      end)

    rails = Enum.map(live_rails, &elem(&1, 1))
    expected_order = rails |> Enum.reverse() |> Enum.map(& &1.rail_key)
    session_pid = Session.whereis(path)

    assert :sys.get_state(session_pid).foreground_order == expected_order

    # Recreate the previous buggy persisted shape: the rail still exists in the
    # durable foreground map, but the global order discarded the oldest entry.
    :sys.replace_state(session_pid, fn state ->
      %{state | foreground_order: Enum.take(expected_order, 12)}
    end)

    [{oldest_live, oldest_ws, oldest_settings} | _] = live_rails
    {:ok, reattached_ws} = attach_from(oldest_live, path, oldest_settings)

    assert reattached_ws.agent_id == oldest_ws.agent_id
    assert reattached_ws.rail_key == oldest_ws.rail_key
    assert :sys.get_state(session_pid).foreground_order == expected_order

    expected_selected_order = Enum.take(expected_order, 11) ++ [oldest_ws.rail_key]
    oldest_recents = Session.recent_foregrounds(reattached_ws)
    assert length(oldest_recents) == 12
    assert Enum.map(oldest_recents, & &1.rail_key) == expected_selected_order
    refute hd(oldest_recents).rail_key == oldest_ws.rail_key
    assert List.last(oldest_recents).active?

    {newest_live, _newest_ws, newest_settings} = List.last(live_rails)

    assert {:ok, selected_ws} =
             call_from(newest_live, fn ->
               Session.select_foreground(path, oldest_ws.rail_key, newest_settings)
             end)

    assert selected_ws.agent_id == oldest_ws.agent_id
    assert :sys.get_state(session_pid).foreground_order == expected_order

    assert Enum.map(Session.recent_foregrounds(selected_ws), & &1.rail_key) ==
             expected_selected_order

    Session.subscribe_agent(oldest_ws.agent_id)

    assert {:ok, %{id: turn_id}} =
             call_from(newest_live, fn ->
               Session.send_turn(selected_ws, "oldest selected rail still routes")
             end)

    assert_receive {:agent_event,
                    %{type: :turn_completed, turn_id: ^turn_id, session_id: oldest_agent_id}},
                   2_000

    assert oldest_agent_id == oldest_ws.agent_id

    assert [%{user: "oldest selected rail still routes"}] =
             AcpAgent.agent_snapshot(oldest_ws.agent_id).transcript
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

    refreshed_ws = path |> Session.new_foreground(settings) |> await_foreground_transition()

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
        live_process_loop(nil)
      end)

    on_exit(fn -> stop_live_process(pid) end)
    pid
  end

  defp live_process_loop(last_rebind) do
    receive do
      {:attach, caller, ref, path, settings} ->
        send(caller, {ref, Session.attach(path, settings)})
        live_process_loop(last_rebind)

      {:call, caller, ref, fun} when is_function(fun, 0) ->
        send(caller, {ref, fun.()})
        live_process_loop(last_rebind)

      {:workspace_foreground_rebound, ws} ->
        live_process_loop(ws)

      {:last_rebind, caller, ref} ->
        send(caller, {ref, last_rebind})
        live_process_loop(last_rebind)

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

  defp call_from(pid, fun) when is_pid(pid) and is_function(fun, 0) do
    ref = make_ref()
    send(pid, {:call, self(), ref, fun})
    assert_receive {^ref, result}, 2_000
    result
  end

  defp last_rebind(pid) when is_pid(pid) do
    ref = make_ref()
    send(pid, {:last_rebind, self(), ref})
    assert_receive {^ref, ws}, 1_000
    ws
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

  defp await_workspace_state(session_pid, predicate, attempts \\ 200)

  defp await_workspace_state(session_pid, predicate, attempts) when attempts > 0 do
    state = :sys.get_state(session_pid)

    if predicate.(state) do
      state
    else
      receive do
      after
        10 -> await_workspace_state(session_pid, predicate, attempts - 1)
      end
    end
  end

  defp await_workspace_state(_session_pid, _predicate, 0) do
    flunk("workspace session did not reach the expected restart-fence state")
  end

  defp await_agent_state(agent_pid, predicate, attempts \\ 200)

  defp await_agent_state(agent_pid, predicate, attempts) when attempts > 0 do
    state = :sys.get_state(agent_pid)

    if predicate.(state) do
      state
    else
      receive do
      after
        10 -> await_agent_state(agent_pid, predicate, attempts - 1)
      end
    end
  end

  defp await_agent_state(_agent_pid, _predicate, 0) do
    flunk("agent did not reach the expected terminal-fence state")
  end

  defp successful_finalizer_result do
    %{
      saved: [],
      failed: [],
      staged: %{committed: [], pending: []},
      canonical: %{published: [], pending: []}
    }
  end

  defp await_foreground_transition({:ok, ws}), do: ws

  defp await_foreground_transition({:pending, pending_ws}) do
    expected_path = pending_ws.path
    expected_agent_id = pending_ws.agent_id
    expected_rail_key = pending_ws.rail_key

    assert_receive {:workspace_foreground_rebound,
                    %{
                      path: ^expected_path,
                      agent_id: ^expected_agent_id,
                      rail_key: ^expected_rail_key
                    } = ws},
                   2_000

    ws
  end

  defp await_live_foreground_transition({:ok, ws}, _live_pid), do: ws

  defp await_live_foreground_transition({:pending, pending_ws}, live_pid) do
    await_live_foreground_rebind(live_pid, pending_ws, 200)
  end

  defp await_live_foreground_rebind(live_pid, pending_ws, attempts) when attempts > 0 do
    case last_rebind(live_pid) do
      %{agent_id: agent_id, rail_key: rail_key} = ws
      when agent_id == pending_ws.agent_id and rail_key == pending_ws.rail_key ->
        ws

      _other ->
        receive do
        after
          10 -> await_live_foreground_rebind(live_pid, pending_ws, attempts - 1)
        end
    end
  end

  defp await_live_foreground_rebind(_live_pid, _pending_ws, 0) do
    flunk("live process did not receive the pending foreground rebound")
  end
end
