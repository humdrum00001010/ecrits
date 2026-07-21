defmodule Ecrits.Fuse.DocFsConsecutiveProjectionTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Projection
  alias Ecrits.Fuse.{DocFs, DocMount, OpenDocs}
  alias Ecrits.Workspace.Session

  @fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)

  @tag :edit_failure
  test "a second ACP projection write succeeds after the accepted write is canonicalized" do
    if not ehwp_available?(@fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping consecutive projection write regression")
    else
      root = tmp_root()
      path = Path.join(root, "doc.hwpx")
      File.cp!(@fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      {:ok, original_bytes} = Projection.project_file(path)
      original = Jason.decode!(original_bytes)
      [first_paragraph, second_paragraph | _] = split_run_paragraphs(original)

      first_projection =
        original
        |> append_to_paragraph(first_paragraph, " ACP_FIRST_WRITE")
        |> encode_projection()

      {:ok, socket} = replace_projection(socket, projected, "first", first_projection)

      assert {:ok, ^first_projection} = OpenDocs.committed(root, "doc.hwpx")
      assert {:ok, canonical_after_first} = Projection.project_file(path)
      refute canonical_after_first == first_projection

      assert {:ok,
              %{
                accepted_bytes: ^first_projection,
                bytes: ^canonical_after_first,
                name: "doc.hwpx"
              }} =
               OpenDocs.pending_canonical(root, "doc.hwpx")

      assert %{published: ["doc.hwpx"], pending: []} =
               DocFs.flush_canonical(root, mounted?: false)

      assert {:ok, ^canonical_after_first} = OpenDocs.committed(root, "doc.hwpx")

      second_projection =
        canonical_after_first
        |> Jason.decode!()
        |> append_to_paragraph(second_paragraph, " ACP_SECOND_WRITE")
        |> encode_projection()

      assert {:ok, _socket} =
               replace_projection(socket, projected, "second", second_projection)

      assert {:ok, after_second} = Projection.project_file(path)
      assert after_second =~ "ACP_FIRST_WRITE"
      assert after_second =~ "ACP_SECOND_WRITE"
    end
  end

  @tag :edit_failure
  test "retrying the canonical output is a no-op and does not duplicate paragraph text" do
    if not ehwp_available?(@fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping same-output retry regression")
    else
      root = tmp_root()
      path = Path.join(root, "doc.hwpx")
      File.cp!(@fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})
      marker = " ACP_SAME_OUTPUT_RETRY"

      {:ok, original_bytes} = Projection.project_file(path)
      original = Jason.decode!(original_bytes)
      paragraph = original |> split_run_paragraphs() |> hd()

      requested_bytes =
        original
        |> append_to_paragraph(paragraph, marker)
        |> encode_projection()

      assert {:ok, socket} =
               replace_projection(socket, projected, "same-output-first", requested_bytes)

      {:ok, canonical_bytes} = Projection.project_file(path)
      assert paragraph_marker_count(canonical_bytes, paragraph, marker) == 1

      assert %{published: ["doc.hwpx"], pending: []} =
               DocFs.flush_canonical(root, mounted?: false)

      source_before_retry = File.read!(path)

      assert {:ok, _socket} =
               replace_projection(socket, projected, "same-output-retry", canonical_bytes)

      assert File.read!(path) == source_before_retry
      assert {:ok, ^canonical_bytes} = Projection.project_file(path)
      assert paragraph_marker_count(canonical_bytes, paragraph, marker) == 1

      assert {:ok, ^canonical_bytes} = OpenDocs.committed(root, "doc.hwpx")
      assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error
      assert OpenDocs.staged(root, "doc.hwpx") == :error
    end
  end

  @tag :edit_failure
  test "retrying stale accepted octets fails closed without changing the canonical document" do
    if not ehwp_available?(@fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping stale-octet retry regression")
    else
      root = tmp_root()
      path = Path.join(root, "doc.hwpx")
      File.cp!(@fixture, path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        OpenDocs.close(root, "doc.hwpx")
        File.rm_rf(root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)

      projected = Projection.projected_name("doc.hwpx")
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})
      marker = " ACP_STALE_OCTET_RETRY"

      {:ok, original_bytes} = Projection.project_file(path)
      original = Jason.decode!(original_bytes)
      paragraph = original |> split_run_paragraphs() |> hd()

      accepted_bytes =
        original
        |> append_to_paragraph(paragraph, marker)
        |> encode_projection()

      assert {:ok, socket} =
               replace_projection(socket, projected, "stale-octet-first", accepted_bytes)

      {:ok, canonical_bytes} = Projection.project_file(path)
      assert paragraph_marker_count(canonical_bytes, paragraph, marker) == 1

      assert {:ok,
              %{
                accepted_bytes: ^accepted_bytes,
                bytes: ^canonical_bytes,
                name: "doc.hwpx"
              }} = OpenDocs.pending_canonical(root, "doc.hwpx")

      assert %{published: ["doc.hwpx"], pending: []} =
               DocFs.flush_canonical(root, mounted?: false)

      assert {:ok, ^canonical_bytes} = OpenDocs.committed(root, "doc.hwpx")
      assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error
      assert OpenDocs.staged(root, "doc.hwpx") == :error

      source_before_retry = File.read!(path)

      # The stale-run reconciliation in the projection diff reads the replayed
      # accepted bytes as a semantic no-op against canonical; DocFs turns that
      # byte-different no-op into a fail-closed EINVAL below.
      assert {:ok, %{previewed: 0, tokens: 0}} =
               Projection.preview_write_back(path, accepted_bytes)

      assert {:error, 22, _socket} =
               replace_projection(socket, projected, "stale-octet-retry", accepted_bytes)

      assert File.read!(path) == source_before_retry
      assert {:ok, ^canonical_bytes} = Projection.project_file(path)
      assert paragraph_marker_count(canonical_bytes, paragraph, marker) == 1
      assert {:ok, ^canonical_bytes} = OpenDocs.committed(root, "doc.hwpx")
      assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error
      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert OpenDocs.write_failure(root, "doc.hwpx") == :error
    end
  end

  @tag :edit_failure
  test "an Octet open failure rolls an FSKit rename back atomically and the same temp retries once" do
    if not ehwp_available?(@fixture) do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping Octet transport rollback regression")
    else
      root = tmp_root()
      path = Path.join(root, "doc.hwpx")
      oracle_root = tmp_root()
      oracle_path = Path.join(oracle_root, "doc.hwpx")
      File.cp!(@fixture, path)
      File.cp!(@fixture, oracle_path)

      on_exit(fn ->
        _ = Pool.close_by_path(path)
        _ = Pool.close_by_path(oracle_path)
        OpenDocs.close(root, "doc.hwpx")

        if pid = Session.whereis(root) do
          Process.exit(pid, :kill)
        end

        File.rm_rf(root)
        File.rm_rf(oracle_root)
      end)

      OpenDocs.open(root, "doc.hwpx")
      OpenDocs.set_writable(root, true)
      Phoenix.PubSub.subscribe(Ecrits.PubSub, "doc_vfs:" <> DocMount.canonical_root(root))

      projected = Projection.projected_name("doc.hwpx")
      temp_name = projected <> ".octet-retry.tmp"
      temp = "/" <> temp_name
      target = "/" <> projected
      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})
      source_preimage = File.read!(path)

      {:ok, original_projection} = Projection.project_file(path)
      original = Jason.decode!(original_projection)
      paragraph = original |> split_run_paragraphs() |> hd()
      marker = " OCTET_ATOMIC_RETRY_ONCE"

      edited_projection =
        original
        |> append_to_paragraph(paragraph, marker)
        |> encode_projection()

      # Produce the exact healthy browser export from an independent copy. This
      # keeps the regression on the same logical projection input without
      # repeating an ACP/LiveView trip merely to manufacture fixture bytes.
      assert {:ok, %{applied: applied}} = Projection.write_back(oracle_path, edited_projection)
      assert applied > 0
      browser_export = File.read!(oracle_path)
      # Browser authority closes the cold editor after accepting an export. Do
      # the same for the oracle so the expected projection comes from reparsing
      # the exact persisted bytes, not from its pre-close in-memory model.
      :ok = Pool.close_by_path(oracle_path)
      {:ok, canonical_projection} = Projection.project_file(oracle_path)
      assert paragraph_marker_count(canonical_projection, paragraph, marker) == 1

      {:ok, %{id: document_id}} = Pool.info_by_path(path)
      owner = self()

      viewer =
        start_supervised!(
          {Task,
           fn ->
             octet_transport_loop(owner, browser_export, %{
               fail_next_write?: true,
               awaiting_rollback: nil,
               pending: MapSet.new()
             })
           end}
        )

      :ok = Session.attach_viewer(root, document_id, viewer)
      assert {:browser, ^viewer} = Session.route(root, document_id)

      assert {:reply, handle, socket} =
               DocFs.handle_event(:create, %{path: temp, flags: 0}, socket)

      assert {:reply, size, socket} =
               DocFs.handle_event(
                 :write,
                 %{path: temp, handle: handle, offset: 0, data: edited_projection},
                 socket
               )

      assert size == byte_size(edited_projection)

      assert_receive {:vfs_doc_edited,
                      %{
                        phase: :candidate,
                        preview_only: true,
                        edit_id: failed_edit_id,
                        revision: failed_revision,
                        ops: preview_ops
                      } = preview}

      assert is_binary(failed_edit_id)
      assert is_binary(failed_revision)
      assert preview_ops != []
      assert preview.highlights != []

      assert {:noreply, socket} =
               DocFs.handle_event(
                 :release,
                 %{path: temp, flags: 0, handle: handle},
                 socket
               )

      assert {:error, 22, socket} =
               DocFs.handle_event(:rename, %{path: temp, target: target}, socket)

      assert_receive {:browser_transport, :vfs_write, ^failed_edit_id,
                      {:error, "octet socket open timed out"}}

      assert_receive {:browser_transport, :vfs_rollback, ^failed_edit_id,
                      {:ok, %{"rolled_back" => true}}}

      assert_receive {:vfs_doc_edited,
                      %{
                        phase: :rejected,
                        edit_id: ^failed_edit_id,
                        revision: ^failed_revision,
                        reason: rejected_reason
                      }}

      assert rejected_reason =~ "browser_writeback_rejected"
      assert rejected_reason =~ "octet socket open timed out"
      refute_receive {:vfs_doc_edited, %{edit_id: ^failed_edit_id, phase: :committed}}, 20
      refute_receive {:browser_transport, :vfs_commit, ^failed_edit_id, _reply}, 20

      assert browser_transport_state(viewer) == %{
               fail_next_write?: false,
               awaiting_rollback: nil,
               pending: []
             }

      # Failure is fully atomic at every durable/semantic layer.
      assert File.read!(path) == source_preimage
      assert {:ok, ^original_projection} = Projection.project_file(path)
      assert paragraph_marker_count(original_projection, paragraph, marker) == 0
      assert OpenDocs.committed(root, "doc.hwpx") == :error
      assert OpenDocs.pending_canonical(root, "doc.hwpx") == :error
      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert OpenDocs.write_failure(root, "doc.hwpx") == :error

      assert {:reply, ^edited_projection, _socket} =
               DocFs.handle_event(
                 :read,
                 %{path: temp, offset: 0, size: byte_size(edited_projection)},
                 socket
               )

      assert Map.has_key?(
               Exfuse.Socket.get_assign(socket, :wbuf, %{}),
               {:path, temp_name}
             )

      refute Map.has_key?(
               Exfuse.Socket.get_assign(socket, :preview_hashes, %{}),
               temp_name
             )

      refute Map.has_key?(
               Exfuse.Socket.get_assign(socket, :vfs_edit_identities, %{}),
               temp_name
             )

      # The transport loop becomes healthy only after the rollback ACK. Retrying
      # the preserved FSKit temp therefore feeds the identical logical bytes once.
      assert {:noreply, socket} =
               DocFs.handle_event(:rename, %{path: temp, target: target}, socket)

      assert_receive {:browser_transport, :vfs_write, successful_edit_id,
                      {:ok, %{"bytes" => ^browser_export}}}

      refute successful_edit_id == failed_edit_id

      assert_receive {:browser_transport, :vfs_commit, ^successful_edit_id,
                      {:ok, %{"committed" => true}}}

      assert_receive {:vfs_doc_edited,
                      %{edit_id: ^successful_edit_id, browser_authority: true} = committed}

      refute Map.get(committed, :preview_only, false)
      refute_receive {:vfs_doc_edited, %{phase: :rejected, edit_id: ^successful_edit_id}}, 20

      assert browser_transport_state(viewer) == %{
               fail_next_write?: false,
               awaiting_rollback: nil,
               pending: []
             }

      assert File.read!(path) == browser_export
      assert {:ok, ^canonical_projection} = Projection.project_file(path)
      assert paragraph_marker_count(canonical_projection, paragraph, marker) == 1

      assert {:ok, ^edited_projection} = OpenDocs.committed(root, "doc.hwpx")

      assert {:ok,
              %{
                accepted_bytes: ^edited_projection,
                bytes: ^canonical_projection,
                name: "doc.hwpx"
              }} = OpenDocs.pending_canonical(root, "doc.hwpx")

      assert OpenDocs.staged(root, "doc.hwpx") == :error
      assert OpenDocs.write_failure(root, "doc.hwpx") == :error
      refute Map.has_key?(Exfuse.Socket.get_assign(socket, :wbuf, %{}), {:path, temp_name})
    end
  end

  defp replace_projection(socket, projected, label, bytes) do
    temp = projected <> ".#{label}.tmp"

    with {:reply, handle, socket} <-
           DocFs.handle_event(:create, %{path: "/" <> temp, flags: 0}, socket),
         {:reply, size, socket} <-
           DocFs.handle_event(
             :write,
             %{path: "/" <> temp, handle: handle, offset: 0, data: bytes},
             socket
           ),
         true <- size == byte_size(bytes),
         {:noreply, socket} <-
           DocFs.handle_event(
             :release,
             %{path: "/" <> temp, flags: 0, handle: handle},
             socket
           ),
         {:noreply, socket} <-
           DocFs.handle_event(
             :rename,
             %{path: "/" <> temp, target: "/" <> projected},
             socket
           ) do
      {:ok, socket}
    else
      {:error, errno, socket} -> {:error, errno, socket}
      false -> {:error, :short_write, socket}
      other -> {:error, other, socket}
    end
  end

  defp octet_transport_loop(owner, browser_export, state) do
    receive do
      {:doc_browser_request, from, ref, verb, payload} ->
        handle_octet_transport_request(
          owner,
          browser_export,
          state,
          from,
          ref,
          verb,
          payload
        )

      {:doc_browser_request, from, ref, verb, payload, _expected_document_id} ->
        handle_octet_transport_request(
          owner,
          browser_export,
          state,
          from,
          ref,
          verb,
          payload
        )

      {:transport_state, from, ref} ->
        snapshot = %{
          fail_next_write?: state.fail_next_write?,
          awaiting_rollback: state.awaiting_rollback,
          pending: state.pending |> MapSet.to_list() |> Enum.sort()
        }

        send(from, {:transport_state, ref, snapshot})
        octet_transport_loop(owner, browser_export, state)
    end
  end

  defp handle_octet_transport_request(
         owner,
         browser_export,
         state,
         from,
         ref,
         verb,
         payload
       ) do
    edit_id = Map.fetch!(payload, :edit_id)
    {reply, state} = octet_transport_reply(verb, edit_id, browser_export, state)
    send(owner, {:browser_transport, verb, edit_id, reply})
    send(from, {:doc_browser_reply, ref, reply})
    acknowledge_browser_completion(from, ref)
    octet_transport_loop(owner, browser_export, state)
  end

  defp octet_transport_reply(
         :vfs_write,
         edit_id,
         _browser_export,
         %{fail_next_write?: true} = state
       ) do
    {{:error, "octet socket open timed out"}, %{state | awaiting_rollback: edit_id}}
  end

  defp octet_transport_reply(:vfs_write, edit_id, browser_export, state) do
    reply = {:ok, %{"bytes" => browser_export}}
    {reply, %{state | pending: MapSet.put(state.pending, edit_id)}}
  end

  defp octet_transport_reply(:vfs_rollback, edit_id, _browser_export, state) do
    reply = {:ok, %{"rolled_back" => true}}

    {reply,
     %{
       state
       | fail_next_write?: false,
         awaiting_rollback: nil,
         pending: MapSet.delete(state.pending, edit_id)
     }}
  end

  defp octet_transport_reply(:vfs_commit, edit_id, _browser_export, state) do
    reply = {:ok, %{"committed" => true}}
    {reply, %{state | pending: MapSet.delete(state.pending, edit_id)}}
  end

  defp acknowledge_browser_completion(from, ref) do
    receive do
      {:doc_browser_request_completed, ^from, ^ref, ack_ref} ->
        send(from, {:doc_browser_request_completion_ack, ack_ref, :ok})
    end
  end

  defp browser_transport_state(viewer) do
    ref = make_ref()
    send(viewer, {:transport_state, self(), ref})

    receive do
      {:transport_state, ^ref, state} -> state
    after
      1_000 -> flunk("browser transport did not report its transaction state")
    end
  end

  defp split_run_paragraphs(document) do
    for {section, section_index} <- Enum.with_index(document),
        {nodes, paragraph_index} <- Enum.with_index(section),
        Enum.count(nodes, &(&1["type"] == "char")) >= 2,
        do: {section_index, paragraph_index}
  end

  defp append_to_paragraph(document, {section_index, paragraph_index}, suffix) do
    update_in(
      document,
      [Access.at(section_index), Access.at(paragraph_index)],
      fn nodes ->
        Enum.map(nodes, fn
          %{"type" => "paragraph", "text" => text} = node when is_binary(text) ->
            Map.put(node, "text", text <> suffix)

          node ->
            node
        end)
      end
    )
  end

  defp encode_projection(document), do: Jason.encode!(document) <> "\n"

  defp paragraph_marker_count(bytes, {section_index, paragraph_index}, marker) do
    text =
      bytes
      |> Jason.decode!()
      |> get_in([Access.at(section_index), Access.at(paragraph_index)])
      |> Enum.find_value(fn
        %{"type" => "paragraph", "text" => text} when is_binary(text) -> text
        _node -> nil
      end)

    length(String.split(text, marker)) - 1
  end

  defp tmp_root do
    Path.join(
      System.tmp_dir!(),
      "ecrits-consecutive-projection-#{System.unique_integer([:positive])}"
    )
    |> tap(&File.mkdir_p!/1)
  end

  defp ehwp_available?(fixture) do
    root = tmp_root()
    path = Path.join(root, "probe.hwpx")
    File.cp!(fixture, path)

    case Pool.open(path, kind: :hwpx) do
      {:ok, _id} ->
        _ = Pool.close_by_path(path)
        File.rm_rf(root)
        true

      _other ->
        File.rm_rf(root)
        false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end
end
