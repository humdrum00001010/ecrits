defmodule Ecrits.AcpAgent.SessionQueueTest do
  @moduledoc """
  Phase 5: the `send_turn` FIFO queue + multi-modal input seam at the `Session`
  level, driven through the real `ExMCP.ACP` stack via `EcritsWeb.FakeAcpAdapter`.

  The legacy behaviour was "a mid-turn send cancels the running turn and starts a
  new one". Phase 5 replaces that with an ENQUEUE: a mid-turn send is queued and
  drains in order when the running turn finishes. A re-Enter (`flush_queue/2`)
  promotes the head immediately.
  """

  use ExUnit.Case, async: false

  alias Ecrits.AcpAgent.Session
  alias Ecrits.Agent.Dialog

  # A turn that blocks until the test releases it, so we can deterministically
  # observe a turn being "in flight" while we enqueue behind it.
  defp start_blocking_session(ctx \\ %{}) do
    id = "queue-test-" <> Ecto.UUID.generate()

    start_supervised!(
      {Session,
       [
         id: id,
         ctx: nil,
         provider: %{id: "codex"},
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         adapter_opts:
           [
             exmcp_adapter: EcritsWeb.FakeAcpAdapter,
             test_pid: self(),
             wait_for: :go,
             script: [{:text_delta, "ok"}]
           ] ++ Map.get(ctx, :extra_opts, []),
         workspace_root: File.cwd!(),
         mcp_servers: []
       ]}
    )

    :ok = Ecrits.AcpAgent.subscribe(id)
    pid = Session.whereis(id)
    {id, pid}
  end

  test "a mid-turn send is ENQUEUED (not cancelled) and drains in order" do
    {_id, pid} = start_blocking_session()

    # Turn 1 starts and blocks (the fake adapter waits for :go).
    {:ok, %{id: turn1, status: :running}} = Session.send_turn(pid, nil, "first")
    assert_receive {:agent_adapter_waiting, task1}, 2_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn1}}, 2_000

    # A second send while turn 1 is in flight ENQUEUES (status :queued) — turn 1
    # is NOT cancelled.
    {:ok, %{id: turn2, status: :queued}} = Session.send_turn(pid, nil, "second")

    assert_receive {:agent_event, %{type: :turn_queued, pending: 1, input: "second", picks: []}},
                   2_000

    assert %{pending: 1, queued: [%{turn_id: ^turn2, input: "second", picks: []}]} =
             Session.agent_snapshot(pid)

    refute_received {:agent_event, %{type: :turn_cancelled}}

    # Release turn 1 → it completes → the queue head (turn 2) drains and starts.
    send(task1, :go)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000
    assert_receive {:agent_adapter_waiting, task2}, 2_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000

    send(task2, :go)
  end

  test "a display preview splits pending prose at its transcript position" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn_id, status: :running}} = Session.send_turn(pid, nil, "edit it")
    assert_receive {:agent_adapter_waiting, task}, 2_000

    send(pid, {:turn_event, turn_id, %{type: :text_delta, delta: "before preview"}})
    _ = :sys.get_state(pid)

    :ok =
      Session.append_transcript_item(pid, %{
        role: :edit_preview,
        status: :sent,
        turn_id: turn_id,
        document_path: "template.hwpx"
      })

    send(pid, {:turn_event, turn_id, %{type: :text_delta, delta: "after preview"}})
    _ = :sys.get_state(pid)
    send(task, :go)

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    assert [%Dialog{items: items}] = Session.transcript(pid)

    assert [
             %{role: :user},
             %{role: :agent, body: "before preview", segment: 0},
             %{role: :edit_preview},
             %{role: :agent, body: "after previewok", segment: 1}
           ] = items
  end

  @tag :edit_failure
  test "terminal durability never holds the turn commit lock" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn_id, status: :running}} = Session.send_turn(pid, nil, "finish promptly")
    assert_receive {:agent_adapter_waiting, adapter_task}, 2_000

    handoff = Process.whereis(Ecrits.WorkspaceHandoff)
    assert is_pid(handoff)
    :ok = :sys.suspend(handoff)

    {lock_result, lock_task} =
      try do
        send(adapter_task, :go)
        assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

        lock_task =
          Task.async(fn ->
            :global.trans(
              {{Session, :turn_commit, pid, turn_id}, self()},
              fn -> :lock_acquired end
            )
          end)

        {Task.yield(lock_task, 250), lock_task}
      after
        :ok = :sys.resume(handoff)
      end

    if is_nil(lock_result), do: Task.shutdown(lock_task, :brutal_kill)
    assert lock_result == {:ok, :lock_acquired}

    assert %{current_turn: nil} = Session.agent_snapshot(pid)
  end

  test "an in-flight snapshot is immutable, complete, and tied to one process instance" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn_id, status: :running}} = Session.send_turn(pid, nil, "inspect this")
    assert_receive {:agent_adapter_waiting, task}, 2_000

    assert_receive {:agent_event,
                    %{
                      type: :turn_started,
                      turn_id: ^turn_id,
                      instance_id: instance_id
                    }},
                   2_000

    send(pid, {:turn_event, turn_id, %{type: :reasoning_delta, delta: "first thought"}})
    send(pid, {:turn_event, turn_id, %{type: :text_delta, delta: "before tool"}})

    send(pid, {
      :turn_event,
      turn_id,
      %{
        type: :tool_call_started,
        tool_call_id: "snapshot-tool",
        name: "doc.edit",
        kind: "edit",
        arguments: %{"document" => "contract.hwpx", "ops" => []}
      }
    })

    send(pid, {:turn_event, turn_id, %{type: :reasoning_delta, delta: "second thought"}})
    send(pid, {:turn_event, turn_id, %{type: :text_delta, delta: "after tool"}})
    _ = :sys.get_state(pid)

    before = :sys.get_state(pid).current
    snapshot = Session.agent_snapshot(pid)
    after_snapshot = :sys.get_state(pid).current

    assert before == after_snapshot
    assert snapshot.instance_id == instance_id

    assert %{
             id: ^turn_id,
             turn_id: ^turn_id,
             pending_text: "after tool",
             text_segment: 1,
             pending_reasoning: "",
             reasoning_segment: 2,
             active_tools: %{
               "snapshot-tool" => %{
                 name: "doc.edit",
                 kind: "edit",
                 args: %{"document" => "contract.hwpx", "ops" => []}
               }
             },
             items: items
           } = snapshot.current_turn

    assert Enum.map(items, & &1.role) == [:user, :thinking, :agent, :tool, :thinking]
    assert Enum.at(items, 0).body == "inspect this"
    assert Enum.at(items, 1).body == "first thought"
    assert Enum.at(items, 2).body == "before tool"
    assert Enum.at(items, 3).status == :running
    assert Enum.at(items, 4).body == "second thought"

    send(task, :go)

    assert_receive {:agent_event,
                    %{
                      type: :turn_completed,
                      turn_id: ^turn_id,
                      instance_id: ^instance_id
                    }},
                   2_000
  end

  test "agent snapshot migrates legacy ACP file tools into distinct file activity" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn_id, status: :running}} = Session.send_turn(pid, nil, "inspect this")
    assert_receive {:agent_adapter_waiting, task}, 2_000

    file_operation_names = ~w(read_text_file search_text_file edit_text_file)

    persisted_items =
      Enum.with_index(file_operation_names, fn name, index ->
        %{
          role: :tool,
          tool_call_id: "persisted-#{name}",
          name: name,
          kind: "read",
          status: :completed,
          path: "contract-#{index}.hwpx.jsonl",
          query: if(name == "search_text_file", do: "(인)", else: nil)
        }
      end)

    persisted_doc_tool = %{
      role: :tool,
      tool_call_id: "persisted-doc-open",
      name: "doc.open_doc",
      kind: "read",
      status: :completed
    }

    named_non_tool_items = [
      %{role: :user, name: "read_text_file", body: "user content"},
      %{role: "agent", name: "search_text_file", body: "agent content"},
      %{
        role: :edit_preview,
        name: "edit_text_file",
        status: :sent,
        document_path: "contract.hwpx"
      }
    ]

    current_items =
      Enum.with_index(file_operation_names, fn name, index ->
        %{
          role: :tool,
          tool_call_id: "current-#{name}",
          name: name,
          kind: "read",
          status: :running,
          path: "current-#{index}.hwpx.jsonl",
          query: if(name == "search_text_file", do: "서명", else: nil),
          arguments: %{"path" => "contract.hwpx.jsonl"}
        }
      end)

    current_doc_tool = %{
      role: :tool,
      tool_call_id: "current-doc-open",
      name: "doc.open_doc",
      kind: "read",
      status: :running,
      arguments: %{"path" => "current"}
    }

    :sys.replace_state(pid, fn state ->
      legacy_dialog =
        Ecrits.Agent.new_dialog!(%{
          turn_id: "legacy-turn",
          user: "",
          agent: "",
          items: persisted_items ++ named_non_tool_items ++ [persisted_doc_tool]
        })

      state
      |> Map.put(:transcript, [legacy_dialog])
      |> Map.update!(
        :current,
        &Map.put(&1, :items, current_items ++ named_non_tool_items ++ [current_doc_tool])
      )
    end)

    snapshot = Session.agent_snapshot(pid)

    assert [%Dialog{items: persisted_snapshot_items}] = snapshot.transcript

    assert Enum.map(persisted_snapshot_items, &{&1.role, &1.name}) == [
             {:file_activity, "read_text_file"},
             {:file_activity, "search_text_file"},
             {:file_activity, "edit_text_file"},
             {:user, "read_text_file"},
             {:agent, "search_text_file"},
             {:edit_preview, "edit_text_file"},
             {:tool, "doc.open_doc"}
           ]

    assert Enum.map(Enum.take(persisted_snapshot_items, 3), fn item ->
             {item.file_operation_id, item.operation, item.path, item.query, item.status}
           end) == [
             {"persisted-read_text_file", "read_text_file", "contract-0.hwpx.jsonl", nil,
              :completed},
             {"persisted-search_text_file", "search_text_file", "contract-1.hwpx.jsonl", "(인)",
              :completed},
             {"persisted-edit_text_file", "edit_text_file", "contract-2.hwpx.jsonl", nil,
              :completed}
           ]

    assert Enum.map(snapshot.current_turn.items, &{Map.get(&1, :role), Map.get(&1, :name)}) == [
             {:user, nil},
             {:file_activity, "read_text_file"},
             {:file_activity, "search_text_file"},
             {:file_activity, "edit_text_file"},
             {:user, "read_text_file"},
             {"agent", "search_text_file"},
             {:edit_preview, "edit_text_file"},
             {:tool, "doc.open_doc"}
           ]

    assert %{
             "current-doc-open" => %{
               name: "doc.open_doc",
               args: %{"path" => "current"}
             }
           } = snapshot.current_turn.active_tools

    assert Enum.count(persisted_snapshot_items, &(&1.role == :file_activity)) == 3

    assert Enum.count(snapshot.current_turn.items, fn item ->
             Map.get(item, :role) == :file_activity
           end) == 3

    refute Enum.any?(snapshot.current_turn.items, fn item ->
             Map.get(item, :role) == :tool and Map.get(item, :name) in file_operation_names
           end)

    send(pid, {
      :turn_event,
      turn_id,
      %{
        type: :file_operation_completed,
        file_operation_id: "current-read_text_file",
        tool_call_id: "current-read_text_file",
        operation: "read_text_file",
        path: "current-0.hwpx.jsonl",
        query: nil,
        kind: "read",
        status: :completed,
        result: %{}
      }
    })

    _ = :sys.get_state(pid)
    refreshed = Session.agent_snapshot(pid)

    assert Enum.count(refreshed.current_turn.items, fn item ->
             Map.get(item, :role) == :file_activity
           end) == 3

    assert %{status: :completed} =
             Enum.find(refreshed.current_turn.items, fn item ->
               Map.get(item, :file_operation_id) == "current-read_text_file"
             end)

    send(task, :go)
  end

  test "ACP file activity events persist in order and hydrate with their metadata" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn_id, status: :running}} =
      Session.send_turn(pid, nil, "inspect and update the contract")

    assert_receive {:agent_adapter_waiting, task}, 2_000

    read_started = %{
      type: :file_operation_started,
      file_operation_id: "file-read-1",
      tool_call_id: "file-read-1",
      operation: "read_text_file",
      path: "contract.hwpx.jsonl",
      query: nil,
      kind: "read",
      status: :running
    }

    send(pid, {:turn_event, turn_id, read_started})

    assert_receive {:agent_event,
                    %{
                      type: :file_operation_started,
                      turn_id: ^turn_id,
                      file_operation_id: "file-read-1",
                      operation: "read_text_file",
                      path: "contract.hwpx.jsonl",
                      status: :running
                    }},
                   2_000

    send(pid, {
      :turn_event,
      turn_id,
      Map.merge(read_started, %{
        type: :file_operation_completed,
        status: :completed,
        result: %{ok: true}
      })
    })

    search_started = %{
      type: :file_operation_started,
      file_operation_id: "file-search-1",
      tool_call_id: "file-search-1",
      operation: "search_text_file",
      path: "contract.hwpx.jsonl",
      query: "(인)",
      kind: "search",
      status: :running
    }

    send(pid, {:turn_event, turn_id, search_started})

    send(pid, {
      :turn_event,
      turn_id,
      Map.merge(search_started, %{
        type: :file_operation_failed,
        status: :failed,
        reason: "not found"
      })
    })

    edit_started = %{
      type: :file_operation_started,
      file_operation_id: "file-edit-1",
      tool_call_id: "file-edit-1",
      operation: "edit_text_file",
      path: "contract.hwpx.jsonl",
      query: nil,
      kind: "edit",
      status: :running
    }

    send(pid, {:turn_event, turn_id, edit_started})

    assert %{current_turn: %{items: current_items}} = Session.agent_snapshot(pid)

    assert Enum.map(
             Enum.filter(current_items, &(Map.get(&1, :role) == :file_activity)),
             &{&1.operation, &1.status, &1.path, &1.query}
           ) == [
             {"read_text_file", :completed, "contract.hwpx.jsonl", nil},
             {"search_text_file", :failed, "contract.hwpx.jsonl", "(인)"},
             {"edit_text_file", :running, "contract.hwpx.jsonl", nil}
           ]

    send(pid, {
      :turn_event,
      turn_id,
      Map.merge(edit_started, %{
        type: :file_operation_completed,
        status: :completed,
        result: %{edits: 2}
      })
    })

    _ = :sys.get_state(pid)
    send(task, :go)

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    assert [%Dialog{} = dialog] = Session.transcript(pid)

    file_items = Enum.filter(dialog.items, &(&1.role == :file_activity))

    assert Enum.map(file_items, &{&1.operation, &1.status, &1.path, &1.query}) == [
             {"read_text_file", :completed, "contract.hwpx.jsonl", nil},
             {"search_text_file", :failed, "contract.hwpx.jsonl", "(인)"},
             {"edit_text_file", :completed, "contract.hwpx.jsonl", nil}
           ]

    hydrated =
      dialog
      |> Ecrits.Agent.dump_dialog()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Ecrits.Agent.load_dialog!()

    assert Enum.map(
             Enum.filter(hydrated.items, &(&1.role == :file_activity)),
             &{&1.file_operation_id, &1.operation, &1.status, &1.path, &1.query}
           ) == [
             {"file-read-1", "read_text_file", :completed, "contract.hwpx.jsonl", nil},
             {"file-search-1", "search_text_file", :failed, "contract.hwpx.jsonl", "(인)"},
             {"file-edit-1", "edit_text_file", :completed, "contract.hwpx.jsonl", nil}
           ]
  end

  test "a file operation still running when its turn ends is durably failed" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn_id, status: :running}} =
      Session.send_turn(pid, nil, "inspect the mounted projection")

    assert_receive {:agent_adapter_waiting, task}, 2_000

    send(pid, {
      :turn_event,
      turn_id,
      %{
        type: :file_operation_started,
        file_operation_id: "dangling-read",
        operation: "read_text_file",
        path: "contract.hwpx.jsonl",
        kind: "read",
        status: :running
      }
    })

    _ = :sys.get_state(pid)
    send(task, :go)

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    assert [%Dialog{} = persisted_dialog] = :sys.get_state(pid).transcript

    assert %{status: :failed, reason: persisted_reason, body: persisted_body} =
             Enum.find(
               persisted_dialog.items,
               &(Map.get(&1, :file_operation_id) == "dangling-read")
             )

    assert persisted_reason == "Turn ended before the file operation finished."
    assert persisted_body == persisted_reason

    assert [%Dialog{} = dialog] = Session.transcript(pid)

    assert %{status: :failed, reason: reason, body: body} =
             Enum.find(dialog.items, &(Map.get(&1, :file_operation_id) == "dangling-read"))

    assert reason == "Turn ended before the file operation finished."
    assert body == reason

    hydrated =
      dialog
      |> Ecrits.Agent.dump_dialog()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Ecrits.Agent.load_dialog!()

    assert %{status: :failed, reason: ^reason, body: ^body} =
             Enum.find(hydrated.items, &(Map.get(&1, :file_operation_id) == "dangling-read"))
  end

  test "reverse-order legacy file rows dedupe without regressing terminal metadata" do
    {_id, pid} = start_blocking_session()

    terminal = %{
      role: :file_activity,
      file_operation_id: "legacy-search",
      operation: "search_text_file",
      status: :failed,
      output: "projection search failed"
    }

    late_running_envelope = %{
      role: :tool,
      tool_call_id: "legacy-search",
      name: "search_text_file",
      status: :running,
      input:
        Jason.encode!(%{
          "path" => "mounted/contract.hwpx.jsonl",
          "query" => "(인)"
        })
    }

    :sys.replace_state(pid, fn state ->
      dialog =
        Ecrits.Agent.new_dialog!(%{
          turn_id: "legacy-turn",
          user: "",
          agent: "",
          items: [terminal, late_running_envelope]
        })

      %{state | transcript: [dialog]}
    end)

    assert [%Dialog{items: items}] = Session.transcript(pid)
    assert [file_activity] = Enum.filter(items, &(&1.role == :file_activity))

    assert %{
             file_operation_id: "legacy-search",
             tool_call_id: "legacy-search",
             operation: "search_text_file",
             name: "search_text_file",
             status: :failed,
             path: "mounted/contract.hwpx.jsonl",
             query: "(인)",
             reason: "projection search failed",
             body: "projection search failed"
           } = file_activity
  end

  test "snapshot cursor covers emitted edit deltas and retains a bounded in-flight preview" do
    {_id, pid} = start_blocking_session()

    assert %{event_seq: 0} = Session.agent_snapshot(pid)

    # Simulate a Session process whose state predates the cursor field. Its first
    # post-upgrade event must start one process-owned sequence at 1.
    :sys.replace_state(pid, &Map.delete(&1, :event_seq))

    {:ok, %{id: turn_id, status: :running}} = Session.send_turn(pid, nil, "edit this")
    assert_receive {:agent_adapter_waiting, task}, 2_000

    assert_receive {:agent_event,
                    %{
                      type: :turn_started,
                      turn_id: ^turn_id,
                      event_seq: 1,
                      instance_id: instance_id
                    }},
                   2_000

    assert_receive {:agent_event,
                    %{type: :thread_title, event_seq: 2, instance_id: ^instance_id}},
                   2_000

    assert %{instance_id: ^instance_id} = Session.tool_context(pid)
    assert %{event_seq: 2, current_turn: %{edit_preview: nil}} = Session.agent_snapshot(pid)

    send(pid, {
      :turn_event,
      turn_id,
      %{type: :edit_delta, edit_id: "edit-1", path: "contract.hwpx", delta: "first "}
    })

    send(pid, {
      :turn_event,
      turn_id,
      %{type: :edit_delta, edit_id: "edit-1", path: "contract.hwpx", delta: "second"}
    })

    _ = :sys.get_state(pid)

    assert_receive {:agent_event, %{type: :edit_delta, delta: "first ", event_seq: 3}},
                   2_000

    assert_receive {:agent_event, %{type: :edit_delta, delta: "second", event_seq: 4}},
                   2_000

    assert %{
             event_seq: 4,
             current_turn: %{
               edit_preview: %{
                 edit_id: "edit-1",
                 path: "contract.hwpx",
                 text: "first second",
                 delta_count: 2
               }
             }
           } = Session.agent_snapshot(pid)

    tail = String.duplicate("z", 5_001)

    send(pid, {
      :turn_event,
      turn_id,
      %{type: :edit_delta, edit_id: "edit-2", path: "appendix.hwpx", delta: tail}
    })

    _ = :sys.get_state(pid)

    assert_receive {:agent_event, %{type: :edit_delta, edit_id: "edit-2", event_seq: 5}},
                   2_000

    assert %{
             event_seq: 5,
             current_turn: %{
               edit_preview: %{
                 edit_id: "edit-2",
                 path: "appendix.hwpx",
                 text: "..." <> bounded_tail,
                 delta_count: 1
               }
             }
           } = Session.agent_snapshot(pid)

    assert String.length(bounded_tail) == 5_000
    assert bounded_tail == String.duplicate("z", 5_000)

    send(task, :go)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000
  end

  test "a delayed preview for a completed turn does not attach to the queued turn now running" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn1, status: :running}} = Session.send_turn(pid, nil, "first edit")
    assert_receive {:agent_adapter_waiting, task1}, 2_000

    {:ok, %{id: turn2, status: :queued}} = Session.send_turn(pid, nil, "second edit")
    assert_receive {:agent_event, %{type: :turn_queued, turn_id: ^turn2}}, 2_000

    send(task1, :go)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000
    assert_receive {:agent_adapter_waiting, task2}, 2_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000

    delayed_preview = %{
      role: :edit_preview,
      status: :sent,
      turn_id: turn1,
      edit_id: "edit-from-first-turn",
      document_id: "document-from-first-turn",
      document_path: "first.hwpx",
      preview_snapshot: %{
        id: "snapshot-from-first-turn",
        document_id: "document-from-first-turn"
      }
    }

    :ok = Session.append_transcript_item(pid, delayed_preview)

    assert [%Dialog{turn_id: ^turn1, items: first_items}] = Session.transcript(pid)
    assert Enum.any?(first_items, &(&1.role == :edit_preview))

    send(task2, :go)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn2}}, 2_000

    assert [
             %Dialog{turn_id: ^turn1, items: replay_first_items},
             %Dialog{turn_id: ^turn2, items: replay_second_items}
           ] = dialogs = Session.transcript(pid)

    assert Enum.any?(replay_first_items, &(&1.role == :edit_preview))
    refute Enum.any?(replay_second_items, &(&1.role == :edit_preview))

    replayed =
      Enum.map(dialogs, fn dialog ->
        dialog
        |> Ecrits.Agent.dump_dialog()
        |> Jason.encode!()
        |> Jason.decode!()
        |> Ecrits.Agent.load_dialog!()
      end)

    assert Enum.map(replayed, & &1.turn_id) == [turn1, turn2]

    assert [preview] =
             replayed
             |> hd()
             |> Map.fetch!(:items)
             |> Enum.filter(&(&1.role == :edit_preview))

    assert Ecrits.Agent.edit_preview_identity(preview, turn1) ==
             {turn1, "edit-from-first-turn", "document-from-first-turn"}
  end

  @tag :edit_failure
  test "completed preview retries persist one descriptor and replay its exact payload" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn_id, status: :running}} =
      Session.send_turn(pid, nil, "fill the delivery place")

    assert_receive {:agent_adapter_waiting, task}, 2_000
    send(task, :go)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    highlights = [
      %{
        "kind" => "text",
        "op" => "insert_text",
        "ref" => %{"section" => 0, "paragraph" => 40, "offset" => 0},
        "text" => " ◇ 납품장소 : 미기재",
        "length" => 13,
        "offset" => 0
      }
    ]

    descriptor = %{
      role: :edit_preview,
      status: :sent,
      turn_id: turn_id,
      edit_id: "vfs-edit-601",
      document_id: "contract-document",
      document_path: "contract.hwp",
      hash: "same-highlight-hash",
      summary: "1 change · insert_text",
      highlights: highlights,
      version: %{byte_size: 138_240, mtime: 1},
      preview_snapshot: %{id: "snapshot-a", document_id: "contract-document"},
      preview_identity: %{
        turn_id: turn_id,
        edit_id: "vfs-edit-601",
        document_id: "contract-document",
        snapshot_id: "snapshot-a"
      }
    }

    Enum.each(["snapshot-a", "snapshot-b", "snapshot-c", "snapshot-c"], fn snapshot_id ->
      retry =
        descriptor
        |> put_in([:preview_snapshot, :id], snapshot_id)
        |> put_in([:preview_identity, :snapshot_id], snapshot_id)
        |> put_in([:version, :mtime], :erlang.phash2(snapshot_id))

      assert :ok = Session.append_transcript_item(pid, retry)
    end)

    # Exercise the same JSON dump/load boundary used by the handoff store when a
    # rail is replayed after re-attachment.
    assert [dialog] = Session.durable_snapshot(pid).transcript

    replayed =
      dialog
      |> Jason.encode!()
      |> Jason.decode!()
      |> Ecrits.Agent.load_dialog!()

    assert [preview] = Enum.filter(replayed.items, &(&1.role == :edit_preview))
    assert preview.summary == "1 change · insert_text"
    assert preview.highlights == highlights
    assert preview.hash == "same-highlight-hash"
    assert preview.preview_snapshot["id"] == "snapshot-c"
    assert preview.preview_identity["snapshot_id"] == "snapshot-c"
  end

  test "reasoning and shell execution persist in their actual event order" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn_id, status: :running}} = Session.send_turn(pid, nil, "inspect files")
    assert_receive {:agent_adapter_waiting, task}, 2_000

    send(pid, {:turn_event, turn_id, %{type: :reasoning_delta, delta: "Plan command"}})

    send(pid, {
      :turn_event,
      turn_id,
      %{
        type: :tool_call_started,
        tool_call_id: "shell-1",
        name: "Bash",
        kind: "execute",
        arguments: %{"command" => "pwd"}
      }
    })

    send(pid, {
      :turn_event,
      turn_id,
      %{
        type: :tool_call_completed,
        tool_call_id: "shell-1",
        name: "Bash",
        kind: "execute",
        result: %{"output" => "/tmp"}
      }
    })

    send(pid, {:turn_event, turn_id, %{type: :reasoning_delta, delta: "Read output"}})
    send(pid, {:turn_event, turn_id, %{type: :text_delta, delta: "Finished "}})
    _ = :sys.get_state(pid)
    send(task, :go)

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    assert [%Dialog{items: items}] = Session.transcript(pid)

    assert [
             %{role: :user},
             %{role: :thinking, body: "Plan command", segment: 0},
             %{role: :tool, name: "Bash", kind: "execute", status: :completed},
             %{role: :thinking, body: "Read output", segment: 1},
             %{role: :agent, body: "Finished ok"}
           ] = items
  end

  test "a queued follow-up drains as an addendum, not a standalone newcomer prompt" do
    {_id, pid} = start_blocking_session(%{extra_opts: [report_prompts: true, echo_opts: true]})

    {:ok, %{id: turn1, status: :running}} =
      Session.send_turn(pid, nil, "try fill all fields on this document")

    assert_receive {:fake_acp_prompt, _session_id1, prompt1}, 2_000
    assert prompt1 =~ "try fill all fields on this document"
    assert_receive {:agent_adapter_waiting, task1}, 2_000

    {:ok, %{id: turn2, status: :queued}} =
      Session.send_turn(pid, nil, "with reasonable defaults")

    assert_receive {:agent_event, %{type: :turn_queued, turn_id: ^turn2}}, 2_000

    send(task1, :go)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000
    assert_receive {:fake_acp_prompt, _session_id2, prompt2}, 2_000

    assert prompt2 =~ "Continue previous task."
    assert prompt2 =~ "Previous: try fill all fields on this document"
    assert prompt2 =~ "Addendum: with reasonable defaults"

    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000
    assert_receive {:agent_adapter_waiting, task2}, 2_000
    send(task2, :go)

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn2}}, 2_000

    assert [
             %{user: "try fill all fields on this document"},
             %{user: "with reasonable defaults"}
           ] = Session.transcript(pid)
  end

  test "queued turn document context does not retarget the running turn" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn1, status: :running}} =
      Session.send_turn(pid, nil, "read first",
        document_path: "first.hwp",
        pool_document_id: "d_hwp_first"
      )

    assert_receive {:agent_adapter_waiting, task1}, 2_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn1}}, 2_000

    assert %{
             active_doc: "d_hwp_first",
             document_path: "first.hwp"
           } = Session.tool_context(pid)

    {:ok, %{id: turn2, status: :queued}} =
      Session.send_turn(pid, nil, "read second",
        document_path: "second.hwp",
        pool_document_id: "d_hwp_second"
      )

    assert_receive {:agent_event, %{type: :turn_queued, turn_id: ^turn2}}, 2_000

    assert %{
             active_doc: "d_hwp_first",
             document_path: "first.hwp"
           } = Session.tool_context(pid)

    send(task1, :go)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000
    assert_receive {:agent_adapter_waiting, task2}, 2_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000

    assert %{
             active_doc: "d_hwp_second",
             document_path: "second.hwp"
           } = Session.tool_context(pid)

    send(task2, :go)
  end

  test "live option updates do not retarget document context" do
    id = "queue-doc-update-" <> Ecto.UUID.generate()

    start_supervised!(
      {Session,
       [
         id: id,
         ctx: nil,
         provider: %{id: "codex"},
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         adapter_opts: [
           exmcp_adapter: EcritsWeb.FakeAcpAdapter,
           script: [{:text_delta, "ok"}]
         ],
         workspace_root: File.cwd!(),
         document_path: "seed.hwp",
         pool_document_id: "d_hwp_seed",
         mcp_servers: []
       ]}
    )

    :ok = Ecrits.AcpAgent.subscribe(id)
    pid = Session.whereis(id)

    assert %{
             active_doc: "d_hwp_seed",
             document_path: "seed.hwp"
           } = Session.tool_context(pid)

    :ok =
      Session.update_options(pid,
        model: "changed-model",
        document_path: "other.hwp",
        pool_document_id: "d_hwp_other"
      )

    assert %{
             active_doc: "d_hwp_seed",
             document_path: "seed.hwp"
           } = Session.tool_context(pid)

    {:ok, %{id: turn_id, status: :running}} =
      Session.send_turn(pid, nil, "read turn doc",
        document_path: "turn.hwp",
        pool_document_id: "d_hwp_turn"
      )

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    assert %{
             active_doc: "d_hwp_turn",
             document_path: "turn.hwp"
           } = Session.tool_context(pid)
  end

  test "re-Enter waits for the cancelled task to die before running the queue head" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn1}} = Session.send_turn(pid, nil, "first")
    assert_receive {:agent_adapter_waiting, _adapter_task1}, 2_000

    %{current: %{task_pid: old_task_pid}} = :sys.get_state(pid)
    :erlang.suspend_process(old_task_pid)

    {:ok, %{id: turn2, status: :queued}} = Session.send_turn(pid, nil, "second")
    assert_receive {:agent_event, %{type: :turn_queued}}, 2_000

    try do
      assert {:ok, %{id: ^turn2, status: :queued}} = Session.flush_queue(pid, nil)
      assert_receive {:agent_event, %{type: :turn_cancelled, turn_id: ^turn1}}, 2_000

      assert %{
               current: nil,
               cancellation_fence: %{task_pid: ^old_task_pid, mode: :drain},
               terminal_finalization: nil
             } = :sys.get_state(pid)

      refute_receive {:agent_event, %{type: :turn_started, turn_id: ^turn2}}, 100

      old_task_monitor = Process.monitor(old_task_pid)
      Process.exit(old_task_pid, :kill)
      assert_receive {:DOWN, ^old_task_monitor, :process, ^old_task_pid, :killed}, 2_000

      assert_receive {:agent_adapter_waiting, task2}, 2_000
      assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000
      send(task2, :go)
    after
      if Process.alive?(old_task_pid), do: :erlang.resume_process(old_task_pid)
    end
  end

  test "cancel stops only the current turn and leaves queued follow-ups idle" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn1, status: :running}} = Session.send_turn(pid, nil, "first")
    assert_receive {:agent_adapter_waiting, task1}, 2_000

    {:ok, %{id: turn2, status: :queued}} = Session.send_turn(pid, nil, "second")
    assert_receive {:agent_event, %{type: :turn_queued, turn_id: ^turn2}}, 2_000

    %{current: %{task_pid: old_task_pid}} = :sys.get_state(pid)
    old_task_monitor = Process.monitor(old_task_pid)

    assert {:ok, %{id: ^turn1, status: :cancelled}} = Session.cancel(pid, nil, turn1)
    assert_receive {:agent_event, %{type: :turn_cancelled, turn_id: ^turn1}}, 2_000

    assert {:ok, %{current_turn: nil}} = Session.snapshot(pid)

    assert %{status: :idle, pending: 1, queued: [%{turn_id: ^turn2, input: "second"}]} =
             Session.agent_snapshot(pid)

    send(task1, :go)
    assert_receive {:DOWN, ^old_task_monitor, :process, ^old_task_pid, _reason}, 2_000
    _ = :sys.get_state(pid)

    assert {:ok, %{id: ^turn2, status: :running}} = Session.flush_queue(pid, nil)
    assert_receive {:agent_adapter_waiting, task2}, 2_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000

    send(task2, :go)
  end

  test "turn commit fence serializes cancellation and rejects a cancelled owner" do
    {_id, pid} = start_blocking_session()
    {:ok, %{id: turn_id, status: :running}} = Session.send_turn(pid, nil, "edit")
    assert_receive {:agent_adapter_waiting, _adapter_task}, 2_000

    context = Session.tool_context(pid)

    identity = %{
      agent_id: context.agent_id,
      instance_id: context.instance_id,
      turn_id: turn_id
    }

    owner = self()

    commit =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               Session.with_turn_commit(pid, identity, fn ->
                 send(owner, {:commit_fence_acquired, self()})

                 receive do
                   :release_commit -> :committed
                 end
               end)

             send(owner, {:commit_fence_result, result})
           end},
          id: make_ref()
        )
      )

    assert_receive {:commit_fence_acquired, ^commit}

    _cancel =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             send(owner, {:cancel_fence_result, Session.cancel(pid, nil, turn_id)})
           end},
          id: make_ref()
        )
      )

    refute_receive {:cancel_fence_result, _result}, 50
    send(commit, :release_commit)
    assert_receive {:commit_fence_result, :committed}

    assert_receive {:cancel_fence_result, {:ok, %{id: ^turn_id, status: :cancelled}}},
                   2_000

    assert {:error, :turn_invalidated} =
             Session.with_turn_commit(pid, identity, fn -> :must_not_commit end)
  end

  test "natural completion waits for the commit lock, retries a crashed lock owner, and then drains" do
    {_id, pid} = start_blocking_session()
    {:ok, %{id: turn1}} = Session.send_turn(pid, nil, "first")
    assert_receive {:agent_adapter_waiting, adapter_task1}, 2_000
    {:ok, %{id: turn2, status: :queued}} = Session.send_turn(pid, nil, "second")

    identity = turn_identity(pid, turn1)
    owner = self()

    commit =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               Session.with_turn_commit(pid, identity, fn ->
                 send(owner, {:terminal_race_commit_acquired, self()})

                 receive do
                   :release_terminal_race_commit -> :committed
                 end
               end)

             send(owner, {:terminal_race_commit_result, result})
           end},
          id: make_ref()
        )
      )

    assert_receive {:terminal_race_commit_acquired, ^commit}
    send(adapter_task1, :go)

    state =
      await_session_state(pid, fn state ->
        match?(
          %{current: %{turn_id: ^turn1}, terminal_transition: %{turn_id: ^turn1}},
          state
        )
      end)

    assert %{phase: :waiting, outcome: :completed, lock_pid: first_lock_pid} =
             state.terminal_transition

    refute_received {:agent_event, %{type: :turn_completed, turn_id: ^turn1}}
    refute_received {:agent_event, %{type: :turn_started, turn_id: ^turn2}}

    first_lock_ref = Process.monitor(first_lock_pid)
    Process.exit(first_lock_pid, :kill)
    assert_receive {:DOWN, ^first_lock_ref, :process, ^first_lock_pid, :killed}

    state =
      await_session_state(pid, fn state ->
        match?(
          %{
            terminal_transition: %{
              turn_id: ^turn1,
              phase: :waiting,
              lock_pid: lock_pid
            }
          }
          when lock_pid != first_lock_pid,
          state
        )
      end)

    token = state.terminal_transition.token
    replacement_lock_pid = state.terminal_transition.lock_pid

    send(pid, {:turn_failed, turn1, :duplicate_terminal_edge})
    send(pid, {:finish_turn_done, turn1})

    state = :sys.get_state(pid)

    assert %{token: ^token, lock_pid: ^replacement_lock_pid, outcome: :completed} =
             state.terminal_transition

    refute_received {:agent_event, %{type: :turn_failed, turn_id: ^turn1}}
    refute_received {:agent_event, %{type: :turn_started, turn_id: ^turn2}}

    send(commit, :release_terminal_race_commit)
    assert_receive {:terminal_race_commit_result, :committed}, 2_000
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000
    assert_receive {:agent_adapter_waiting, adapter_task2}, 2_000
    send(adapter_task2, :go)
  end

  test "turn failure cannot overlap a commit callback or start the queued turn" do
    {_id, pid} = start_blocking_session()
    {:ok, %{id: turn1}} = Session.send_turn(pid, nil, "first")
    assert_receive {:agent_adapter_waiting, _adapter_task1}, 2_000
    {:ok, %{id: turn2, status: :queued}} = Session.send_turn(pid, nil, "second")

    {commit, identity} = hold_turn_commit(pid, turn1)
    assert_receive {:held_turn_commit_acquired, ^commit, ^turn1}

    send(pid, {:turn_failed, turn1, :expected_failure})

    assert %{
             current: %{turn_id: ^turn1},
             terminal_transition: %{
               turn_id: ^turn1,
               phase: :waiting,
               outcome: {:failed, :expected_failure, :close}
             }
           } = await_terminal_transition(pid, turn1)

    assert Session.tool_context(pid).turn_id == identity.turn_id
    refute_received {:agent_event, %{type: :turn_failed, turn_id: ^turn1}}
    refute_received {:agent_event, %{type: :turn_started, turn_id: ^turn2}}

    send(commit, :release_held_turn_commit)
    assert_receive {:held_turn_commit_result, ^turn1, :committed}, 2_000
    assert_receive {:agent_event, %{type: :turn_failed, turn_id: ^turn1}}, 2_000
    assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000
    assert_receive {:agent_adapter_waiting, adapter_task2}, 2_000
    send(adapter_task2, :go)
  end

  test "public cancel and prepare_restart win safely when their lock already owns a recorded transition" do
    for api <- [:cancel, :prepare_restart] do
      {id, pid} = start_blocking_session()
      {:ok, %{id: turn1}} = Session.send_turn(pid, nil, "first")
      assert_receive {:agent_adapter_waiting, adapter_task1}, 2_000
      {:ok, %{id: turn2, status: :queued}} = Session.send_turn(pid, nil, "second")

      identity = turn_identity(pid, turn1)
      owner = self()

      commit =
        start_supervised!(
          Supervisor.child_spec(
            {Task,
             fn ->
               result =
                 Session.with_turn_commit(pid, identity, fn ->
                   send(owner, {:terminal_api_commit_acquired, self(), api, turn1})

                   receive do
                     :run_terminal_api ->
                       api_result =
                         case api do
                           :cancel -> Session.cancel(pid, nil, turn1)
                           :prepare_restart -> Session.prepare_restart(pid, File.cwd!())
                         end

                       send(owner, {:terminal_api_result, api, turn1, api_result})
                       :committed
                   end
                 end)

               send(owner, {:terminal_api_commit_result, api, turn1, result})
             end},
            id: make_ref()
          )
        )

      assert_receive {:terminal_api_commit_acquired, ^commit, ^api, ^turn1}
      send(pid, {:finish_turn_done, turn1})

      assert %{
               current: %{turn_id: ^turn1},
               terminal_transition: %{turn_id: ^turn1, phase: :waiting, outcome: :completed}
             } = await_terminal_transition(pid, turn1)

      send(commit, :run_terminal_api)

      case api do
        :cancel ->
          assert_receive {:terminal_api_result, :cancel, ^turn1,
                          {:ok, %{id: ^turn1, status: :cancelled}}},
                         2_000

        :prepare_restart ->
          assert_receive {:terminal_api_result, :prepare_restart, ^turn1,
                          {:pending, {^id, instance_id, ^turn1}}},
                         2_000

          assert is_binary(instance_id)
      end

      assert_receive {:terminal_api_commit_result, ^api, ^turn1, :committed}, 2_000
      assert_receive {:agent_event, %{type: :turn_cancelled, turn_id: ^turn1}}, 2_000
      refute_received {:agent_event, %{type: :turn_completed, turn_id: ^turn1}}
      refute_received {:agent_event, %{type: :turn_started, turn_id: ^turn2}}

      assert %{current: nil, terminal_transition: nil, queue: [%{turn_id: ^turn2}]} =
               :sys.get_state(pid)

      send(adapter_task1, :go)
    end
  end

  test "abnormal guardian and worker DOWN wait for the commit lock before advancing" do
    for crashed_process <- [:task, :worker] do
      {_id, pid} = start_blocking_session()
      {:ok, %{id: turn1}} = Session.send_turn(pid, nil, "first")
      assert_receive {:agent_adapter_waiting, _adapter_task1}, 2_000
      {:ok, %{id: turn2, status: :queued}} = Session.send_turn(pid, nil, "second")

      {commit, _identity} = hold_turn_commit(pid, turn1)
      assert_receive {:held_turn_commit_acquired, ^commit, ^turn1}

      current = :sys.get_state(pid).current

      crashed_pid =
        case crashed_process do
          :task -> current.task_pid
          :worker -> current.worker_pid
        end

      Process.exit(crashed_pid, :kill)

      assert %{
               current: %{turn_id: ^turn1},
               terminal_transition: %{
                 turn_id: ^turn1,
                 phase: :waiting,
                 outcome: {:failed, _reason, :cancel_and_close}
               }
             } = await_terminal_transition(pid, turn1)

      refute_received {:agent_event, %{type: :turn_failed, turn_id: ^turn1}}
      refute_received {:agent_event, %{type: :turn_started, turn_id: ^turn2}}

      send(commit, :release_held_turn_commit)
      assert_receive {:held_turn_commit_result, ^turn1, :committed}, 2_000
      assert_receive {:agent_event, %{type: :turn_failed, turn_id: ^turn1}}, 2_000
      assert_receive {:agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000
      assert_receive {:agent_adapter_waiting, adapter_task2}, 2_000
      send(adapter_task2, :go)
    end
  end

  test "flush_queue on an empty queue returns {:error, :empty_queue}" do
    {_id, pid} = start_blocking_session()
    assert {:error, :empty_queue} = Session.flush_queue(pid, nil)
  end

  test "a multi-modal block-list input runs end-to-end (text + image)" do
    id = "queue-mm-" <> Ecto.UUID.generate()

    start_supervised!(
      {Session,
       [
         id: id,
         ctx: nil,
         provider: %{id: "codex"},
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         adapter_opts: [
           exmcp_adapter: EcritsWeb.FakeAcpAdapter,
           test_pid: self(),
           script: [{:text_delta, "saw it"}]
         ],
         workspace_root: File.cwd!(),
         mcp_servers: []
       ]}
    )

    :ok = Ecrits.AcpAgent.subscribe(id)
    pid = Session.whereis(id)

    input = [
      %{type: :text, text: "describe this image"},
      %{type: :image, mime_type: "image/png", data: "AAAA"}
    ]

    {:ok, %{id: turn_id, status: :running}} = Session.send_turn(pid, nil, input)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    # The transcript records the typed text (the display text of the modality).
    [%{user: user}] = Session.transcript(pid)
    assert user == "describe this image"

    # The auto-title derives from the typed text too.
    assert Session.title(pid) == "describe this image"
  end

  test "a prompt with no first ACP activity fails before the long idle window" do
    id = "queue-initial-stall-" <> Ecto.UUID.generate()

    start_supervised!(
      {Session,
       [
         id: id,
         ctx: nil,
         provider: %{id: "codex"},
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         adapter_opts: [
           exmcp_adapter: EcritsWeb.FakeAcpAdapter,
           test_pid: self(),
           wait_for: :never_released,
           initial_activity_timeout: 25,
           script: [{:text_delta, "too late"}]
         ],
         workspace_root: File.cwd!(),
         mcp_servers: []
       ]}
    )

    :ok = Ecrits.AcpAgent.subscribe(id)
    pid = Session.whereis(id)

    {:ok, %{id: turn_id, status: :running}} = Session.send_turn(pid, nil, "stall")
    assert_receive {:agent_adapter_waiting, _task_pid}, 2_000

    assert_receive {:agent_event, %{type: :turn_failed, turn_id: ^turn_id, reason: reason}},
                   1_000

    assert reason =~ "no activity for 25ms"
  end

  test "session-routed ACP updates keep the stream task from false-stalling" do
    id = "queue-session-update-heartbeat-" <> Ecto.UUID.generate()

    start_supervised!(
      {Session,
       [
         id: id,
         ctx: nil,
         provider: %{id: "codex"},
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         adapter_opts: [
           exmcp_adapter: EcritsWeb.FakeAcpAdapter,
           test_pid: self(),
           wait_for: :release_prompt,
           initial_activity_timeout: 50,
           script: [{:text_delta, "done"}]
         ],
         workspace_root: File.cwd!(),
         mcp_servers: []
       ]}
    )

    :ok = Ecrits.AcpAgent.subscribe(id)
    pid = Session.whereis(id)

    {:ok, %{id: turn_id, status: :running}} = Session.send_turn(pid, nil, "tool heartbeat")
    assert_receive {:agent_adapter_waiting, task_pid}, 2_000

    send(pid, {:acp_session_update, "fake-session", fake_tool_update("doc.render")})

    assert_receive {:agent_event,
                    %{type: :tool_call_started, turn_id: ^turn_id, name: "doc.render"}},
                   2_000

    refute_receive {:agent_event, %{type: :turn_failed, turn_id: ^turn_id}}, 150

    send(task_pid, :release_prompt)
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000
  end

  test "an invalid multi-modal input fails fast at the boundary" do
    {_id, pid} = start_blocking_session()
    assert {:error, {:invalid_input, :empty_input}} = Session.send_turn(pid, nil, [])

    assert {:error, {:invalid_input, {:unknown_block_type, "bogus"}}} =
             Session.send_turn(pid, nil, [%{"type" => "bogus"}])
  end

  defp turn_identity(pid, turn_id) do
    context = Session.tool_context(pid)

    %{
      agent_id: context.agent_id,
      instance_id: context.instance_id,
      turn_id: turn_id
    }
  end

  defp hold_turn_commit(pid, turn_id) do
    identity = turn_identity(pid, turn_id)
    owner = self()

    task =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             result =
               Session.with_turn_commit(pid, identity, fn ->
                 send(owner, {:held_turn_commit_acquired, self(), turn_id})

                 receive do
                   :release_held_turn_commit -> :committed
                 end
               end)

             send(owner, {:held_turn_commit_result, turn_id, result})
           end},
          id: make_ref()
        )
      )

    {task, identity}
  end

  defp await_terminal_transition(pid, turn_id) do
    await_session_state(pid, fn state ->
      match?(%{terminal_transition: %{turn_id: ^turn_id}}, state)
    end)
  end

  defp await_session_state(pid, predicate, attempts \\ 1_000)

  defp await_session_state(pid, predicate, attempts) when attempts > 0 do
    state = :sys.get_state(pid)

    if predicate.(state) do
      state
    else
      await_session_state(pid, predicate, attempts - 1)
    end
  end

  defp await_session_state(_pid, _predicate, 0) do
    flunk("session did not reach the expected synchronized state")
  end

  defp fake_tool_update(name) do
    %{
      "sessionUpdate" => "tool_call",
      "toolCallId" => "tool-heartbeat",
      "toolName" => name,
      "rawInput" => %{"document" => "d_pptx_test"}
    }
  end
end
