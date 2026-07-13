defmodule Ecrits.AcpAgent.AcpStreamTest do
  use ExUnit.Case, async: true

  alias Ecrits.AcpAgent.AcpStream

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
        "input" => %{"command" => "ls"}
      }

      assert {:event, event, state} =
               AcpStream.map_session_update(update, AcpStream.update_state())

      assert %{
               type: :tool_call_started,
               tool_call_id: "call-1",
               name: "Bash",
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

      assert {:event, %{type: :tool_call_completed, name: "Bash"}, _state} =
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

  describe "map_session_update/2 ACP edits" do
    test "normalizes an edit as an edit delta rather than a generic tool call" do
      started = %{
        "sessionUpdate" => "tool_call",
        "toolCallId" => "edit-1",
        "title" => "Edit File",
        "kind" => "edit",
        "rawInput" => %{"path" => ".ecrits/mount/template.hwpx.jsonl", "diff" => "@@ edit @@"}
      }

      assert {:event, event, state} =
               AcpStream.map_session_update(started, AcpStream.update_state())

      assert event == %{
               type: :edit_delta,
               edit_id: "edit-1",
               path: ".ecrits/mount/template.hwpx.jsonl",
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
            "path" => ".ecrits/mount/template.hwpx.jsonl",
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
