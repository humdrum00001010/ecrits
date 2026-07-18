defmodule Ecrits.Doc.EditorTest do
  use ExUnit.Case, async: false

  alias Ecrits.AcpAgent.Session, as: AgentSession
  alias Ecrits.Doc.Editor
  alias Ecrits.Test.ExceptionalEditorBackend
  alias Ecrits.Test.FakeEhwpRuntime

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)
    on_exit(fn -> restore(:ehwp, :runtime, prev) end)

    pid =
      start_supervised!(
        {Editor,
         document_id: "d_#{System.unique_integer([:positive])}",
         kind: :hwp,
         backend: Ecrits.Doc.Rhwp,
         path: "contract.hwp",
         open_opts: [__text__: "제1조 (목적)\n제2조 (계약기간)\n제3조 (대금지급)"]}
      )

    {:ok, editor: pid}
  end

  describe "apply/2" do
    test "applies an edit and marks the document dirty", %{editor: editor} do
      assert {:ok, applied} =
               Editor.apply(editor, %{op: "replace_text", query: "제2조", replacement: "X2"})

      assert applied.op == "replace_text"
      assert applied.invalidated == []
      assert applied.native == [%{"ok" => true, "replaced" => 1}]
      assert Editor.dirty?(editor)

      assert {:ok, %{text: text}} = Editor.read(editor, [])
      assert text =~ "X2"
    end

    test "serializes multiple writes through the editor mailbox", %{editor: editor} do
      assert {:ok, _} =
               Editor.apply(editor, %{op: "replace_text", query: "제2조", replacement: "AA"})

      assert {:ok, _} =
               Editor.apply(editor, %{op: "replace_text", query: "제3조", replacement: "BB"})

      assert {:ok, %{text: text}} = Editor.read(editor, [])
      assert text =~ "AA"
      assert text =~ "BB"
    end

    test "an atomic batch restores the exact preimage when a later command fails" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "ecrits-editor-atomic-batch-#{System.unique_integer([:positive])}"
        )

      path = Path.join(dir, "contract.hwp")
      initial = "제1조 (목적)\n제2조 (계약기간)\n제3조 (대금지급)"
      File.mkdir_p!(dir)
      File.write!(path, initial)
      on_exit(fn -> File.rm_rf(dir) end)

      child =
        Supervisor.child_spec(
          {Editor,
           document_id: "d_atomic_#{System.unique_integer([:positive])}",
           kind: :hwp,
           backend: Ecrits.Doc.Rhwp,
           path: path,
           open_opts: [__text__: initial]},
          id: {:atomic_editor, System.unique_integer([:positive])}
        )

      editor = start_supervised!(child)
      owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
      before_snapshot = Editor.dirty_snapshot(editor)
      before_history = Editor.history(editor)
      source_preimage = File.read!(path)
      :ok = Editor.subscribe(editor)

      commands = [
        {:apply,
         %{
           "op" => "insert_text",
           "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
           "text" => "MUST_ROLL_BACK"
         }},
        {:apply,
         %{
           "op" => "insert_text",
           "ref" => %{"section" => 0, "paragraph" => 999, "offset" => 0},
           "text" => "FAIL"
         }}
      ]

      assert {:error, _reason} =
               Editor.apply_batch_and_save(editor, commands,
                 owner: owner,
                 format: :hwp,
                 path: path
               )

      assert {:ok, %{text: ^initial}} = Editor.read(editor, [])
      assert File.read!(path) == source_preimage
      assert Editor.dirty_snapshot(editor) == before_snapshot
      assert Editor.history(editor) == before_history
      refute_receive {:doc_applied, _info}
    end

    test "a cancelled turn that wins before dequeue cannot mutate the server editor" do
      {dir, path, initial} = exceptional_source("cancel-before-dequeue")
      on_exit(fn -> File.rm_rf(dir) end)

      editor = start_exceptional_editor(path, [])
      {session, turn_id, owner, _adapter_task} = start_blocking_agent_turn()
      test_pid = self()

      :ok = :sys.suspend(editor)

      on_exit(fn ->
        if Process.alive?(editor) do
          try do
            :sys.resume(editor)
          catch
            :exit, _reason -> :ok
          end
        end
      end)

      caller =
        start_supervised!(
          Supervisor.child_spec(
            {Task,
             fn ->
               receive do
                 :start_editor_call -> :ok
               end

               send(test_pid, {:editor_call_starting, self()})

               result =
                 Editor.apply_batch_and_save(editor, [insert_command("MUST_NOT_COMMIT")],
                   owner: owner,
                   agent_session: session,
                   path: path,
                   format: :hwp
                 )

               send(test_pid, {:editor_call_result, result})
             end},
            id: make_ref()
          )
        )

      :erlang.trace(caller, true, [:send])
      send(caller, :start_editor_call)
      assert_receive {:editor_call_starting, ^caller}

      assert_receive {:trace, ^caller, :send,
                      {:"$gen_call", _from, {:apply_batch_and_save, _commands, _opts}}, ^editor}

      assert {:ok, %{id: ^turn_id, status: :cancelled}} =
               AgentSession.cancel(session, nil, turn_id)

      :ok = :sys.resume(editor)

      assert_receive {:editor_call_result, {:error, :turn_invalidated}}, 2_000
      assert File.read!(path) == initial
      assert {:ok, %{text: ^initial}} = Editor.read(editor, [])
      assert Editor.dirty_snapshot(editor) == %{dirty?: false, revision: 0, owner: nil}
      assert Editor.history(editor) == []
    end

    test "a mismatched live turn identity is rejected before server mutation" do
      {dir, path, initial} = exceptional_source("mismatched-turn")
      on_exit(fn -> File.rm_rf(dir) end)

      editor = start_exceptional_editor(path, [])
      {session, turn_id, owner, _adapter_task} = start_blocking_agent_turn()
      invalid_owner = %{owner | turn_id: turn_id <> "-stale"}

      assert {:error, :turn_invalidated} =
               Editor.apply_batch_and_save(editor, [insert_command("STALE_MUTATION")],
                 owner: invalid_owner,
                 agent_session: session,
                 path: path,
                 format: :hwp
               )

      assert File.read!(path) == initial
      assert {:ok, %{text: ^initial}} = Editor.read(editor, [])
      assert Editor.dirty_snapshot(editor) == %{dirty?: false, revision: 0, owner: nil}
      assert Editor.history(editor) == []

      assert {:ok, %{id: ^turn_id, status: :cancelled}} =
               AgentSession.cancel(session, nil, turn_id)
    end

    test "the editor-owned fence survives caller death and terminal cancellation waits" do
      {dir, path, initial} = exceptional_source("editor-owned-turn-fence")
      on_exit(fn -> File.rm_rf(dir) end)

      editor = start_exceptional_editor(path, [])
      {session, turn_id, owner, _adapter_task} = start_blocking_agent_turn()
      test_pid = self()

      turn_commit = fn identity, commit ->
        AgentSession.with_turn_commit(session, identity, fn ->
          send(test_pid, {:server_commit_fence_acquired, self()})

          receive do
            :release_server_commit -> commit.()
          end
        end)
      end

      caller =
        start_supervised!(
          Supervisor.child_spec(
            {Task,
             fn ->
               result =
                 Editor.apply_batch_and_save(editor, [insert_command("COMMITTED_ONCE")],
                   owner: owner,
                   agent_session: session,
                   turn_commit_fun: turn_commit,
                   path: path,
                   format: :hwp,
                   after_save: fn _applied ->
                     send(test_pid, {:server_after_save_running, self()})

                     receive do
                       :release_server_after_save -> :ok
                     end
                   end
                 )

               send(test_pid, {:unexpected_live_caller_result, result})
             end},
            id: make_ref()
          )
        )

      assert_receive {:server_commit_fence_acquired, ^editor}, 2_000

      caller_ref = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 2_000

      _cancel =
        start_supervised!(
          Supervisor.child_spec(
            {Task,
             fn ->
               result = AgentSession.cancel(session, nil, turn_id)
               send(test_pid, {:terminal_cancel_result, result})
             end},
            id: make_ref()
          )
        )

      refute_receive {:terminal_cancel_result, _result}, 50
      send(editor, :release_server_commit)
      assert_receive {:server_after_save_running, ^editor}, 2_000
      refute_receive {:terminal_cancel_result, _result}, 50
      send(editor, :release_server_after_save)
      _ = :sys.get_state(editor)

      assert_receive {:terminal_cancel_result, {:ok, %{id: ^turn_id, status: :cancelled}}},
                     2_000

      expected = initial <> "COMMITTED_ONCE"
      assert File.read!(path) == expected
      assert {:ok, %{text: ^expected}} = Editor.read(editor, [])
      assert length(Editor.history(editor)) == 1
      assert Editor.dirty_snapshot(editor) == %{dirty?: false, revision: 1, owner: nil}
      refute_receive {:unexpected_live_caller_result, _result}
    end

    test "an after-save failure is fail-stop and never rolls back persisted bytes" do
      {dir, path, initial} = exceptional_source("after-save-fail-stop")
      on_exit(fn -> File.rm_rf(dir) end)

      editor = start_exceptional_editor(path, [])
      test_pid = self()
      editor_ref = Process.monitor(editor)
      marker = "PERSISTED_BEFORE_CALLBACK_FAILURE"

      _caller =
        start_supervised!(
          Supervisor.child_spec(
            {Task,
             fn ->
               Editor.apply_batch_and_save(editor, [insert_command(marker)],
                 path: path,
                 format: :hwp,
                 after_save: fn _applied ->
                   send(test_pid, {:after_save_observed, self(), File.read!(path)})
                   {:error, :injected_callback_failure}
                 end
               )
             end},
            id: make_ref()
          )
        )

      expected = initial <> marker
      assert_receive {:after_save_observed, ^editor, ^expected}, 2_000

      assert_receive {:DOWN, ^editor_ref, :process, ^editor,
                      {:after_save_failed, :injected_callback_failure}},
                     2_000

      assert File.read!(path) == expected
    end

    test "a writer queued behind a failed batch runs after rollback", %{editor: editor} do
      owner_a = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
      owner_b = %{agent_id: "agent-b", instance_id: "instance-b", turn_id: "turn-b"}

      failing_commands = [
        {:apply,
         %{
           "op" => "insert_text",
           "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
           "text" => "ROLLED_BACK_A"
         }},
        {:apply,
         %{
           "op" => "insert_text",
           "ref" => %{"section" => 0, "paragraph" => 999, "offset" => 0},
           "text" => "FAIL"
         }}
      ]

      writer_b_op = %{
        "op" => "insert_text",
        "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
        "text" => "QUEUED_B"
      }

      batch_tag = make_ref()
      writer_tag = make_ref()

      send(
        editor,
        {:"$gen_call", {self(), batch_tag},
         {:apply_batch_and_save, failing_commands,
          [owner: owner_a, format: :hwp, path: "contract.hwp"]}}
      )

      send(editor, {:"$gen_call", {self(), writer_tag}, {:apply, writer_b_op, [owner: owner_b]}})

      assert_receive {^batch_tag, {:error, _reason}}, 5_000
      assert_receive {^writer_tag, {:ok, _applied}}, 5_000

      assert {:ok, %{text: text}} = Editor.read(editor, [])
      assert text =~ "QUEUED_B"
      refute text =~ "ROLLED_BACK_A"

      snapshot = Editor.dirty_snapshot(editor)
      assert snapshot.owner == owner_b
      assert Editor.owner_status(snapshot, owner_b) == :exclusive
      assert [entry] = Editor.history(editor)
      assert entry.owner == owner_b
    end

    test "a save that writes then raises restores before the queued writer runs" do
      {dir, path, initial} = exceptional_source("save-raise")
      on_exit(fn -> File.rm_rf(dir) end)

      editor =
        start_exceptional_editor(path,
          save_failure: :raise,
          close_failure: :raise_once_before_close,
          observer: self()
        )

      owner_a = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
      owner_b = %{agent_id: "agent-b", instance_id: "instance-b", turn_id: "turn-b"}
      before_snapshot = Editor.dirty_snapshot(editor)
      before_history = Editor.history(editor)
      batch_tag = make_ref()
      writer_tag = make_ref()

      send(
        editor,
        {:"$gen_call", {self(), batch_tag},
         {:apply_batch_and_save, [insert_command("REJECTED_A")],
          [owner: owner_a, path: path, format: :hwp]}}
      )

      send(
        editor,
        {:"$gen_call", {self(), writer_tag}, {:apply, insert_op("QUEUED_B"), [owner: owner_b]}}
      )

      assert_receive {^batch_tag,
                      {:error,
                       {:atomic_boundary_failed, :batch_save,
                        {:raise, RuntimeError, "injected save raise"}}}},
                     5_000

      assert_receive {^writer_tag, {:ok, _applied}}, 5_000

      assert_receive {:exceptional_backend_close, rejected_handle, 1, :raised_before_disposal}

      assert_receive {:exceptional_backend_close, ^rejected_handle, 2, :disposed}
      refute Process.alive?(rejected_handle)
      assert Process.alive?(editor)
      assert File.read!(path) == initial
      assert {:ok, %{text: text}} = Editor.read(editor, [])
      assert text == initial <> "QUEUED_B"

      assert Editor.dirty_snapshot(editor) == %{
               dirty?: true,
               revision: before_snapshot.revision + 1,
               owner: owner_b
             }

      assert [entry] = Editor.history(editor)
      assert entry.owner == owner_b
      assert length(before_history) == 0
    end

    test "an edit that mutates then exits restores the exact preimage" do
      {dir, path, initial} = exceptional_source("edit-exit")
      on_exit(fn -> File.rm_rf(dir) end)

      editor = start_exceptional_editor(path, edit_failure: :exit_on_rejected)
      owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}

      assert {:ok, _applied} = Editor.apply(editor, insert_op("PREEXISTING"), owner: owner)

      before_snapshot = Editor.dirty_snapshot(editor)
      before_history = Editor.history(editor)

      assert {:error, {:atomic_boundary_failed, :batch_apply, {:exit, {:injected_exit, :edit}}}} =
               Editor.apply_batch_and_save(editor, [insert_command("REJECTED_EXIT")],
                 owner: owner,
                 path: path,
                 format: :hwp
               )

      assert Process.alive?(editor)
      assert File.read!(path) == initial
      assert {:ok, %{text: text}} = Editor.read(editor, [])
      assert text == initial <> "PREEXISTING"
      assert Editor.dirty_snapshot(editor) == before_snapshot
      assert Editor.history(editor) == before_history
    end

    test "an unexpected save return after a write restores source and model" do
      {dir, path, initial} = exceptional_source("save-unexpected")
      on_exit(fn -> File.rm_rf(dir) end)

      editor = start_exceptional_editor(path, save_failure: :unexpected)
      owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
      before_snapshot = Editor.dirty_snapshot(editor)

      assert {:error,
              {:atomic_unexpected_result, :batch_save, {:unexpected_backend_return, :save}}} =
               Editor.apply_batch_and_save(editor, [insert_command("REJECTED_UNEXPECTED")],
                 owner: owner,
                 path: path,
                 format: :hwp
               )

      assert Process.alive?(editor)
      assert File.read!(path) == initial
      assert {:ok, %{text: ^initial}} = Editor.read(editor, [])
      assert Editor.dirty_snapshot(editor) == before_snapshot
      assert Editor.history(editor) == []
    end

    test "fail-stop termination disposes rejected and restored rollback handles" do
      {dir, path, initial} = exceptional_source("close-both-handles")
      on_exit(fn -> File.rm_rf(dir) end)

      editor =
        start_exceptional_editor(
          path,
          [
            save_failure: :raise,
            close_failure: :raise_twice_before_close,
            reopen_close_failure: :raise_once_before_close,
            observer: self()
          ],
          restart: :temporary
        )

      ref = Process.monitor(editor)
      owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}

      assert {:error,
              {:atomic_rollback_failed,
               {:atomic_boundary_failed, :batch_save,
                {:raise, RuntimeError, "injected save raise"}},
               {:atomic_rejected_handle_close_failed,
                {:close_retry_failed, _first_close_error, _retry_close_error},
                {:close_failed, _restored_close_error}}}} =
               Editor.apply_batch_and_save(editor, [insert_command("REJECTED_BOTH_HANDLES")],
                 owner: owner,
                 path: path,
                 format: :hwp
               )

      assert_receive {:DOWN, ^ref, :process, ^editor, _reason}, 5_000

      assert_receive {:exceptional_backend_close, rejected_handle, 1, :raised_before_disposal}

      assert_receive {:exceptional_backend_close, ^rejected_handle, 2, :raised_before_disposal}

      assert_receive {:exceptional_backend_close, restored_handle, 1, :raised_before_disposal}

      refute restored_handle == rejected_handle
      assert_receive {:exceptional_backend_close, ^rejected_handle, 3, :disposed}
      assert_receive {:exceptional_backend_close, ^restored_handle, 2, :disposed}
      refute Process.alive?(rejected_handle)
      refute Process.alive?(restored_handle)
      assert File.read!(path) == initial

      reopened = start_exceptional_editor(path, [])
      assert {:ok, %{text: ^initial}} = Editor.read(reopened, [])
      assert Editor.dirty_snapshot(reopened) == %{dirty?: false, revision: 0, owner: nil}
      assert Editor.history(reopened) == []
    end

    test "a failed model reopen fail-stops only after restoring the source" do
      {dir, path, initial} = exceptional_source("reopen-raise")
      on_exit(fn -> File.rm_rf(dir) end)

      editor =
        start_exceptional_editor(
          path,
          [save_failure: :raise, reopen_failure: :raise],
          restart: :temporary
        )

      ref = Process.monitor(editor)
      owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}

      assert {:error,
              {:atomic_rollback_failed,
               {:atomic_boundary_failed, :batch_save,
                {:raise, RuntimeError, "injected save raise"}},
               {:atomic_model_restore_failed,
                {:atomic_boundary_failed, :model_reopen,
                 {:raise, RuntimeError, "injected reopen raise"}}}}} =
               Editor.apply_batch_and_save(editor, [insert_command("REJECTED_REOPEN")],
                 owner: owner,
                 path: path,
                 format: :hwp
               )

      assert_receive {:DOWN, ^ref, :process, ^editor, _reason}, 5_000
      refute Process.alive?(editor)
      assert File.read!(path) == initial

      reopened = start_exceptional_editor(path, [])
      assert {:ok, %{text: ^initial}} = Editor.read(reopened, [])
      assert Editor.dirty_snapshot(reopened) == %{dirty?: false, revision: 0, owner: nil}
      assert Editor.history(reopened) == []
    end

    test "save_if_owner rejects a stale writer snapshot atomically", %{editor: editor} do
      owner_a = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
      owner_b = %{agent_id: "agent-b", instance_id: "instance-b", turn_id: "turn-b"}

      assert {:ok, _} =
               Editor.apply(
                 editor,
                 %{op: "replace_text", query: "제1조", replacement: "A1"},
                 owner: owner_a
               )

      snapshot = Editor.dirty_snapshot(editor)
      assert snapshot.owner == owner_a

      assert {:ok, _} =
               Editor.apply(
                 editor,
                 %{op: "replace_text", query: "제2조", replacement: "B2"},
                 owner: owner_b
               )

      assert {:skipped, :owner_changed} = Editor.save_if_owner(editor, snapshot)
      assert Editor.dirty?(editor)

      snapshot_after = Editor.dirty_snapshot(editor)

      assert snapshot_after.owner == {:mixed, MapSet.new([owner_a, owner_b])}
      assert Editor.owner_status(snapshot_after, owner_a) == :mixed
      assert Editor.owner_status(snapshot_after, owner_b) == :mixed
    end

    test "a successful native no-op does not take dirty ownership", %{editor: editor} do
      owner_a = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}
      owner_b = %{agent_id: "agent-b", instance_id: "instance-b", turn_id: "turn-b"}

      assert {:ok, _} =
               Editor.apply(
                 editor,
                 %{op: "replace_text", query: "제1조", replacement: "A1"},
                 owner: owner_a
               )

      snapshot = Editor.dirty_snapshot(editor)

      assert {:ok, %{native: [%{"ok" => false, "replaced" => 0}]}} =
               Editor.apply(
                 editor,
                 %{op: "replace_text", query: "없는 문구", replacement: "B"},
                 owner: owner_b
               )

      assert Editor.dirty_snapshot(editor) == snapshot
    end

    test "different writers make the unsaved model mixed instead of transferring ownership", %{
      editor: editor
    } do
      owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}

      assert {:ok, _} =
               Editor.apply(editor, %{
                 op: "replace_text",
                 query: "제1조",
                 replacement: "HUMAN"
               })

      assert {:ok, _} =
               Editor.apply(
                 editor,
                 %{op: "replace_text", query: "제2조", replacement: "AGENT"},
                 owner: owner
               )

      snapshot = Editor.dirty_snapshot(editor)
      assert %{dirty?: true, owner: {:mixed, %MapSet{}}} = snapshot
      assert Editor.owner_status(snapshot, owner) == :mixed
    end
  end

  describe "broadcast" do
    test "subscribers receive an :applied event after apply", %{editor: editor} do
      :ok = Editor.subscribe(editor)

      assert {:ok, _} =
               Editor.apply(editor, %{op: "replace_text", query: "제1조", replacement: "Z1"})

      assert_receive {:doc_applied, %{op: %{op: "replace_text"}}}
    end
  end

  describe "history" do
    test "records applied ops in order", %{editor: editor} do
      {:ok, _} = Editor.apply(editor, %{op: "replace_text", query: "제1조", replacement: "Z1"})
      {:ok, _} = Editor.apply(editor, %{op: "replace_text", query: "제2조", replacement: "Z2"})

      history = Editor.history(editor)
      assert length(history) == 2
      assert Enum.map(history, & &1.op.replacement) == ["Z1", "Z2"]
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)

  defp exceptional_source(label) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ecrits-editor-exceptional-#{label}-#{System.unique_integer([:positive])}"
      )

    path = Path.join(dir, "contract.hwp")
    initial = "SOURCE_PREIMAGE"
    File.mkdir_p!(dir)
    File.write!(path, initial)
    {dir, path, initial}
  end

  defp start_exceptional_editor(path, open_opts, child_opts \\ []) do
    child =
      Supervisor.child_spec(
        {Editor,
         document_id: "d_exceptional_#{System.unique_integer([:positive])}",
         kind: :hwp,
         backend: ExceptionalEditorBackend,
         path: path,
         open_opts: open_opts},
        [id: {:exceptional_editor, System.unique_integer([:positive])}] ++ child_opts
      )

    start_supervised!(child)
  end

  defp start_blocking_agent_turn do
    id = "editor-fence-" <> Ecto.UUID.generate()

    session =
      start_supervised!(
        {AgentSession,
         id: id,
         ctx: nil,
         provider: %{id: "codex"},
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         adapter_opts: [
           exmcp_adapter: EcritsWeb.FakeAcpAdapter,
           test_pid: self(),
           wait_for: :go,
           script: [{:text_delta, "ok"}]
         ],
         workspace_root: File.cwd!(),
         mcp_servers: []}
      )

    :ok = Ecrits.AcpAgent.subscribe(id)
    {:ok, %{id: turn_id, status: :running}} = AgentSession.send_turn(session, nil, "edit")
    assert_receive {:agent_adapter_waiting, adapter_task}, 2_000

    context = AgentSession.tool_context(session)

    owner = %{
      agent_id: context.agent_id,
      instance_id: context.instance_id,
      turn_id: turn_id
    }

    {session, turn_id, owner, adapter_task}
  end

  defp insert_command(text), do: {:apply, insert_op(text)}

  defp insert_op(text) do
    %{
      "op" => "insert_text",
      "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
      "text" => text
    }
  end
end
