defmodule Ecrits.Local.AcpAgent.SessionQueueTest do
  @moduledoc """
  Phase 5: the `send_turn` FIFO queue + multi-modal input seam at the `Session`
  level, driven through the real `ExMCP.ACP` stack via `EcritsWeb.FakeAcpAdapter`.

  The legacy behaviour was "a mid-turn send cancels the running turn and starts a
  new one". Phase 5 replaces that with an ENQUEUE: a mid-turn send is queued and
  drains in order when the running turn finishes. A re-Enter (`flush_queue/2`)
  promotes the head immediately.
  """

  use ExUnit.Case, async: false

  alias Ecrits.Local.AcpAgent.Session

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

    :ok = Ecrits.Local.AcpAgent.subscribe(id)
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
    {:ok, %{id: _turn2, status: :queued}} = Session.send_turn(pid, nil, "second")
    assert_receive {:local_agent_event, %{type: :turn_queued, pending: 1}}, 2_000
    refute_received {:local_agent_event, %{type: :turn_cancelled}}

    # Release turn 1 → it completes → the queue head (turn 2) drains and starts.
    send(task1, :go)
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000
    assert_receive {:local_agent_adapter_waiting, task2}, 2_000
    assert_receive {:local_agent_event, %{type: :turn_started}}, 2_000

    send(task2, :go)
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

    :ok = Ecrits.Local.AcpAgent.subscribe(id)
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

  test "an invalid multi-modal input fails fast at the boundary" do
    {_id, pid} = start_blocking_session()
    assert {:error, {:invalid_input, :empty_input}} = Session.send_turn(pid, nil, [])

    assert {:error, {:invalid_input, {:unknown_block_type, "bogus"}}} =
             Session.send_turn(pid, nil, [%{"type" => "bogus"}])
  end
end
