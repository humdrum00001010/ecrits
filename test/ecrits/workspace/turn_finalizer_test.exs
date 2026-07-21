defmodule Ecrits.Workspace.TurnFinalizerTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Projection
  alias Ecrits.Fuse.DocFs
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs
  alias Ecrits.Test.FakeEhwpRuntime
  alias Ecrits.Workspace.Session
  alias Ecrits.Workspace.TurnFinalizer

  setup do
    previous_runtime = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)

    base =
      Path.join(
        System.tmp_dir!(),
        "ecrits_turn_finalizer_#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(base, "workspace")
    other_workspace = Path.join(base, "other")
    File.mkdir_p!(workspace)
    File.mkdir_p!(other_workspace)

    on_exit(fn ->
      if previous_runtime do
        Application.put_env(:ehwp, :runtime, previous_runtime)
      else
        Application.delete_env(:ehwp, :runtime)
      end

      File.rm_rf(base)
    end)

    {:ok, workspace: workspace, other_workspace: other_workspace}
  end

  test "persists and flushes only the terminal turn's workspace", %{
    workspace: workspace,
    other_workspace: other_workspace
  } do
    path = Path.join(workspace, "pending.hwp")
    other_path = Path.join(other_workspace, "unrelated.hwp")

    {:ok, document_id} =
      Pool.open(path, kind: :hwp, open_opts: [__text__: "PENDING contract"])

    {:ok, other_document_id} =
      Pool.open(other_path, kind: :hwp, open_opts: [__text__: "OTHER contract"])

    on_exit(fn ->
      Pool.close(document_id)
      Pool.close(other_document_id)
    end)

    assert {:server, editor} = Pool.route(document_id)
    assert {:server, other_editor} = Pool.route(other_document_id)

    assert {:ok, _result} =
             Editor.apply(editor, %{
               op: "replace_text",
               query: "PENDING",
               replacement: "SAVED"
             })

    assert {:ok, _result} =
             Editor.apply(other_editor, %{
               op: "replace_text",
               query: "OTHER",
               replacement: "UNRELATED"
             })

    assert %{
             saved: [^path],
             failed: [],
             staged: %{committed: [], pending: []}
           } = TurnFinalizer.run(workspace)

    assert File.read!(path) == "SAVED contract"
    refute File.exists?(other_path)
    refute Editor.dirty?(editor)
    assert Editor.dirty?(other_editor)

    assert %{saved: [], failed: [], staged: %{committed: [], pending: []}} =
             TurnFinalizer.run(workspace)
  end

  test "terminal finalizer saves before publishing its owner canonical bytes", %{
    workspace: workspace
  } do
    owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
    name = "terminal-canonical.hwp"
    path = Path.join(workspace, name)

    {:ok, document_id} =
      Pool.open(path, kind: :hwp, open_opts: [__text__: "BEFORE"])

    OpenDocs.open(workspace, name,
      agent_id: owner.agent_id,
      instance_id: owner.instance_id,
      turn_id: owner.turn_id,
      source_path: path
    )

    on_exit(fn ->
      Pool.close(document_id)
      OpenDocs.close(workspace, name)
    end)

    assert {:server, editor} = Pool.route(document_id)

    assert {:ok, _result} =
             Editor.apply(
               editor,
               %{op: "replace_text", query: "BEFORE", replacement: "AFTER"},
               owner: owner
             )

    accepted = ~s({"text":"accepted raw"}\n)
    canonical = ~s({"text":"canonical after save"}\n)

    OpenDocs.accept_projection(
      workspace,
      name,
      accepted,
      canonical,
      Map.put(owner, :source_path, path)
    )

    refute File.exists?(path)
    assert {:ok, ^accepted} = OpenDocs.committed(workspace, name)

    assert {:ok, %{accepted_bytes: ^accepted, bytes: ^canonical}} =
             OpenDocs.pending_canonical(workspace, name)

    test_pid = self()
    canonical_root = DocMount.canonical_root(workspace)

    echo_fun = fn root, temp, target, bytes ->
      assert root == canonical_root
      assert target == Projection.projected_name(name)
      assert bytes == canonical
      assert File.read!(path) == "AFTER"
      send(test_pid, :canonical_echo_after_native_save)
      OpenDocs.complete_canonical_echo(root, temp, name, bytes)
    end

    assert %{
             saved: [^path],
             failed: [],
             staged: %{committed: [], pending: []},
             canonical: %{published: [^name], pending: []}
           } =
             TurnFinalizer.run(workspace,
               agent_id: owner.agent_id,
               instance_id: owner.instance_id,
               turn_id: owner.turn_id,
               mounted?: true,
               echo_fun: echo_fun
             )

    assert_receive :canonical_echo_after_native_save
    assert File.read!(path) == "AFTER"
    assert {:ok, ^canonical} = OpenDocs.committed(workspace, name)
    assert OpenDocs.pending_canonical(workspace, name) == :error
    refute Editor.dirty?(editor)
  end

  test "a scoped terminal saves only documents last written by that exact turn", %{
    workspace: workspace
  } do
    owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
    other_owner = %{agent_id: "agent-b", instance_id: "instance-b", turn_id: "turn-b"}
    owned_path = Path.join(workspace, "owned.hwp")
    other_path = Path.join(workspace, "other-agent.hwp")
    human_path = Path.join(workspace, "human.hwp")

    {:ok, owned_id} = Pool.open(owned_path, kind: :hwp, open_opts: [__text__: "OWNED"])
    {:ok, other_id} = Pool.open(other_path, kind: :hwp, open_opts: [__text__: "OTHER"])
    {:ok, human_id} = Pool.open(human_path, kind: :hwp, open_opts: [__text__: "HUMAN"])

    on_exit(fn ->
      Pool.close(owned_id)
      Pool.close(other_id)
      Pool.close(human_id)
    end)

    assert {:server, owned_editor} = Pool.route(owned_id)
    assert {:server, other_editor} = Pool.route(other_id)
    assert {:server, human_editor} = Pool.route(human_id)

    assert {:ok, _} =
             Editor.apply(
               owned_editor,
               %{op: "replace_text", query: "OWNED", replacement: "SAVED_A"},
               owner: owner
             )

    assert {:ok, _} =
             Editor.apply(
               other_editor,
               %{op: "replace_text", query: "OTHER", replacement: "UNSAVED_B"},
               owner: other_owner
             )

    assert {:ok, _} =
             Editor.apply(human_editor, %{
               op: "replace_text",
               query: "HUMAN",
               replacement: "UNSAVED_HUMAN"
             })

    assert %{
             saved: [^owned_path],
             failed: [],
             staged: %{committed: [], pending: []}
           } =
             TurnFinalizer.run(workspace,
               agent_id: owner.agent_id,
               instance_id: owner.instance_id,
               turn_id: owner.turn_id
             )

    assert File.read!(owned_path) == "SAVED_A"
    refute File.exists?(other_path)
    refute File.exists?(human_path)
    refute Editor.dirty?(owned_editor)
    assert Editor.dirty?(other_editor)
    assert Editor.dirty?(human_editor)
  end

  test "a scoped terminal refuses a same-document mix of human and agent writes", %{
    workspace: workspace
  } do
    owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
    path = Path.join(workspace, "mixed.hwp")
    {:ok, document_id} = Pool.open(path, kind: :hwp, open_opts: [__text__: "HUMAN AGENT"])
    on_exit(fn -> Pool.close(document_id) end)
    assert {:server, editor} = Pool.route(document_id)

    assert {:ok, _} =
             Editor.apply(editor, %{
               op: "replace_text",
               query: "HUMAN",
               replacement: "HUMAN_DIRTY"
             })

    assert {:ok, _} =
             Editor.apply(
               editor,
               %{op: "replace_text", query: "AGENT", replacement: "AGENT_DIRTY"},
               owner: owner
             )

    assert %{
             saved: [],
             failed: [{^path, :mixed_unsaved_writers}],
             staged: %{committed: [], pending: []},
             canonical: %{published: [], pending: []}
           } =
             TurnFinalizer.run(workspace,
               agent_id: owner.agent_id,
               instance_id: owner.instance_id,
               turn_id: owner.turn_id
             )

    refute File.exists?(path)
    assert Editor.dirty?(editor)
  end

  test "native save failure keeps that document's canonical projection pending", %{
    workspace: workspace
  } do
    owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
    name = "mixed-with-canonical.hwp"
    path = Path.join(workspace, name)
    {:ok, document_id} = Pool.open(path, kind: :hwp, open_opts: [__text__: "HUMAN AGENT"])

    OpenDocs.open(workspace, name,
      agent_id: owner.agent_id,
      instance_id: owner.instance_id,
      turn_id: owner.turn_id,
      source_path: path
    )

    on_exit(fn ->
      Pool.close(document_id)
      OpenDocs.close(workspace, name)
    end)

    assert {:server, editor} = Pool.route(document_id)

    assert {:ok, _} =
             Editor.apply(editor, %{
               op: "replace_text",
               query: "HUMAN",
               replacement: "HUMAN_DIRTY"
             })

    assert {:ok, _} =
             Editor.apply(
               editor,
               %{op: "replace_text", query: "AGENT", replacement: "AGENT_DIRTY"},
               owner: owner
             )

    OpenDocs.accept_projection(
      workspace,
      name,
      "accepted-raw",
      "canonical-engine-state",
      Map.put(owner, :source_path, path)
    )

    assert {:ok, pending_before} = OpenDocs.pending_canonical(workspace, name)

    assert %{
             saved: [],
             failed: [{^path, :mixed_unsaved_writers}],
             canonical: %{
               published: [],
               pending: [{^name, {:native_save_failed, :mixed_unsaved_writers}}]
             }
           } =
             TurnFinalizer.run(workspace,
               agent_id: owner.agent_id,
               instance_id: owner.instance_id,
               turn_id: owner.turn_id,
               mounted?: false
             )

    assert {:ok, ^pending_before} = OpenDocs.pending_canonical(workspace, name)
    refute File.exists?(path)
    assert Editor.dirty?(editor)
  end

  test "a partial terminal identity fails closed without saving", %{workspace: workspace} do
    path = Path.join(workspace, "partial.hwp")
    {:ok, document_id} = Pool.open(path, kind: :hwp, open_opts: [__text__: "PARTIAL"])
    on_exit(fn -> Pool.close(document_id) end)
    assert {:server, editor} = Pool.route(document_id)

    assert {:ok, _} =
             Editor.apply(editor, %{
               op: "replace_text",
               query: "PARTIAL",
               replacement: "MUST_NOT_SAVE"
             })

    assert %{
             saved: [],
             failed: [{^workspace, :incomplete_turn_identity}],
             staged: %{committed: [], pending: []},
             canonical: %{published: [], pending: []}
           } = TurnFinalizer.run(workspace, agent_id: "agent-a")

    refute File.exists?(path)
    assert Editor.dirty?(editor)
  end

  test "terminal saves preserve every supported document format" do
    for kind <- [:hwp, :hwpx, :docx, :pptx, :xlsx] do
      assert TurnFinalizer.__save_format_for_test__(kind) == kind
    end
  end

  test "Session serializes distinct terminals and retains bounded summaries only", %{
    workspace: workspace
  } do
    {:ok, ws} =
      Session.attach(workspace,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "done"}]
        ],
        workspace_root: workspace
      )

    session_pid = Session.whereis(workspace)
    pool_pid = Process.whereis(Pool)
    instance_id = Session.snapshot(ws).instance_id
    assert is_pid(session_pid)
    assert is_pid(pool_pid)
    :ok = Session.subscribe_file_events(workspace)

    on_exit(fn ->
      if Process.alive?(session_pid) do
        DynamicSupervisor.terminate_child(Ecrits.Workspace.SessionSupervisor, session_pid)
      end
    end)

    :ok = :sys.suspend(pool_pid)

    try do
      assert {:ok, :started} =
               Session.finalize_turn(ws, "terminal-a", instance_id: instance_id)

      assert {:ok, :running} =
               Session.finalize_turn(ws, "terminal-a", instance_id: instance_id)

      assert {:ok, :queued} =
               Session.finalize_turn(ws, "terminal-b", instance_id: instance_id)

      state = :sys.get_state(session_pid)

      assert %{
               key: {agent_id, ^instance_id, "terminal-a"},
               pid: active_pid,
               ref: active_ref
             } = state.turn_finalization_active

      assert agent_id == ws.agent_id
      assert is_pid(active_pid)
      assert is_reference(active_ref)
      assert state.turn_finalization_queue == [{ws.agent_id, instance_id, "terminal-b"}]

      assert %{status: :running} =
               state.turn_finalizations[{ws.agent_id, instance_id, "terminal-a"}]

      assert %{status: :queued} =
               state.turn_finalizations[{ws.agent_id, instance_id, "terminal-b"}]
    after
      :ok = :sys.resume(pool_pid)
    end

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: agent_id,
                      instance_id: ^instance_id,
                      turn_id: "terminal-a",
                      summary: summary_a
                    }},
                   2_000

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: ^agent_id,
                      instance_id: ^instance_id,
                      turn_id: "terminal-b",
                      summary: summary_b
                    }},
                   2_000

    assert agent_id == ws.agent_id
    assert summary_a.successful?
    assert summary_b.successful?

    state = :sys.get_state(session_pid)
    assert state.turn_finalization_active == nil
    assert state.turn_finalization_queue == []

    assert %{status: :completed, summary: ^summary_a} =
             state.turn_finalizations[{agent_id, instance_id, "terminal-a"}]

    assert %{status: :completed, summary: ^summary_b} =
             state.turn_finalizations[{agent_id, instance_id, "terminal-b"}]

    refute Map.has_key?(state.turn_finalizations[{agent_id, instance_id, "terminal-a"}], :result)
    refute Map.has_key?(state.turn_finalizations[{agent_id, instance_id, "terminal-b"}], :result)

    assert {:ok, {:completed, ^summary_a}} =
             Session.finalize_turn(ws, "terminal-a", instance_id: instance_id)

    assert {:ok, {:completed, ^summary_b}} =
             Session.finalize_turn(ws, "terminal-b", instance_id: instance_id)

    assert {:error, :unknown_agent} =
             Session.finalize_turn(%{ws | agent_id: "unknown-agent"}, "terminal-c",
               instance_id: instance_id
             )

    refute_receive {:workspace_turn_finalized, %{agent_id: ^agent_id}}, 100
  end

  test "Session retries an uncatchably killed finalizer before completing the turn", %{
    workspace: workspace
  } do
    {:ok, ws} =
      Session.attach(workspace,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "done"}]
        ],
        workspace_root: workspace
      )

    session_pid = Session.whereis(workspace)
    pool_pid = Process.whereis(Pool)
    instance_id = Session.snapshot(ws).instance_id
    agent_id = ws.agent_id
    :ok = Session.subscribe_file_events(workspace)

    on_exit(fn ->
      if Process.alive?(session_pid) do
        DynamicSupervisor.terminate_child(Ecrits.Workspace.SessionSupervisor, session_pid)
      end
    end)

    :ok = :sys.suspend(pool_pid)

    try do
      assert {:ok, :started} =
               Session.finalize_turn(ws, "retry-killed", instance_id: instance_id)

      assert %{turn_finalization_active: %{pid: first_pid, attempts: 1}} =
               :sys.get_state(session_pid)

      monitor_ref = Process.monitor(first_pid)
      Process.exit(first_pid, :kill)
      assert_receive {:DOWN, ^monitor_ref, :process, ^first_pid, :killed}

      assert %{
               turn_finalization_active: %{pid: second_pid, attempts: 2},
               turn_finalizations: %{
                 {^agent_id, ^instance_id, "retry-killed"} => %{
                   status: :running,
                   attempts: 2
                 }
               }
             } = await_retried_finalizer(session_pid, first_pid)

      refute second_pid == first_pid
    after
      :ok = :sys.resume(pool_pid)
    end

    assert_receive {:workspace_turn_finalized,
                    %{
                      instance_id: ^instance_id,
                      turn_id: "retry-killed",
                      summary: %{successful?: true}
                    }},
                   2_000

    refute_receive {:workspace_turn_finalized, %{turn_id: "retry-killed"}}, 100
  end

  test "Session keeps an unsuccessful result fenced until a later attempt succeeds", %{
    workspace: workspace
  } do
    {:ok, ws} =
      Session.attach(workspace,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "done"}]
        ],
        workspace_root: workspace
      )

    session_pid = Session.whereis(workspace)
    pool_pid = Process.whereis(Pool)
    instance_id = Session.snapshot(ws).instance_id
    agent_id = ws.agent_id
    key = {agent_id, instance_id, "retry-result"}
    :ok = Session.subscribe_file_events(workspace)

    failed_result = %{
      saved: [],
      failed: [{workspace, :transient_failure}],
      staged: %{committed: [], pending: []},
      canonical: %{published: [], pending: []}
    }

    pending_result = %{
      saved: [],
      failed: [],
      staged: %{committed: [], pending: [{"contract.hwp", :temporarily_busy}]},
      canonical: %{published: [], pending: [{"contract.hwp", :echo_pending}]}
    }

    successful_result = %{
      saved: [],
      failed: [],
      staged: %{committed: [], pending: []},
      canonical: %{published: [], pending: []}
    }

    :ok = :sys.suspend(pool_pid)

    try do
      assert {:ok, :started} =
               Session.finalize_turn(ws, "retry-result", instance_id: instance_id)

      assert %{turn_finalization_active: %{pid: first_pid, attempts: 1}} =
               :sys.get_state(session_pid)

      send(
        session_pid,
        {:workspace_turn_finalization_finished, key, first_pid, failed_result}
      )

      assert %{
               turn_finalization_active: %{pid: second_pid, attempts: 2},
               turn_finalizations: %{
                 ^key => %{status: :running, attempts: 2}
               }
             } = await_retried_finalizer(session_pid, first_pid)

      refute second_pid == first_pid
      refute_receive {:workspace_turn_finalized, %{turn_id: "retry-result"}}, 100

      send(
        session_pid,
        {:workspace_turn_finalization_finished, key, second_pid, pending_result}
      )

      assert %{
               turn_finalization_active: nil,
               turn_finalizations: %{
                 ^key => %{
                   status: :queued,
                   attempts: 2,
                   retry_token: retry_token
                 }
               }
             } = :sys.get_state(session_pid)

      assert is_reference(retry_token)

      assert {:ok, :queued} =
               Session.finalize_turn(ws, "retry-result", instance_id: instance_id)

      refute_receive {:workspace_turn_finalized, %{turn_id: "retry-result"}}, 20

      send(session_pid, {:retry_workspace_turn_finalization, key, retry_token})

      assert %{
               turn_finalization_active: %{pid: third_pid, attempts: 3},
               turn_finalizations: %{
                 ^key => %{status: :running, attempts: 3}
               }
             } = await_retried_finalizer(session_pid, second_pid, 3)

      send(
        session_pid,
        {:workspace_turn_finalization_finished, key, third_pid, successful_result}
      )

      assert_receive {:workspace_turn_finalized,
                      %{
                        agent_id: ^agent_id,
                        instance_id: ^instance_id,
                        turn_id: "retry-result",
                        summary: %{successful?: true}
                      }},
                     2_000

      assert %{
               turn_finalization_active: nil,
               turn_finalizations: %{
                 ^key => %{status: :completed, summary: %{successful?: true}}
               }
             } = :sys.get_state(session_pid)
    after
      :ok = :sys.resume(pool_pid)
    end

    refute_receive {:workspace_turn_finalized, %{turn_id: "retry-result"}}, 100
  end

  test "Session discards unsafe legacy pair-key finalization state on hot reload", %{
    workspace: workspace
  } do
    {:ok, ws} =
      Session.attach(workspace,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "done"}]
        ],
        workspace_root: workspace
      )

    session_pid = Session.whereis(workspace)
    pool_pid = Process.whereis(Pool)
    instance_id = Session.snapshot(ws).instance_id
    agent_id = ws.agent_id
    :ok = Session.subscribe_file_events(workspace)
    legacy_key = {agent_id, "legacy-turn"}
    new_key = {agent_id, instance_id, "post-upgrade-turn"}

    legacy_worker =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    legacy_monitor = Process.monitor(legacy_worker)

    :sys.replace_state(session_pid, fn state ->
      state
      |> Map.put(:turn_finalizations, %{legacy_key => %{status: :running, attempts: 1}})
      |> Map.put(:turn_finalization_order, [legacy_key])
      |> Map.put(:turn_finalization_queue, [legacy_key])
      |> Map.put(:turn_finalization_waiters, %{legacy_key => MapSet.new([self()])})
      |> Map.put(:turn_finalization_active, %{
        key: legacy_key,
        pid: legacy_worker,
        ref: make_ref(),
        attempts: 1
      })
    end)

    :ok = :sys.suspend(pool_pid)

    try do
      assert {:ok, :started} =
               Session.finalize_turn(ws, "post-upgrade-turn", instance_id: instance_id)

      assert_receive {:DOWN, ^legacy_monitor, :process, ^legacy_worker, :killed}, 2_000

      state = :sys.get_state(session_pid)
      refute Map.has_key?(state.turn_finalizations, legacy_key)
      refute Map.has_key?(state.turn_finalization_waiters, legacy_key)
      refute legacy_key in state.turn_finalization_order
      refute legacy_key in state.turn_finalization_queue
      assert %{key: ^new_key, attempts: 1} = state.turn_finalization_active
    after
      :ok = :sys.resume(pool_pid)
    end

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: ^agent_id,
                      instance_id: ^instance_id,
                      turn_id: "post-upgrade-turn",
                      summary: %{successful?: true}
                    }},
                   2_000
  end

  defp await_retried_finalizer(
         session_pid,
         previous_pid,
         expected_attempts \\ 2,
         remaining \\ 50
       )

  defp await_retried_finalizer(_session_pid, _previous_pid, _expected_attempts, 0),
    do: flunk("workspace session did not start the finalizer retry")

  defp await_retried_finalizer(session_pid, previous_pid, expected_attempts, remaining) do
    state = :sys.get_state(session_pid)

    case state.turn_finalization_active do
      %{pid: pid, attempts: ^expected_attempts} when pid != previous_pid ->
        state

      _other ->
        receive do
        after
          5 ->
            await_retried_finalizer(
              session_pid,
              previous_pid,
              expected_attempts,
              remaining - 1
            )
        end
    end
  end

  test "dirty-doc enumeration failure is recorded instead of reported successful", %{
    workspace: workspace
  } do
    assert %{
             saved: [],
             failed: [{^workspace, {:dirty_docs_exit, _reason}}],
             staged: %{committed: [], pending: []}
           } = TurnFinalizer.run(workspace, pool: :missing_turn_finalizer_pool)
  end

  test "terminal finalizer handles an exact invalid staged buffer without retrying it", %{
    workspace: workspace
  } do
    path = Path.join(workspace, "invalid-staged-contract.hwp")
    File.write!(path, "fixture")

    owner = %{
      agent_id: "invalid-stage-agent",
      instance_id: "invalid-stage-instance",
      turn_id: "invalid-stage-turn"
    }

    OpenDocs.open(workspace, "invalid-staged-contract.hwp",
      agent_id: owner.agent_id,
      instance_id: owner.instance_id,
      turn_id: owner.turn_id
    )

    on_exit(fn ->
      Pool.close_by_path(path)
      OpenDocs.close(workspace, "invalid-staged-contract.hwp")
    end)

    Phoenix.PubSub.subscribe(
      Ecrits.PubSub,
      "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(workspace)
    )

    OpenDocs.stage(
      workspace,
      "invalid-staged-contract.hwp",
      "[",
      {:invalid_ir_json, "["},
      Map.put(owner, :edit_id, "invalid-stage-edit")
    )

    assert %{
             staged: %{committed: [], rejected: [], pending: []}
           } =
             TurnFinalizer.run(workspace,
               agent_id: owner.agent_id,
               instance_id: owner.instance_id,
               turn_id: "stale-terminal-turn"
             )

    assert {:ok, "[", {:invalid_ir_json, "["}} =
             OpenDocs.staged(workspace, "invalid-staged-contract.hwp")

    refute_receive {:vfs_doc_edited, %{phase: :rejected}}, 20

    assert %{
             saved: [],
             failed: [],
             staged: %{
               committed: [],
               rejected: [
                 {"invalid-staged-contract.hwp", {:invalid_ir_json, "["}}
               ],
               pending: []
             },
             canonical: %{published: [], pending: []}
           } =
             TurnFinalizer.run(workspace,
               agent_id: owner.agent_id,
               instance_id: owner.instance_id,
               turn_id: owner.turn_id
             )

    assert OpenDocs.staged(workspace, "invalid-staged-contract.hwp") == :error

    assert_receive {:vfs_doc_edited,
                    %{
                      phase: :rejected,
                      doc: "invalid-staged-contract.hwp",
                      edit_id: "invalid-stage-edit",
                      agent_id: "invalid-stage-agent",
                      instance_id: "invalid-stage-instance",
                      turn_id: "invalid-stage-turn"
                    }}
  end

  test "successful staged flush preserves a newer same-owner generation and keeps it pending", %{
    workspace: workspace
  } do
    owner = %{
      agent_id: "stale-success-agent",
      instance_id: "stale-success-instance",
      turn_id: "stale-success-turn"
    }

    doc = open_staged_test_doc(workspace, "stale-success.hwp", owner)

    {edited_projection, true} =
      replace_first_projected_text(doc.projection, "STALE_SUCCESS_APPLIED")

    OpenDocs.stage(
      workspace,
      doc.name,
      edited_projection,
      :structural_change,
      Map.put(owner, :edit_id, "stale-success-old-edit")
    )

    assert [{_, _, _, old_identity}] = OpenDocs.staged_with_identity(workspace)

    :ok = :sys.suspend(doc.editor)
    on_exit(fn -> resume_if_alive(doc.editor) end)

    flush =
      Task.async(fn ->
        DocFs.flush_staged(workspace,
          agent_id: owner.agent_id,
          instance_id: owner.instance_id,
          turn_id: owner.turn_id
        )
      end)

    await_suspended_editor_call(doc.editor)

    OpenDocs.stage(
      workspace,
      doc.name,
      "[",
      {:invalid_ir_json, "["},
      Map.put(owner, :edit_id, "stale-success-new-edit")
    )

    assert [{_, "[", {:invalid_ir_json, "["}, new_identity}] =
             OpenDocs.staged_with_identity(workspace)

    assert new_identity.stage_generation > old_identity.stage_generation
    :ok = :sys.resume(doc.editor)

    assert %{
             committed: ["stale-success.hwp"],
             rejected: [],
             pending: [
               {"stale-success.hwp", {:staged_replaced, :accepted_write}}
             ]
           } = Task.await(flush, 2_000)

    assert [{"stale-success.hwp", "[", {:invalid_ir_json, "["}, ^new_identity}] =
             OpenDocs.staged_with_identity(workspace)
  end

  test "invalid stale flush preserves a new owner and rejects the old exact preview", %{
    workspace: workspace
  } do
    old_owner = %{
      agent_id: "stale-reject-old-agent",
      instance_id: "stale-reject-old-instance",
      turn_id: "stale-reject-old-turn"
    }

    new_owner = %{
      agent_id: "stale-reject-new-agent",
      instance_id: "stale-reject-new-instance",
      turn_id: "stale-reject-new-turn"
    }

    doc = open_staged_test_doc(workspace, "stale-reject.hwp", old_owner)

    Phoenix.PubSub.subscribe(
      Ecrits.PubSub,
      "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(workspace)
    )

    OpenDocs.stage(
      workspace,
      doc.name,
      "[",
      {:invalid_ir_json, "["},
      Map.put(old_owner, :edit_id, "stale-reject-old-edit")
    )

    assert [{_, _, _, old_identity}] = OpenDocs.staged_with_identity(workspace)

    :ok = :sys.suspend(doc.editor)
    on_exit(fn -> resume_if_alive(doc.editor) end)

    flush =
      Task.async(fn ->
        DocFs.flush_staged(workspace,
          agent_id: old_owner.agent_id,
          instance_id: old_owner.instance_id,
          turn_id: old_owner.turn_id
        )
      end)

    await_suspended_editor_call(doc.editor)

    OpenDocs.stage(
      workspace,
      doc.name,
      "{",
      {:invalid_ir_json, "{"},
      Map.put(new_owner, :edit_id, "stale-reject-new-edit")
    )

    assert [{_, "{", {:invalid_ir_json, "{"}, new_identity}] =
             OpenDocs.staged_with_identity(workspace)

    assert new_identity.stage_generation > old_identity.stage_generation
    :ok = :sys.resume(doc.editor)

    assert %{
             committed: [],
             rejected: [
               {"stale-reject.hwp", {:invalid_ir_json, "["}}
             ],
             pending: []
           } = Task.await(flush, 2_000)

    assert [{"stale-reject.hwp", "{", {:invalid_ir_json, "{"}, ^new_identity}] =
             OpenDocs.staged_with_identity(workspace)

    assert_receive {:vfs_doc_edited,
                    %{
                      phase: :rejected,
                      doc: "stale-reject.hwp",
                      edit_id: "stale-reject-old-edit",
                      agent_id: "stale-reject-old-agent",
                      instance_id: "stale-reject-old-instance",
                      turn_id: "stale-reject-old-turn"
                    }}

    refute_receive {:vfs_doc_edited, %{phase: :rejected}}, 20
  end

  test "successful settlement keeps a same-owner stage queued after exact removal pending", %{
    workspace: workspace
  } do
    owner = %{
      agent_id: "post-remove-success-agent",
      instance_id: "post-remove-success-instance",
      turn_id: "post-remove-success-turn"
    }

    doc = open_staged_test_doc(workspace, "post-remove-success.hwp", owner)

    {edited_projection, true} =
      replace_first_projected_text(doc.projection, "POST_REMOVE_SUCCESS_APPLIED")

    OpenDocs.stage(
      workspace,
      doc.name,
      edited_projection,
      :structural_change,
      Map.put(owner, :edit_id, "post-remove-success-old-edit")
    )

    {open_docs, hook_ref} = install_staged_settlement_hook()

    flush =
      Task.async(fn ->
        DocFs.flush_staged(workspace,
          agent_id: owner.agent_id,
          instance_id: owner.instance_id,
          turn_id: owner.turn_id
        )
      end)

    canonical_root = DocMount.canonical_root(workspace)

    assert_receive {:staged_settlement_removed, ^hook_ref, ^canonical_root,
                    "post-remove-success.hwp"},
                   2_000

    replacement =
      Task.async(fn ->
        OpenDocs.stage(
          workspace,
          doc.name,
          "[",
          {:invalid_ir_json, "["},
          Map.put(owner, :edit_id, "post-remove-success-new-edit")
        )
      end)

    await_open_docs_stage_call(replacement.pid, workspace, doc.name)
    send(open_docs, {:continue_staged_settlement, hook_ref})

    assert :ok = Task.await(replacement, 2_000)

    assert %{
             committed: ["post-remove-success.hwp"],
             rejected: [],
             pending: [
               {"post-remove-success.hwp", {:staged_replaced, :accepted_write}}
             ]
           } = Task.await(flush, 2_000)

    assert {:ok, ^edited_projection} = OpenDocs.committed(workspace, doc.name)

    assert [{"post-remove-success.hwp", "[", {:invalid_ir_json, "["}, new_identity}] =
             OpenDocs.staged_with_identity(workspace)

    assert new_identity.edit_id == "post-remove-success-new-edit"
  end

  test "invalid settlement keeps a different-owner stage queued after exact removal", %{
    workspace: workspace
  } do
    old_owner = %{
      agent_id: "post-remove-reject-old-agent",
      instance_id: "post-remove-reject-old-instance",
      turn_id: "post-remove-reject-old-turn"
    }

    new_owner = %{
      agent_id: "post-remove-reject-new-agent",
      instance_id: "post-remove-reject-new-instance",
      turn_id: "post-remove-reject-new-turn"
    }

    doc = open_staged_test_doc(workspace, "post-remove-reject.hwp", old_owner)

    Phoenix.PubSub.subscribe(
      Ecrits.PubSub,
      "doc_vfs:" <> DocMount.canonical_root(workspace)
    )

    OpenDocs.stage(
      workspace,
      doc.name,
      "[",
      {:invalid_ir_json, "["},
      Map.put(old_owner, :edit_id, "post-remove-reject-old-edit")
    )

    {open_docs, hook_ref} = install_staged_settlement_hook()

    flush =
      Task.async(fn ->
        DocFs.flush_staged(workspace,
          agent_id: old_owner.agent_id,
          instance_id: old_owner.instance_id,
          turn_id: old_owner.turn_id
        )
      end)

    canonical_root = DocMount.canonical_root(workspace)

    assert_receive {:staged_settlement_removed, ^hook_ref, ^canonical_root,
                    "post-remove-reject.hwp"},
                   2_000

    replacement =
      Task.async(fn ->
        OpenDocs.stage(
          workspace,
          doc.name,
          "{",
          {:invalid_ir_json, "{"},
          Map.put(new_owner, :edit_id, "post-remove-reject-new-edit")
        )
      end)

    await_open_docs_stage_call(replacement.pid, workspace, doc.name)
    send(open_docs, {:continue_staged_settlement, hook_ref})

    assert :ok = Task.await(replacement, 2_000)

    assert %{
             committed: [],
             rejected: [
               {"post-remove-reject.hwp", {:invalid_ir_json, "["}}
             ],
             pending: []
           } = Task.await(flush, 2_000)

    assert [{"post-remove-reject.hwp", "{", {:invalid_ir_json, "{"}, new_identity}] =
             OpenDocs.staged_with_identity(workspace)

    assert new_identity.edit_id == "post-remove-reject-new-edit"

    assert_receive {:vfs_doc_edited,
                    %{
                      phase: :rejected,
                      doc: "post-remove-reject.hwp",
                      edit_id: "post-remove-reject-old-edit",
                      agent_id: "post-remove-reject-old-agent",
                      instance_id: "post-remove-reject-old-instance",
                      turn_id: "post-remove-reject-old-turn"
                    }}

    refute_receive {:vfs_doc_edited, %{phase: :rejected}}, 20
  end

  test "Session finalizer flushes staged JSONL through Session.route without self-deadlock", %{
    workspace: workspace
  } do
    path = Path.join(workspace, "staged-contract.hwp")
    File.write!(path, "fixture")

    {:ok, ws} =
      Session.attach(workspace,
        provider: "codex",
        adapter_opts: [
          exmcp_adapter: EcritsWeb.FakeAcpAdapter,
          script: [{:text_delta, "done"}]
        ],
        workspace_root: workspace
      )

    session_pid = Session.whereis(workspace)
    instance_id = Session.snapshot(ws).instance_id
    :ok = Session.subscribe_file_events(workspace)

    OpenDocs.open(workspace, "staged-contract.hwp",
      agent_id: ws.agent_id,
      instance_id: instance_id,
      turn_id: "staged-terminal"
    )

    OpenDocs.set_writable(workspace, true)

    on_exit(fn ->
      Pool.close_by_path(path)
      OpenDocs.close(workspace, "staged-contract.hwp")

      if Process.alive?(session_pid) do
        DynamicSupervisor.terminate_child(Ecrits.Workspace.SessionSupervisor, session_pid)
      end
    end)

    assert {:ok, projected} = Projection.project_file(path)
    assert {edited_projection, true} = replace_first_projected_text(projected, "STAGED_OK")

    OpenDocs.stage(
      workspace,
      "staged-contract.hwp",
      edited_projection,
      :structural_change,
      %{
        agent_id: ws.agent_id,
        instance_id: instance_id,
        turn_id: "staged-terminal",
        edit_id: "staged-edit"
      }
    )

    assert {:ok, :started} =
             Session.finalize_turn(ws, "staged-terminal", instance_id: instance_id)

    assert_receive {:workspace_turn_finalized,
                    %{
                      agent_id: agent_id,
                      instance_id: ^instance_id,
                      turn_id: "staged-terminal",
                      result: %{
                        failed: [],
                        staged: %{committed: ["staged-contract.hwp"], pending: []}
                      },
                      summary: %{successful?: true, committed: 1}
                    }},
                   2_000

    assert agent_id == ws.agent_id
    assert OpenDocs.staged(workspace, "staged-contract.hwp") == :error

    assert [] =
             OpenDocs.dirty_owner_entries(workspace,
               agent_id: ws.agent_id,
               instance_id: instance_id,
               turn_id: "staged-terminal"
             )

    assert {:ok, after_projection} = Projection.project_file(path)
    assert after_projection =~ "STAGED_OK"
  end

  defp open_staged_test_doc(workspace, name, owner) do
    path = Path.join(workspace, name)
    File.write!(path, "fixture")

    OpenDocs.open(workspace, name,
      agent_id: owner.agent_id,
      instance_id: owner.instance_id,
      turn_id: owner.turn_id
    )

    OpenDocs.set_writable(workspace, true)

    on_exit(fn ->
      Pool.close_by_path(path)
      OpenDocs.close(workspace, name)
    end)

    assert {:ok, projection} = Projection.project_file(path)
    assert {:ok, %{id: document_id}} = Pool.info_by_path(path)
    assert {:server, editor} = Pool.route(document_id)

    %{name: name, path: path, projection: projection, editor: editor}
  end

  defp await_suspended_editor_call(editor, attempts \\ 200)

  defp await_suspended_editor_call(_editor, 0) do
    flunk("staged flush did not reach the suspended document editor")
  end

  defp await_suspended_editor_call(editor, attempts) do
    messages =
      case Process.info(editor, :messages) do
        {:messages, messages} -> messages
        nil -> []
      end

    if Enum.any?(messages, &match?({:"$gen_call", _from, _request}, &1)) do
      :ok
    else
      receive do
      after
        5 -> await_suspended_editor_call(editor, attempts - 1)
      end
    end
  end

  defp resume_if_alive(editor) do
    if Process.alive?(editor), do: :sys.resume(editor)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp install_staged_settlement_hook do
    open_docs = Process.whereis(OpenDocs)
    hook_ref = make_ref()
    test_pid = self()

    :sys.replace_state(open_docs, fn state ->
      Map.put(state, :staged_settlement_test_hook, {test_pid, hook_ref})
    end)

    on_exit(fn ->
      send(open_docs, {:continue_staged_settlement, hook_ref})

      if Process.alive?(open_docs) do
        try do
          :sys.replace_state(open_docs, &Map.delete(&1, :staged_settlement_test_hook))
        catch
          :exit, _reason -> :ok
        end
      end
    end)

    {open_docs, hook_ref}
  end

  defp await_open_docs_stage_call(caller, root, name, attempts \\ 200)

  defp await_open_docs_stage_call(_caller, _root, _name, 0) do
    flunk("replacement stage call did not queue behind exact settlement")
  end

  defp await_open_docs_stage_call(caller, root, name, attempts) do
    canonical_root = DocMount.canonical_root(root)

    queued? =
      case Process.info(Process.whereis(OpenDocs), :messages) do
        {:messages, messages} ->
          Enum.any?(messages, fn
            {:"$gen_call", {^caller, _tag},
             {:stage, ^canonical_root, ^name, _bytes, _reason, _identity}} ->
              true

            _message ->
              false
          end)

        _unavailable ->
          false
      end

    if queued? do
      :ok
    else
      receive do
      after
        5 -> await_open_docs_stage_call(caller, root, name, attempts - 1)
      end
    end
  end

  defp replace_first_projected_text(bytes, replacement) do
    decoded = Jason.decode!(bytes)
    {updated, changed?} = replace_first_text_node(decoded, replacement)
    {Jason.encode!(updated), changed?}
  end

  defp replace_first_text_node(%{"text" => _text} = node, replacement) do
    {Map.put(node, "text", replacement), true}
  end

  defp replace_first_text_node(list, replacement) when is_list(list) do
    Enum.map_reduce(list, false, fn
      item, false -> replace_first_text_node(item, replacement)
      item, true -> {item, true}
    end)
  end

  defp replace_first_text_node(map, replacement) when is_map(map) do
    Enum.reduce(map, {map, false}, fn
      {_key, _value}, {updated, true} ->
        {updated, true}

      {key, value}, {updated, false} ->
        {new_value, changed?} = replace_first_text_node(value, replacement)
        {Map.put(updated, key, new_value), changed?}
    end)
  end

  defp replace_first_text_node(value, _replacement), do: {value, false}
end
