defmodule Contract.PacketsTest do
  use Contract.DataCase, async: false

  @moduletag :repeatable_read

  alias Contract.Context
  alias Contract.Change
  alias Contract.ChatThread
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.IO.R2Stub
  alias Contract.Packets
  alias Contract.Packets.Packet
  alias Contract.Packets.PacketDocument
  alias Contract.RhwpSnapshot.Record, as: RhwpSnapshotRecord
  alias Contract.Snapshot

  setup do
    R2Stub.setup()
    R2Stub.reset()

    original_drivers = Application.get_env(:contract, :io_drivers, [])
    Application.put_env(:contract, :io_drivers, Keyword.put(original_drivers, :r2, R2Stub))

    on_exit(fn ->
      Application.put_env(:contract, :io_drivers, original_drivers)
      R2Stub.reset()
    end)

    :ok
  end

  defp scope do
    %Context{
      user: %Contract.Accounts.User{
        id: Ecto.UUID.generate(),
        email: "u#{System.unique_integer([:positive])}@x"
      }
    }
  end

  defp create_packet!(scope, attrs \\ %{}) do
    attrs = Map.merge(%{title: "Packet #{System.unique_integer([:positive])}"}, attrs)
    {:ok, packet} = Packets.create_packet(scope, attrs)
    packet
  end

  defp create_document!(scope, attrs \\ %{}) do
    attrs = Map.merge(%{title: "Doc #{System.unique_integer([:positive])}"}, attrs)
    {:ok, document} = Documents.create(scope, attrs)
    document
  end

  defp create_document_with_artifacts!(scope, attrs \\ %{}) do
    upload_key = "uploads/#{scope.user.id}/direct/#{Ecto.UUID.generate()}.hwp"

    document =
      create_document!(
        scope,
        Map.merge(
          %{
            metadata: %{
              "source" => %{"object_key" => upload_key}
            }
          },
          attrs
        )
      )

    snapshot_key = "documents/#{document.id}/snapshots/1.json"
    native_key = "documents/#{document.id}/snapshots/1.hwp"
    ir_key = "documents/#{document.id}/snapshots/1.ir.json"

    %Snapshot{}
    |> Snapshot.changeset(%{
      document_id: document.id,
      revision: 1,
      projection: %{"title" => document.title},
      r2_key: snapshot_key
    })
    |> Repo.insert!()

    %RhwpSnapshotRecord{}
    |> RhwpSnapshotRecord.changeset(%{
      document_id: document.id,
      revision: 1,
      format: "hwp",
      content_type: "application/x-hwp",
      r2_key: native_key,
      ir_r2_key: ir_key,
      projection: %{"revision" => 1}
    })
    |> Repo.insert!()

    %Change{}
    |> Change.changeset(%{
      document_id: document.id,
      command_kind: "seed",
      actor_type: :user,
      actor_id: scope.user.id,
      result_revision: 1
    })
    |> Repo.insert!()

    Repo.insert!(%ChatThread{owner_id: scope.user.id, document_id: document.id})

    for key <- [upload_key, snapshot_key, native_key, ir_key] do
      assert {:ok, _} = R2Stub.put(key, "body")
    end

    document
  end

  describe "create/list/update" do
    test "creates owner-scoped packets and lists only owned packets" do
      owner = scope()
      other = scope()

      packet =
        create_packet!(owner, %{
          owner_id: other.user.id,
          title: "Acme NDA",
          counterparty: "Acme",
          metadata: %{"source" => "test"}
        })

      _hidden = create_packet!(other, %{title: "Hidden"})

      assert packet.owner_id == owner.user.id
      assert packet.title == "Acme NDA"
      assert packet.counterparty == "Acme"
      assert packet.status == "active"
      assert packet.metadata == %{"source" => "test"}

      assert [%Packet{id: id}] = Packets.list_packets_for_scope(owner)
      assert id == packet.id
      assert Packets.list_packets_for_scope(%Context{user: nil}) == []
    end

    test "anonymous create is forbidden" do
      assert {:error, :forbidden} =
               Packets.create_packet(%Context{user: nil}, %{title: "Nope"})
    end

    test "update_packet/3 enforces owner ACL" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner, %{title: "Old"})

      assert {:ok, %Packet{title: "New"}} =
               Packets.update_packet(owner, packet, %{title: "New"})

      assert {:error, :forbidden} =
               Packets.update_packet(other, packet, %{title: "Other"})
    end
  end

  describe "delete_packet/2" do
    test "deletes owned packet and deletes documents with no remaining packet refs" do
      owner = scope()
      packet = create_packet!(owner)
      document = create_document_with_artifacts!(owner)
      upload_key = document.metadata["source"]["object_key"]
      {:ok, _packet_document} = Packets.attach_document(owner, packet.id, document.id)

      assert {:ok, 1} = Packets.document_ref_count(owner, document.id)
      objects_before = R2Stub.objects()
      assert {:ok, %Packet{id: deleted_id}} = Packets.delete_packet(owner, packet.id)
      assert deleted_id == packet.id

      assert {:error, :not_found} = Packets.get_packet(owner, packet.id)
      assert Repo.get(Document, document.id) == nil
      assert {:error, :not_found} = Packets.document_ref_count(owner, document.id)
      assert Repo.get_by(PacketDocument, packet_id: packet.id, document_id: document.id) == nil
      assert Repo.get_by(Change, document_id: document.id) == nil
      assert Repo.get_by(Snapshot, document_id: document.id) == nil
      assert Repo.get_by(RhwpSnapshotRecord, document_id: document.id) == nil
      assert Repo.get_by(ChatThread, document_id: document.id) == nil
      assert R2Stub.objects() == objects_before
      assert Map.has_key?(objects_before, upload_key)
      refute Enum.any?(R2Stub.calls(), &match?({:delete, _key}, &1))
    end

    test "deleting one packet leaves documents active when another packet still references them" do
      owner = scope()
      first = create_packet!(owner)
      second = create_packet!(owner)
      document = create_document!(owner)

      {:ok, _packet_document} = Packets.attach_document(owner, first.id, document.id)
      {:ok, _packet_document} = Packets.attach_document(owner, second.id, document.id)

      assert {:ok, 2} = Packets.document_ref_count(owner, document.id)
      assert {:ok, %Packet{id: deleted_id}} = Packets.delete_packet(owner, first.id)
      assert deleted_id == first.id

      assert %Document{status: :draft} = Repo.get!(Document, document.id)
      assert {:ok, 1} = Packets.document_ref_count(owner, document.id)
      assert Repo.get_by(PacketDocument, packet_id: first.id, document_id: document.id) == nil
      assert Repo.get_by(PacketDocument, packet_id: second.id, document_id: document.id)
    end

    test "delete_packet/2 keeps DB deletes without cloud cleanup" do
      owner = scope()
      packet = create_packet!(owner)
      document = create_document_with_artifacts!(owner)
      upload_key = document.metadata["source"]["object_key"]

      assert {:ok, _packet_document} = Packets.attach_document(owner, packet.id, document.id)
      objects_before = R2Stub.objects()

      assert {:ok, %Packet{id: deleted_id}} = Packets.delete_packet(owner, packet.id)
      assert deleted_id == packet.id

      assert Repo.get(Packet, packet.id) == nil
      assert Repo.get(Document, document.id) == nil
      assert Repo.get_by(PacketDocument, packet_id: packet.id, document_id: document.id) == nil
      assert Repo.get_by(Change, document_id: document.id) == nil
      assert Repo.get_by(Snapshot, document_id: document.id) == nil
      assert Repo.get_by(RhwpSnapshotRecord, document_id: document.id) == nil
      assert Repo.get_by(ChatThread, document_id: document.id) == nil

      assert R2Stub.objects() == objects_before
      assert Map.has_key?(objects_before, upload_key)
      refute Enum.any?(R2Stub.calls(), &match?({:delete, _key}, &1))
    end

    test "delete_packet/2 enforces owner ACL" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner)

      assert {:error, :forbidden} = Packets.delete_packet(other, packet.id)
      assert {:error, :forbidden} = Packets.delete_packet(%Context{user: nil}, packet.id)
      assert {:ok, %Packet{id: packet_id}} = Packets.get_packet(owner, packet.id)
      assert packet_id == packet.id
    end
  end

  describe "get_packet/2" do
    test "enforces owner ACL and preloads linked documents" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner)
      document = create_document!(owner)
      {:ok, _packet_document} = Packets.attach_document(owner, packet.id, document.id)

      assert {:ok, %Packet{} = loaded} = Packets.get_packet(owner, packet.id)
      assert Enum.map(loaded.documents, & &1.id) == [document.id]

      assert [%PacketDocument{document: %Document{id: document_id}}] =
               loaded.packet_documents

      assert document_id == document.id
      assert {:error, :forbidden} = Packets.get_packet(other, packet.id)
      assert {:error, :not_found} = Packets.get_packet(owner, Ecto.UUID.generate())
    end
  end

  describe "packet documents" do
    test "same document can be attached to two packets" do
      owner = scope()
      first = create_packet!(owner, %{title: "First"})
      second = create_packet!(owner, %{title: "Second"})
      document = create_document!(owner)

      assert {:ok, %PacketDocument{}} = Packets.attach_document(owner, first.id, document.id)
      assert {:ok, %PacketDocument{}} = Packets.attach_document(owner, second.id, document.id)

      count =
        PacketDocument
        |> where([pd], pd.document_id == ^document.id)
        |> Repo.aggregate(:count)

      assert count == 2
      assert {:ok, 2} = Packets.document_ref_count(owner, document.id)
    end

    test "packet_for_document/2 returns an owned packet for attached document" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner)
      document = create_document!(owner)
      other_document = create_document!(other)

      assert {:error, :not_found} = Packets.packet_for_document(owner, document.id)

      {:ok, _packet_document} = Packets.attach_document(owner, packet.id, document.id)

      assert {:ok, %Packet{id: packet_id}} = Packets.packet_for_document(owner, document.id)
      assert packet_id == packet.id
      assert {:error, :forbidden} = Packets.packet_for_document(other, document.id)
      assert {:error, :forbidden} = Packets.packet_for_document(owner, other_document.id)

      assert {:error, :forbidden} =
               Packets.packet_for_document(%Context{user: nil}, document.id)
    end

    test "cannot attach another owner's document" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner)
      other_document = create_document!(other)

      assert {:error, :forbidden} =
               Packets.attach_document(owner, packet.id, other_document.id)

      assert Repo.aggregate(PacketDocument, :count) == 0
    end

    test "re-attaching same document returns existing join row" do
      owner = scope()
      packet = create_packet!(owner)
      document = create_document!(owner)

      assert {:ok, %PacketDocument{} = first} =
               Packets.attach_document(owner, packet.id, document.id, %{role: "source"})

      assert {:ok, %PacketDocument{} = second} =
               Packets.attach_document(owner, packet.id, document.id, %{role: "review"})

      assert second.id == first.id
      assert second.role == "source"
      assert Repo.aggregate(PacketDocument, :count) == 1
    end

    test "document_ref_count/2 is owner scoped" do
      owner = scope()
      other = scope()
      packet = create_packet!(owner)
      document = create_document!(owner)
      other_document = create_document!(other)

      assert {:ok, 0} = Packets.document_ref_count(owner, document.id)
      {:ok, _packet_document} = Packets.attach_document(owner, packet.id, document.id)
      assert {:ok, 1} = Packets.document_ref_count(owner, document.id)

      assert {:error, :forbidden} = Packets.document_ref_count(other, document.id)
      assert {:error, :forbidden} = Packets.document_ref_count(owner, other_document.id)
      assert {:error, :forbidden} = Packets.document_ref_count(%Context{user: nil}, document.id)
      assert {:error, :not_found} = Packets.document_ref_count(owner, Ecto.UUID.generate())
    end

    test "detach removes last membership and deletes orphaned document" do
      owner = scope()
      packet = create_packet!(owner)
      attached = create_document_with_artifacts!(owner, %{title: "Attached"})
      upload_key = attached.metadata["source"]["object_key"]
      available = create_document!(owner, %{title: "Available"})

      assert available_document_ids(owner, packet.id) == Enum.sort([available.id, attached.id])

      assert {:ok, _packet_document} = Packets.attach_document(owner, packet.id, attached.id)
      assert available_document_ids(owner, packet.id) == [available.id]

      objects_before = R2Stub.objects()
      assert :ok = Packets.detach_document(owner, packet.id, attached.id)
      assert Repo.get(Document, attached.id) == nil
      assert {:error, :not_found} = Packets.document_ref_count(owner, attached.id)
      assert available_document_ids(owner, packet.id) == [available.id]
      assert Repo.get_by(Change, document_id: attached.id) == nil
      assert Repo.get_by(Snapshot, document_id: attached.id) == nil
      assert Repo.get_by(RhwpSnapshotRecord, document_id: attached.id) == nil
      assert Repo.get_by(ChatThread, document_id: attached.id) == nil
      assert R2Stub.objects() == objects_before
      assert Map.has_key?(objects_before, upload_key)
      refute Enum.any?(R2Stub.calls(), &match?({:delete, _key}, &1))

      assert :ok = Packets.detach_document(owner, packet.id, attached.id)
    end

    test "detach keeps DB deletes without cloud cleanup" do
      owner = scope()
      packet = create_packet!(owner)
      attached = create_document_with_artifacts!(owner, %{title: "Attached"})
      upload_key = attached.metadata["source"]["object_key"]

      assert {:ok, _packet_document} = Packets.attach_document(owner, packet.id, attached.id)
      objects_before = R2Stub.objects()

      assert :ok = Packets.detach_document(owner, packet.id, attached.id)

      assert Repo.get(Document, attached.id) == nil
      assert Repo.get_by(PacketDocument, packet_id: packet.id, document_id: attached.id) == nil
      assert Repo.get_by(Change, document_id: attached.id) == nil
      assert Repo.get_by(Snapshot, document_id: attached.id) == nil
      assert Repo.get_by(RhwpSnapshotRecord, document_id: attached.id) == nil
      assert Repo.get_by(ChatThread, document_id: attached.id) == nil

      assert R2Stub.objects() == objects_before
      assert Map.has_key?(objects_before, upload_key)
      refute Enum.any?(R2Stub.calls(), &match?({:delete, _key}, &1))
    end

    test "detach from one of two packets leaves shared document active" do
      owner = scope()
      first = create_packet!(owner)
      second = create_packet!(owner)
      document = create_document!(owner)

      {:ok, _packet_document} = Packets.attach_document(owner, first.id, document.id)
      {:ok, _packet_document} = Packets.attach_document(owner, second.id, document.id)

      assert :ok = Packets.detach_document(owner, first.id, document.id)

      assert %Document{status: :draft} = Repo.get!(Document, document.id)
      assert {:ok, 1} = Packets.document_ref_count(owner, document.id)
      assert available_document_ids(owner, first.id) == [document.id]
      assert available_document_ids(owner, second.id) == []
    end
  end

  defp available_document_ids(scope, packet_id) do
    scope
    |> Packets.list_available_documents(packet_id)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end
end
