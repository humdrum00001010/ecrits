defmodule Ecrits.Doc.MCPServerVFSFallbackTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Ecrits.AcpAgent.Session, as: AgentSession
  alias Ecrits.Doc.{MCPServer, MCPToolPolicy, Pool, Projection}
  alias Ecrits.Fuse.{DocFs, DocMount}
  alias Ecrits.Fuse.OpenDocs
  alias Ecrits.Test.FileEhwpRuntime
  alias EcritsWeb.Plugs.DocToolsMCPPlug

  @marker_text "Approved by Alex [[STAMP]] on file"
  @marker "[[STAMP]]"

  setup do
    previous_vfs = Application.get_env(:ecrits, :doc_vfs)
    previous_runtime = Application.get_env(:ehwp, :runtime)
    previous_file_runtime_ref = Application.get_env(:ecrits, :file_ehwp_runtime_ref)
    Application.put_env(:ecrits, :doc_vfs, enabled: true)
    Application.put_env(:ehwp, :runtime, FileEhwpRuntime)
    Application.delete_env(:ecrits, :file_ehwp_runtime_ref)

    suffix =
      "#{System.unique_integer([:positive])}-#{Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)}"

    root = Path.join(System.tmp_dir!(), "ecrits-vfs-sequence-#{suffix}")

    source = Path.join(root, "contract.hwp")
    mounted_at = Path.join([root, ".ecrits", "contract.hwp.jsonl"])
    image = Path.join(root, "assets/stamp.png")
    brief = Path.join(root, "프로젝트_브리프.md")
    outside_image = root <> "-outside-stamp.png"
    linked_image = Path.join(root, "assets/linked-stamp.png")
    File.mkdir_p!(Path.dirname(mounted_at))
    File.mkdir_p!(Path.dirname(image))
    File.write!(source, @marker_text)
    File.write!(mounted_at, "mounted projection is not authoritative")
    File.write!(image, "original image bytes")
    File.write!(brief, "contract evidence")
    File.write!(outside_image, "outside image bytes")
    File.ln_s!(outside_image, linked_image)

    {:ok, document} = Pool.open(source, kind: :hwp)
    agent_id = "fg-vfs-sequence-#{System.unique_integer([:positive])}"

    agent_pid =
      start_supervised!(
        {AgentSession,
         id: agent_id,
         ctx: nil,
         provider: %{id: "codex"},
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         adapter_opts: [
           exmcp_adapter: EcritsWeb.FakeAcpAdapter,
           wait_for: :release_vfs_turn,
           test_pid: self()
         ],
         workspace_root: root,
         document_path: "contract.hwp",
         pool_document_id: document,
         mcp_servers: []},
        id: {:agent, agent_id}
      )

    :ok = Ecrits.AcpAgent.subscribe(agent_id)
    assert {:ok, %{id: turn_id}} = AgentSession.send_turn(agent_pid, nil, "fill contract")
    assert_receive {:agent_adapter_waiting, turn_task}, 2_000
    %{instance_id: instance_id} = AgentSession.tool_context(agent_pid)

    OpenDocs.open(root, "contract.hwp",
      agent_id: agent_id,
      instance_id: instance_id,
      turn_id: turn_id,
      source_path: source
    )

    baseline = projection("template picture placeholder [[STAMP]]")
    OpenDocs.cache_committed(root, "contract.hwp", baseline)

    sequence =
      MCPToolPolicy.new_vfs_sequence()
      |> MCPToolPolicy.record_vfs_open(
        %{
          "document" => document,
          "mounted_at" => mounted_at,
          "mount_name" => "contract.hwp",
          "path" => source,
          "mount_error" => nil
        },
        revision(baseline)
      )

    :ok = AgentSession.put_doc_vfs_sequence(agent_pid, turn_id, sequence)
    {:ok, state} = MCPServer.init([])

    on_exit(fn ->
      send(turn_task, :release_vfs_turn)
      Pool.close(document)
      OpenDocs.close(root, "contract.hwp")
      File.rm_rf(root)
      File.rm(outside_image)
      restore(:ecrits, :doc_vfs, previous_vfs)
      restore(:ehwp, :runtime, previous_runtime)
      restore(:ecrits, :file_ehwp_runtime_ref, previous_file_runtime_ref)
    end)

    {:ok,
     root: root,
     source: source,
     mounted_at: mounted_at,
     image: image,
     brief: brief,
     linked_image: linked_image,
     document: document,
     agent_id: agent_id,
     instance_id: instance_id,
     agent_pid: agent_pid,
     turn_task: turn_task,
     turn_id: turn_id,
     state: state}
  end

  test "actual handler requires a changed committed projection, not staged or mounted bytes",
       ctx do
    args = find_args(ctx)
    {:ok, primary_sequence} = AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    assert_terminal_find_error("acp_commit_required", call("doc.find", args, ctx.state))

    assert {:ok, %{phase: :native_marker_find_spent}} =
             AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    assert_terminal_find_error(
      "native_marker_find_already_used",
      call("doc.find", args, ctx.state)
    )

    changed = projection(@marker_text)
    OpenDocs.cache_committed(ctx.root, "contract.hwp", changed)
    OpenDocs.stage(ctx.root, "contract.hwp", changed, :partial_write)
    :ok = AgentSession.put_doc_vfs_sequence(ctx.agent_pid, ctx.turn_id, primary_sequence)
    assert_terminal_find_error("acp_commit_required", call("doc.find", args, ctx.state))

    OpenDocs.unstage(ctx.root, "contract.hwp")
    OpenDocs.uncache_committed(ctx.root, "contract.hwp")
    :ok = AgentSession.put_doc_vfs_sequence(ctx.agent_pid, ctx.turn_id, primary_sequence)

    # The mounted file exists and can contain anything, but it is never accepted
    # as post-commit authority without OpenDocs.committed/2.
    File.write!(ctx.mounted_at, changed)
    assert_terminal_find_error("acp_commit_required", call("doc.find", args, ctx.state))

    OpenDocs.cache_committed(ctx.root, "contract.hwp", changed)
    OpenDocs.record_write_failure(ctx.root, "contract.hwp", :engine_write_failed)
    :ok = AgentSession.put_doc_vfs_sequence(ctx.agent_pid, ctx.turn_id, primary_sequence)
    assert_terminal_find_error("acp_commit_required", call("doc.find", args, ctx.state))
  end

  test "projection broadcasts preserve the explicitly pinned ACP identity", ctx do
    Phoenix.PubSub.subscribe(
      Ecrits.PubSub,
      "doc_vfs:" <> Ecrits.Fuse.DocMount.canonical_root(ctx.root)
    )

    %{instance_id: instance_id} = AgentSession.tool_context(ctx.agent_pid)
    identity = [agent_id: ctx.agent_id, instance_id: instance_id, turn_id: ctx.turn_id]

    assert {:ok, %{previewed: 1}} =
             Projection.preview_write_back(
               ctx.source,
               projection("X"),
               [root: ctx.root, edit_id: "originating-turn-edit"] ++ identity
             )

    assert_receive {:vfs_doc_edited,
                    %{
                      agent_id: agent_id,
                      instance_id: ^instance_id,
                      turn_id: turn_id,
                      edit_id: "originating-turn-edit",
                      preview_only: true
                    }},
                   1_000

    assert agent_id == ctx.agent_id
    assert turn_id == ctx.turn_id

    assert {:ok, %{applied: 1}} =
             Projection.write_back(
               ctx.source,
               projection("X"),
               [root: ctx.root, edit_id: "originating-turn-edit"] ++ identity
             )

    assert_receive {:vfs_doc_edited,
                    %{
                      agent_id: ^agent_id,
                      instance_id: ^instance_id,
                      turn_id: ^turn_id,
                      edit_id: "originating-turn-edit"
                    } = committed},
                   1_000

    refute Map.get(committed, :preview_only, false)
  end

  test "DocFs pins one ACP turn across temp preview and later final rename", ctx do
    Phoenix.PubSub.subscribe(
      Ecrits.PubSub,
      "doc_vfs:" <> DocMount.canonical_root(ctx.root)
    )

    OpenDocs.set_writable(ctx.root, true)
    socket = Exfuse.Socket.new(DocMount.mount_point(ctx.root), %{root: ctx.root})
    temp = "/contract.hwp.jsonl.tmp"
    target = "/contract.hwp.jsonl"
    bytes = projection("X")

    assert {:reply, handle, socket} =
             DocFs.handle_event(:create, %{path: temp, flags: 0}, socket)

    assert {:reply, size, socket} =
             DocFs.handle_event(
               :write,
               %{path: temp, handle: handle, offset: 0, data: bytes},
               socket
             )

    assert size == byte_size(bytes)

    assert_receive {:vfs_doc_edited,
                    %{
                      turn_id: preview_turn_id,
                      edit_id: edit_id,
                      preview_only: true
                    }},
                   1_000

    assert preview_turn_id == ctx.turn_id

    assert {:noreply, socket} =
             DocFs.handle_event(
               :release,
               %{path: temp, flags: 0, handle: handle},
               socket
             )

    OpenDocs.open(ctx.root, "contract.hwp",
      agent_id: ctx.agent_id,
      instance_id: ctx.instance_id,
      turn_id: "later-queued-turn",
      source_path: ctx.source
    )

    assert {:noreply, _socket} =
             DocFs.handle_event(:rename, %{path: temp, target: target}, socket)

    assert_receive {:vfs_doc_edited,
                    %{
                      turn_id: ^preview_turn_id,
                      edit_id: ^edit_id
                    } = committed},
                   1_000

    refute Map.get(committed, :preview_only, false)
  end

  test "a malformed first marker lookup says the consumed attempt cannot be retried", ctx do
    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(@marker_text))

    malformed =
      ctx
      |> find_args()
      |> Map.put("pattern", "Approved by Alex")

    assert_terminal_find_error(
      "exact_native_marker_find_required",
      call("doc.find", malformed, ctx.state)
    )

    assert {:ok, %{phase: :native_marker_find_spent}} =
             AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    assert_terminal_find_error(
      "native_marker_find_already_used",
      call("doc.find", find_args(ctx), ctx.state)
    )
  end

  test "non-string first marker patterns are consumed without raising", ctx do
    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(@marker_text))
    {:ok, primary_sequence} = AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    for pattern <- [nil, 42, %{"unexpected" => "object"}, ["unexpected", "list"]] do
      :ok =
        AgentSession.put_doc_vfs_sequence(ctx.agent_pid, ctx.turn_id, primary_sequence)

      invalid = find_args(ctx) |> Map.put("pattern", pattern)

      assert_terminal_find_error(
        "exact_native_marker_find_required",
        call("doc.find", invalid, ctx.state)
      )

      assert {:ok, %{phase: :native_marker_find_spent}} =
               AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

      assert_terminal_find_error(
        "native_marker_find_already_used",
        call("doc.find", find_args(ctx), ctx.state)
      )
    end
  end

  test "actual handler enforces open-current first and rejects a second open", ctx do
    {:ok, empty_state} = MCPServer.init([])

    :ok =
      AgentSession.put_doc_vfs_sequence(
        ctx.agent_pid,
        ctx.turn_id,
        MCPToolPolicy.new_vfs_sequence()
      )

    assert_terminal_find_error(
      "native_marker_find_before_open",
      call("doc.find", Map.put(find_args(ctx), "pattern", "anything"), empty_state)
    )

    assert {:ok, %{phase: :awaiting_open, native_marker_find_spent?: true}} =
             AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    assert_error(
      "current_document_open_required",
      call("doc.open_doc", %{"_agent_id" => ctx.agent_id, "path" => "contract.hwp"}, empty_state)
    )

    assert {:ok, %{content: [_opened]}, opened_state} =
             call(
               "doc.open_doc",
               %{"_agent_id" => ctx.agent_id, "path" => "current"},
               empty_state
             )

    assert {:ok, %{phase: :acp_primary, native_marker_find_spent?: true}} =
             AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    assert_terminal_find_error(
      "native_marker_find_already_used",
      call("doc.find", find_args(ctx), opened_state)
    )

    assert_error(
      "doc_already_opened_for_turn",
      call(
        "doc.open_doc",
        %{"_agent_id" => ctx.agent_id, "path" => "current"},
        opened_state
      )
    )
  end

  test "actual handler spends one exact lookup and retains its returned ref", ctx do
    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(@marker_text))

    assert {:ok, %{content: [content]}, state} = call("doc.find", find_args(ctx), ctx.state)
    assert %{"matches" => [%{"before_marker_ref" => ref}]} = Jason.decode!(content.text)

    assert Jason.decode!(ref) == %{
             "section" => 0,
             "paragraph" => 77,
             "offset" => 17,
             "cellPath" => [
               %{"controlIndex" => 0, "cellIndex" => 3, "cellParaIndex" => 3}
             ]
           }

    assert_error("native_marker_find_already_used", call("doc.find", find_args(ctx), state))
  end

  # 2026-07-19: a full brief-driven fill left ten byte-identical
  # "대표자 성명 : ... (인)" rows, so a unique pattern could never address the
  # intended signature block. Ambiguity earns one corrected retry and an
  # occurrence ordinal instead of consuming the turn's only lookup.
  test "an ambiguous repeated pattern earns one retry and occurrence selects the target", ctx do
    text = "대표자 성명 : 김에크리츠 (인)"
    File.write!(ctx.source, text)

    Application.put_env(:ecrits, :file_ehwp_runtime_elements, [
      %{"type" => "paragraph", "text" => text, "ref" => "hwp:s0/p10/c0+0"},
      %{"type" => "paragraph", "text" => text, "ref" => "hwp:s0/p40/c0+0"}
    ])

    on_exit(fn -> Application.delete_env(:ecrits, :file_ehwp_runtime_elements) end)

    committed =
      Jason.encode!([
        [
          [%{"type" => "paragraph", "text" => text}],
          [%{"type" => "paragraph", "text" => text}]
        ]
      ])

    OpenDocs.cache_committed(ctx.root, "contract.hwp", committed)
    args = find_args(ctx, text, "(인)")

    assert_error("find_pattern_ambiguous", call("doc.find", args, ctx.state))

    assert {:ok, %{phase: :acp_primary, find_retry_used?: true} = retry_sequence} =
             AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    refute Map.get(retry_sequence, :native_marker_find_spent?)

    assert {:ok, %{content: [content]}, state} =
             call("doc.find", Map.put(args, "occurrence", 2), ctx.state)

    assert %{"matches" => [%{"before_marker_ref" => ref}]} = Jason.decode!(content.text)
    assert %{"paragraph" => 40} = Jason.decode!(ref)

    assert {:ok, %{phase: :native_marker_ref_ready, native_marker_ref: ^ref}} =
             AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    assert_error("native_marker_find_already_used", call("doc.find", args, state))
  end

  test "actual handler canonicalizes the live HWP cell ref at a Unicode marker offset", ctx do
    text = "수급사업자 한빛 (인)"
    File.write!(ctx.source, text)
    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(text))

    assert {:ok, %{content: [content]}, _state} =
             call("doc.find", find_args(ctx, text, "(인)"), ctx.state)

    assert %{"matches" => [%{"before_marker_ref" => ref, "marker_offset" => 9}]} =
             Jason.decode!(content.text)

    assert Jason.decode!(ref) == %{
             "section" => 0,
             "paragraph" => 77,
             "offset" => 9,
             "cellPath" => [
               %{"controlIndex" => 0, "cellIndex" => 3, "cellParaIndex" => 3}
             ]
           }
  end

  test "a malformed live HWP marker ref is terminal and cannot be retried", ctx do
    text = "수급사업자 한빛 (인)"
    File.write!(ctx.source, text)
    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(text))

    Application.put_env(
      :ecrits,
      :file_ehwp_runtime_ref,
      "hwp:s0/p77/tbl0/cellx/cp3/c0+18"
    )

    args = find_args(ctx, text, "(인)")
    assert_terminal_find_error("native_marker_not_found", call("doc.find", args, ctx.state))

    assert_terminal_find_error(
      "native_marker_find_already_used",
      call("doc.find", args, ctx.state)
    )
  end

  test "an authorized no-match is explicitly terminal and cannot be retried", ctx do
    text = "Archived by Sam <SEAL> on file"
    args = find_args(ctx, text, "<SEAL>")
    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(text))

    assert_terminal_find_error(
      "native_marker_not_found",
      call("doc.find", args, ctx.state)
    )

    assert {:ok, %{phase: :native_marker_find_spent}} =
             AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    assert_terminal_find_error(
      "native_marker_find_already_used",
      call("doc.find", args, ctx.state)
    )
  end

  test "an authorized downstream lookup error is explicitly terminal and cannot be retried",
       ctx do
    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(@marker_text))
    File.chmod!(ctx.source, 0o000)

    assert_terminal_find_error(
      "native_marker_lookup_failed",
      call("doc.find", find_args(ctx), ctx.state)
    )

    assert {:ok, %{phase: :native_marker_find_spent}} =
             AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    assert_terminal_find_error(
      "native_marker_find_already_used",
      call("doc.find", find_args(ctx), ctx.state)
    )
  end

  test "a source-evidence failure spends the native fallback attempt", ctx do
    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(@marker_text))
    {:ok, %{content: [content]}, ready_state} = call("doc.find", find_args(ctx), ctx.state)
    %{"matches" => [%{"before_marker_ref" => ref}]} = Jason.decode!(content.text)

    bad = edit_args(ctx, ref, Path.join(ctx.root, "missing-stamp.png"))

    assert {:ok, %{content: [error_content], isError: true}, spent_state} =
             call("doc.edit", bad, ready_state)

    assert %{"error" => "workspace_picture_source_required"} = Jason.decode!(error_content.text)

    assert_error(
      "native_marker_ref_required",
      call("doc.edit", edit_args(ctx, ref, ctx.image), spent_state)
    )
  end

  test "an in-workspace symlink to an outside image is rejected and spends the attempt", ctx do
    assert File.regular?(ctx.linked_image)

    assert {:error, {:symlink, _path}} =
             Ecrits.Path.join(ctx.root, Path.relative_to(ctx.linked_image, ctx.root))

    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(@marker_text))
    {:ok, %{content: [content]}, ready_state} = call("doc.find", find_args(ctx), ctx.state)
    %{"matches" => [%{"before_marker_ref" => ref}]} = Jason.decode!(content.text)

    assert {:ok, %{content: [error_content], isError: true}, spent_state} =
             call("doc.edit", edit_args(ctx, ref, ctx.linked_image), ready_state)

    assert %{"error" => "workspace_picture_source_required"} =
             Jason.decode!(error_content.text)

    assert_error(
      "native_marker_ref_required",
      call("doc.edit", edit_args(ctx, ref, ctx.image), spent_state)
    )
  end

  test "model-controlled sizing is rejected before doc.edit and spends the attempt", ctx do
    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(@marker_text))
    {:ok, %{content: [content]}, ready_state} = call("doc.find", find_args(ctx), ctx.state)
    %{"matches" => [%{"before_marker_ref" => ref}]} = Jason.decode!(content.text)

    sized_args =
      ctx
      |> edit_args(ref, ctx.image)
      |> update_in(["op"], &Map.put(&1, "width", 999))

    assert {:ok, %{content: [error_content], isError: true}, spent_state} =
             call("doc.edit", sized_args, ready_state)

    assert %{"error" => "vfs_fallback_unrepresentable_required"} =
             Jason.decode!(error_content.text)

    assert_error(
      "native_marker_ref_required",
      call("doc.edit", edit_args(ctx, ref, ctx.image), spent_state)
    )
  end

  test "the exact returned ref reaches the edit path byte-for-byte and is spent", ctx do
    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(@marker_text))
    {:ok, %{content: [content]}, ready_state} = call("doc.find", find_args(ctx), ctx.state)
    %{"matches" => [%{"before_marker_ref" => ref}]} = Jason.decode!(content.text)

    assert {:ok, %{content: [_downstream], isError: true}, spent_state} =
             call("doc.edit", edit_args(ctx, ref, ctx.image), ready_state)

    assert_error(
      "native_marker_ref_required",
      call("doc.edit", edit_args(ctx, ref, ctx.image), spent_state)
    )
  end

  test "streamable HTTP POSTs share the AgentSession sequence across fresh handlers", ctx do
    OpenDocs.cache_committed(ctx.root, "contract.hwp", projection(@marker_text))

    first = post_tool(ctx, 1, "doc.find", Map.delete(find_args(ctx), "_agent_id"))
    %{"result" => %{"content" => [%{"text" => find_json}]}} = first
    %{"matches" => [%{"before_marker_ref" => ref}]} = Jason.decode!(find_json)

    second = post_tool(ctx, 2, "doc.find", Map.delete(find_args(ctx), "_agent_id"))
    assert rpc_tool_error(second, "native_marker_find_already_used")

    _edit_attempt =
      post_tool(ctx, 3, "doc.edit", Map.delete(edit_args(ctx, ref, ctx.image), "_agent_id"))

    spent =
      post_tool(ctx, 4, "doc.edit", Map.delete(edit_args(ctx, ref, ctx.image), "_agent_id"))

    assert rpc_tool_error(spent, "native_marker_ref_required")
  end

  test "separate HTTP POSTs expose only the existing surface and require open-current first",
       ctx do
    :ok =
      AgentSession.put_doc_vfs_sequence(
        ctx.agent_pid,
        ctx.turn_id,
        MCPToolPolicy.new_vfs_sequence()
      )

    assert %{"result" => %{"tools" => tools}} = post_rpc(ctx, 10, "tools/list", %{})
    assert Enum.map(tools, & &1["name"]) == ["doc.open_doc", "doc.find", "doc.edit"]

    open_tool = Enum.find(tools, &(&1["name"] == "doc.open_doc"))
    assert get_in(open_tool, ["inputSchema", "properties", "path", "const"]) == "current"

    before_open = post_tool(ctx, 11, "doc.find", Map.delete(find_args(ctx), "_agent_id"))
    assert rpc_tool_error(before_open, "native_marker_find_before_open")

    wrong_open = post_tool(ctx, 12, "doc.open_doc", %{"path" => "contract.hwp"})
    assert rpc_tool_error(wrong_open, "current_document_open_required")

    assert %{"result" => %{"content" => [%{"text" => opened_json}]}} =
             post_tool(ctx, 13, "doc.open_doc", %{"path" => "current"})

    document = ctx.document

    assert %{
             "document" => ^document,
             "mounted_at" => mounted_at,
             "mount_error" => nil,
             "workspace_files" => workspace_files
           } = Jason.decode!(opened_json)

    assert is_binary(mounted_at) and mounted_at != ""

    assert Enum.any?(workspace_files, &match?(%{"path" => "프로젝트_브리프.md", "kind" => "text"}, &1))

    assert Enum.any?(
             workspace_files,
             &match?(%{"path" => "assets/stamp.png", "kind" => "picture"}, &1)
           )

    refute Enum.any?(workspace_files, &(&1["path"] == "contract.hwp"))
    refute Enum.any?(workspace_files, &String.starts_with?(&1["path"], ".ecrits/"))

    repeated = post_tool(ctx, 14, "doc.open_doc", %{"path" => "current"})
    assert rpc_tool_error(repeated, "doc_already_opened_for_turn")
  end

  test "the durable tool sequence is discarded with its ACP turn", ctx do
    assert {:ok, %{phase: :acp_primary}} =
             AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    send(ctx.turn_task, :release_vfs_turn)

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: turn_id}}, 2_000
    assert turn_id == ctx.turn_id

    assert {:error, :turn_mismatch} =
             AgentSession.doc_vfs_sequence(ctx.agent_pid, ctx.turn_id)

    unavailable = post_tool(ctx, 15, "doc.open_doc", %{"path" => "current"})
    assert rpc_tool_error(unavailable, "doc_turn_unavailable")
  end

  test "VFS catalog exposes only open, one strict lookup, and picture fallback" do
    {:ok, state} = MCPServer.init([])
    assert {:ok, tools, nil, ^state} = MCPServer.handle_list_tools(nil, state)

    assert Enum.map(tools, & &1.name) == ["doc.open_doc", "doc.find", "doc.edit"]
    edit = Enum.find(tools, &(&1.name == "doc.edit"))
    assert edit.inputSchema["required"] == ["document", "op", "fallback"]
  end

  defp call(name, args, _discarded_prior_request_state) do
    {:ok, fresh_request_state} = MCPServer.init([])
    MCPServer.handle_call_tool(name, args, fresh_request_state)
  end

  defp find_args(ctx, text \\ @marker_text, marker \\ @marker) do
    %{
      "_agent_id" => ctx.agent_id,
      "document" => ctx.document,
      "pattern" => text,
      "type" => "paragraph",
      "marker" => marker,
      "case_sensitive" => true,
      "limit" => 1
    }
  end

  defp edit_args(ctx, ref, src) do
    %{
      "_agent_id" => ctx.agent_id,
      "document" => ctx.document,
      "op" => %{
        "op" => "insert_picture",
        "ref" => ref,
        "src" => src
      },
      "fallback" => %{
        "attempted" => "vfs",
        "reason" => "unrepresentable",
        "detail" => "overlay immediately before the existing marker",
        "mounted_at" => ctx.mounted_at
      }
    }
  end

  defp assert_error(expected, {:ok, %{content: [content], isError: true}, _state}) do
    payload = Jason.decode!(content.text)
    assert %{"error" => ^expected} = payload
    payload
  end

  defp assert_terminal_find_error(expected, result) do
    assert %{"message" => message} = assert_error(expected, result)
    assert message =~ "consumed"
    assert message =~ "Do not call doc.find again"
  end

  defp post_tool(ctx, id, name, arguments) do
    post_rpc(ctx, id, "tools/call", %{"name" => name, "arguments" => arguments})
  end

  defp post_rpc(ctx, id, method, params) do
    body = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}

    conn(:post, "/mcp/doc-tools/#{URI.encode(ctx.agent_id)}", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", "2025-06-18")
    |> DocToolsMCPPlug.call(DocToolsMCPPlug.init([]))
    |> Map.fetch!(:resp_body)
    |> Jason.decode!()
  end

  defp rpc_tool_error(
         %{"result" => %{"content" => [%{"text" => json}], "isError" => true}},
         error
       ) do
    match?(%{"error" => ^error}, Jason.decode!(json))
  end

  defp rpc_tool_error(_response, _error), do: false

  defp projection(text), do: Jason.encode!([[[%{"type" => "paragraph", "text" => text}]]])
  defp revision(bytes), do: :crypto.hash(:sha256, bytes)

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
