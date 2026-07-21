defmodule Ecrits.AcpAgent.PermissionHandlerTest do
  use ExUnit.Case, async: true

  alias Ecrits.AcpAgent.PermissionHandler

  @options [
    %{"optionId" => "allow-once", "kind" => "allow_once"},
    %{"optionId" => "allow-always", "kind" => "allow_always"},
    %{"optionId" => "reject-once", "kind" => "reject_once"},
    %{"optionId" => "reject-always", "kind" => "reject_always"}
  ]

  setup do
    root =
      Path.join(System.tmp_dir!(), "permission-handler-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "read-only rejects a provider-native tool escalation once", %{root: root} do
    assert {:ok, state} =
             PermissionHandler.init(access_control: "read-only", workspace_root: root)

    assert {:ok, %{"outcome" => "selected", "optionId" => "reject-once"}, ^state} =
             PermissionHandler.handle_permission_request(
               "session-read",
               %{"title" => "Apply patch", "kind" => "edit", "path" => "contract.jsonl"},
               @options,
               state
             )
  end

  test "read-only allows provider-native reads inside the workspace", %{root: root} do
    assert {:ok, state} =
             PermissionHandler.init(access_control: "read-only", workspace_root: root)

    assert {:ok, %{"outcome" => "selected", "optionId" => "allow-once"}, ^state} =
             PermissionHandler.handle_permission_request(
               "session-read",
               %{"title" => "Read", "kind" => "read", "path" => "contract.jsonl"},
               @options,
               state
             )
  end

  test "ask does not silently auto-approve a provider-native mutation", %{root: root} do
    assert {:ok, state} = PermissionHandler.init(access_control: "ask", workspace_root: root)

    assert {:ok, %{"outcome" => "cancelled"}, ^state} =
             PermissionHandler.handle_permission_request(
               "session-ask",
               %{"title" => "Apply patch", "kind" => "edit", "path" => "contract.jsonl"},
               @options,
               state
             )
  end

  test "full workspace selects the single-use allow option", %{root: root} do
    assert {:ok, state} =
             PermissionHandler.init(access_control: "full-workspace", workspace_root: root)

    assert {:ok, %{"outcome" => "selected", "optionId" => "allow-once"}, ^state} =
             PermissionHandler.handle_permission_request(
               "session-full",
               %{"title" => "Apply patch", "kind" => "edit", "path" => "contract.jsonl"},
               @options,
               state
             )
  end

  test "full workspace approves Codex v2 file-change requests that omit paths", %{root: root} do
    assert {:ok, state} =
             PermissionHandler.init(access_control: "full-workspace", workspace_root: root)

    tool_call = %{
      "toolName" => "edit",
      "kind" => "edit",
      "title" => "Approve File Changes",
      "rawInput" => %{
        "threadId" => "thread-1",
        "turnId" => "turn-1",
        "itemId" => "item-1",
        "startedAtMs" => 1,
        "reason" => nil,
        "grantRoot" => nil
      }
    }

    assert {:ok, %{"outcome" => "selected", "optionId" => "allow-once"}, ^state} =
             PermissionHandler.handle_permission_request(
               "session-full",
               tool_call,
               @options,
               state
             )
  end

  test "full workspace approves Codex MCP edits whose mounted projection and source stay inside",
       %{
         root: root
       } do
    projection = Path.join(root, ".ecrits/contract.hwp.jsonl")
    signature = Path.join(root, "signature.png")
    File.mkdir_p!(Path.dirname(projection))
    File.write!(projection, "[]\n")
    File.write!(signature, "png")

    assert {:ok, state} =
             PermissionHandler.init(access_control: "full-workspace", workspace_root: root)

    tool_call = %{
      "toolName" => "mcp:doc",
      "kind" => "other",
      "rawInput" => %{
        "_meta" => %{
          "codex_approval_kind" => "mcp_tool_call",
          "tool_params" => %{
            "fallback" => %{"mounted_at" => projection},
            "op" => %{"op" => "insert_picture", "src" => signature}
          }
        }
      }
    }

    assert {:ok, %{"outcome" => "selected", "optionId" => "allow-once"}, ^state} =
             PermissionHandler.handle_permission_request(
               "session-full",
               tool_call,
               @options,
               state
             )

    outside =
      Path.join(System.tmp_dir!(), "permission-mcp-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    for {key_path, outside_path} <- [
          {["fallback", "mounted_at"], Path.join(outside, "contract.hwp.jsonl")},
          {["op", "src"], Path.join(outside, "signature.png")}
        ] do
      rejected_call =
        put_in(tool_call, ["rawInput", "_meta", "tool_params" | key_path], outside_path)

      assert {:ok, %{"outcome" => "selected", "optionId" => "reject-once"}, ^state} =
               PermissionHandler.handle_permission_request(
                 "session-full",
                 rejected_call,
                 @options,
                 state
               )
    end
  end

  test "Codex file-change grant roots and legacy fileChanges remain confined", %{root: root} do
    outside =
      Path.join(
        System.tmp_dir!(),
        "permission-grant-outside-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:ok, state} =
             PermissionHandler.init(access_control: "full-workspace", workspace_root: root)

    assert {:ok, %{"outcome" => "selected", "optionId" => "allow-once"}, ^state} =
             PermissionHandler.handle_permission_request(
               "session-full",
               %{
                 "toolName" => "edit",
                 "kind" => "edit",
                 "rawInput" => %{
                   "fileChanges" => %{
                     Path.join(root, "contract.jsonl") => %{"type" => "update"}
                   }
                 }
               },
               @options,
               state
             )

    for raw_input <- [
          %{"grantRoot" => outside},
          %{"fileChanges" => %{Path.join(outside, "contract.jsonl") => %{"type" => "update"}}}
        ] do
      assert {:ok, %{"outcome" => "selected", "optionId" => "reject-once"}, ^state} =
               PermissionHandler.handle_permission_request(
                 "session-full",
                 %{"toolName" => "edit", "kind" => "edit", "rawInput" => raw_input},
                 @options,
                 state
               )
    end
  end

  test "rejects outside and symlinked paths even in full workspace", %{root: root} do
    outside =
      Path.join(System.tmp_dir!(), "permission-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.ln_s!(outside, Path.join(root, "linked-outside"))
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:ok, state} =
             PermissionHandler.init(access_control: "full-workspace", workspace_root: root)

    for path <- [Path.join(outside, "secret.txt"), "linked-outside/secret.txt"] do
      assert {:ok, %{"outcome" => "selected", "optionId" => "reject-once"}, ^state} =
               PermissionHandler.handle_permission_request(
                 "session-full",
                 %{"title" => "Write", "kind" => "edit", "path" => path},
                 @options,
                 state
               )
    end
  end

  test "full workspace fails closed for a command without a canonical cwd", %{root: root} do
    assert {:ok, state} =
             PermissionHandler.init(access_control: "full-workspace", workspace_root: root)

    assert {:ok, %{"outcome" => "selected", "optionId" => "reject-once"}, ^state} =
             PermissionHandler.handle_permission_request(
               "session-full",
               %{"title" => "Bash", "kind" => "execute", "rawInput" => %{"command" => "pwd"}},
               @options,
               state
             )
  end

  test "exports no ACP filesystem or terminal callbacks" do
    refute function_exported?(PermissionHandler, :handle_file_read, 4)
    refute function_exported?(PermissionHandler, :handle_file_write, 4)
    refute function_exported?(PermissionHandler, :handle_terminal_request, 4)
  end
end
