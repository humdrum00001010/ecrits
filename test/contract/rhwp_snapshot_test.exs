defmodule Contract.RhwpSnapshotTest do
  use Contract.DataCase, async: false

  alias Contract.Change
  alias Contract.Command
  alias Contract.Context
  alias Contract.IO.R2Stub
  alias Contract.RhwpSnapshot.Record
  alias Contract.RhwpSnapshot
  alias Contract.Runtime
  alias Contract.Snapshot
  alias Contract.Store

  setup do
    R2Stub.setup()
    R2Stub.reset()

    original = Application.get_env(:contract, :io_drivers, [])
    Application.put_env(:contract, :io_drivers, Keyword.put(original, :r2, R2Stub))
    on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)
    :ok
  end

  defp scope do
    user = %Contract.Accounts.User{id: Ecto.UUID.generate()}
    Context.for_user(user)
  end

  defp create_doc(%Context{} = ctx, title \\ "Doc") do
    doc_id = Ecto.UUID.generate()

    action = %Command{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      base_revision: 0,
      idempotency_key: "create-#{doc_id}",
      payload: %{"title" => title, "type_key" => "nda_v1"}
    }

    assert {:ok, %Change{}} = Runtime.apply(ctx, action)
    doc_id
  end

  describe "commit/4 — dual write" do
    test "writes native .hwp, companion .ir.json, and the rhwp_snapshots row" do
      ctx = scope()
      doc_id = create_doc(ctx)
      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"
      ir_key = "documents/#{doc_id}/snapshots/1.ir.json"

      # Simulate the .hwp already on R2 (the client PUT it before
      # the commit handler runs).
      R2Stub.put(hwp_key, "fake-hwp-bytes")
      ir = %{"title" => "Doc", "sections" => [%{"idx" => 0, "paragraphs" => []}]}

      assert {:ok, %Record{} = snap} = RhwpSnapshot.commit(doc_id, 1, hwp_key, ir)
      assert snap.document_id == doc_id
      assert snap.revision == 1
      assert snap.format == "hwp"
      assert snap.content_type == "application/x-hwp"
      assert snap.r2_key == hwp_key
      assert snap.ir_r2_key == ir_key

      objects = R2Stub.objects()
      assert Map.has_key?(objects, hwp_key)
      assert Map.has_key?(objects, ir_key)

      assert {:ok, %{"title" => "Doc"}} = Jason.decode(objects[ir_key])
    end

    test "rolls back both R2 blobs when the snapshots row insert fails" do
      ctx = scope()
      doc_id = create_doc(ctx)
      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"
      ir_key = "documents/#{doc_id}/snapshots/1.ir.json"

      R2Stub.put(hwp_key, "fake-hwp-bytes")

      # Force the insert to violate the FK by passing a bogus document_id
      # — Repo will return an error_changeset. We pass a malformed UUID
      # to fail the cast.
      assert {:error, _reason} =
               RhwpSnapshot.commit("not-a-uuid", 1, hwp_key, %{"title" => "X"})

      # Both R2 keys must be gone after rollback.
      objects = R2Stub.objects()
      refute Map.has_key?(objects, hwp_key)
      refute Map.has_key?(objects, ir_key)
    end

    test "retries transient IR PUT errors and succeeds on a later attempt" do
      ctx = scope()
      doc_id = create_doc(ctx)
      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"

      R2Stub.put(hwp_key, "fake-hwp-bytes")

      # Only the first PUT fails — the retry should succeed.
      R2Stub.fail_next(:put, :timeout)

      assert {:ok, %Record{}} = RhwpSnapshot.commit(doc_id, 1, hwp_key, %{"x" => 1})
    end

    test "does not overwrite the runtime Store snapshot at the same revision" do
      ctx = scope()
      doc_id = create_doc(ctx)
      assert {:ok, _state} = Store.snapshot(doc_id, 1)

      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"
      R2Stub.put(hwp_key, "fake-hwp-bytes")
      ir = %{"title" => "Doc", "sections" => [], "fields" => []}

      assert {:ok, %Record{} = rhwp_snap} = RhwpSnapshot.commit(doc_id, 1, hwp_key, ir)
      assert rhwp_snap.r2_key == hwp_key

      assert %Snapshot{r2_key: state_key} =
               Contract.Repo.get_by(Snapshot, document_id: doc_id, revision: 1)

      assert state_key == "documents/#{doc_id}/snapshots/1.json"
    end

    test "upload_and_commit/5 writes native HWP bytes server-side before committing IR" do
      ctx = scope()
      doc_id = create_doc(ctx)
      hwp_key = "documents/#{doc_id}/snapshots/1.hwp"
      ir_key = "documents/#{doc_id}/snapshots/1.ir.json"

      ir = %{
        "title" => "Doc",
        "sections" => [%{"idx" => 0, "paragraphs" => [%{"idx" => 0, "text" => "Body"}]}]
      }

      assert {:ok, %Record{} = snap} =
               RhwpSnapshot.upload_and_commit(doc_id, 1, "server-side-hwp", ir, "hwp")

      assert snap.r2_key == hwp_key
      assert snap.ir_r2_key == ir_key
      assert snap.format == "hwp"
      assert snap.projection == ir

      objects = R2Stub.objects()
      assert objects[hwp_key] == "server-side-hwp"
      assert {:ok, ^ir} = Jason.decode(objects[ir_key])
    end
  end

  describe "to_agent_ir/1 with no snapshot" do
    test "returns an empty IR — no legacy node-graph reconstruction" do
      ctx = scope()
      doc_id = create_doc(ctx, "Cold Doc")
      {:ok, state} = Runtime.load(ctx, doc_id)

      refute Contract.Repo.get_by(Snapshot, document_id: doc_id, revision: state.revision)

      ir = Contract.MCP.Projection.to_agent_ir(state)
      assert is_map(ir)
      assert ir["sections"] == []
      assert ir["fields"] == []
      assert ir["revision"] == state.revision
    end
  end
end
