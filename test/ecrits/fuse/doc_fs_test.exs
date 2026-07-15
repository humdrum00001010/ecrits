defmodule Ecrits.Fuse.DocFsTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Projection
  alias Ecrits.Fuse.DocFs
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs

  @hwpx_fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)

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

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

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

  test "invalid temp rename stages instead of failing, then later valid rename commits" do
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

      assert {:noreply, socket} =
               DocFs.handle_event(
                 :rename,
                 %{path: "/doc.hwpx.jsonl.tmp", target: "/" <> projected},
                 socket
               )

      assert {:ok, "[", {:invalid_ir_json, "["}} = OpenDocs.staged(root, "doc.hwpx")

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
      assert {:ok, ^after_bytes} = OpenDocs.committed(root, "doc.hwpx")

      {:reply, visible_after_commit, socket} =
        DocFs.handle_event(
          :read,
          %{path: "/" <> projected, offset: 0, size: byte_size(after_bytes)},
          socket
        )

      assert visible_after_commit == after_bytes

      {:reply, attrs, _socket} =
        DocFs.handle_event(:getattr, %{path: "/" <> projected}, socket)

      assert {_mode, _nlink, size, _mtime} = attrs
      assert size == byte_size(after_bytes)

      OpenDocs.open(root, "doc.hwpx")
      assert {:ok, ^after_bytes} = OpenDocs.committed(root, "doc.hwpx")

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

      assert {:error, _eio, socket} =
               DocFs.handle_event(
                 :release,
                 %{path: "/" <> projected, flags: 0, handle: handle},
                 socket
               )

      assert OpenDocs.staged(root, "doc.hwpx") == :error

      {:ok, projected_bytes} = Projection.project_file(path)

      {:reply, visible, _socket} =
        DocFs.handle_event(:read, %{path: "/" <> projected, offset: 0, size: 3}, socket)

      assert visible == binary_part(projected_bytes, 0, 3)
      assert visible == "[[["
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

      assert {:noreply, _socket} =
               DocFs.handle_event(
                 :rename,
                 %{path: "/doc.hwpx.jsonl.tmp", target: "/" <> projected},
                 socket
               )

      assert {:ok, "[", {:invalid_ir_json, "["}} = OpenDocs.staged(root, "doc.hwpx")

      {:ok, projected_bytes} = Projection.project_file(path)

      {:reply, visible, _socket} =
        DocFs.handle_event(:read, %{path: "/" <> projected, offset: 0, size: 64}, socket)

      assert visible == binary_part(projected_bytes, 0, 64)
      refute visible == "["
    end
  end

  test "turn-completion flush rolls back invalid staged JSONL to projected truth" do
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
      OpenDocs.stage(root, "doc.hwpx", "[", {:invalid_ir_json, "["})

      assert %{committed: [], pending: [{"doc.hwpx", {:invalid_ir_json, "["}}]} =
               DocFs.flush_staged(root)

      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert {:ok, bytes} = Projection.project_file(path)
      assert bytes =~ "[[["
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

      {:ok, bytes} = Projection.project_file(path)
      new_bytes = replace_first_cell_text(bytes, "DOCFS_STAGED_FLUSH_OK")
      OpenDocs.stage(root, "doc.hwpx", new_bytes, :structural_change)

      assert %{committed: ["doc.hwpx"], pending: []} = DocFs.flush_staged(root)
      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert {:ok, after_bytes} = Projection.project_file(path)
      assert after_bytes =~ "DOCFS_STAGED_FLUSH_OK"
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
    end
  end

  defp replace_first_cell_text(bytes, text, opts \\ []) do
    [doc] = bytes |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    {doc, true} = replace_first_cell_text_in_doc(doc, text, false)

    if Keyword.get(opts, :pretty, false) do
      Jason.encode!(doc, pretty: true)
    else
      Jason.encode!(doc) <> "\n"
    end
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
