defmodule Contract.Local.Agent.Adapters.CodexAppServerTest do
  use ExUnit.Case, async: false

  alias Contract.Local.Agent.Adapters.CodexAppServer

  test "streams deltas that arrive before turn start response" do
    executable = delayed_turn_start_response_stub!()

    turn = %{
      id: "turn-#{Ecto.UUID.generate()}",
      session_id: "session-#{Ecto.UUID.generate()}",
      input: "hello",
      workspace_root: File.cwd!(),
      document_id: nil,
      tools: [],
      tool_context: %{}
    }

    started_at = System.monotonic_time(:millisecond)

    assert {:ok, stream} =
             CodexAppServer.stream_turn(turn,
               executable: executable,
               cwd: File.cwd!(),
               timeout: 2_000
             )

    returned_in_ms = System.monotonic_time(:millisecond) - started_at
    assert returned_in_ms < 150

    assert [
             %{type: :text_delta, delta: "early "},
             %{type: :text_delta, delta: "late"}
           ] = Enum.take(stream, 2)
  end

  defp delayed_turn_start_response_stub! do
    path =
      Path.join(
        System.tmp_dir!(),
        "contract-codex-delayed-turn-start-#{Ecto.UUID.generate()}.py"
      )

    File.write!(path, """
    #!/usr/bin/env python3
    import json
    import sys
    import time

    THREAD_ID = "thread-1"
    TURN_ID = "turn-1"

    def send(payload):
        sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\\n")
        sys.stdout.flush()

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")

        if method == "initialize":
            send({"id": request_id, "result": {"userAgent": "stub", "codexHome": "/tmp", "platformFamily": "unix", "platformOs": "linux"}})
        elif method == "thread/start":
            send({"id": request_id, "result": {"thread": {"id": THREAD_ID}}})
        elif method == "turn/start":
            send({"method": "item/agentMessage/delta", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "itemId": "msg-1", "delta": "early "}})
            time.sleep(0.25)
            send({"id": request_id, "result": {"turn": {"id": TURN_ID}}})
            send({"method": "item/agentMessage/delta", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "itemId": "msg-1", "delta": "late"}})
            send({"method": "turn/completed", "params": {"threadId": THREAD_ID, "turn": {"id": TURN_ID, "status": "completed", "error": None}}})
        else:
            send({"id": request_id, "error": {"code": -32601, "message": "unknown method"}})
    """)

    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
