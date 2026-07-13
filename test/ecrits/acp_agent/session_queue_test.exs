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
    assert_receive {:local_agent_adapter_waiting, task1}, 2_000
    assert_receive {:local_agent_event, %{type: :turn_started, turn_id: ^turn1}}, 2_000

    # A second send while turn 1 is in flight ENQUEUES (status :queued) — turn 1
    # is NOT cancelled.
    {:ok, %{id: turn2, status: :queued}} = Session.send_turn(pid, nil, "second")

    assert_receive {:local_agent_event,
                    %{type: :turn_queued, pending: 1, input: "second", picks: []}},
                   2_000

    assert %{pending: 1, queued: [%{turn_id: ^turn2, input: "second", picks: []}]} =
             Session.agent_snapshot(pid)

    refute_received {:local_agent_event, %{type: :turn_cancelled}}

    # Release turn 1 → it completes → the queue head (turn 2) drains and starts.
    send(task1, :go)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000
    assert_receive {:local_agent_adapter_waiting, task2}, 2_000
    assert_receive {:local_agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000

    send(task2, :go)
  end

  test "a queued follow-up drains as an addendum, not a standalone newcomer prompt" do
    {_id, pid} = start_blocking_session(%{extra_opts: [report_prompts: true, echo_opts: true]})

    {:ok, %{id: turn1, status: :running}} =
      Session.send_turn(pid, nil, "try fill all fields on this document")

    assert_receive {:fake_acp_prompt, _session_id1, prompt1}, 2_000
    assert prompt1 =~ "try fill all fields on this document"
    assert_receive {:local_agent_adapter_waiting, task1}, 2_000

    {:ok, %{id: turn2, status: :queued}} =
      Session.send_turn(pid, nil, "with reasonable defaults")

    assert_receive {:local_agent_event, %{type: :turn_queued, turn_id: ^turn2}}, 2_000

    send(task1, :go)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000
    assert_receive {:fake_acp_prompt, _session_id2, prompt2}, 2_000

    assert prompt2 =~ "Continue previous task."
    assert prompt2 =~ "Previous: try fill all fields on this document"
    assert prompt2 =~ "Addendum: with reasonable defaults"

    assert_receive {:local_agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000
    assert_receive {:local_agent_adapter_waiting, task2}, 2_000
    send(task2, :go)

    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn2}}, 2_000

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

    assert_receive {:local_agent_adapter_waiting, task1}, 2_000
    assert_receive {:local_agent_event, %{type: :turn_started, turn_id: ^turn1}}, 2_000

    assert %{
             active_doc: "d_hwp_first",
             document_path: "first.hwp"
           } = Session.tool_context(pid)

    {:ok, %{id: turn2, status: :queued}} =
      Session.send_turn(pid, nil, "read second",
        document_path: "second.hwp",
        pool_document_id: "d_hwp_second"
      )

    assert_receive {:local_agent_event, %{type: :turn_queued, turn_id: ^turn2}}, 2_000

    assert %{
             active_doc: "d_hwp_first",
             document_path: "first.hwp"
           } = Session.tool_context(pid)

    send(task1, :go)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000
    assert_receive {:local_agent_adapter_waiting, task2}, 2_000
    assert_receive {:local_agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000

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

    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

    assert %{
             active_doc: "d_hwp_turn",
             document_path: "turn.hwp"
           } = Session.tool_context(pid)
  end

  test "re-Enter flushes the queue head NOW (cancel current + run head)" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn1}} = Session.send_turn(pid, nil, "first")
    assert_receive {:local_agent_adapter_waiting, task1}, 2_000

    {:ok, %{status: :queued}} = Session.send_turn(pid, nil, "second")
    assert_receive {:local_agent_event, %{type: :turn_queued}}, 2_000

    # Flush: the running turn is cancelled and the head launches immediately,
    # without waiting for turn 1 to finish.
    {:ok, %{status: :running}} = Session.flush_queue(pid, nil)
    assert_receive {:local_agent_event, %{type: :turn_cancelled, turn_id: ^turn1}}, 2_000
    assert_receive {:local_agent_adapter_waiting, task2}, 2_000

    # The cancelled task winds down; release the flushed head.
    send(task1, :go)
    send(task2, :go)
  end

  test "cancel stops only the current turn and leaves queued follow-ups idle" do
    {_id, pid} = start_blocking_session()

    {:ok, %{id: turn1, status: :running}} = Session.send_turn(pid, nil, "first")
    assert_receive {:local_agent_adapter_waiting, task1}, 2_000

    {:ok, %{id: turn2, status: :queued}} = Session.send_turn(pid, nil, "second")
    assert_receive {:local_agent_event, %{type: :turn_queued, turn_id: ^turn2}}, 2_000

    assert {:ok, %{id: ^turn1, status: :cancelled}} = Session.cancel(pid, nil, turn1)
    assert_receive {:local_agent_event, %{type: :turn_cancelled, turn_id: ^turn1}}, 2_000

    assert {:ok, %{current_turn: nil}} = Session.snapshot(pid)

    assert %{status: :idle, pending: 1, queued: [%{turn_id: ^turn2, input: "second"}]} =
             Session.agent_snapshot(pid)

    send(task1, :go)

    assert {:ok, %{id: ^turn2, status: :running}} = Session.flush_queue(pid, nil)
    assert_receive {:local_agent_adapter_waiting, task2}, 2_000
    assert_receive {:local_agent_event, %{type: :turn_started, turn_id: ^turn2}}, 2_000

    send(task2, :go)
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
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000

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
    assert_receive {:local_agent_adapter_waiting, _task_pid}, 2_000

    assert_receive {:local_agent_event, %{type: :turn_failed, turn_id: ^turn_id, reason: reason}},
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
    assert_receive {:local_agent_adapter_waiting, task_pid}, 2_000

    send(pid, {:acp_session_update, "fake-session", fake_tool_update("doc.render")})

    assert_receive {:local_agent_event,
                    %{type: :tool_call_started, turn_id: ^turn_id, name: "doc.render"}},
                   2_000

    refute_receive {:local_agent_event, %{type: :turn_failed, turn_id: ^turn_id}}, 150

    send(task_pid, :release_prompt)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000
  end

  test "an invalid multi-modal input fails fast at the boundary" do
    {_id, pid} = start_blocking_session()
    assert {:error, {:invalid_input, :empty_input}} = Session.send_turn(pid, nil, [])

    assert {:error, {:invalid_input, {:unknown_block_type, "bogus"}}} =
             Session.send_turn(pid, nil, [%{"type" => "bogus"}])
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
