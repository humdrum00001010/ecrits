defmodule Ecrits.AcpAgent.AcpStreamTest do
  use ExUnit.Case, async: true

  alias Ecrits.AcpAgent.AcpStream
  alias Ecrits.AcpAgent.CodexAdapter
  alias ExMCP.ACP.Adapters.Codex

  describe "official adapter option shaping" do
    test "Codex maps Read to read-only and Ask/Full to the workspace agent mode" do
      cwd = File.cwd!()

      assert AcpStream.provider_adapter_opts(CodexAdapter, cwd,
               access_control: "read-only",
               approval_policy: "on_write",
               sandbox: "read-only"
             )[:mode_id] == "read-only"

      for access <- ["ask", "full-workspace"] do
        opts =
          AcpStream.provider_adapter_opts(CodexAdapter, cwd,
            access_control: access,
            approval_policy: if(access == "ask", do: "on_write", else: "never"),
            sandbox: "workspace-write"
          )

        assert opts[:mode_id] == "agent"
        refute Keyword.has_key?(opts, :approvalPolicy)
        refute Keyword.has_key?(opts, :disable_memories)
        refute Keyword.has_key?(opts, :auto_approve_mcp_servers)
      end
    end

    test "both wrappers install a permission-only handler without fs or terminal capabilities" do
      for adapter <- [CodexAdapter, Ecrits.AcpAgent.ClaudeAdapter] do
        opts =
          AcpStream.permission_handler_client_opts(
            [],
            adapter,
            [access_control: "full-workspace"],
            File.cwd!()
          )

        assert opts[:handler] == Ecrits.AcpAgent.PermissionHandler
        assert opts[:handler_opts][:access_control] == "full-workspace"
        assert opts[:handler_opts][:workspace_root] == File.cwd!()
        assert opts[:capabilities] == %{}
      end
    end

    test "Claude always keeps native tools available and carries model, thinking, and MCP config" do
      opts =
        AcpStream.provider_adapter_opts(Ecrits.AcpAgent.ClaudeAdapter, File.cwd!(),
          model: "claude-sonnet-4-5",
          permission_mode: "plan",
          reasoning_effort: "high",
          mcp_servers: [%{"name" => "doc", "url" => "http://localhost/doc"}]
        )

      assert opts[:permission_mode] == "default"
      assert opts[:model] == "claude-sonnet-4-5"
      assert opts[:max_thinking_tokens] == 21_333
      assert opts[:mcp_servers] == [%{"name" => "doc", "url" => "http://localhost/doc"}]
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
  end

  describe "Codex reasoning summary updates" do
    test "summaryTextDelta reaches the normalized thinking event" do
      {:ok, adapter_state} = Codex.init([])
      adapter_state = %{adapter_state | sessions: %{"thr-reasoning" => %{id: "thr-reasoning"}}}

      inbound =
        Jason.encode!(%{
          "method" => "item/reasoning/summaryTextDelta",
          "params" => %{
            "threadId" => "thr-reasoning",
            "itemId" => "reasoning-1",
            "delta" => "Inspect workspace"
          }
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

    test "an MCP envelope supplies the canonical visible tool name" do
      started = %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "mcp-open-doc",
        "toolName" => "mcp.doc.doc.open_doc",
        "kind" => "execute",
        "rawInput" => %{
          "server" => "doc",
          "tool" => "doc.open_doc",
          "arguments" => %{"path" => "current"}
        }
      }

      assert {:event, %{name: "doc.open_doc"}, state} =
               AcpStream.map_session_update(started, AcpStream.update_state())

      completed = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "mcp-open-doc",
        "toolName" => "mcp.doc.doc.open_doc",
        "status" => "completed",
        "rawOutput" => %{"ok" => true}
      }

      assert {:event, %{name: "doc.open_doc"}, _state} =
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

  describe "map_session_update/2 generic provider tools" do
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
    test "two ACP diff blocks emit two ordered changes" do
      update = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-ordered",
        "kind" => "edit",
        "status" => "in_progress",
        "content" => [
          %{
            "type" => "diff",
            "path" => "first.md",
            "oldText" => "first\r\nold",
            "newText" => "first\r\nnew"
          },
          %{
            "type" => "diff",
            "path" => "second.md",
            "oldText" => "second old",
            "newText" => "second new"
          }
        ]
      }

      assert {:event,
              %{
                type: :file_change_snapshot,
                phase: :proposed,
                edit_id: "edit-ordered",
                changes: [
                  %{path: "first.md", old_text: "first\r\nold", new_text: "first\r\nnew"},
                  %{path: "second.md", old_text: "second old", new_text: "second new"}
                ],
                fingerprint: fingerprint
              }, _state} = AcpStream.map_session_update(update, AcpStream.update_state())

      assert is_binary(fingerprint)
    end

    test "the second ACP diff block is not discarded" do
      update = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-second-block",
        "kind" => "edit",
        "status" => "in_progress",
        "rawInput" => %{"path" => "fallback.md", "newText" => "fallback"},
        "content" => [
          %{"type" => "diff", "path" => "same.md", "oldText" => "one", "newText" => "two"},
          %{"type" => "diff", "path" => "same.md", "oldText" => nil, "newText" => nil}
        ]
      }

      assert {:event, %{changes: changes}, _state} =
               AcpStream.map_session_update(update, AcpStream.update_state())

      assert changes == [
               %{path: "same.md", old_text: "one", new_text: "two"},
               %{path: "same.md", old_text: nil, new_text: nil}
             ]
    end

    test "an identical repeated whole snapshot is skipped" do
      update = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-repeat",
        "kind" => "edit",
        "status" => "in_progress",
        "content" => [
          %{"type" => "diff", "path" => "repeat.md", "oldText" => "before", "newText" => "after"}
        ]
      }

      assert {:event, %{fingerprint: fingerprint}, state} =
               AcpStream.map_session_update(update, AcpStream.update_state())

      assert {:skip, repeated_state} = AcpStream.map_session_update(update, state)
      assert repeated_state.edit_snapshots == %{"edit-repeat" => fingerprint}
    end

    test "a changed snapshot for the same edit id is emitted whole rather than appended" do
      first = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-replaced",
        "kind" => "edit",
        "status" => "in_progress",
        "content" => [
          %{"type" => "diff", "path" => "one.md", "oldText" => "a", "newText" => "b"}
        ]
      }

      changed = %{
        first
        | "content" => [
            %{"type" => "diff", "path" => "one.md", "oldText" => "a", "newText" => "c"},
            %{"type" => "diff", "path" => "two.md", "oldText" => "x", "newText" => "y"}
          ]
      }

      assert {:event, %{fingerprint: first_fingerprint}, state} =
               AcpStream.map_session_update(first, AcpStream.update_state())

      assert {:event,
              %{
                edit_id: "edit-replaced",
                changes: [
                  %{path: "one.md", old_text: "a", new_text: "c"},
                  %{path: "two.md", old_text: "x", new_text: "y"}
                ],
                fingerprint: changed_fingerprint
              }, changed_state} = AcpStream.map_session_update(changed, state)

      refute changed_fingerprint == first_fingerprint
      assert changed_state.edit_snapshots == %{"edit-replaced" => changed_fingerprint}
    end

    test "empty and non-diff ACP content are skipped" do
      base = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-empty",
        "kind" => "edit",
        "status" => "in_progress"
      }

      assert {:skip, empty_state} =
               AcpStream.map_session_update(
                 Map.put(base, "content", []),
                 AcpStream.update_state()
               )

      assert empty_state.edit_snapshots == %{}

      non_diff =
        base
        |> Map.put("toolCallId", "edit-non-diff")
        |> Map.put("content", [%{"type" => "content", "text" => "not a diff"}])

      assert {:skip, non_diff_state} = AcpStream.map_session_update(non_diff, empty_state)
      assert non_diff_state.edit_snapshots == %{}
    end

    test "different paths remain distinct in one snapshot" do
      update = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-distinct-paths",
        "kind" => "edit",
        "status" => "in_progress",
        "content" => [
          %{"type" => "diff", "path" => "a/shared.jsonl", "oldText" => "x", "newText" => "y"},
          %{"type" => "diff", "path" => "b/shared.jsonl", "oldText" => "x", "newText" => "y"}
        ]
      }

      assert {:event, %{changes: [first, second]}, _state} =
               AcpStream.map_session_update(update, AcpStream.update_state())

      assert first.path == "a/shared.jsonl"
      assert second.path == "b/shared.jsonl"
      refute first.path == second.path
    end

    test "a completed edit with a new final diff emits the snapshot before completion" do
      snapshot = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-terminal",
        "title" => "Edit File",
        "kind" => "edit",
        "status" => "in_progress",
        "content" => [
          %{
            "type" => "diff",
            "path" => "terminal.md",
            "oldText" => "before",
            "newText" => "after"
          }
        ]
      }

      assert {:event, %{type: :file_change_snapshot}, state} =
               AcpStream.map_session_update(snapshot, AcpStream.update_state())

      completed = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-terminal",
        "status" => "completed",
        "content" => [
          %{
            "type" => "diff",
            "path" => "terminal.md",
            "oldText" => "before",
            "newText" => "final"
          }
        ],
        "rawOutput" => %{"applied" => true}
      }

      assert {:events,
              [
                %{
                  type: :file_change_snapshot,
                  edit_id: "edit-terminal",
                  changes: [
                    %{path: "terminal.md", old_text: "before", new_text: "final"}
                  ]
                },
                %{
                  type: :tool_call_completed,
                  tool_call_id: "edit-terminal",
                  name: "Edit File",
                  kind: "edit",
                  result: %{"applied" => true}
                }
              ], _state} = AcpStream.map_session_update(completed, state)
    end

    test "a failed edit with a new final diff emits the snapshot before failure" do
      failed = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-failed-terminal",
        "title" => "Edit File",
        "kind" => "edit",
        "status" => "failed",
        "content" => [
          %{
            "type" => "diff",
            "path" => "failed.md",
            "oldText" => "before",
            "newText" => "proposed"
          },
          %{
            "type" => "content",
            "content" => %{"type" => "text", "text" => "permission denied"}
          }
        ]
      }

      assert {:events,
              [
                %{
                  type: :file_change_snapshot,
                  edit_id: "edit-failed-terminal",
                  changes: [
                    %{path: "failed.md", old_text: "before", new_text: "proposed"}
                  ]
                },
                %{
                  type: :tool_call_failed,
                  tool_call_id: "edit-failed-terminal",
                  name: "Edit File",
                  kind: "edit",
                  reason: reason
                }
              ], _state} = AcpStream.map_session_update(failed, AcpStream.update_state())

      assert reason =~ "permission denied"
    end

    test "an identical final edit fingerprint emits only the terminal lifecycle" do
      snapshot = %{
        "sessionUpdate" => "tool_call_update",
        "toolCallId" => "edit-identical-terminal",
        "title" => "Edit File",
        "kind" => "edit",
        "status" => "in_progress",
        "content" => [
          %{
            "type" => "diff",
            "path" => "same.md",
            "oldText" => "before",
            "newText" => "after"
          }
        ]
      }

      assert {:event, %{type: :file_change_snapshot}, state} =
               AcpStream.map_session_update(snapshot, AcpStream.update_state())

      completed =
        snapshot
        |> Map.put("status", "completed")
        |> Map.put("rawOutput", %{"applied" => true})

      assert {:event,
              %{
                type: :tool_call_completed,
                tool_call_id: "edit-identical-terminal",
                name: "Edit File",
                kind: "edit"
              }, _state} = AcpStream.map_session_update(completed, state)
    end

    test "a one-off turn stream emits both events from one terminal edit notification" do
      turn = %{input: "edit it", workspace_root: File.cwd!()}

      events =
        EcritsWeb.FakeAcpAdapter
        |> AcpStream.turn_stream(turn,
          test_pid: self(),
          wait_for: :release_prompt,
          timeout: 5_000
        )
        |> Stream.transform(false, fn event, injected? ->
          if event.type == :provider_session and not injected? do
            send(self(), {
              :acp_session_update,
              event.provider_session_id,
              %{
                "sessionUpdate" => "tool_call_update",
                "toolCallId" => "one-off-terminal-edit",
                "title" => "Edit File",
                "kind" => "edit",
                "status" => "completed",
                "content" => [
                  %{
                    "type" => "diff",
                    "path" => "one-off.md",
                    "oldText" => "before",
                    "newText" => "after"
                  }
                ],
                "rawOutput" => %{"applied" => true}
              }
            })
          end

          {[event], injected? or event.type == :provider_session}
        end)
        |> Enum.take(3)

      assert [
               %{type: :provider_session},
               %{type: :file_change_snapshot, edit_id: "one-off-terminal-edit"},
               %{type: :tool_call_completed, tool_call_id: "one-off-terminal-edit"}
             ] = events
    end

    test "raw input remains a compatibility fallback when ACP diff content is absent" do
      update = %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "edit-raw-input",
        "title" => "Edit File",
        "kind" => "edit",
        "rawInput" => %{
          "path" => ".ecrits/template.hwpx.jsonl",
          "oldText" => "old opaque text",
          "newText" => "new opaque text"
        }
      }

      assert {:event,
              %{
                type: :file_change_snapshot,
                phase: :proposed,
                edit_id: "edit-raw-input",
                changes: [
                  %{
                    path: ".ecrits/template.hwpx.jsonl",
                    old_text: "old opaque text",
                    new_text: "new opaque text"
                  }
                ]
              }, _state} = AcpStream.map_session_update(update, AcpStream.update_state())
    end
  end
end
