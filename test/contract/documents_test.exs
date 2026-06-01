defmodule Contract.DocumentsTest do
  use Contract.DataCase, async: false

  @moduletag :repeatable_read

  alias Contract.Context
  alias Contract.ChatThread
  alias Contract.Change
  alias Contract.ContractTypes.DocumentType
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.IO.R2Stub
  alias Contract.RhwpSnapshot.Record
  alias Contract.Snapshot
  alias Contract.Store

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

  describe "create/2" do
    test "creates an owner-scoped document and ignores legacy matter_id" do
      s = scope()

      assert {:ok, %Document{} = doc} =
               Documents.create(s, %{
                 "matter_id" => Ecto.UUID.generate(),
                 "title" => "T",
                 "type_key" => "nda_v1"
               })

      assert doc.owner_id == s.user.id
      assert doc.title == "T"
      assert doc.type_key == "nda_v1"
      assert %DocumentType{key: "nda_v1"} = Repo.get(DocumentType, doc.document_type_id)
      refute Map.has_key?(Map.from_struct(doc), :matter_id)
    end

    test "accepts missing type_key" do
      s = scope()
      assert {:ok, %Document{type_key: nil}} = Documents.create(s, %{"title" => "Untyped"})
    end

    test "anonymous create is forbidden" do
      assert {:error, :forbidden} = Documents.create(%Context{user: nil}, %{"title" => "X"})
    end
  end

  describe "get/list/search" do
    test "get/2 returns :not_found for an unknown document id" do
      owner = scope()
      assert {:error, :not_found} = Documents.get(owner, Ecto.UUID.generate())
    end

    test "get/2 enforces owner ACL" do
      owner = scope()
      other = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Private"})

      assert {:ok, %Document{id: id}} = Documents.get(owner, doc.id)
      assert id == doc.id
      assert {:error, :forbidden} = Documents.get(other, doc.id)
    end

    test "list_recent_for_scope/2 returns only owned documents" do
      owner = scope()
      other = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Visible"})
      {:ok, _} = Documents.create(other, %{title: "Hidden"})

      assert [%Document{id: id}] = Documents.list_recent_for_scope(owner, 10)
      assert id == doc.id
    end

    test "list_all_for_scope/2 returns every owned document, ordered desc by updated_at" do
      owner = scope()
      other = scope()
      {:ok, _hidden} = Documents.create(other, %{title: "Hidden"})

      # Create a bunch of owner-scoped docs so we hit beyond the legacy
      # recent-window size.
      ids =
        for i <- 1..30 do
          {:ok, doc} = Documents.create(owner, %{title: "Doc #{i}"})
          doc.id
        end

      results = Documents.list_all_for_scope(owner)
      assert length(results) == length(ids)
      assert Enum.all?(results, &(&1.id in ids))

      # Order: most recently updated first.
      updated_ats = Enum.map(results, & &1.updated_at)
      assert updated_ats == Enum.sort(updated_ats, {:desc, NaiveDateTime})
    end

    test "list_all_for_scope/2 returns [] when scope has no user" do
      anon = %Context{user: nil, perms: []}
      assert Documents.list_all_for_scope(anon) == []
    end

    test "search/3 returns only owned matches" do
      owner = scope()
      other = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Needle"})
      {:ok, _} = Documents.create(other, %{title: "Needle hidden"})

      assert [%Document{id: id}] = Documents.search(owner, "Needle", 10)
      assert id == doc.id
    end
  end

  describe "updates" do
    test "complete_write/2 freezes the current head and matching snapshot revision" do
      owner = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Ready"})
      insert_change!(doc.id, 3)
      insert_rhwp_snapshot!(doc.id, 3)

      assert {:ok, %Document{} = completed} = Documents.complete_write(owner, doc.id)

      assert completed.status == :write_completed
      assert %DateTime{} = completed.write_completed_at
      assert completed.write_completed_by_id == owner.user.id
      assert completed.write_completed_revision == 3
      assert completed.write_completed_snapshot_revision == 3
    end

    test "complete_write/2 uses the actual changes head when documents.latest_revision is stale" do
      owner = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Stale cached revision"})
      assert :ok = Documents.touch_revision(doc.id, 3)
      insert_change!(doc.id, 4)
      insert_rhwp_snapshot!(doc.id, 3)

      assert {:ok, 4} = Store.latest_revision(doc.id)
      assert Repo.get!(Document, doc.id).latest_revision == 3
      assert {:error, :checkpoint_required} = Documents.complete_write(owner, doc.id)

      insert_rhwp_snapshot!(doc.id, 4)

      assert {:ok, %Document{} = completed} = Documents.complete_write(owner, doc.id)
      assert completed.status == :write_completed
      assert completed.write_completed_revision == 4
      assert completed.write_completed_snapshot_revision == 4
    end

    test "with_document_lock/2 runs the callback inside a transaction" do
      assert {:ok, :locked} =
               Documents.with_document_lock(Ecto.UUID.generate(), fn ->
                 assert Repo.in_transaction?()
                 {:ok, :locked}
               end)
    end

    test "complete_write/2 requires a committed rhwp snapshot at the document head" do
      owner = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Needs checkpoint"})
      insert_change!(doc.id, 3)

      assert {:error, :checkpoint_required} = Documents.complete_write(owner, doc.id)

      assert %Document{status: :draft} = Repo.get!(Document, doc.id)
    end

    test "guard_body_mutation/2 rejects body changes after write completion" do
      owner = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Frozen"})
      insert_change!(doc.id, 2)
      insert_rhwp_snapshot!(doc.id, 2)
      assert {:ok, _completed} = Documents.complete_write(owner, doc.id)

      change = %Change{
        document_id: doc.id,
        command_kind: "edit_text",
        payload: [
          %{
            "op" => "insert_text",
            "target_type" => "document",
            "target_id" => doc.id,
            "args" => %{"text" => "late"}
          }
        ]
      }

      assert {:error, :write_completed} = Documents.guard_body_mutation(doc.id, change)
    end

    test "guard_body_mutation/2 rejects document type replacement changes" do
      owner = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Typed", type_key: "service_agreement_v1"})

      change = %Change{
        document_id: doc.id,
        command_kind: "set_contract_type",
        payload: [
          %{
            "op" => "set_attr",
            "target_type" => "document",
            "target_id" => doc.id,
            "args" => %{"key" => "type_key", "value" => "employment_v1"}
          }
        ]
      }

      assert {:error, :document_type_already_set} =
               Documents.guard_body_mutation(doc.id, change)
    end

    test "delete/2 enforces owner ACL and hard-deletes the document" do
      owner = scope()
      other = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Draft"})

      assert {:error, :forbidden} = Documents.delete(other, doc.id)
      assert {:ok, %Document{id: deleted_id}} = Documents.delete(owner, doc.id)
      assert deleted_id == doc.id
      assert Repo.get(Document, doc.id) == nil
    end

    test "delete/2 removes document-scoped state rows without cloud cleanup" do
      owner = scope()
      upload_key = "uploads/#{owner.user.id}/direct/source.hwp"

      {:ok, doc} =
        Documents.create(owner, %{
          title: "Stateful",
          metadata: %{"source" => %{"object_key" => upload_key}}
        })

      insert_change!(doc.id, 1)
      insert_rhwp_snapshot!(doc.id, 1)

      snapshot_key = "documents/#{doc.id}/projection/1.json"
      native_key = "documents/#{doc.id}/snapshots/1.hwp"
      ir_key = "documents/#{doc.id}/snapshots/1.ir.json"

      %Snapshot{}
      |> Snapshot.changeset(%{
        document_id: doc.id,
        revision: 1,
        projection: %{"title" => "Stateful"},
        r2_key: snapshot_key
      })
      |> Repo.insert!()

      Repo.insert!(%ChatThread{owner_id: owner.user.id, document_id: doc.id})
      assert {:ok, _} = R2Stub.put(upload_key, "uploaded-source")
      assert {:ok, _} = R2Stub.put(snapshot_key, "{}")
      assert {:ok, _} = R2Stub.put(native_key, "hwp")
      assert {:ok, _} = R2Stub.put(ir_key, "{}")
      objects_before = R2Stub.objects()

      assert {:ok, %Document{}} = Documents.delete(owner, doc.id)

      assert Repo.get(Document, doc.id) == nil
      refute Repo.get_by(Change, document_id: doc.id)
      refute Repo.get_by(Record, document_id: doc.id)
      refute Repo.get_by(Snapshot, document_id: doc.id)
      refute Repo.get_by(ChatThread, document_id: doc.id)
      assert R2Stub.objects() == objects_before
      refute Enum.any?(R2Stub.calls(), &match?({:delete, _key}, &1))
    end

    test "delete/2 ignores retired cloud cleanup" do
      owner = scope()
      upload_key = "uploads/#{owner.user.id}/direct/source.hwp"

      {:ok, doc} =
        Documents.create(owner, %{
          title: "Stateful",
          metadata: %{"source" => %{"object_key" => upload_key}}
        })

      insert_change!(doc.id, 1)
      assert {:ok, _} = R2Stub.put(upload_key, "uploaded-source")

      assert {:ok, %Document{}} = Documents.delete(owner, doc.id)

      assert Repo.get(Document, doc.id) == nil
      refute Repo.get_by(Change, document_id: doc.id)
      assert R2Stub.objects() == %{upload_key => "uploaded-source"}
      refute Enum.any?(R2Stub.calls(), &match?({:delete, _key}, &1))
    end

    test "set_type/3 enforces owner ACL" do
      owner = scope()
      other = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Draft"})

      assert {:error, :forbidden} = Documents.set_type(other, doc.id, "nda_v1")

      assert {:ok, %Document{type_key: "nda_v1"} = doc} =
               Documents.set_type(owner, doc.id, "nda_v1")

      assert %DocumentType{key: "nda_v1"} = Repo.get(DocumentType, doc.document_type_id)
    end

    test "set_type/3 rejects replacing an existing document type" do
      owner = scope()

      {:ok, doc} =
        Documents.create(owner, %{
          title: "Typed",
          type_key: "service_agreement_v1"
        })

      assert {:error, :document_type_already_set} =
               Documents.set_type(owner, doc.id, "employment_v1")

      assert %Document{type_key: "service_agreement_v1"} = Repo.get!(Document, doc.id)
    end

    test "set_type/2 leaves an already typed row unchanged" do
      owner = scope()

      {:ok, doc} =
        Documents.create(owner, %{
          title: "Typed",
          type_key: "service_agreement_v1"
        })

      assert :ok = Documents.set_type(doc.id, "employment_v1")
      assert %Document{type_key: "service_agreement_v1"} = Repo.get!(Document, doc.id)
    end

    test "touch_revision/2 never decreases latest_revision" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Revisioned"})

      assert :ok = Documents.touch_revision(doc.id, 5)
      assert Contract.Repo.get!(Document, doc.id).latest_revision == 5
      assert :ok = Documents.touch_revision(doc.id, 2)
      assert Contract.Repo.get!(Document, doc.id).latest_revision == 5
    end
  end

  defp insert_rhwp_snapshot!(document_id, revision) do
    %Record{}
    |> Record.changeset(%{
      document_id: document_id,
      revision: revision,
      format: "hwp",
      content_type: "application/x-hwp",
      r2_key: "documents/#{document_id}/snapshots/#{revision}.hwp",
      ir_r2_key: "documents/#{document_id}/snapshots/#{revision}.ir.json",
      projection: %{"revision" => revision}
    })
    |> Repo.insert!()
  end

  defp insert_change!(document_id, revision) do
    %Change{}
    |> Change.changeset(%{
      document_id: document_id,
      command_kind: "edit_text",
      actor_type: :user,
      result_revision: revision,
      payload: []
    })
    |> Repo.insert!()
  end
end
