defmodule Ecrits.Fuse.DocFsTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Projection
  alias Ecrits.Fuse.DocFs
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs

  @hwpx_fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)

  test "terminal cleanup CAS cannot remove a newer same-owner edit generation" do
    root = tmp_root("doc_fs_staged_generation")

    on_exit(fn ->
      OpenDocs.unstage(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      edit_id: "same-edit"
    }

    OpenDocs.stage(
      root,
      "doc.hwpx",
      "[",
      {:invalid_ir_json, "["},
      owner
    )

    assert [{"doc.hwpx", old_bytes, old_reason, old_identity}] =
             OpenDocs.staged_with_identity(root)

    OpenDocs.stage(
      root,
      "doc.hwpx",
      "[",
      {:invalid_ir_json, "["},
      owner
    )

    assert [{"doc.hwpx", new_bytes, new_reason, new_identity}] =
             OpenDocs.staged_with_identity(root)

    assert new_identity.stage_generation > old_identity.stage_generation

    assert Map.delete(new_identity, :stage_generation) ==
             Map.delete(old_identity, :stage_generation)

    assert new_bytes == old_bytes
    assert new_reason == old_reason

    assert {:error, :stale} =
             OpenDocs.discard_staged(
               root,
               "doc.hwpx",
               old_bytes,
               old_reason,
               old_identity
             )

    assert [{"doc.hwpx", ^new_bytes, ^new_reason, ^new_identity}] =
             OpenDocs.staged_with_identity(root)

    assert :ok =
             OpenDocs.discard_staged(
               root,
               "doc.hwpx",
               new_bytes,
               new_reason,
               new_identity
             )

    assert OpenDocs.staged(root, "doc.hwpx") == :error
  end

  test "terminal cleanup discards the exact captured generation of a closed document" do
    root = tmp_root("doc_fs_closed_stage_cleanup")

    on_exit(fn ->
      OpenDocs.unstage(root, "closed.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "closed-agent",
      instance_id: "closed-instance",
      turn_id: "closed-turn",
      edit_id: "closed-edit"
    }

    OpenDocs.stage(root, "closed.hwpx", "[", {:invalid_ir_json, "["}, owner)

    assert %{
             committed: [],
             rejected: [],
             pending: []
           } =
             DocFs.flush_staged(root,
               agent_id: owner.agent_id,
               instance_id: owner.instance_id,
               turn_id: owner.turn_id
             )

    assert OpenDocs.staged(root, "closed.hwpx") == :error
  end

  test "doc VFS identity canonicalizes /tmp and /private/tmp spellings" do
    root = Path.join("/tmp", "ecrits-doc-vfs-canonical-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    real_root = DocMount.canonical_root(root)

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    if real_root == root do
      IO.puts("\n[skip] /tmp is not a distinct realpath on this machine")
    else
      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      assert OpenDocs.member?(real_root, "doc.hwpx")
      assert OpenDocs.writable?(real_root)
      assert DocMount.mount_point(root) == Path.join(real_root, ".ecrits")

      assert Pool.document_id_for(Path.join(root, "doc.hwpx"), :hwpx) ==
               Pool.document_id_for(Path.join(real_root, "doc.hwpx"), :hwpx)
    end
  end

  test "readdir projects opened supported root documents as jsonl names" do
    root = tmp_root("doc_fs_readdir")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      OpenDocs.close(root, "notes.txt")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx")
    OpenDocs.open(root, "notes.txt")

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, names, _socket} = DocFs.handle_event(:readdir, %{path: "/"}, socket)
    assert names == [{"doc.hwpx.jsonl", {0o0644, 2, 0}}]
  end

  test "readdir projects opened nested documents through a flat mount name" do
    root = tmp_root("doc_fs_nested_readdir")
    source = Path.join(root, "drafts/doc.hwpx")
    mount_name = "drafts%2Fdoc.hwpx"

    on_exit(fn ->
      OpenDocs.close(root, mount_name)
      File.rm_rf(root)
    end)

    File.mkdir_p!(Path.dirname(source))
    File.write!(source, "fake-hwpx")
    OpenDocs.open(root, mount_name, source_path: source)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, names, _socket} = DocFs.handle_event(:readdir, %{path: "/"}, socket)
    assert names == [{"drafts%2Fdoc.hwpx.jsonl", {0o0644, 2, 0}}]
  end

  test "chmod accepts writable projected files and atomic rewrite temps" do
    root = tmp_root("doc_fs_chmod")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx")
    OpenDocs.set_writable(root, true)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:noreply, socket} =
             DocFs.handle_event(
               :chmod,
               %{path: "/doc.hwpx.jsonl", mode: 0o0644},
               socket
             )

    assert {:reply, _handle, socket} =
             DocFs.handle_event(
               :create,
               %{path: "/doc.hwpx.jsonl.tmp", flags: 0, mode: 0o0600},
               socket
             )

    assert {:noreply, _socket} =
             DocFs.handle_event(
               :chmod,
               %{path: "/doc.hwpx.jsonl.tmp", mode: 0o0644},
               socket
             )
  end

  test "reads and attrs expose a complete staged structural rewrite instead of truncating committed bytes" do
    root = tmp_root("doc_fs_staged_structural_read")
    source = Path.join(root, "doc.hwpx")
    committed = ~s({"version":"committed","padding":"longer old projection"})
    staged = ~s({"version":"staged"})

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    File.write!(source, "fake-hwpx")
    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.cache_committed(root, "doc.hwpx", committed)
    OpenDocs.stage(root, "doc.hwpx", staged, :structural_change)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, ^staged, socket} =
             DocFs.handle_event(
               :read,
               %{path: "/doc.hwpx.jsonl", offset: 0, size: byte_size(committed)},
               socket
             )

    assert {:reply, {_mode, _nlink, size, _mtime}, _socket} =
             DocFs.handle_event(:getattr, %{path: "/doc.hwpx.jsonl"}, socket)

    assert size == byte_size(staged)
  end

  test "a stale canonical claim cannot overwrite a newer accepted raw projection" do
    root = tmp_root("doc_fs_canonical_cas")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)

    owner_a = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    owner_b = %{
      agent_id: "agent-b",
      instance_id: "instance-b",
      turn_id: "turn-b",
      source_path: source
    }

    OpenDocs.accept_projection(root, "doc.hwpx", "raw-a", "canonical-a", owner_a)
    assert {:ok, first} = OpenDocs.pending_canonical(root, "doc.hwpx")

    assert [^first] =
             OpenDocs.pending_canonical_entries(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a"
             )

    assert [] =
             OpenDocs.pending_canonical_entries(root,
               agent_id: "agent-a",
               instance_id: "wrong-instance",
               turn_id: "turn-a"
             )

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    assert :ok = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, first)

    OpenDocs.accept_projection(root, "doc.hwpx", "raw-b", "canonical-b", owner_b)

    assert {:error, :stale} =
             OpenDocs.complete_canonical_echo(root, temp, "doc.hwpx", "canonical-a")

    assert :ok = OpenDocs.cancel_canonical_echo(root, temp)
    assert {:ok, "raw-b"} = OpenDocs.committed(root, "doc.hwpx")

    assert {:ok, %{accepted_bytes: "raw-b", bytes: "canonical-b"}} =
             OpenDocs.pending_canonical(root, "doc.hwpx")
  end

  test "a slower native projection cannot overwrite a newer generation with the same raw predecessor" do
    root = tmp_root("doc_fs_native_generation")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)

    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical-initial", %{
      source_path: source
    })

    assert {:ok, "raw", older_generation} =
             OpenDocs.begin_canonical_stage(root, "doc.hwpx")

    assert {:ok, "raw", newer_generation} =
             OpenDocs.begin_canonical_stage(root, "doc.hwpx")

    assert newer_generation > older_generation

    assert :ok =
             OpenDocs.complete_canonical_stage(
               root,
               "doc.hwpx",
               "raw",
               "canonical-newer",
               newer_generation,
               %{source_path: source, turn_id: "newer"}
             )

    assert {:error, :stale} =
             OpenDocs.complete_canonical_stage(
               root,
               "doc.hwpx",
               "raw",
               "canonical-older",
               older_generation,
               %{source_path: source, turn_id: "older"}
             )

    assert {:ok, "raw"} = OpenDocs.committed(root, "doc.hwpx")

    assert {:ok, %{bytes: "canonical-newer", generation: ^newer_generation, turn_id: "newer"}} =
             OpenDocs.pending_canonical(root, "doc.hwpx")
  end

  test "failed in-flight canonical projection remains owner-scoped and terminal retry publishes it" do
    root = tmp_root("doc_fs_in_flight_retry")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.cache_committed(root, "doc.hwpx", "raw")

    assert {:ok, "raw", generation} =
             OpenDocs.begin_canonical_stage(root, "doc.hwpx", owner)

    assert [
             %{
               accepted_bytes: "raw",
               generation: ^generation,
               name: "doc.hwpx",
               source_path: ^source
             }
           ] =
             OpenDocs.in_flight_canonical_entries(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a"
             )

    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error

    assert %{
             published: [],
             pending: [{"doc.hwpx", {:canonical_projection_failed, :unavailable}}]
           } =
             DocFs.flush_canonical(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a",
               mounted?: false,
               project_fun: fn ^source -> {:error, :unavailable} end
             )

    assert [%{generation: ^generation}] =
             OpenDocs.in_flight_canonical_entries(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a"
             )

    assert %{published: ["doc.hwpx"], pending: []} =
             DocFs.flush_canonical(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a",
               mounted?: false,
               project_fun: fn ^source -> {:ok, "canonical"} end
             )

    assert {:ok, "canonical"} = OpenDocs.committed(root, "doc.hwpx")
    assert [] = OpenDocs.in_flight_canonical_entries(root)
  end

  test "newer native stage preserves but blocks an older pending canonical generation" do
    root = tmp_root("doc_fs_in_flight_blocks_stale_pending")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)

    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical-old", %{
      agent_id: "agent-old",
      instance_id: "instance-old",
      turn_id: "turn-old",
      source_path: source
    })

    assert {:ok, old_pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    newer_owner = %{
      agent_id: "agent-new",
      instance_id: "instance-new",
      turn_id: "turn-new",
      source_path: source
    }

    assert {:ok, "raw", newer_generation} =
             OpenDocs.begin_canonical_stage(root, "doc.hwpx", newer_owner)

    canonical_root = DocMount.canonical_root(root)

    assert [
             {{:__vfs_committed__, ^canonical_root, "doc.hwpx"},
              %{in_flight: %{generation: ^newer_generation}, pending: ^old_pending}}
           ] =
             :ets.lookup(:ecrits_fuse_open_docs, {:__vfs_committed__, canonical_root, "doc.hwpx"})

    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error

    assert [] =
             OpenDocs.pending_canonical_entries(root,
               agent_id: "agent-old",
               instance_id: "instance-old",
               turn_id: "turn-old"
             )

    assert :ok =
             OpenDocs.complete_canonical_stage(
               root,
               "doc.hwpx",
               "raw",
               "canonical-new",
               newer_generation,
               newer_owner
             )

    assert {:ok,
            %{
              bytes: "canonical-new",
              generation: ^newer_generation,
              turn_id: "turn-new"
            }} = OpenDocs.pending_canonical(root, "doc.hwpx")
  end

  test "killing a canonical echo claimant restores its pending publication" do
    root = tmp_root("doc_fs_echo_claimant_killed")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", %{source_path: source})
    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    parent = self()

    {claimant, monitor_ref} =
      spawn_monitor(fn ->
        result = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, pending)
        send(parent, {:canonical_echo_claimed, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:canonical_echo_claimed, ^claimant, :ok}
    assert {:ok, %{temp_name: ^temp}} = OpenDocs.canonical_echo(root, temp)
    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error

    Process.exit(claimant, :kill)
    assert_receive {:DOWN, ^monitor_ref, :process, ^claimant, :killed}

    assert_eventually(fn ->
      OpenDocs.canonical_echo(root, temp) == :error and
        OpenDocs.pending_canonical(root, "doc.hwpx") == {:ok, pending}
    end)
  end

  test "flush synchronously reclaims a dead echo before its queued DOWN cleanup" do
    root = tmp_root("doc_fs_dead_echo_flush_race")
    source = Path.join(root, "doc.hwpx")
    mount = DocMount.mount_point(root)
    File.write!(source, "fake-hwpx")
    File.mkdir_p!(mount)

    on_exit(fn ->
      _ = :sys.resume(OpenDocs)
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", owner)
    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    temp_path = Path.join(mount, temp)
    File.write!(temp_path, "partial-canonical-echo")
    parent = self()

    {claimant, claimant_ref} =
      spawn_monitor(fn ->
        result = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, pending)
        send(parent, {:canonical_echo_claimed, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:canonical_echo_claimed, ^claimant, :ok}
    assert {:ok, %{temp_name: ^temp}} = OpenDocs.canonical_echo(root, temp)
    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error

    :ok = :sys.suspend(OpenDocs)

    flush =
      Task.async(fn ->
        DocFs.flush_canonical(root,
          agent_id: "agent-a",
          instance_id: "instance-a",
          turn_id: "turn-a",
          mounted?: false
        )
      end)

    assert_eventually(fn -> reclaim_call_queued?(flush.pid, root) end)

    Process.exit(claimant, :kill)
    assert_receive {:DOWN, ^claimant_ref, :process, ^claimant, :killed}
    refute Process.alive?(claimant)
    assert {:ok, %{temp_name: ^temp}} = OpenDocs.canonical_echo(root, temp)
    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error
    assert File.exists?(temp_path)

    :ok = :sys.resume(OpenDocs)

    assert %{published: ["doc.hwpx"], pending: []} = Task.await(flush)
    assert {:ok, "canonical"} = OpenDocs.committed(root, "doc.hwpx")
    assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error
    assert OpenDocs.canonical_echo(root, temp) == :error

    assert [] =
             :ets.match_object(
               :ecrits_fuse_open_docs,
               {{:__vfs_canonical_echo__, DocMount.canonical_root(root), :_}, :_}
             )

    refute File.exists?(temp_path)
  end

  test "dead echo cleanup releases OpenDocs before mounted unlink waits on file_server" do
    root = tmp_root("doc_fs_dead_echo_cleanup_lock")
    source = Path.join(root, "doc.hwpx")
    mount = DocMount.mount_point(root)
    File.write!(source, "fake-hwpx")
    File.mkdir_p!(mount)

    on_exit(fn ->
      _ = :sys.resume(OpenDocs)
      _ = :sys.resume(Process.whereis(:file_server_2))
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", owner)
    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    temp_path = Path.join(mount, temp)
    File.write!(temp_path, "partial-canonical-echo")
    parent = self()

    {claimant, claimant_ref} =
      spawn_monitor(fn ->
        result = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, pending)
        send(parent, {:canonical_echo_claimed, self(), result})
        receive do: (:stop -> :ok)
      end)

    assert_receive {:canonical_echo_claimed, ^claimant, :ok}

    supervisor = start_supervised!(Task.Supervisor)
    :ok = :sys.suspend(OpenDocs)

    flush =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DocFs.flush_canonical(root,
          agent_id: "agent-a",
          instance_id: "instance-a",
          turn_id: "turn-a",
          mounted?: false
        )
      end)

    assert_eventually(fn -> reclaim_call_queued?(flush.pid, root) end)

    Process.exit(claimant, :kill)
    assert_receive {:DOWN, ^claimant_ref, :process, ^claimant, :killed}

    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)
    :ok = :sys.resume(OpenDocs)

    assert_eventually(fn -> file_server_call_queued?(file_server, flush.pid) end)

    stage =
      Task.Supervisor.async_nolink(supervisor, fn ->
        OpenDocs.stage(root, "other.hwpx", "[", {:invalid_ir_json, "["}, owner)
      end)

    assert :ok = Task.await(stage, 1_000)
    :ok = :sys.resume(file_server)

    assert %{published: ["doc.hwpx"], pending: []} = Task.await(flush, 2_000)
    assert {:ok, "canonical"} = OpenDocs.committed(root, "doc.hwpx")
    refute File.exists?(temp_path)
  end

  test "closing during canonical echo removes the mounted temp after releasing OpenDocs" do
    root = tmp_root("doc_fs_close_during_echo")
    source = Path.join(root, "doc.hwpx")
    mount = DocMount.mount_point(root)
    File.write!(source, "fake-hwpx")
    File.mkdir_p!(mount)

    on_exit(fn ->
      _ = :sys.resume(Process.whereis(:file_server_2))
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", %{source_path: source})
    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    temp_path = Path.join(mount, temp)
    File.write!(temp_path, "partial-canonical-echo")
    assert :ok = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, pending)

    supervisor = start_supervised!(Task.Supervisor)
    file_server = Process.whereis(:file_server_2)
    :ok = :sys.suspend(file_server)

    close =
      Task.Supervisor.async_nolink(supervisor, fn ->
        OpenDocs.close(root, "doc.hwpx")
      end)

    assert_eventually(fn -> file_server_call_queued?(file_server, close.pid) end)

    stage =
      Task.Supervisor.async_nolink(supervisor, fn ->
        OpenDocs.stage(root, "unrelated.hwpx", "bytes", :test)
      end)

    assert :ok = Task.await(stage, 500)
    refute OpenDocs.member?(root, "doc.hwpx")
    assert OpenDocs.canonical_echo(root, temp) == :error
    assert {:ok, "partial-canonical-echo"} = Ecrits.FS.raw_read(temp_path)

    :ok = :sys.resume(file_server)
    assert :ok = Task.await(close, 1_000)
    refute File.exists?(temp_path)
  end

  test "legacy separate canonical pending row migrates without losing its owner" do
    root = tmp_root("doc_fs_legacy_pending_migration")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    canonical_root = DocMount.canonical_root(root)
    committed_key = {:__vfs_committed__, canonical_root, "doc.hwpx"}
    pending_key = {:__vfs_canonical_pending__, canonical_root, "doc.hwpx"}

    legacy_pending = %{
      name: "doc.hwpx",
      accepted_bytes: "raw",
      bytes: "canonical",
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    :ets.insert(:ecrits_fuse_open_docs, {committed_key, "raw"})
    :ets.insert(:ecrits_fuse_open_docs, {pending_key, legacy_pending})

    assert {:ok, "raw"} = OpenDocs.committed(root, "doc.hwpx")

    assert {:ok, %{bytes: "canonical", generation: 0, turn_id: "turn-a"}} =
             OpenDocs.pending_canonical(root, "doc.hwpx")

    assert [
             %{
               agent_id: "agent-a",
               generation: 0,
               instance_id: "instance-a",
               name: "doc.hwpx",
               source_path: ^source,
               turn_id: "turn-a"
             }
           ] =
             OpenDocs.dirty_owner_entries(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a"
             )

    assert :ets.lookup(:ecrits_fuse_open_docs, pending_key) == []
  end

  test "dirty ownership filters exact identity and source and clears only by CAS" do
    root = tmp_root("doc_fs_dirty_owner_cas")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    owner = %{
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    }

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", owner)

    filters = [
      agent_id: "agent-a",
      instance_id: "instance-a",
      turn_id: "turn-a",
      source_path: source
    ]

    assert [dirty_owner] = OpenDocs.dirty_owner_entries(root, filters)
    assert dirty_owner.source_path == source

    assert [] =
             OpenDocs.dirty_owner_entries(root,
               agent_id: "agent-a",
               instance_id: "instance-a",
               turn_id: "turn-a",
               source_path: Path.join(root, "another.hwpx")
             )

    stale_owner = Map.update!(dirty_owner, :generation, &(&1 + 1))
    assert {:error, :stale} = OpenDocs.clear_dirty_owner(root, "doc.hwpx", stale_owner)
    assert [^dirty_owner] = OpenDocs.dirty_owner_entries(root, filters)

    assert :ok = OpenDocs.clear_dirty_owner(root, "doc.hwpx", dirty_owner)
    assert [] = OpenDocs.dirty_owner_entries(root, filters)
    assert {:error, :not_dirty} = OpenDocs.clear_dirty_owner(root, "doc.hwpx", dirty_owner)
  end

  test "reserved canonical temps require a registered exact echo and bypass read-only policy" do
    root = tmp_root("doc_fs_internal_canonical_echo")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.set_writable(root, false)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", %{source_path: source})

    guessed = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:error, 5, _socket} =
             DocFs.handle_event(:create, %{path: "/" <> guessed, flags: 0}, socket)

    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")
    assert :ok = OpenDocs.begin_canonical_echo(root, "doc.hwpx", guessed, pending)

    {:reply, handle, socket} =
      DocFs.handle_event(:create, %{path: "/" <> guessed, flags: 0}, socket)

    {:reply, 5, socket} =
      DocFs.handle_event(
        :write,
        %{path: "/" <> guessed, handle: handle, offset: 0, data: "wrong"},
        socket
      )

    {:noreply, socket} =
      DocFs.handle_event(:release, %{path: "/" <> guessed, handle: handle}, socket)

    assert {:error, 5, _socket} =
             DocFs.handle_event(
               :rename,
               %{path: "/" <> guessed, target: "/doc.hwpx.jsonl"},
               socket
             )

    assert {:ok, "raw"} = OpenDocs.committed(root, "doc.hwpx")
    assert {:ok, %{bytes: "canonical"}} = OpenDocs.pending_canonical(root, "doc.hwpx")

    assert %{published: ["doc.hwpx"], pending: []} =
             DocFs.flush_canonical(root,
               mounted?: true,
               echo_fun: &echo_canonical_through_doc_fs/4
             )

    assert {:ok, "canonical"} = OpenDocs.committed(root, "doc.hwpx")

    read_socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    assert {:reply, "canonical", _read_socket} =
             DocFs.handle_event(
               :read,
               %{path: "/doc.hwpx.jsonl", offset: 0, size: 64},
               read_socket
             )
  end

  test "canonical publication exceptions restore the pending claim" do
    root = tmp_root("doc_fs_canonical_exception")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", %{source_path: source})

    assert %{published: [], pending: [{"doc.hwpx", {:canonical_publication_exception, _}}]} =
             DocFs.flush_canonical(root,
               mounted?: true,
               echo_fun: fn _root, _temp, _target, _bytes -> raise "echo crashed" end
             )

    assert {:ok, "raw"} = OpenDocs.committed(root, "doc.hwpx")

    assert {:ok, %{accepted_bytes: "raw", bytes: "canonical"}} =
             OpenDocs.pending_canonical(root, "doc.hwpx")

    assert %{
             published: [],
             pending: [{"doc.hwpx", {:canonical_publication_caught, :throw, :boom}}]
           } =
             DocFs.flush_canonical(root,
               mounted?: fn _root -> throw(:boom) end
             )

    assert {:ok, "raw"} = OpenDocs.committed(root, "doc.hwpx")

    assert {:ok, %{accepted_bytes: "raw", bytes: "canonical"}} =
             OpenDocs.pending_canonical(root, "doc.hwpx")
  end

  test "closing during an internal echo makes its reserved temp permanently unroutable" do
    root = tmp_root("doc_fs_closed_echo")
    source = Path.join(root, "doc.hwpx")
    File.write!(source, "fake-hwpx")

    on_exit(fn ->
      OpenDocs.close(root, "doc.hwpx")
      File.rm_rf(root)
    end)

    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.accept_projection(root, "doc.hwpx", "raw", "canonical", %{source_path: source})
    assert {:ok, pending} = OpenDocs.pending_canonical(root, "doc.hwpx")

    temp = ".ecrits-canonical-" <> Base.encode16(:crypto.strong_rand_bytes(8)) <> ".tmp"
    assert :ok = OpenDocs.begin_canonical_echo(root, "doc.hwpx", temp, pending)

    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    {:reply, handle, socket} =
      DocFs.handle_event(:create, %{path: "/" <> temp, flags: 0}, socket)

    OpenDocs.close(root, "doc.hwpx")
    OpenDocs.open(root, "doc.hwpx", source_path: source)
    OpenDocs.cache_committed(root, "doc.hwpx", "fresh-open")

    assert OpenDocs.canonical_echo(root, temp) == :error

    assert {:error, 5, socket} =
             DocFs.handle_event(
               :write,
               %{path: "/" <> temp, handle: handle, offset: 0, data: "canonical"},
               socket
             )

    assert {:error, 5, _socket} =
             DocFs.handle_event(
               :rename,
               %{path: "/" <> temp, target: "/doc.hwpx.jsonl"},
               socket
             )

    assert {:ok, "fresh-open"} = OpenDocs.committed(root, "doc.hwpx")
  end

  test "release rejects a complete unsupported structural rewrite while preserving it for correction" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs structural release e2e")
    else
      root = tmp_root("doc_fs_structural_release")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:reply, handle, socket} =
        DocFs.handle_event(:open, %{path: "/" <> projected, flags: 0}, socket)

      {:ok, bytes} = Projection.project_file(path)
      new_bytes = insert_duplicate_paragraph(bytes)

      {:noreply, socket} =
        DocFs.handle_event(:truncate, %{path: "/" <> projected, size: 0}, socket)

      assert {:reply, size, socket} =
               DocFs.handle_event(
                 :write,
                 %{path: "/" <> projected, handle: handle, offset: 0, data: new_bytes},
                 socket
               )

      assert size == byte_size(new_bytes)

      assert {:error, 22, socket} =
               DocFs.handle_event(
                 :release,
                 %{path: "/" <> projected, flags: 0, handle: handle},
                 socket
               )

      assert {:ok, ^new_bytes, {:structural_change, detail}} =
               OpenDocs.staged(root, "doc.hwpx")

      assert is_binary(detail) and detail != ""

      assert {:reply, ^new_bytes, _socket} =
               DocFs.handle_event(
                 :read,
                 %{path: "/" <> projected, offset: 0, size: byte_size(new_bytes)},
                 socket
               )

      assert {:ok, after_bytes} = Projection.project_file(path)
      refute after_bytes == new_bytes
    end
  end

  test "release failure broadcasts the exact provisional preview rejection" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs release rejection e2e")
    else
      root = tmp_root("doc_fs_release_preview_rejection")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)
      owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx",
        agent_id: owner.agent_id,
        instance_id: owner.instance_id,
        turn_id: owner.turn_id,
        source_path: path
      )

      OpenDocs.set_writable(root, true)
      Phoenix.PubSub.subscribe(Ecrits.PubSub, "doc_vfs:" <> DocMount.canonical_root(root))

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:reply, handle, socket} =
        DocFs.handle_event(:open, %{path: "/" <> projected, flags: 0}, socket)

      {:ok, original} = Projection.project_file(path)
      edited = replace_first_cell_text(original, "DOCFS_RELEASE_REJECTED_PREVIEW")

      assert {:ok, %{id: document_id}} = Pool.info_by_path(path)
      assert {:server, editor} = Pool.route(document_id)
      assert %{handle: %{ehwp: %Ehwp.Handle{id: ehwp_handle_id}}} = :sys.get_state(editor)
      assert [{ehwp_session, _value}] = Registry.lookup(Ehwp.Registry, ehwp_handle_id)

      :sys.replace_state(ehwp_session, fn state ->
        %{state | runtime: Ecrits.Test.FailingEditEhwpRuntime}
      end)

      previous_runtime = Application.get_env(:ehwp, :runtime)
      Application.put_env(:ehwp, :runtime, Ecrits.Test.FailingEditEhwpRuntime)

      on_exit(fn ->
        if previous_runtime do
          Application.put_env(:ehwp, :runtime, previous_runtime)
        else
          Application.delete_env(:ehwp, :runtime)
        end

        if Process.alive?(ehwp_session) do
          :sys.replace_state(ehwp_session, &%{&1 | runtime: Ehwp.Runtime})
        end
      end)

      {:noreply, socket} =
        DocFs.handle_event(:truncate, %{path: "/" <> projected, size: 0}, socket)

      assert {:reply, size, socket} =
               DocFs.handle_event(
                 :write,
                 %{path: "/" <> projected, handle: handle, offset: 0, data: edited},
                 socket
               )

      assert size == byte_size(edited)
      assert_receive {:vfs_doc_edited, %{preview_only: true} = preview}
      refute_receive {:vfs_doc_edited, %{phase: :rejected}}

      assert {:error, _errno, _socket} =
               DocFs.handle_event(
                 :release,
                 %{path: "/" <> projected, flags: 0, handle: handle},
                 socket
               )

      assert_receive {:vfs_doc_edited, %{phase: :rejected} = rejected}
      assert rejected.edit_id == preview.edit_id
      assert rejected.revision == preview.revision
      assert Map.take(rejected, [:agent_id, :instance_id, :turn_id]) == owner
      refute_receive {:vfs_doc_edited, %{phase: :rejected}}, 20
    end
  end

  test "sibling temp rename rejects an unsupported structural rewrite as EINVAL and keeps the temp" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs structural temp rename e2e")
    else
      root = tmp_root("doc_fs_structural_temp_rename")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      temp = projected <> ".tmp"
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:reply, temp_handle, socket} =
        DocFs.handle_event(:create, %{path: "/" <> temp, flags: 0}, socket)

      {:ok, bytes} = Projection.project_file(path)
      OpenDocs.cache_committed(root, "doc.hwpx", bytes)
      new_bytes = insert_duplicate_paragraph(bytes)

      assert {:reply, size, socket} =
               DocFs.handle_event(
                 :write,
                 %{path: "/" <> temp, handle: temp_handle, offset: 0, data: new_bytes},
                 socket
               )

      assert size == byte_size(new_bytes)

      assert {:noreply, socket} =
               DocFs.handle_event(
                 :release,
                 %{path: "/" <> temp, flags: 0, handle: temp_handle},
                 socket
               )

      OpenDocs.stage(root, "doc.hwpx", new_bytes, :structural_change)
      assert {:ok, ^new_bytes, :structural_change} = OpenDocs.staged(root, "doc.hwpx")

      assert {:error, 22, socket} =
               DocFs.handle_event(
                 :rename,
                 %{path: "/" <> temp, target: "/" <> projected},
                 socket
               )

      assert {:reply, ^new_bytes, _socket} =
               DocFs.handle_event(
                 :read,
                 %{path: "/" <> temp, offset: 0, size: byte_size(new_bytes)},
                 socket
               )

      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert {:ok, ^bytes} = OpenDocs.committed(root, "doc.hwpx")

      assert {:reply, ^bytes, socket} =
               DocFs.handle_event(
                 :read,
                 %{path: "/" <> projected, offset: 0, size: byte_size(new_bytes)},
                 socket
               )

      assert {:reply, {_mode, _nlink, target_size, _mtime}, _socket} =
               DocFs.handle_event(:getattr, %{path: "/" <> projected}, socket)

      assert target_size == byte_size(bytes)
      assert {:ok, ^bytes} = Projection.project_file(path)
    end
  end

  test "chunked in-place rewrite commits once the buffer is valid" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs HWPX write-back e2e")
    else
      root = tmp_root("doc_fs_chunked_release")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      origin = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}

      OpenDocs.open(root, "doc.hwpx",
        agent_id: origin.agent_id,
        instance_id: origin.instance_id,
        turn_id: origin.turn_id
      )

      OpenDocs.set_writable(root, true)

      Phoenix.PubSub.subscribe(Ecrits.PubSub, "doc_vfs:" <> DocMount.canonical_root(root))

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:reply, handle, socket} =
        DocFs.handle_event(:open, %{path: "/" <> projected, flags: 0}, socket)

      {:ok, bytes} = Projection.project_file(path)
      new_bytes = replace_first_cell_text(bytes, "DOCFS_CHUNKED_RELEASE_OK")
      {left, right} = :erlang.split_binary(new_bytes, 97)
      left_size = byte_size(left)
      right_size = byte_size(right)

      {:noreply, socket} =
        DocFs.handle_event(:truncate, %{path: "/" <> projected, size: 0}, socket)

      {:reply, ^left_size, socket} =
        DocFs.handle_event(
          :write,
          %{path: "/" <> projected, handle: handle, offset: 0, data: left},
          socket
        )

      {:ok, visible_before_complete} = Projection.project_file(path)
      refute visible_before_complete =~ "DOCFS_CHUNKED_RELEASE_OK"
      left_error = String.slice(left, 0, 80)
      assert {:ok, ^left, {:invalid_ir_json, ^left_error}} = OpenDocs.staged(root, "doc.hwpx")

      # Opening the same projection for another agent mutates OpenDocs, but the
      # already-started write must retain the tuple pinned before this invalid
      # first chunk failed preview parsing.
      OpenDocs.open(root, "doc.hwpx",
        agent_id: "agent-b",
        instance_id: "instance-b",
        turn_id: "turn-b"
      )

      assert {:noreply, socket} =
               DocFs.handle_event(
                 :flush,
                 %{path: "/" <> projected, flags: 0, handle: handle},
                 socket
               )

      {:ok, visible_after_flush} = Projection.project_file(path)
      refute visible_after_flush =~ "DOCFS_CHUNKED_RELEASE_OK"

      {:reply, ^right_size, socket} =
        DocFs.handle_event(
          :write,
          %{path: "/" <> projected, handle: handle, offset: left_size, data: right},
          socket
        )

      assert {:ok, after_live_write_bytes} = Projection.project_file(path)
      assert after_live_write_bytes =~ "DOCFS_CHUNKED_RELEASE_OK"
      assert OpenDocs.staged(root, "doc.hwpx") == :error

      assert_receive {:vfs_doc_edited, preview}
      assert preview.preview_only
      assert preview.phase == :candidate
      assert is_binary(preview.edit_id)
      assert is_binary(preview.revision)
      refute Map.has_key?(preview, :preview_steps)
      assert Map.take(preview, [:agent_id, :instance_id, :turn_id]) == origin

      assert_receive {:vfs_doc_edited, committed}
      assert committed.edit_id == preview.edit_id
      assert committed.phase == :committed
      assert committed.revision == preview.revision
      assert Map.take(committed, [:agent_id, :instance_id, :turn_id]) == origin
      assert committed.preview_continuation
      refute Map.get(committed, :preview_only, false)

      assert {:noreply, _socket} =
               DocFs.handle_event(
                 :release,
                 %{path: "/" <> projected, flags: 0, handle: handle},
                 socket
               )

      assert {:ok, after_bytes} = Projection.project_file(path)
      assert after_bytes =~ "DOCFS_CHUNKED_RELEASE_OK"
    end
  end

  test "temp preview and final rename retain the owner pinned before another agent opens" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs temp owner pin e2e")
    else
      root = tmp_root("doc_fs_temp_owner_pin")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      origin = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}

      OpenDocs.open(root, "doc.hwpx",
        agent_id: origin.agent_id,
        instance_id: origin.instance_id,
        turn_id: origin.turn_id
      )

      OpenDocs.set_writable(root, true)
      Phoenix.PubSub.subscribe(Ecrits.PubSub, "doc_vfs:" <> DocMount.canonical_root(root))

      projected = Projection.projected_name("doc.hwpx")
      temp = "/doc.hwpx.jsonl.tmp"
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:reply, temp_handle, socket} =
        DocFs.handle_event(:create, %{path: temp, flags: 0}, socket)

      {:ok, bytes} = Projection.project_file(path)
      new_bytes = replace_first_cell_text(bytes, "DOCFS_TEMP_OWNER_PIN_OK")

      {:reply, size, socket} =
        DocFs.handle_event(
          :write,
          %{path: temp, handle: temp_handle, offset: 0, data: new_bytes},
          socket
        )

      assert size == byte_size(new_bytes)
      assert_receive {:vfs_doc_edited, preview}
      assert preview.preview_only
      assert Map.take(preview, [:agent_id, :instance_id, :turn_id]) == origin

      OpenDocs.open(root, "doc.hwpx",
        agent_id: "agent-b",
        instance_id: "instance-b",
        turn_id: "turn-b"
      )

      {:noreply, socket} =
        DocFs.handle_event(
          :release,
          %{path: temp, flags: 0, handle: temp_handle},
          socket
        )

      assert {:noreply, _socket} =
               DocFs.handle_event(
                 :rename,
                 %{path: temp, target: "/" <> projected},
                 socket
               )

      assert_receive {:vfs_doc_edited, committed}
      assert committed.edit_id == preview.edit_id
      assert Map.take(committed, [:agent_id, :instance_id, :turn_id]) == origin
      assert {:ok, after_bytes} = Projection.project_file(path)
      assert after_bytes =~ "DOCFS_TEMP_OWNER_PIN_OK"
    end
  end

  test "rejected complete temp rename retracts its preview and preserves the source temp" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs rejected temp preview e2e")
    else
      root = tmp_root("doc_fs_rejected_temp_preview")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}

      OpenDocs.open(root, "doc.hwpx",
        agent_id: owner.agent_id,
        instance_id: owner.instance_id,
        turn_id: owner.turn_id
      )

      OpenDocs.set_writable(root, true)
      Phoenix.PubSub.subscribe(Ecrits.PubSub, "doc_vfs:" <> DocMount.canonical_root(root))

      projected = Projection.projected_name("doc.hwpx")
      temp = "/doc.hwpx.jsonl.tmp"
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:reply, handle, socket} = DocFs.handle_event(:create, %{path: temp, flags: 0}, socket)
      {:ok, original} = Projection.project_file(path)
      edited = replace_first_cell_text(original, "DOCFS_REJECTED_PREVIEW")

      assert {:reply, size, socket} =
               DocFs.handle_event(
                 :write,
                 %{path: temp, handle: handle, offset: 0, data: edited},
                 socket
               )

      assert size == byte_size(edited)
      assert_receive {:vfs_doc_edited, %{preview_only: true} = preview}

      assert {:noreply, socket} =
               DocFs.handle_event(
                 :release,
                 %{path: temp, flags: 0, handle: handle},
                 socket
               )

      OpenDocs.set_writable(root, false)

      assert {:error, 30, socket} =
               DocFs.handle_event(
                 :rename,
                 %{path: temp, target: "/" <> projected},
                 socket
               )

      assert_receive {:vfs_doc_edited, %{phase: :rejected} = rejected}
      assert rejected.edit_id == preview.edit_id
      assert rejected.revision == preview.revision
      assert Map.take(rejected, [:agent_id, :instance_id, :turn_id]) == owner

      assert {:reply, ^edited, _socket} =
               DocFs.handle_event(
                 :read,
                 %{path: temp, offset: 0, size: byte_size(edited)},
                 socket
               )

      refute Map.has_key?(
               Exfuse.Socket.get_assign(socket, :preview_hashes, %{}),
               "doc.hwpx.jsonl.tmp"
             )

      refute Map.has_key?(
               Exfuse.Socket.get_assign(socket, :vfs_edit_identities, %{}),
               "doc.hwpx.jsonl.tmp"
             )

      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert {:ok, ^original} = Projection.project_file(path)
      refute_receive {:vfs_doc_edited, %{preview_only: false}}, 20
    end
  end

  test "accepted raw table bytes stay global and replay idempotently until canonical echo" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs byte-stream cache e2e")
    else
      root = tmp_root("doc_fs_out_of_order_exact_bytes")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:ok, bytes} = Projection.project_file(path)

      accepted_bytes =
        bytes
        |> insert_compact_table("DOCFS_EXACT_TABLE")
        |> String.replace(":0.0", ":0")

      assert {:ok, _projection} = Jason.decode(accepted_bytes)

      chunk_size = 512 * 1024

      chunks =
        [0, 2 * chunk_size, chunk_size, 3 * chunk_size]
        |> Enum.map(fn offset ->
          size = min(chunk_size, byte_size(accepted_bytes) - offset)
          {offset, binary_part(accepted_bytes, offset, size)}
        end)

      table_temp = projected <> ".table.tmp"

      {:reply, handle, socket} =
        DocFs.handle_event(:create, %{path: "/" <> table_temp, flags: 0}, socket)

      socket =
        Enum.reduce(chunks, socket, fn {offset, data}, socket ->
          assert {:reply, size, socket} =
                   DocFs.handle_event(
                     :write,
                     %{path: "/" <> table_temp, handle: handle, offset: offset, data: data},
                     socket
                   )

          assert size == byte_size(data)
          socket
        end)

      assert {:noreply, socket} =
               DocFs.handle_event(
                 :fsync,
                 %{path: "/" <> table_temp, handle: handle, datasync: false, flags: 0},
                 socket
               )

      assert {:noreply, socket} =
               DocFs.handle_event(
                 :release,
                 %{path: "/" <> table_temp, flags: 0, handle: handle},
                 socket
               )

      assert {:noreply, socket} =
               DocFs.handle_event(
                 :rename,
                 %{path: "/" <> table_temp, target: "/" <> projected},
                 socket
               )

      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert {:ok, canonical_bytes} = Projection.project_file(path)
      assert canonical_bytes =~ "DOCFS_EXACT_TABLE_H1"
      assert byte_size(canonical_bytes) > byte_size(accepted_bytes)
      assert {:ok, ^accepted_bytes} = OpenDocs.committed(root, "doc.hwpx")

      assert {:ok,
              %{
                accepted_bytes: ^accepted_bytes,
                bytes: ^canonical_bytes,
                name: "doc.hwpx"
              } = pending_before_replay} = OpenDocs.pending_canonical(root, "doc.hwpx")

      observer_socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      assert {:reply, ^accepted_bytes, observer_socket} =
               DocFs.handle_event(
                 :read,
                 %{path: "/" <> projected, offset: 0, size: byte_size(canonical_bytes)},
                 observer_socket
               )

      assert {:reply, {_mode, _nlink, observer_size, _mtime}, _observer_socket} =
               DocFs.handle_event(:getattr, %{path: "/" <> projected}, observer_socket)

      assert observer_size == byte_size(accepted_bytes)

      assert {:reply, ^accepted_bytes, socket} =
               DocFs.handle_event(
                 :read,
                 %{path: "/" <> projected, offset: 0, size: byte_size(canonical_bytes)},
                 socket
               )

      assert {:reply, {_mode, _nlink, size, _mtime}, _socket} =
               DocFs.handle_event(:getattr, %{path: "/" <> projected}, socket)

      assert size == byte_size(accepted_bytes)

      Phoenix.PubSub.subscribe(Ecrits.PubSub, "doc_vfs:" <> DocMount.canonical_root(root))
      second_socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})
      replay_temp = projected <> ".replay.tmp"

      {:reply, second_handle, second_socket} =
        DocFs.handle_event(:create, %{path: "/" <> replay_temp, flags: 0}, second_socket)

      assert {:reply, second_size, second_socket} =
               DocFs.handle_event(
                 :write,
                 %{
                   path: "/" <> replay_temp,
                   handle: second_handle,
                   offset: 0,
                   data: accepted_bytes
                 },
                 second_socket
               )

      assert second_size == byte_size(accepted_bytes)

      assert {:noreply, second_socket} =
               DocFs.handle_event(
                 :fsync,
                 %{
                   path: "/" <> replay_temp,
                   handle: second_handle,
                   datasync: false,
                   flags: 0
                 },
                 second_socket
               )

      assert {:noreply, second_socket} =
               DocFs.handle_event(
                 :release,
                 %{path: "/" <> replay_temp, flags: 0, handle: second_handle},
                 second_socket
               )

      assert {:noreply, second_socket} =
               DocFs.handle_event(
                 :rename,
                 %{path: "/" <> replay_temp, target: "/" <> projected},
                 second_socket
               )

      assert {:ok, ^canonical_bytes} = Projection.project_file(path)
      assert {:ok, ^accepted_bytes} = OpenDocs.committed(root, "doc.hwpx")
      assert {:ok, ^pending_before_replay} = OpenDocs.pending_canonical(root, "doc.hwpx")

      assert {:reply, ^accepted_bytes, _second_socket} =
               DocFs.handle_event(
                 :read,
                 %{path: "/" <> projected, offset: 0, size: byte_size(canonical_bytes)},
                 second_socket
               )

      refute_receive {:vfs_doc_edited, _info}, 50

      assert %{published: ["doc.hwpx"], pending: []} =
               DocFs.flush_canonical(root,
                 mounted?: true,
                 echo_fun: &echo_canonical_through_doc_fs/4
               )

      assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error
      assert {:ok, ^canonical_bytes} = OpenDocs.committed(root, "doc.hwpx")
      refute_receive {:vfs_doc_edited, _info}, 50

      third_socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      assert {:reply, ^canonical_bytes, third_socket} =
               DocFs.handle_event(
                 :read,
                 %{path: "/" <> projected, offset: 0, size: byte_size(canonical_bytes)},
                 third_socket
               )

      assert {:reply, {_mode, _nlink, canonical_size, _mtime}, _third_socket} =
               DocFs.handle_event(:getattr, %{path: "/" <> projected}, third_socket)

      assert canonical_size == byte_size(canonical_bytes)
    end
  end

  test "invalid in-place release stages instead of failing, then later valid release commits" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs HWPX staged release e2e")
    else
      root = tmp_root("doc_fs_staged_release")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:reply, handle, socket} =
        DocFs.handle_event(:open, %{path: "/" <> projected, flags: 0}, socket)

      {:noreply, socket} =
        DocFs.handle_event(:truncate, %{path: "/" <> projected, size: 0}, socket)

      {:reply, 1, socket} =
        DocFs.handle_event(
          :write,
          %{path: "/" <> projected, handle: handle, offset: 0, data: "["},
          socket
        )

      assert {:noreply, socket} =
               DocFs.handle_event(
                 :release,
                 %{path: "/" <> projected, flags: 0, handle: handle},
                 socket
               )

      assert {:ok, "[", {:invalid_ir_json, "["}} = OpenDocs.staged(root, "doc.hwpx")

      {:ok, projected_bytes} = Projection.project_file(path)

      {:reply, visible, socket} =
        DocFs.handle_event(:read, %{path: "/" <> projected, offset: 0, size: 64}, socket)

      assert visible == binary_part(projected_bytes, 0, 64)
      refute visible == "["

      {:reply, handle, socket} =
        DocFs.handle_event(:open, %{path: "/" <> projected, flags: 0}, socket)

      {:ok, bytes} = Projection.project_file(path)
      new_bytes = replace_first_cell_text(bytes, "DOCFS_STAGED_RELEASE_OK")

      {:noreply, socket} =
        DocFs.handle_event(:truncate, %{path: "/" <> projected, size: 0}, socket)

      {:reply, size, socket} =
        DocFs.handle_event(
          :write,
          %{path: "/" <> projected, handle: handle, offset: 0, data: new_bytes},
          socket
        )

      assert size == byte_size(new_bytes)

      assert {:noreply, _socket} =
               DocFs.handle_event(
                 :release,
                 %{path: "/" <> projected, flags: 0, handle: handle},
                 socket
               )

      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert {:ok, after_bytes} = Projection.project_file(path)
      assert after_bytes =~ "DOCFS_STAGED_RELEASE_OK"
    end
  end

  test "invalid temp rename fails without replacing the target, then a valid rename commits" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs HWPX staged rename e2e")
    else
      root = tmp_root("doc_fs_staged_rename")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:reply, temp_handle, socket} =
        DocFs.handle_event(:create, %{path: "/doc.hwpx.jsonl.tmp", flags: 0}, socket)

      {:reply, 1, socket} =
        DocFs.handle_event(
          :write,
          %{path: "/doc.hwpx.jsonl.tmp", handle: temp_handle, offset: 0, data: "["},
          socket
        )

      {:noreply, socket} =
        DocFs.handle_event(
          :release,
          %{path: "/doc.hwpx.jsonl.tmp", flags: 0, handle: temp_handle},
          socket
        )

      assert {:error, 22, socket} =
               DocFs.handle_event(
                 :rename,
                 %{path: "/doc.hwpx.jsonl.tmp", target: "/" <> projected},
                 socket
               )

      assert OpenDocs.staged(root, "doc.hwpx") == :error

      assert {:reply, "[", socket} =
               DocFs.handle_event(
                 :read,
                 %{path: "/doc.hwpx.jsonl.tmp", offset: 0, size: 1},
                 socket
               )

      {:ok, projected_bytes} = Projection.project_file(path)

      {:reply, visible, socket} =
        DocFs.handle_event(:read, %{path: "/" <> projected, offset: 0, size: 64}, socket)

      assert visible == binary_part(projected_bytes, 0, 64)
      refute visible == "["

      {:reply, temp_handle, socket} =
        DocFs.handle_event(:create, %{path: "/doc.hwpx.jsonl.new", flags: 0}, socket)

      {:ok, bytes} = Projection.project_file(path)
      new_bytes = replace_first_cell_text(bytes, "DOCFS_STAGED_RENAME_OK")

      {:reply, size, socket} =
        DocFs.handle_event(
          :write,
          %{path: "/doc.hwpx.jsonl.new", handle: temp_handle, offset: 0, data: new_bytes},
          socket
        )

      assert size == byte_size(new_bytes)

      {:noreply, socket} =
        DocFs.handle_event(
          :release,
          %{path: "/doc.hwpx.jsonl.new", flags: 0, handle: temp_handle},
          socket
        )

      assert {:noreply, _socket} =
               DocFs.handle_event(
                 :rename,
                 %{path: "/doc.hwpx.jsonl.new", target: "/" <> projected},
                 socket
               )

      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert {:ok, after_bytes} = Projection.project_file(path)
      assert after_bytes =~ "DOCFS_STAGED_RENAME_OK"
      assert {:ok, ^new_bytes} = OpenDocs.committed(root, "doc.hwpx")

      {:reply, visible_after_commit, socket} =
        DocFs.handle_event(
          :read,
          %{path: "/" <> projected, offset: 0, size: byte_size(new_bytes)},
          socket
        )

      assert visible_after_commit == new_bytes

      {:reply, attrs, _socket} =
        DocFs.handle_event(:getattr, %{path: "/" <> projected}, socket)

      assert {_mode, _nlink, size, _mtime} = attrs
      assert size == byte_size(new_bytes)

      OpenDocs.open(root, "doc.hwpx")
      assert {:ok, ^new_bytes} = OpenDocs.committed(root, "doc.hwpx")

      OpenDocs.close(root, "doc.hwpx")
      OpenDocs.open(root, "doc.hwpx")
      assert OpenDocs.committed(root, "doc.hwpx") == :error
    end
  end

  test "complete non-document JSONL overwrite fails and keeps projected truth visible" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs invalid root-shape e2e")
    else
      root = tmp_root("doc_fs_invalid_root_shape")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:reply, handle, socket} =
        DocFs.handle_event(:open, %{path: "/" <> projected, flags: 0}, socket)

      bad = ~s({"text":"","type":"picture"}\n)

      {:noreply, socket} =
        DocFs.handle_event(:truncate, %{path: "/" <> projected, size: 0}, socket)

      {:reply, size, socket} =
        DocFs.handle_event(
          :write,
          %{path: "/" <> projected, handle: handle, offset: 0, data: bad},
          socket
        )

      assert size == byte_size(bad)

      assert {:error, 22, socket} =
               DocFs.handle_event(
                 :release,
                 %{path: "/" <> projected, flags: 0, handle: handle},
                 socket
               )

      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert OpenDocs.write_failure(root, "doc.hwpx") == :error

      {:ok, projected_bytes} = Projection.project_file(path)

      {:reply, visible, _socket} =
        DocFs.handle_event(:read, %{path: "/" <> projected, offset: 0, size: 3}, socket)

      assert visible == binary_part(projected_bytes, 0, 3)
      assert visible == "[\n["
    end
  end

  test "read-only projected property returns EINVAL, clears stale stage, and leaves source unchanged" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs read-only property e2e")
    else
      root = tmp_root("doc_fs_read_only_property")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:reply, handle, socket} =
        DocFs.handle_event(:open, %{path: "/" <> projected, flags: 0}, socket)

      {:ok, bytes} = Projection.project_file(path)
      invalid_bytes = change_first_paragraph_property(bytes, "paraShapeId", &(&1 + 1))

      {:noreply, socket} =
        DocFs.handle_event(:truncate, %{path: "/" <> projected, size: 0}, socket)

      {:reply, size, socket} =
        DocFs.handle_event(
          :write,
          %{path: "/" <> projected, handle: handle, offset: 0, data: invalid_bytes},
          socket
        )

      assert size == byte_size(invalid_bytes)

      OpenDocs.stage(root, "doc.hwpx", bytes, :structural_change)
      assert {:ok, ^bytes, :structural_change} = OpenDocs.staged(root, "doc.hwpx")

      assert {:error, 22, _socket} =
               DocFs.handle_event(
                 :release,
                 %{path: "/" <> projected, flags: 0, handle: handle},
                 socket
               )

      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert OpenDocs.write_failure(root, "doc.hwpx") == :error
      assert {:ok, ^bytes} = Projection.project_file(path)
    end
  end

  test "multiple nested projection values reject rename as EINVAL and preserve the temp" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs multiple-root rename e2e")
    else
      root = tmp_root("doc_fs_multiple_roots")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      temp = "/doc.hwpx.jsonl.tmp"
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})
      {:ok, bytes} = Projection.project_file(path)
      invalid_bytes = bytes <> "\n" <> bytes

      {:reply, temp_handle, socket} =
        DocFs.handle_event(:create, %{path: temp, flags: 0}, socket)

      {:reply, size, socket} =
        DocFs.handle_event(
          :write,
          %{path: temp, handle: temp_handle, offset: 0, data: invalid_bytes},
          socket
        )

      assert size == byte_size(invalid_bytes)

      {:noreply, socket} =
        DocFs.handle_event(:release, %{path: temp, flags: 0, handle: temp_handle}, socket)

      assert {:error, 22, socket} =
               DocFs.handle_event(
                 :rename,
                 %{path: temp, target: "/" <> projected},
                 socket
               )

      assert {:reply, ^invalid_bytes, _socket} =
               DocFs.handle_event(
                 :read,
                 %{path: temp, offset: 0, size: byte_size(invalid_bytes)},
                 socket
               )

      assert {:ok, ^bytes} = Projection.project_file(path)
      assert OpenDocs.staged(root, "doc.hwpx") == :error
    end
  end

  test "temp rename prefers dirty handle bytes over an empty path buffer" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs temp handle preference e2e")
    else
      root = tmp_root("doc_fs_temp_handle_preference")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:reply, temp_handle, socket} =
        DocFs.handle_event(:create, %{path: "/doc.hwpx.jsonl.tmp", flags: 0}, socket)

      {:reply, 0, socket} =
        DocFs.handle_event(
          :write,
          %{path: "/doc.hwpx.jsonl.tmp", handle: 0, offset: 0, data: ""},
          socket
        )

      {:reply, 1, socket} =
        DocFs.handle_event(
          :write,
          %{path: "/doc.hwpx.jsonl.tmp", handle: temp_handle, offset: 0, data: "["},
          socket
        )

      assert {:error, 22, socket} =
               DocFs.handle_event(
                 :rename,
                 %{path: "/doc.hwpx.jsonl.tmp", target: "/" <> projected},
                 socket
               )

      assert OpenDocs.staged(root, "doc.hwpx") == :error

      assert {:reply, "[", socket} =
               DocFs.handle_event(
                 :read,
                 %{path: "/doc.hwpx.jsonl.tmp", offset: 0, size: 1},
                 socket
               )

      {:ok, projected_bytes} = Projection.project_file(path)

      {:reply, visible, _socket} =
        DocFs.handle_event(:read, %{path: "/" <> projected, offset: 0, size: 64}, socket)

      assert visible == binary_part(projected_bytes, 0, 64)
      refute visible == "["
    end
  end

  test "turn-completion flush terminally rejects invalid staged JSONL without a pending retry" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs invalid staged flush e2e")
    else
      root = tmp_root("doc_fs_invalid_staged_flush")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      identity = %{
        edit_id: "invalid-terminal-edit",
        agent_id: "invalid-terminal-agent",
        instance_id: "invalid-terminal-instance",
        turn_id: "invalid-terminal-turn"
      }

      Phoenix.PubSub.subscribe(Ecrits.PubSub, "doc_vfs:" <> DocMount.canonical_root(root))

      OpenDocs.stage(root, "doc.hwpx", "[", {:invalid_ir_json, "["}, identity)
      OpenDocs.record_write_failure(root, "doc.hwpx", :engine_unavailable)

      assert %{
               committed: [],
               rejected: [{"doc.hwpx", {:invalid_ir_json, "["}}],
               pending: []
             } =
               DocFs.flush_staged(root)

      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert OpenDocs.write_failure(root, "doc.hwpx") == :error

      assert_receive {:vfs_doc_edited,
                      %{
                        phase: :rejected,
                        doc: "doc.hwpx",
                        edit_id: "invalid-terminal-edit",
                        agent_id: "invalid-terminal-agent",
                        instance_id: "invalid-terminal-instance",
                        turn_id: "invalid-terminal-turn"
                      }}

      assert {:ok, bytes} = Projection.project_file(path)
      assert String.starts_with?(bytes, "[\n[\n[")
    end
  end

  test "turn-completion flush commits staged valid JSONL" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs staged flush e2e")
    else
      root = tmp_root("doc_fs_staged_flush")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      # Every committed VFS edit must publish its chat-rail preview event —
      # 2026-07-19 field regression: the write path stopped passing :root and
      # broadcast_edit silently skipped, so edits committed with no preview.
      Phoenix.PubSub.subscribe(Ecrits.PubSub, "doc_vfs:" <> root)

      {:ok, bytes} = Projection.project_file(path)
      new_bytes = replace_first_cell_text(bytes, "DOCFS_STAGED_FLUSH_OK")
      OpenDocs.stage(root, "doc.hwpx", new_bytes, :structural_change)

      assert %{committed: ["doc.hwpx"], pending: []} = DocFs.flush_staged(root)
      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert {:ok, after_bytes} = Projection.project_file(path)
      assert after_bytes =~ "DOCFS_STAGED_FLUSH_OK"

      assert_receive {:vfs_doc_edited, %{doc: "doc.hwpx", path: ^path} = info}, 5_000
      assert is_binary(info.edit_id) or is_nil(info.edit_id)
      assert info.applied >= 1
    end
  end

  test "turn-completion flush retains the identity stored with staged bytes" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs staged identity e2e")
    else
      root = tmp_root("doc_fs_staged_identity")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx",
        agent_id: "agent-b",
        instance_id: "instance-b",
        turn_id: "turn-b"
      )

      OpenDocs.set_writable(root, true)
      Phoenix.PubSub.subscribe(Ecrits.PubSub, "doc_vfs:" <> DocMount.canonical_root(root))

      {:ok, bytes} = Projection.project_file(path)
      new_bytes = replace_first_cell_text(bytes, "DOCFS_STAGED_IDENTITY_OK")

      identity = %{
        edit_id: "staged-edit-a",
        agent_id: "agent-a",
        instance_id: "instance-a",
        turn_id: "turn-a"
      }

      OpenDocs.stage(root, "doc.hwpx", new_bytes, :structural_change, identity)

      assert %{committed: ["doc.hwpx"], pending: []} = DocFs.flush_staged(root)
      assert_receive {:vfs_doc_edited, committed}
      assert Map.take(committed, [:edit_id, :agent_id, :instance_id, :turn_id]) == identity
    end
  end

  test "turn-completion flush commits staged pretty nested JSON" do
    if not ehwp_available?(@hwpx_fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping DocFs staged pretty JSON flush e2e")
    else
      root = tmp_root("doc_fs_staged_pretty_flush")
      path = Path.join(root, "doc.hwpx")
      File.cp!(@hwpx_fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      {:ok, bytes} = Projection.project_file(path)
      new_bytes = replace_first_cell_text(bytes, "DOCFS_STAGED_PRETTY_FLUSH_OK", pretty: true)
      OpenDocs.stage(root, "doc.hwpx", new_bytes, {:invalid_ir_json, "["})

      assert %{committed: ["doc.hwpx"], pending: []} = DocFs.flush_staged(root)
      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert {:ok, after_bytes} = Projection.project_file(path)
      assert after_bytes =~ "DOCFS_STAGED_PRETTY_FLUSH_OK"
      assert {:ok, ^new_bytes} = OpenDocs.committed(root, "doc.hwpx")
    end
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      receive do
      after
        5 -> assert_eventually(fun, attempts - 1)
      end
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp reclaim_call_queued?(caller, root) do
    canonical_root = DocMount.canonical_root(root)

    case Process.info(Process.whereis(OpenDocs), :messages) do
      {:messages, messages} ->
        Enum.any?(messages, fn
          {:"$gen_call", {^caller, _tag},
           {:reclaim_dead_canonical_echoes, ^canonical_root, _filters}} ->
            true

          _message ->
            false
        end)

      _unavailable ->
        false
    end
  end

  defp file_server_call_queued?(file_server, caller) do
    case Process.info(file_server, :messages) do
      {:messages, messages} ->
        Enum.any?(messages, fn
          {:"$gen_call", {^caller, _tag}, _request} -> true
          _message -> false
        end)

      _unavailable ->
        false
    end
  end

  defp replace_first_cell_text(bytes, text, opts \\ []) do
    doc = Jason.decode!(bytes)
    {doc, true} = replace_first_cell_text_in_doc(doc, text, false)

    if Keyword.get(opts, :pretty, false) do
      Jason.encode!(doc, pretty: true)
    else
      Jason.encode!(doc) <> "\n"
    end
  end

  defp change_first_paragraph_property(bytes, property, change) do
    doc = Jason.decode!(bytes)

    {doc, true} =
      Enum.map_reduce(doc, false, fn section, changed? ->
        Enum.map_reduce(section, changed?, fn paragraph, changed? ->
          Enum.map_reduce(paragraph, changed?, fn
            %{"type" => "paragraph"} = node, false ->
              {Map.update!(node, property, change), true}

            node, changed? ->
              {node, changed?}
          end)
        end)
      end)

    Jason.encode!(doc) <> "\n"
  end

  defp insert_duplicate_paragraph(bytes) do
    [section | remaining_sections] = Jason.decode!(bytes)
    inserted_paragraph = section |> Enum.at(1) |> Jason.encode!() |> Jason.decode!()

    Jason.encode!([List.insert_at(section, 2, inserted_paragraph) | remaining_sections])
  end

  defp insert_compact_table(bytes, marker) do
    table = %{
      "type" => "table",
      "cells" => [
        [marker <> "_H1", marker <> "_H2"],
        [marker <> "_A", marker <> "_B"]
      ],
      "header" => true
    }

    {doc, true} =
      bytes
      |> Jason.decode!()
      |> Enum.map_reduce(false, fn section, changed? ->
        Enum.map_reduce(section, changed?, fn paragraph, changed? ->
          insert_after_first_text_node(paragraph, table, changed?)
        end)
      end)

    Jason.encode!(doc) <> "\n"
  end

  defp insert_after_first_text_node(nodes, _table, true), do: {nodes, true}

  defp insert_after_first_text_node(nodes, table, false) do
    {reversed, changed?} =
      Enum.reduce(nodes, {[], false}, fn
        %{"type" => "paragraph", "text" => text} = node, {acc, false}
        when is_binary(text) and text != "" ->
          {[table, node | acc], true}

        node, {acc, changed?} ->
          {[node | acc], changed?}
      end)

    {Enum.reverse(reversed), changed?}
  end

  defp echo_canonical_through_doc_fs(root, temp, target, bytes) do
    socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

    {:reply, handle, socket} =
      DocFs.handle_event(:create, %{path: "/" <> temp, flags: 0}, socket)

    {:reply, size, socket} =
      DocFs.handle_event(
        :write,
        %{path: "/" <> temp, handle: handle, offset: 0, data: bytes},
        socket
      )

    true = size == byte_size(bytes)

    {:noreply, socket} =
      DocFs.handle_event(
        :fsync,
        %{path: "/" <> temp, handle: handle, datasync: false, flags: 0},
        socket
      )

    {:noreply, socket} =
      DocFs.handle_event(:release, %{path: "/" <> temp, handle: handle}, socket)

    {:noreply, _socket} =
      DocFs.handle_event(
        :rename,
        %{path: "/" <> temp, target: "/" <> target},
        socket
      )

    :ok
  end

  defp replace_first_cell_text_in_doc(sections, text, changed?) do
    Enum.map_reduce(sections, changed?, fn section, changed? ->
      Enum.map_reduce(section, changed?, fn paragraph, changed? ->
        {paragraph, {changed?, _cell_seen?}} =
          Enum.map_reduce(paragraph, {changed?, false}, fn
            %{"type" => "cell"} = node, {changed?, _cell_seen?} ->
              {node, {changed?, true}}

            %{"type" => "paragraph", "text" => old} = node, {false, true}
            when is_binary(old) and old != "" ->
              {Map.put(node, "text", text), {true, true}}

            node, state ->
              {node, state}
          end)

        {paragraph, changed?}
      end)
    end)
  end

  defp tmp_root(label) do
    Path.join(System.tmp_dir!(), "ecrits-#{label}-#{System.unique_integer([:positive])}")
    |> tap(&File.mkdir_p!/1)
  end

  defp ehwp_available?(fixture) do
    root = tmp_root("doc_fs_probe")
    path = Path.join(root, "probe.hwpx")
    File.cp!(fixture, path)

    case Pool.open(path, kind: :hwpx) do
      {:ok, _id} ->
        _ = Pool.close_by_path(path)
        File.rm_rf(root)
        true

      _ ->
        File.rm_rf(root)
        false
    end
  rescue
    _ ->
      false
  catch
    _, _ ->
      false
  end
end
