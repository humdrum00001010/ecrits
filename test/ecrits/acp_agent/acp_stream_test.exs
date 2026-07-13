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
  end
end
