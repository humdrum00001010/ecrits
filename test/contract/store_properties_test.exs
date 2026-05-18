defmodule Contract.StorePropertiesTest do
  @moduledoc """
  Property-based invariants for `Contract.Store`. SPEC.md §16 calls these
  out implicitly via "Store is durable truth":

    1. Across any sequence of successful appends, `result_revision`
       advances by exactly +1 each step.
    2. `Store.load(doc)` reconstructs the same `Runtime.State` as folding
       `Session.Reducer.apply/2` over every persisted Change.
  """
  use Contract.DataCase, async: false
  use ExUnitProperties

  alias Contract.Change
  alias Contract.IO.R2Stub
  alias Contract.Lease
  alias Contract.Runtime
  alias Contract.Session.Reducer
  alias Contract.Store

  setup do
    R2Stub.setup()
    R2Stub.reset()

    original = Application.get_env(:contract, :io_drivers, [])
    Application.put_env(:contract, :io_drivers, Keyword.put(original, :r2, R2Stub))
    on_exit(fn -> Application.put_env(:contract, :io_drivers, original) end)

    :ok
  end

  defp action_gen do
    StreamData.member_of([:rename, :update_metadata])
  end

  defp build_op(:rename, doc, i) do
    %{
      "op" => "set_attr",
      "target_type" => "document",
      "target_id" => doc,
      "args" => %{"key" => "title", "value" => "Title-#{i}"}
    }
  end

  defp build_op(:update_metadata, doc, i) do
    %{
      "op" => "set_attr",
      "target_type" => "document",
      "target_id" => doc,
      "args" => %{"key" => "metadata", "value" => %{"draft_state" => "rev-#{i}"}}
    }
  end

  defp build_change(doc, base_revision, op, i) do
    %Change{
      document_id: doc,
      command_kind: "rename_document",
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: base_revision,
      idempotency_key: "prop-#{i}",
      payload: [build_op(op, doc, i)],
      marks: [],
      message: nil,
      affected_refs: [],
      preimage: %{},
      inverse: [],
      status: :active
    }
  end

  defp create_change(doc) do
    %Change{
      document_id: doc,
      command_kind: "create_document",
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: 0,
      idempotency_key: "create-#{doc}",
      payload: [
        %{
          "op" => "create_node",
          "target_type" => "document",
          "target_id" => doc,
          "args" => %{"title" => "Init", "type_key" => "nda"}
        }
      ],
      marks: [],
      message: nil,
      affected_refs: [],
      preimage: %{},
      inverse: [],
      status: :active
    }
  end

  property "result_revision is strictly monotonic across any sequence of appends" do
    check all(sequence <- StreamData.list_of(action_gen(), min_length: 1, max_length: 8)) do
      doc = Ecto.UUID.generate()
      {:ok, lease} = Lease.acquire(doc, "prop-owner-#{System.unique_integer([:positive])}")

      {:ok, %Change{result_revision: rev0}} =
        Store.append(doc, create_change(doc), lease.fencing_token)

      revisions =
        Enum.reduce(Enum.with_index(sequence), [rev0], fn {op, i}, [prev | _] = acc ->
          change = build_change(doc, prev, op, i)
          {:ok, %Change{result_revision: r}} = Store.append(doc, change, lease.fencing_token)
          [r | acc]
        end)

      assert revisions
             |> Enum.reverse()
             |> Enum.chunk_every(2, 1, :discard)
             |> Enum.all?(fn [a, b] -> b == a + 1 end)

      :ok = Lease.release(doc, lease.owner_ref, lease.fencing_token) |> elem(1)
    end
  end

  property "load(doc) equals fold of Session.Reducer.apply over the persisted changes" do
    check all(sequence <- StreamData.list_of(action_gen(), min_length: 1, max_length: 6)) do
      doc = Ecto.UUID.generate()
      {:ok, lease} = Lease.acquire(doc, "prop-fold-#{System.unique_integer([:positive])}")

      {:ok, _} = Store.append(doc, create_change(doc), lease.fencing_token)

      Enum.reduce(Enum.with_index(sequence), 1, fn {op, i}, prev ->
        change = build_change(doc, prev, op, i)
        {:ok, c} = Store.append(doc, change, lease.fencing_token)
        c.result_revision
      end)

      {:ok, loaded} = Store.load(doc)

      {:ok, all_changes} = Store.changes_since(doc, 0)
      base = %Runtime.State{document_id: doc, revision: 0}

      folded =
        Enum.reduce(all_changes, base, fn change, acc ->
          {:ok, next} = Reducer.apply(Store.change_to_input(change), acc)
          next
        end)

      assert loaded.revision == folded.revision
      assert loaded.projection == folded.projection

      :ok = Lease.release(doc, lease.owner_ref, lease.fencing_token) |> elem(1)
    end
  end

  property "load == load after a snapshot at the latest revision" do
    check all(sequence <- StreamData.list_of(action_gen(), min_length: 0, max_length: 5)) do
      doc = Ecto.UUID.generate()
      {:ok, lease} = Lease.acquire(doc, "prop-snap-#{System.unique_integer([:positive])}")

      {:ok, _} = Store.append(doc, create_change(doc), lease.fencing_token)

      Enum.reduce(Enum.with_index(sequence), 1, fn {op, i}, prev ->
        change = build_change(doc, prev, op, i)
        {:ok, c} = Store.append(doc, change, lease.fencing_token)
        c.result_revision
      end)

      {:ok, before_snap} = Store.load(doc)
      {:ok, _} = Store.snapshot(doc, before_snap.revision)
      {:ok, after_snap} = Store.load(doc)

      assert before_snap.revision == after_snap.revision
      assert before_snap.projection == after_snap.projection

      :ok = Lease.release(doc, lease.owner_ref, lease.fencing_token) |> elem(1)
    end
  end
end
