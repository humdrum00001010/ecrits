defmodule Ecrits.Local.Agent.EndpointTest do
  use ExUnit.Case, async: false

  alias Ecrits.Context
  alias Ecrits.Local.Document
  alias Ecrits.Local.Agent.Adapters.CodexAppServer
  alias Ecrits.Local.Agent.Adapters.Fake
  alias Ecrits.Local.Agent.Endpoint

  @ctx %Context{
    user: %{
      id: "00000000-0000-0000-0000-000000000294",
      email: "local-agent@example.test"
    }
  }

  test "starts session and streams injected test adapter response" do
    {:ok, session} = start_local_session(adapter: Fake)

    assert session.provider == %{
             id: "codex",
             label: "Codex",
             icon: "local-agent-provider-codex",
             favicon_src: "/images/icons/openai-blossom.svg"
           }

    :ok = Endpoint.subscribe(session.id)

    assert {:ok, %{id: turn_id, status: :running}} =
             Endpoint.send_turn(@ctx, session.id, "hello")

    assert_receive {:local_agent_event, %{type: :turn_started, turn_id: ^turn_id}}, 1_000

    assert_receive {:local_agent_event,
                    %{type: :text_delta, turn_id: ^turn_id, delta: "Fake response: "}},
                   1_000

    assert_receive {:local_agent_event, %{type: :text_delta, turn_id: ^turn_id, delta: "hello"}},
                   1_000

    assert_receive {:local_agent_event,
                    %{type: :turn_completed, turn_id: ^turn_id, text: "Fake response: hello"}},
                   1_000

    assert {:ok, %{current_turn: nil}} = Endpoint.status(@ctx, session.id)
  end

  test "exposes provider metadata for UI picker" do
    assert [
             %{
               id: "codex",
               label: "Codex",
               icon: "local-agent-provider-codex",
               favicon_src: "/images/icons/openai-blossom.svg"
             },
             %{
               id: "claude",
               label: "Claude",
               icon: "local-agent-provider-claude",
               favicon_src: "/images/icons/claude-favicon.ico"
             },
             %{
               id: "external",
               label: "External ACP",
               icon: "local-agent-provider-external",
               favicon_src: "/favicon.ico"
             }
           ] = Endpoint.provider_metadata()
  end

  test "rejects fake provider on public path" do
    assert {:error, {:unsupported_provider, :fake, ["codex", "claude", "external"]}} =
             Endpoint.start_session(@ctx, provider: :fake)
  end

  test "rejects unsupported provider before starting session" do
    assert {:error, {:unsupported_provider, "bogus", ["codex", "claude", "external"]}} =
             Endpoint.start_session(@ctx, provider: "bogus")
  end

  test "streams fake adapter tool events and executes local document read" do
    {:ok, session} =
      start_local_session(
        adapter: Fake,
        document_session: self(),
        adapter_opts: [
          script: [
            {:tool_call, "doc.read", %{"at" => 0, "size" => 1}},
            {:text_delta, "done"}
          ]
        ]
      )

    :ok = Endpoint.subscribe(session.id)
    assert {:ok, %{id: turn_id}} = Endpoint.send_turn(@ctx, session.id, "read")

    assert_receive {:local_agent_tool_call, caller, ref, :read, %{"at" => 0, "size" => 1}}, 1_000
    send(caller, {ref, {:ok, %{"revision" => 1, "items" => ["Alpha"]}}})

    assert_receive {:local_agent_event, %{type: :tool_call_started, turn_id: ^turn_id}}, 1_000

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_completed,
                      turn_id: ^turn_id,
                      name: "doc.read",
                      result: %{"revision" => 1}
                    }},
                   1_000

    assert_receive {:local_agent_event,
                    %{type: :turn_completed, turn_id: ^turn_id, text: "done"}},
                   1_000
  end

  test "resolves document tools from session document id by default" do
    {document, _bytes} = open_local_document!()

    {:ok, session} =
      start_local_session(
        adapter: Fake,
        document_id: document.id,
        workspace_root: document.workspace_root,
        adapter_opts: [
          script: [
            %{
              type: :tool_call,
              id: "tool-read-current-doc",
              name: "doc.read",
              arguments: %{}
            }
          ]
        ]
      )

    :ok = Endpoint.subscribe(session.id)
    assert {:ok, %{id: turn_id, tools: tools}} = Endpoint.send_turn(@ctx, session.id, "read doc")
    assert Enum.any?(tools, &(&1["namespace"] == "doc" and &1["name"] == "read"))

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_completed,
                      turn_id: ^turn_id,
                      tool_call_id: "tool-read-current-doc",
                      name: "doc.read",
                      result: result
                    }},
                   1_000

    assert %{
             "document_id" => document_id,
             "relative_path" => "docs/current.hwpx",
             "text" => text
           } = result

    assert text =~ "전력기술관리법"

    refute Map.has_key?(result, "bytes_base64")
    assert document_id == document.id
  end

  test "cancels an active fake adapter turn" do
    {:ok, session} =
      start_local_session(
        adapter: Fake,
        adapter_opts: [
          test_pid: self(),
          wait_for: :release_fake_stream,
          script: [{:text_delta, "late"}]
        ]
      )

    :ok = Endpoint.subscribe(session.id)
    assert {:ok, %{id: turn_id}} = Endpoint.send_turn(@ctx, session.id, "wait")
    assert_receive {:fake_adapter_waiting, _stream_pid}, 1_000

    assert {:ok, %{id: ^turn_id, status: :cancelled}} = Endpoint.cancel(@ctx, session.id, turn_id)
    assert_receive {:local_agent_event, %{type: :turn_cancelled, turn_id: ^turn_id}}, 1_000
    assert {:ok, %{current_turn: nil}} = Endpoint.status(@ctx, session.id)
  end

  test "on_write approval policy gates writes until approved" do
    {:ok, session} =
      start_local_session(
        adapter: Fake,
        approval_policy: :on_write,
        access_control: "full-workspace",
        document_session: self(),
        adapter_opts: [
          script: [
            %{
              type: :tool_call,
              id: "tool-write-1",
              name: "doc.write",
              arguments: %{"text" => "approved"}
            }
          ]
        ]
      )

    :ok = Endpoint.subscribe(session.id)
    assert {:ok, %{id: turn_id}} = Endpoint.send_turn(@ctx, session.id, "write")

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_approval_required,
                      turn_id: ^turn_id,
                      tool_call_id: "tool-write-1",
                      name: "doc.write"
                    }},
                   1_000

    refute_receive {:local_agent_tool_call, _caller, _ref, :write, _args}, 50

    assert {:ok, %{pending_tool_call_ids: ["tool-write-1"]}} =
             Endpoint.status(@ctx, session.id)

    task_supervisor = start_supervised!(Task.Supervisor)

    approve_task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Endpoint.approve_tool_call(@ctx, session.id, "tool-write-1")
      end)

    assert_receive {:local_agent_tool_call, caller, ref, :write, %{"text" => "approved"}}, 1_000
    send(caller, {ref, {:ok, %{"revision" => 2}}})

    assert {:ok, %{"revision" => 2}} = Task.await(approve_task)

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_completed,
                      turn_id: ^turn_id,
                      tool_call_id: "tool-write-1",
                      result: %{"revision" => 2}
                    }},
                   1_000
  end

  test "persists streamed events to opt-in JSONL" do
    path = Path.join(System.tmp_dir!(), "ecrits-local-agent-#{Ecto.UUID.generate()}.jsonl")
    on_exit(fn -> File.rm(path) end)

    {:ok, session} = start_local_session(adapter: Fake, persistence: {:jsonl, path})
    :ok = Endpoint.subscribe(session.id)

    assert {:ok, %{id: turn_id}} = Endpoint.send_turn(@ctx, session.id, "persist")
    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 1_000

    events =
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.any?(events, &(&1["type"] == "turn_started"))
    assert Enum.any?(events, &(&1["type"] == "turn_completed" and &1["turn_id"] == turn_id))
  end

  test "codex provider reports missing executable as an explicit turn failure" do
    missing = "ecrits-codex-missing-#{Ecto.UUID.generate()}"

    {:ok, session} =
      start_local_session(
        provider: :codex,
        adapter: CodexAppServer,
        adapter_opts: [executable: missing, timeout: 1_000]
      )

    :ok = Endpoint.subscribe(session.id)

    assert {:ok, %{id: turn_id}} = Endpoint.send_turn(@ctx, session.id, "hello")

    assert_receive {:local_agent_event,
                    %{
                      type: :turn_failed,
                      turn_id: ^turn_id,
                      reason: reason
                    }},
                   1_000

    assert reason =~ "codex_executable_missing"
    assert reason =~ missing
  end

  test "codex provider surfaces dynamic tool item events" do
    executable = codex_dynamic_tool_event_stub!()

    {:ok, session} =
      start_local_session(
        provider: :codex,
        adapter: CodexAppServer,
        adapter_opts: [executable: executable, timeout: 2_000]
      )

    :ok = Endpoint.subscribe(session.id)

    assert {:ok, %{id: turn_id}} = Endpoint.send_turn(@ctx, session.id, "read")

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_started,
                      turn_id: ^turn_id,
                      tool_call_id: "dyn-read-1",
                      name: "doc.read",
                      arguments: %{"at" => 0, "size" => 1}
                    }},
                   1_000

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_completed,
                      turn_id: ^turn_id,
                      tool_call_id: "dyn-read-1",
                      name: "doc.read",
                      result: %{"items" => [%{"text" => "Alpha"}]}
                    }},
                   1_000

    assert_receive {:local_agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 1_000
  end

  test "codex provider executes dynamic document tools through the session" do
    executable = codex_app_server_stub!()
    {document, _bytes} = open_local_document!()

    {:ok, session} =
      start_local_session(
        provider: :codex,
        adapter: CodexAppServer,
        document_id: document.id,
        workspace_root: document.workspace_root,
        adapter_opts: [executable: executable, timeout: 2_000, approval_policy: "on_write"]
      )

    :ok = Endpoint.subscribe(session.id)

    assert {:ok, %{id: turn_id}} = Endpoint.send_turn(@ctx, session.id, "hello codex")

    assert_receive {:local_agent_event, %{type: :turn_started, turn_id: ^turn_id}}, 1_000

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_started,
                      turn_id: ^turn_id,
                      tool_call_id: "tool-read-1",
                      name: "doc.read",
                      arguments: %{"sec" => 0, "at" => 0, "size" => 1}
                    }},
                   1_000

    assert_receive {:local_agent_event,
                    %{
                      type: :tool_call_completed,
                      turn_id: ^turn_id,
                      tool_call_id: "tool-read-1",
                      name: "doc.read",
                      result: %{"document_id" => document_id, "text" => text}
                    }},
                   1_000

    assert document_id == document.id
    assert text =~ "전력기술관리법"

    assert_receive {:local_agent_event, %{type: :text_delta, turn_id: ^turn_id, delta: "Hello "}},
                   1_000

    assert_receive {:local_agent_event,
                    %{type: :text_delta, turn_id: ^turn_id, delta: "from Codex"}},
                   1_000

    assert_receive {:local_agent_event,
                    %{type: :turn_completed, turn_id: ^turn_id, text: "Hello from Codex"}},
                   1_000

    refute_receive {:local_agent_event, %{name: "command.exec"}}, 100
  end

  @tag :live_openai
  @tag timeout: 180_000
  test "codex provider smoke calls real local executable when available" do
    case CodexAppServer.resolve_executable() do
      {:error, {:codex_executable_missing, _candidates} = reason} ->
        assert {:codex_executable_missing, ["codex-acp", "codex"]} = reason

      {:ok, executable} ->
        {:ok, session} =
          start_local_session(
            provider: :codex,
            adapter_opts: [
              executable: executable.path,
              cwd: File.cwd!(),
              timeout: 150_000,
              developer_instructions: "Reply only final answer. Do not edit files."
            ]
          )

        :ok = Endpoint.subscribe(session.id)

        assert {:ok, %{id: turn_id}} =
                 Endpoint.send_turn(@ctx, session.id, "Reply exactly: local-agent-smoke")

        assert_receive {:local_agent_event,
                        %{
                          type: :turn_completed,
                          turn_id: ^turn_id,
                          text: "local-agent-smoke"
                        }},
                       150_000
    end
  end

  defp start_local_session(opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    opts = Keyword.put_new(opts, :id, id)

    on_exit(fn ->
      case Endpoint.whereis(id) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end
    end)

    Endpoint.start_session(@ctx, opts)
  end

  defp open_local_document! do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-local-agent-doc-#{System.unique_integer([:positive])}"
      )

    bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")
    path = Path.join([root, "docs", "current.hwpx"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)

    assert {:ok, document} = Document.open(root, "docs/current.hwpx")

    ir = %{
      "version" => 1,
      "sections" => [
        %{
          "idx" => 0,
          "paragraphs" => [%{"idx" => 0, "text" => "Endpoint Alpha"}]
        }
      ],
      "positional_index" => %{
        "version" => 1,
        "paragraphs" => [
          %{"sec" => 0, "para" => 0, "page" => 0, "off_start" => 0, "off_end" => 14}
        ],
        "tables" => []
      }
    }

    assert {:ok, document, _snapshot} = Document.checkpoint(document, bytes, %{ir: ir})

    on_exit(fn ->
      _ = Document.close(document.id)
      File.rm_rf(root)
    end)

    {document, bytes}
  end

  defp codex_app_server_stub! do
    path =
      Path.join(System.tmp_dir!(), "ecrits-codex-app-server-stub-#{Ecto.UUID.generate()}.py")

    File.write!(path, """
    #!/usr/bin/env python3
    import json
    import sys

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
            if message.get("params", {}).get("approvalPolicy") != "on-request":
                send({"id": request_id, "error": {"code": -32600, "message": "expected normalized on-request approval policy"}})
                continue
            dynamic_tools = message.get("params", {}).get("dynamicTools") or []
            if any("." in tool.get("name", "") for tool in dynamic_tools):
                send({"id": request_id, "error": {"code": -32600, "message": "dynamic tool name must match ^[a-zA-Z0-9_-]+$"}})
                continue
            expected = {("doc", "read"), ("doc", "find"), ("doc", "write")}
            actual = {(tool.get("namespace"), tool.get("name")) for tool in dynamic_tools}
            if not expected.issubset(actual):
                send({"id": request_id, "error": {"code": -32600, "message": "missing namespaced doc tools"}})
                continue
            send({"id": request_id, "result": {"thread": {"id": THREAD_ID}}})
        elif method == "turn/start":
            if message.get("params", {}).get("approvalPolicy") != "on-request":
                send({"id": request_id, "error": {"code": -32600, "message": "expected normalized on-request turn approval policy"}})
                continue
            send({"id": request_id, "result": {"turn": {"id": TURN_ID}}})
            send({"method": "item/started", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "item": {"type": "commandExecution", "id": "cmd-1", "command": "echo hi", "cwd": "/tmp", "status": "inProgress", "commandActions": [], "aggregatedOutput": None, "exitCode": None, "durationMs": None}}})
            send({"method": "item/completed", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "item": {"type": "commandExecution", "id": "cmd-1", "command": "echo hi", "cwd": "/tmp", "status": "completed", "commandActions": [], "aggregatedOutput": "hi\\n", "exitCode": 0, "durationMs": 1}}})
            send({"id": "tool-request-1", "method": "item/tool/call", "params": {"id": "tool-read-1", "namespace": "doc", "tool": "read", "arguments": {"sec": 0, "at": 0, "size": 1}}})
            tool_response = json.loads(sys.stdin.readline())
            tool_text = (tool_response.get("result", {}).get("contentItems") or [{}])[0].get("text", "")
            if "전력기술관리법" not in tool_text:
                send({"method": "error", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "error": {"message": "tool response missing document content", "tool_text": tool_text}}})
            send({"method": "item/agentMessage/delta", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "itemId": "msg-1", "delta": "Hello "}})
            send({"method": "item/agentMessage/delta", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "itemId": "msg-1", "delta": "from Codex"}})
            send({"method": "turn/completed", "params": {"threadId": THREAD_ID, "turn": {"id": TURN_ID, "status": "completed", "error": None}}})
        else:
            send({"id": request_id, "error": {"code": -32601, "message": "unknown method"}})
    """)

    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp codex_dynamic_tool_event_stub! do
    path =
      Path.join(System.tmp_dir!(), "ecrits-codex-dynamic-tool-stub-#{Ecto.UUID.generate()}.py")

    File.write!(path, """
    #!/usr/bin/env python3
    import json
    import sys

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
            send({"id": request_id, "result": {"turn": {"id": TURN_ID}}})
            send({"method": "item/started", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "item": {"type": "dynamicToolCall", "id": "dyn-read-1", "namespace": "doc", "name": "read", "arguments": {"at": 0, "size": 1}}}})
            send({"method": "item/completed", "params": {"threadId": THREAD_ID, "turnId": TURN_ID, "item": {"type": "dynamicToolCall", "id": "dyn-read-1", "namespace": "doc", "name": "read", "result": {"items": [{"text": "Alpha"}]}}}})
            send({"method": "turn/completed", "params": {"threadId": THREAD_ID, "turn": {"id": TURN_ID, "status": "completed", "error": None}}})
        else:
            send({"id": request_id, "error": {"code": -32601, "message": "unknown method"}})
    """)

    File.chmod!(path, 0o755)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
