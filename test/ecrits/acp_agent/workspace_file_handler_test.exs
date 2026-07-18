defmodule Ecrits.AcpAgent.WorkspaceFileHandlerTest do
  use ExUnit.Case, async: true

  alias Ecrits.AcpAgent.WorkspaceFileHandler
  alias Ecrits.AcpAgent.Session
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-acp-file-handler-#{System.unique_integer([:positive])}"
      )

    source = Path.join(root, "working/contract.hwp")
    mount_name = "working%2Fcontract.hwp"
    projection = Path.join(root, ".ecrits/#{mount_name}.jsonl")
    brief = Path.join(root, "brief.md")
    raw_document = source

    File.mkdir_p!(Path.dirname(projection))
    File.mkdir_p!(Path.dirname(source))
    File.write!(projection, ~s({"text":"old"}\n{"text":"other"}\n))
    File.write!(brief, "one\ntwo\nthree\n")
    File.write!(raw_document, <<0, 1, 2, 3>>)

    OpenDocs.open(root, mount_name,
      source_path: source,
      agent_id: "agent-1",
      instance_id: "instance-1",
      turn_id: "turn-1"
    )

    on_exit(fn ->
      OpenDocs.close(root, mount_name)
      File.rm_rf(root)
    end)

    %{
      root: root,
      source: source,
      mount_name: mount_name,
      projection: projection,
      brief: brief,
      raw_document: raw_document
    }
  end

  test "reads bounded workspace evidence and the exact active projection", context do
    state = handler_state(context)

    assert {:ok, "two\nthree", state} =
             WorkspaceFileHandler.handle_file_read(
               "session-1",
               "brief.md",
               %{"line" => 2, "limit" => 2},
               state
             )

    assert {:ok, ~s({"text":"old"}\n{"text":"other"}\n), _state} =
             WorkspaceFileHandler.handle_file_read(
               "session-1",
               context.projection,
               %{},
               state
             )
  end

  test "denies traversal, raw documents, hidden files, symlinks, and hardlinks", context do
    state = handler_state(context)

    assert_read_error(state, "../outside.md", "path_outside_workspace")
    assert_read_error(state, "working/contract.hwp", "raw_document_denied")

    other_projection = Path.join(context.root, ".ecrits/other.hwp.jsonl")
    File.write!(other_projection, ~s({"text":"other"}\n))
    assert_read_error(state, other_projection, "hidden_path_denied")

    symlink = Path.join(context.root, "brief-link.md")
    File.ln_s!(context.brief, symlink)

    assert {:error, reason, ^state} =
             WorkspaceFileHandler.handle_file_read("session-1", symlink, %{}, state)

    assert reason in ["symlink_denied", "path_outside_workspace"]

    hardlink = Path.join(context.root, "brief-hardlink.md")
    File.ln!(context.brief, hardlink)
    assert_read_error(state, hardlink, "hardlink_denied")
  end

  test "writes valid JSONL through the exact projection.tmp rename protocol", context do
    state = handler_state(context)
    content = ~s({"text":"new"}\n{"table":{"rows":4}}\n)

    assert {:ok, _state} =
             WorkspaceFileHandler.handle_file_write(
               "session-1",
               context.projection,
               content,
               write_opts(context.projection),
               state
             )

    assert File.read!(context.projection) == content
    refute File.exists?(context.projection <> ".tmp")
  end

  @tag :edit_failure
  test "leaves accepted raw and canonical pending until the terminal finalizer", context do
    state = handler_state(context)
    accepted = ~s({"text":"accepted raw"}\n)
    canonical = ~s({"text":"canonical engine output"}\n)

    owner = %{
      agent_id: "agent-1",
      instance_id: "instance-1",
      turn_id: "turn-1",
      source_path: context.source
    }

    OpenDocs.accept_projection(
      context.root,
      context.mount_name,
      accepted,
      canonical,
      owner
    )

    File.write!(context.projection, accepted)

    other_name = "other.hwp"
    other_source = Path.join(context.root, other_name)
    File.write!(other_source, <<0, 1, 2, 3>>)

    OpenDocs.open(context.root, other_name,
      source_path: other_source,
      agent_id: "agent-2",
      instance_id: "instance-2",
      turn_id: "turn-2"
    )

    OpenDocs.accept_projection(
      context.root,
      other_name,
      "other raw",
      "other canonical",
      %{
        agent_id: "agent-2",
        instance_id: "instance-2",
        turn_id: "turn-2",
        source_path: other_source
      }
    )

    on_exit(fn -> OpenDocs.close(context.root, other_name) end)

    assert {:ok, ^accepted, state} =
             WorkspaceFileHandler.handle_file_read(
               "session-1",
               context.projection,
               %{},
               state
             )

    assert {:ok, _state} =
             WorkspaceFileHandler.handle_file_write(
               "session-1",
               context.projection,
               accepted,
               write_opts(context.projection),
               state
             )

    assert File.read!(context.projection) == accepted
    assert {:ok, ^accepted} = OpenDocs.committed(context.root, context.mount_name)

    assert {:ok, %{accepted_bytes: ^accepted, bytes: ^canonical}} =
             OpenDocs.pending_canonical(context.root, context.mount_name)

    assert {:ok, "other raw"} = OpenDocs.committed(context.root, other_name)

    assert {:ok, %{bytes: "other canonical"}} =
             OpenDocs.pending_canonical(context.root, other_name)
  end

  @tag :edit_failure
  test "rejects malformed JSONL, a different projection, and read-only writes", context do
    state = handler_state(context)
    original = File.read!(context.projection)

    assert {:error, "invalid JSONL at line 2", ^state} =
             WorkspaceFileHandler.handle_file_write(
               "session-1",
               context.projection,
               ~s({"ok":true}\nnot-json\n),
               write_opts(context.projection),
               state
             )

    assert File.read!(context.projection) == original

    assert {:error, "wrong_projection", ^state} =
             WorkspaceFileHandler.handle_file_write(
               "session-1",
               Path.join(context.root, ".ecrits/other.hwp.jsonl"),
               ~s({"ok":true}\n),
               write_opts(context.projection),
               state
             )

    read_only = handler_state(context, read_only?: true)

    assert {:error, "read_only", ^read_only} =
             WorkspaceFileHandler.handle_file_write(
               "session-1",
               context.projection,
               ~s({"ok":true}\n),
               write_opts(context.projection),
               read_only
             )
  end

  test "binds file access to one ACP provider session", context do
    state = handler_state(context)

    assert {:ok, _content, state} =
             WorkspaceFileHandler.handle_file_read("session-1", "brief.md", %{}, state)

    assert {:error, "wrong_acp_session", ^state} =
             WorkspaceFileHandler.handle_file_read("session-2", "brief.md", %{}, state)
  end

  test "binds production session_pid access to the live agent instance and turn", context do
    agent_id = "handler-live-#{Ecto.UUID.generate()}"

    session_pid =
      start_supervised!(
        {Session,
         id: agent_id,
         ctx: nil,
         provider: %{id: "codex"},
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         adapter_opts: [
           exmcp_adapter: EcritsWeb.FakeAcpAdapter,
           wait_for: :release_handler_turn,
           test_pid: self()
         ],
         workspace_root: context.root,
         document_path: "working/contract.hwp",
         pool_document_id: "document-1",
         mcp_servers: []},
        id: {:handler_session, agent_id}
      )

    assert {:ok, %{id: turn_id}} = Session.send_turn(session_pid, nil, "edit")
    assert_receive {:agent_adapter_waiting, turn_task}, 2_000

    %{instance_id: instance_id} = Session.tool_context(session_pid)

    OpenDocs.open(context.root, context.mount_name,
      source_path: context.source,
      agent_id: agent_id,
      instance_id: instance_id,
      turn_id: turn_id
    )

    {:ok, state} =
      WorkspaceFileHandler.init(
        workspace_root: context.root,
        session_pid: session_pid,
        read_only?: false
      )

    assert {:ok, "one\ntwo\nthree\n", state} =
             WorkspaceFileHandler.handle_file_read("session-live", context.brief, %{}, state)

    content = ~s({"text":"live owner"}\n)

    assert {:ok, _state} =
             WorkspaceFileHandler.handle_file_write(
               "session-live",
               context.projection,
               content,
               write_opts(context.projection),
               state
             )

    assert File.read!(context.projection) == content
    send(turn_task, :release_handler_turn)
  end

  @tag :edit_failure
  test "requires doc.open_doc registration and follows its exact flattened mount name", context do
    state = handler_state(context)
    OpenDocs.close(context.root, context.mount_name)

    assert_read_error(state, context.projection, "document_not_open")

    assert {:error, "document_not_open", ^state} =
             WorkspaceFileHandler.handle_file_write(
               "session-1",
               context.projection,
               ~s({"text":"new"}\n),
               write_opts(context.projection),
               state
             )
  end

  @tag :edit_failure
  test "rejects stale writes and a changed agent/turn owner", context do
    state = handler_state(context)
    stale_opts = write_opts(context.projection)
    File.write!(context.projection, ~s({"text":"newer"}\n))

    assert {:error, "stale_projection", ^state} =
             WorkspaceFileHandler.handle_file_write(
               "session-1",
               context.projection,
               ~s({"text":"stale edit"}\n),
               stale_opts,
               state
             )

    OpenDocs.open(context.root, context.mount_name,
      source_path: context.source,
      agent_id: "agent-2",
      instance_id: "instance-2",
      turn_id: "turn-2"
    )

    assert {:error, "projection_owner_changed", ^state} =
             WorkspaceFileHandler.handle_file_write(
               "session-1",
               context.projection,
               ~s({"text":"wrong owner"}\n),
               write_opts(context.projection),
               state
             )
  end

  @tag :edit_failure
  test "exclusive staging rejects a pre-existing temp symlink", context do
    state = handler_state(context)
    outside = Path.join(context.root, "outside.txt")
    File.write!(outside, "keep")
    File.ln_s!(outside, context.projection <> ".tmp")

    assert {:error, "projection_temp_exists", ^state} =
             WorkspaceFileHandler.handle_file_write(
               "session-1",
               context.projection,
               ~s({"text":"new"}\n),
               write_opts(context.projection),
               state
             )

    assert File.read!(outside) == "keep"
  end

  test "recovers a regular single-link temp stranded by a killed writer", context do
    state = handler_state(context)
    File.write!(context.projection <> ".tmp", ~s({"text":"partial"}\n))
    content = ~s({"text":"recovered"}\n)

    assert {:ok, _state} =
             WorkspaceFileHandler.handle_file_write(
               "session-1",
               context.projection,
               content,
               write_opts(context.projection),
               state
             )

    assert File.read!(context.projection) == content
    refute File.exists?(context.projection <> ".tmp")
  end

  test "a wedged unremovable temp still fails closed after the canonical retry", context do
    # take9 regression shape: a temp the writer cannot reclaim (here a
    # directory) keeps failing closed with projection_temp_exists — but only
    # after the handler has given DocFs.flush_canonical one chance to resolve
    # a stuck in-flight commit and re-clear.
    state = handler_state(context)
    File.mkdir_p!(context.projection <> ".tmp")

    assert {:error, "projection_temp_exists", ^state} =
             WorkspaceFileHandler.handle_file_write(
               "session-1",
               context.projection,
               ~s({"text":"new"}\n),
               write_opts(context.projection),
               state
             )

    assert File.dir?(context.projection <> ".tmp")
  end

  # 2026-07-19 take15 field bug: every ACP permission request was blanket-
  # rejected regardless of rail mode, so a Full-workspace agent reported
  # "승인이 거절되어" and degraded to sandbox-only fallbacks. The mode toggle is
  # the user's standing answer: Full workspace grants, Read only refuses.
  test "grants permission requests on a full-workspace rail, single-use first", context do
    state = handler_state(context)

    options = [
      %{"kind" => "allow_always", "optionId" => "always"},
      %{"kind" => "allow_once", "optionId" => "once"},
      %{"kind" => "reject_once", "optionId" => "no"}
    ]

    assert {:ok, %{"outcome" => "selected", "optionId" => "once"}, ^state} =
             WorkspaceFileHandler.handle_permission_request("session-1", %{}, options, state)

    assert {:ok, %{"outcome" => "selected", "optionId" => "always"}, ^state} =
             WorkspaceFileHandler.handle_permission_request(
               "session-1",
               %{},
               [
                 %{"kind" => "allow_always", "optionId" => "always"},
                 %{"kind" => "reject_once", "optionId" => "no"}
               ],
               state
             )

    assert {:ok, %{"outcome" => "cancelled"}, ^state} =
             WorkspaceFileHandler.handle_permission_request(
               "session-1",
               %{},
               [%{"kind" => "reject_once", "optionId" => "no"}],
               state
             )
  end

  test "keeps refusing permission requests on a read-only rail", context do
    state = handler_state(context, read_only?: true)

    options = [
      %{"kind" => "allow_once", "optionId" => "once"},
      %{"kind" => "reject_always", "optionId" => "never"},
      %{"kind" => "reject_once", "optionId" => "no"}
    ]

    assert {:ok, %{"outcome" => "selected", "optionId" => "no"}, ^state} =
             WorkspaceFileHandler.handle_permission_request("session-1", %{}, options, state)

    assert {:ok, %{"outcome" => "cancelled"}, ^state} =
             WorkspaceFileHandler.handle_permission_request(
               "session-1",
               %{},
               [%{"kind" => "allow_once", "optionId" => "once"}],
               state
             )
  end

  test "canonicalizes the macOS /tmp alias to the exact mount root" do
    if :os.type() == {:unix, :darwin} do
      alias_root = "/tmp/ecrits-acp-root-#{System.unique_integer([:positive])}"
      root = DocMount.canonical_root(alias_root)
      source = Path.join(root, "contract.hwp")
      projection = Path.join(DocMount.mount_point(root), "contract.hwp.jsonl")

      File.mkdir_p!(Path.dirname(projection))
      File.write!(source, <<0, 1>>)
      File.write!(projection, ~s({"text":"canonical"}\n))

      OpenDocs.open(alias_root, "contract.hwp",
        source_path: source,
        agent_id: "agent-1",
        instance_id: "instance-1",
        turn_id: "turn-1"
      )

      on_exit(fn ->
        OpenDocs.close(alias_root, "contract.hwp")
        File.rm_rf(root)
      end)

      {:ok, state} =
        WorkspaceFileHandler.init(
          workspace_root: alias_root,
          document_path: "contract.hwp",
          expected_identity: %{
            agent_id: "agent-1",
            instance_id: "instance-1",
            turn_id: "turn-1"
          }
        )

      assert {:ok, ~s({"text":"canonical"}\n), _state} =
               WorkspaceFileHandler.handle_file_read("session-1", projection, %{}, state)
    end
  end

  defp handler_state(context, opts \\ []) do
    {:ok, state} =
      WorkspaceFileHandler.init(
        [
          workspace_root: context.root,
          document_path: "working/contract.hwp",
          expected_identity: %{
            agent_id: "agent-1",
            instance_id: "instance-1",
            turn_id: "turn-1"
          }
        ] ++ opts
      )

    state
  end

  defp assert_read_error(state, path, expected) do
    assert {:error, ^expected, ^state} =
             WorkspaceFileHandler.handle_file_read("session-1", path, %{}, state)
  end

  defp write_opts(path) do
    {:ok, content} = File.read(path)

    %{
      "expectedSha256" => :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    }
  end
end
