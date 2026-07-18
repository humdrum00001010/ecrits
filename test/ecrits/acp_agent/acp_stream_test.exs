defmodule Ecrits.AcpAgent.AcpStreamTest do
  use ExUnit.Case, async: true

  alias Ecrits.AcpAgent.AcpStream
  alias Ecrits.AcpAgent.CodexAdapter
  alias ExMCP.ACP.Adapters.Codex

  # :dbg-recorded field bug (2026-07-19, take17 rail, board #459): a turn whose
  # opts lost the full-workspace approval signal ran a silently write-refusing
  # handler while the mode chip read "Full workspace" — the agent reported the
  # projection-write permission request as rejected and ended with zero writes.
  # The authorization must track EITHER full-workspace signal and fail closed
  # only when both are absent.
  describe "ACP write authorization from turn opts" do
    test "either full-workspace signal authorizes writes" do
      full = [sandbox: "workspace-write", approval_policy: "never", permission_mode: "dontAsk"]
      assert AcpStream.acp_write_authorized?(full)

      assert AcpStream.acp_write_authorized?(
               sandbox: "workspace-write",
               approval_policy: :never
             )

      # plumbing drift: approval_policy lost, permission_mode survives
      assert AcpStream.acp_write_authorized?(
               sandbox: "workspace-write",
               permission_mode: "dontAsk"
             )
    end

    test "ask, read-only, and signal-less turns stay fail-closed" do
      refute AcpStream.acp_write_authorized?(
               sandbox: "workspace-write",
               approval_policy: "on_write",
               permission_mode: "default"
             )

      refute AcpStream.acp_write_authorized?(
               sandbox: "read-only",
               approval_policy: "never",
               permission_mode: "dontAsk"
             )

      refute AcpStream.acp_write_authorized?(sandbox: "workspace-write")
      refute AcpStream.acp_write_authorized?([])
    end
  end

  describe "Codex MCP startup readiness" do
    test "surfaces the provider's exact ready notification as an ACP session update" do
      {:ok, state} = CodexAdapter.init([])

      inbound =
        Jason.encode!(%{
          "method" => "mcpServer/startupStatus/updated",
          "params" => %{
            "threadId" => "thread-ready",
            "name" => "doc",
            "status" => "ready",
            "error" => nil,
            "failureReason" => nil
          }
        })

      assert {:messages, [message], ^state} = CodexAdapter.translate_inbound(inbound, state)

      assert %{
               "method" => "session/update",
               "params" => %{
                 "sessionId" => "thread-ready",
                 "update" => %{
                   "sessionUpdate" => "mcp_server_startup",
                   "serverName" => "doc",
                   "status" => "ready"
                 }
               }
             } = message
    end

    test "does not release the prompt barrier until every configured server is ready" do
      send(
        self(),
        {:acp_stream_activity,
         %{
           "sessionUpdate" => "mcp_server_startup",
           "serverName" => "doc",
           "status" => "starting"
         }}
      )

      send(
        self(),
        {:acp_stream_activity,
         %{
           "sessionUpdate" => "mcp_server_startup",
           "serverName" => "doc",
           "status" => "ready"
         }}
      )

      assert :ok = AcpStream.await_mcp_startup("thread-ready", ["doc"], 100)
    end

    test "fails closed when the configured doc server does not become ready" do
      assert {:error, {:mcp_startup_timeout, ["doc"]}} =
               AcpStream.await_mcp_startup("thread-timeout", ["doc"], 0)
    end
  end

  describe "Codex reasoning summary updates" do
    test "summaryTextDelta reaches the normalized thinking event" do
      {:ok, adapter_state} = Codex.init([])
      adapter_state = %{adapter_state | thread_id: "thr-reasoning"}

      inbound =
        Jason.encode!(%{
          "method" => "item/reasoning/summaryTextDelta",
          "params" => %{"itemId" => "reasoning-1", "delta" => "Inspect workspace"}
        })

      assert {:messages, [message], _adapter_state} =
               Codex.translate_inbound(inbound, adapter_state)

      update = get_in(message, ["params", "update"])

      assert {:event, %{type: :reasoning_delta, delta: "Inspect workspace"}, _state} =
               AcpStream.map_session_update(update, AcpStream.update_state())
    end
  end

  describe "map_session_update/2 tool_call_update" do
    # The Claude adapter's first report of a tool_use block is a
    # `tool_call_update` with a non-terminal status and NO prior `tool_call`;
    # its terminal update then carries no toolName.
    test "a first-seen non-terminal update is the call's start" do
      update = %{
        "sessionUpdate" => "tool_call_update",
        "status" => "in_progress",
        "toolCallId" => "call-1",
        "toolName" => "Bash",
        "kind" => "execute",
        "input" => %{"command" => "ls"}
      }

      assert {:event, event, state} =
               AcpStream.map_session_update(update, AcpStream.update_state())

      assert %{
               type: :tool_call_started,
               tool_call_id: "call-1",
               name: "Bash",
               kind: "execute",
               arguments: %{"command" => "ls"}
             } = event

      # A repeat non-terminal update for the same call is not a second start.
      assert {:skip, ^state} = AcpStream.map_session_update(update, state)

      # The terminal update resolves its name from the cached start.
      completed = %{
        "sessionUpdate" => "tool_call_update",
        "status" => "completed",
        "toolCallId" => "call-1",
        "rawOutput" => %{"ok" => true}
      }

      assert {:event, %{type: :tool_call_completed, name: "Bash", kind: "execute"}, _state} =
               AcpStream.map_session_update(completed, state)
    end

    test "a non-terminal update after a spec tool_call start is skipped" do
      started = %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "call-2",
        "toolName" => "Read",
        "rawInput" => %{}
      }

      assert {:event, %{type: :tool_call_started}, state} =
               AcpStream.map_session_update(started, AcpStream.update_state())

      in_progress = %{
        "sessionUpdate" => "tool_call_update",
        "status" => "in_progress",
        "toolCallId" => "call-2"
      }

      assert {:skip, _state} = AcpStream.map_session_update(in_progress, state)
    end

    test "anonymous ACP bookkeeping does not fabricate a tool call" do
      started = %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "call-anonymous-start",
        "status" => "in_progress",
        "rawInput" => %{}
      }

      assert {:skip, state} =
               AcpStream.map_session_update(started, AcpStream.update_state())

      assert state.tool_titles == %{}

      updated = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "call-anonymous-update",
        "status" => "in_progress",
        "rawInput" => %{}
      }

      assert {:skip, state} = AcpStream.map_session_update(updated, state)
      assert state.tool_titles == %{}

      completed = %{updated | "status" => "completed"}
      assert {:skip, state} = AcpStream.map_session_update(completed, state)
      assert state.tool_titles == %{}
    end

    test "ACP kind is not used as a synthetic tool name" do
      update = %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "call-kind-only",
        "kind" => "execute",
        "status" => "in_progress",
        "rawInput" => %{}
      }

      assert {:skip, state} =
               AcpStream.map_session_update(update, AcpStream.update_state())

      assert state.tool_titles == %{}
      assert state.tool_kinds == %{"call-kind-only" => "execute"}
    end
  end

  describe "map_session_update/2 ACP file operations" do
    for operation <- ~w(read_text_file search_text_file edit_text_file) do
      test "#{operation} emits metadata-only distinct file activity" do
        operation = unquote(operation)
        tool_call_id = "#{operation}-call"

        arguments =
          %{"path" => "contract.jsonl"}
          |> then(fn arguments ->
            if operation == "search_text_file",
              do: Map.put(arguments, "query", "(인)"),
              else: arguments
          end)

        started = %{
          "sessionUpdate" => "file_operation",
          "fileOperationId" => tool_call_id,
          "operation" => operation,
          "kind" => if(operation == "edit_text_file", do: "edit", else: "read"),
          "path" => arguments["path"],
          "query" => arguments["query"],
          "status" => "in_progress"
        }

        assert {:event, started_event, state} =
                 AcpStream.map_session_update(started, AcpStream.update_state())

        assert %{
                 type: :file_operation_started,
                 file_operation_id: ^tool_call_id,
                 tool_call_id: ^tool_call_id,
                 operation: ^operation,
                 path: "contract.jsonl",
                 status: :running
               } = started_event

        assert started_event.query == arguments["query"]
        assert state.tool_titles[tool_call_id] == operation
        assert MapSet.member?(state.file_operation_ids, tool_call_id)

        completed_without_name = %{
          "sessionUpdate" => "file_operation_update",
          "fileOperationId" => tool_call_id,
          "status" => "completed",
          "rawOutput" => String.duplicate("private file contents", 10_000)
        }

        assert {:event, completed_event, _completed_state} =
                 AcpStream.map_session_update(completed_without_name, state)

        assert %{
                 type: :file_operation_completed,
                 file_operation_id: ^tool_call_id,
                 operation: ^operation,
                 path: "contract.jsonl",
                 status: :completed
               } = completed_event

        assert completed_event.query == arguments["query"]
        refute Map.has_key?(completed_event, :result)

        failed_with_name = %{
          "sessionUpdate" => "file_operation_update",
          "fileOperationId" => "#{tool_call_id}-direct-failure",
          "operation" => operation,
          "path" => arguments["path"],
          "query" => arguments["query"],
          "status" => "failed",
          "reason" => "file operation failed"
        }

        assert {:event, failed_event, _state} =
                 AcpStream.map_session_update(failed_with_name, AcpStream.update_state())

        assert %{
                 type: :file_operation_failed,
                 operation: ^operation,
                 path: "contract.jsonl",
                 status: :failed,
                 reason: "file operation failed"
               } = failed_event
      end
    end

    test "legacy tool_call-shaped file operations use the distinct compatibility event" do
      started = %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "legacy-read",
        "toolName" => "read_text_file",
        "kind" => "read",
        "rawInput" => %{"path" => "contract.jsonl"}
      }

      assert {:event,
              %{
                type: :file_operation_started,
                file_operation_id: "legacy-read",
                operation: "read_text_file",
                path: "contract.jsonl"
              }, state} = AcpStream.map_session_update(started, AcpStream.update_state())

      completed = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "legacy-read",
        "status" => "completed",
        "rawOutput" => String.duplicate("private file contents", 10_000)
      }

      assert {:event, completed_event, _state} =
               AcpStream.map_session_update(completed, state)

      assert %{
               type: :file_operation_completed,
               file_operation_id: "legacy-read",
               operation: "read_text_file",
               path: "contract.jsonl"
             } = completed_event

      refute Map.has_key?(completed_event, :result)
    end

    test "success false wins over a completed status and caps the failure reason" do
      reason = String.duplicate("x", 2_000)

      update = %{
        "sessionUpdate" => "file_operation_update",
        "fileOperationId" => "failed-read",
        "operation" => "read_text_file",
        "path" => "contract.jsonl",
        "status" => "completed",
        "success" => false,
        "reason" => reason
      }

      assert {:event,
              %{
                type: :file_operation_failed,
                file_operation_id: "failed-read",
                operation: "read_text_file",
                path: "contract.jsonl",
                status: :failed,
                reason: capped_reason
              }, _state} = AcpStream.map_session_update(update, AcpStream.update_state())

      assert byte_size(capped_reason) == 1_003
      assert String.ends_with?(capped_reason, "...")
    end

    test "an ordinary doc.open_doc call still emits chat tool events" do
      started = %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "doc-open-call",
        "toolName" => "doc.open_doc",
        "kind" => "other",
        "rawInput" => %{"path" => "current"}
      }

      assert {:event,
              %{
                type: :tool_call_started,
                tool_call_id: "doc-open-call",
                name: "doc.open_doc",
                kind: "other"
              }, state} = AcpStream.map_session_update(started, AcpStream.update_state())

      completed_without_name = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "doc-open-call",
        "status" => "completed",
        "rawOutput" => %{"opened" => true}
      }

      assert {:event,
              %{
                type: :tool_call_completed,
                tool_call_id: "doc-open-call",
                name: "doc.open_doc",
                kind: "other",
                result: %{"opened" => true}
              }, _state} = AcpStream.map_session_update(completed_without_name, state)
    end
  end

  describe "map_session_update/2 ACP edits" do
    test "normalizes an edit as an edit delta rather than a generic tool call" do
      started = %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "edit-1",
        "title" => "Edit File",
        "kind" => "edit",
        "rawInput" => %{"path" => ".ecrits/template.hwpx.jsonl", "diff" => "@@ edit @@"}
      }

      assert {:event, event, state} =
               AcpStream.map_session_update(started, AcpStream.update_state())

      assert event == %{
               type: :edit_delta,
               edit_id: "edit-1",
               path: ".ecrits/template.hwpx.jsonl",
               delta: "@@ edit @@"
             }

      completed = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-1",
        "kind" => "edit",
        "status" => "completed",
        "content" => [
          %{
            "type" => "diff",
            "path" => ".ecrits/template.hwpx.jsonl",
            "newText" => "@@ edit @@"
          }
        ]
      }

      assert {:skip, _state} = AcpStream.map_session_update(completed, state)
    end

    test "uses a completion-only structured diff when the start had no payload" do
      completed = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-2",
        "kind" => "edit",
        "status" => "completed",
        "content" => [
          %{"type" => "diff", "path" => "notes.md", "newText" => "+replacement"}
        ]
      }

      assert {:event,
              %{
                type: :edit_delta,
                edit_id: "edit-2",
                path: "notes.md",
                delta: "+replacement"
              }, _state} = AcpStream.map_session_update(completed, AcpStream.update_state())
    end
  end
end
