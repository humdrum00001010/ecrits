defmodule Contract.StoreTest do
  use Contract.DataCase, async: true

  alias Contract.Change
  alias Contract.IO.R2Stub
  alias Contract.Lease
  alias Contract.Operation
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

  defp new_document_id, do: Ecto.UUID.generate()

  defp acquire_lease(document_id) do
    {:ok, lease} = Lease.acquire(document_id, "test-owner-#{System.unique_integer([:positive])}")
    lease
  end

  defp build_create_change(document_id, opts \\ []) do
    %Change{
      document_id: document_id,
      command_kind: "create_document",
      actor_type: :user,
      actor_id: Keyword.get(opts, :actor_id, Ecto.UUID.generate()),
      base_revision: 0,
      result_revision: nil,
      idempotency_key: Keyword.get(opts, :idempotency_key, "create-#{document_id}"),
      payload: [
        %{
          "op" => "create_node",
          "target_type" => "document",
          "target_id" => document_id,
          "args" => %{"title" => Keyword.get(opts, :title, "T"), "type_key" => "nda"}
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

  defp build_followup_change(document_id, base_revision, opts \\ []) do
    %Change{
      document_id: document_id,
      command_kind: "rename_document",
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: base_revision,
      result_revision: nil,
      idempotency_key: Keyword.get(opts, :idempotency_key, "rev-#{base_revision}"),
      payload: [
        %{
          "op" => "set_attr",
          "target_type" => "document",
          "target_id" => document_id,
          "args" => %{"key" => "title", "value" => Keyword.get(opts, :title, "Renamed")}
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

  describe "latest_revision/1" do
    test "returns 0 for an unknown document" do
      assert {:ok, 0} = Store.latest_revision(new_document_id())
    end

    test "returns the max result_revision" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)
      assert {:ok, 1} = Store.latest_revision(doc)

      assert {:ok, _} =
               Store.append(doc, build_followup_change(doc, 1), lease.fencing_token)

      assert {:ok, 2} = Store.latest_revision(doc)
    end
  end

  describe "append/3" do
    test "persists a Change row and bumps result_revision to latest + 1" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      assert {:ok, %Change{result_revision: 1} = persisted} =
               Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert persisted.document_id == doc
      assert persisted.command_kind == "create_document"
    end

    test "broadcasts {:change_committed, _} on the document topic" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      :ok = Phoenix.PubSub.subscribe(Contract.PubSub, Store.pubsub_topic(doc))

      assert {:ok, change} =
               Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert_receive {:change_committed, %Change{id: id}}, 1_000
      assert id == change.id
    end

    test "rejects a stale fencing token with {:error, {:fenced_out, _, _, _}}" do
      doc = new_document_id()
      _lease = acquire_lease(doc)

      # Force-bump the lease by acquiring under a different owner after
      # expiring the current row.
      Lease.force_expire!(doc)
      {:ok, _new_lease} = Lease.acquire(doc, "different-owner")

      assert {:error, {:fenced_out, _current, _supplied, _meta}} =
               Store.append(doc, build_create_change(doc), 1)
    end

    test "rejects a base_revision mismatch with {:error, {:revision_conflict, _}}" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      bad = build_followup_change(doc, 99, idempotency_key: "bad")

      assert {:error, {:revision_conflict, expected: 1, got: 99}} =
               Store.append(doc, bad, lease.fencing_token)
    end

    test "idempotency: replaying the same idempotency_key returns the original row" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      change = build_create_change(doc, idempotency_key: "idem-1")

      assert {:ok, persisted1} = Store.append(doc, change, lease.fencing_token)
      assert {:ok, persisted2} = Store.append(doc, change, lease.fencing_token)

      assert persisted1.id == persisted2.id
      assert {:ok, 1} = Store.latest_revision(doc)
    end

    test "idempotency keyed per-document — same key under different doc is allowed" do
      doc_a = new_document_id()
      doc_b = new_document_id()
      lease_a = acquire_lease(doc_a)
      lease_b = acquire_lease(doc_b)

      change_a = build_create_change(doc_a, idempotency_key: "shared")
      change_b = build_create_change(doc_b, idempotency_key: "shared")

      assert {:ok, ca} = Store.append(doc_a, change_a, lease_a.fencing_token)
      assert {:ok, cb} = Store.append(doc_b, change_b, lease_b.fencing_token)

      assert ca.id != cb.id
    end

    test "nil idempotency_key never collides" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      change1 = build_create_change(doc, idempotency_key: nil)

      assert {:ok, c1} = Store.append(doc, change1, lease.fencing_token)
      assert {:ok, _} = Store.latest_revision(doc)

      change2 = build_followup_change(doc, 1, idempotency_key: nil)
      assert {:ok, c2} = Store.append(doc, change2, lease.fencing_token)
      assert c1.id != c2.id
    end

    test "second commit advances revision to 2 with base_revision=1" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert {:ok, %Change{result_revision: 2}} =
               Store.append(doc, build_followup_change(doc, 1), lease.fencing_token)
    end

    test "rejects when fencing_token doesn't match the current row" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      bad_token = lease.fencing_token - 1

      assert {:error, {:fenced_out, _, _, _}} =
               Store.append(doc, build_create_change(doc), bad_token)
    end
  end

  describe "changes_since/2" do
    test "returns sorted (asc) since 0, empty after the latest revision" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert {:ok, _} =
               Store.append(
                 doc,
                 build_followup_change(doc, 1, idempotency_key: "a"),
                 lease.fencing_token
               )

      assert {:ok, _} =
               Store.append(
                 doc,
                 build_followup_change(doc, 2, idempotency_key: "b"),
                 lease.fencing_token
               )

      assert {:ok, changes} = Store.changes_since(doc, 0)
      assert Enum.map(changes, & &1.result_revision) == [1, 2, 3]

      # After the latest revision → empty list.
      assert {:ok, []} = Store.changes_since(doc, 3)
      assert {:ok, []} = Store.changes_since(doc, 99)
    end
  end

  describe "load/1" do
    test "returns empty state at revision 0 for an unknown document" do
      doc = new_document_id()
      assert {:ok, %Runtime.State{revision: 0, projection: proj}} = Store.load(doc)
      assert proj == Runtime.State.empty_projection()
    end

    test "replays all changes into the projection (revision + title both reflect tip)" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      assert {:ok, _} =
               Store.append(doc, build_create_change(doc, title: "Initial"), lease.fencing_token)

      assert {:ok, _} =
               Store.append(
                 doc,
                 build_followup_change(doc, 1, title: "Renamed"),
                 lease.fencing_token
               )

      assert {:ok, %Runtime.State{revision: 2, projection: proj}} = Store.load(doc)
      assert proj.title == "Renamed"
    end

    test "ignores rhwp native visual snapshot rows when hydrating the runtime projection" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      assert {:ok, _} =
               Store.append(
                 doc,
                 build_create_change(doc, title: "Runtime Doc"),
                 lease.fencing_token
               )

      {:ok, _} =
        %Contract.RhwpSnapshot.Record{}
        |> Contract.RhwpSnapshot.Record.changeset(%{
          document_id: doc,
          revision: 1,
          r2_key: "documents/#{doc}/snapshots/1.hwp",
          ir_r2_key: "documents/#{doc}/snapshots/1.ir.json",
          format: "hwp",
          content_type: "application/x-hwp",
          projection: %{
            "title" => "Agent IR Cache",
            "contract_type" => "service_agreement_v1",
            "sections" => [%{"idx" => 0, "paragraphs" => []}],
            "fields" => []
          }
        })
        |> Contract.Repo.insert()

      assert {:ok, %Runtime.State{revision: 1, projection: proj}} = Store.load(doc)
      assert proj.title == "Runtime Doc"
      assert proj.type_key == "nda"
    end
  end

  describe "snapshot/2" do
    test "writes a snapshot row + R2 object at the current revision" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)
      assert {:ok, _} = Store.append(doc, build_followup_change(doc, 1), lease.fencing_token)

      assert {:ok, %Runtime.State{revision: 2}} = Store.snapshot(doc, 2)

      assert %Snapshot{revision: 2, r2_key: key} =
               Contract.Repo.get_by(Snapshot, document_id: doc, revision: 2)

      assert key == "documents/#{doc}/snapshots/2.json"
      assert Map.has_key?(R2Stub.objects(), key)
    end

    test "load/1 short-circuits via snapshot + later changes" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)
      assert {:ok, _} = Store.snapshot(doc, 1)

      assert {:ok, _} =
               Store.append(
                 doc,
                 build_followup_change(doc, 1, title: "After"),
                 lease.fencing_token
               )

      assert {:ok, %Runtime.State{revision: 2, projection: %{title: "After"}}} =
               Store.load(doc)
    end

    test "rolls back the DB row when R2 put fails" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      R2Stub.fail_next(:put, :network_down)

      assert {:error, :network_down} = Store.snapshot(doc, 1)
      assert nil == Contract.Repo.get_by(Snapshot, document_id: doc, revision: 1)
    end

    test "errors when requested revision doesn't match current state" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      assert {:error, {:snapshot_revision_mismatch, expected: 99, got: 1}} =
               Store.snapshot(doc, 99)
    end
  end

  describe "idempotency_seen? / previous_result" do
    test "idempotency_seen? returns false for nil/unseen keys" do
      doc = new_document_id()
      refute Store.idempotency_seen?(doc, nil)
      refute Store.idempotency_seen?(doc, "never-seen")
    end

    test "idempotency_seen?/previous_result reflect persisted Changes, :not_found otherwise" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      assert {:ok, persisted} =
               Store.append(
                 doc,
                 build_create_change(doc, idempotency_key: "seen"),
                 lease.fencing_token
               )

      assert Store.idempotency_seen?(doc, "seen")
      refute Store.idempotency_seen?(doc, "different")

      # previous_result for the seen key resolves to the persisted Change.
      assert {:ok, %Change{id: id}} = Store.previous_result(doc, "seen")
      assert id == persisted.id

      # Missing / nil keys are :not_found.
      assert {:error, :not_found} = Store.previous_result(new_document_id(), "missing")
      assert {:error, :not_found} = Store.previous_result(new_document_id(), nil)
    end
  end

  describe "transaction/1" do
    test "commits/rollsback by return shape ({:ok,_} / {:error,_} / other)" do
      assert {:ok, 42} = Store.transaction(fn -> {:ok, 42} end)
      assert {:error, :nope} = Store.transaction(fn -> {:error, :nope} end)

      assert {:error, {:bad_transaction_return, :weird}} =
               Store.transaction(fn -> :weird end)
    end

    test "actual DB writes inside a failed transaction get rolled back" do
      doc = new_document_id()
      lease = acquire_lease(doc)

      result =
        Store.transaction(fn ->
          {:ok, _} = Store.append(doc, build_create_change(doc), lease.fencing_token)
          {:error, :abort}
        end)

      assert {:error, :abort} = result
      assert {:ok, 0} = Store.latest_revision(doc)
    end
  end

  describe "document set_attr propagation (Task #81)" do
    # When Engine emits a `:set_attr` op against `target_type: :document`,
    # Store.append must mirror the affected attribute(s) onto the
    # `documents` SQL row so dashboard/list queries don't see stale
    # title/status or the initial type selection. The propagation runs inside
    # the same `Repo.transaction/1` as the Change insert.

    alias Contract.Documents

    defp setup_document_row(owner_id \\ nil, opts \\ []) do
      owner_id = owner_id || Ecto.UUID.generate()
      doc_id = Ecto.UUID.generate()
      type_key = Keyword.get(opts, :type_key, "nda_v1")

      {:ok, _doc} =
        %Contract.Documents.Document{id: doc_id}
        |> Contract.Documents.Document.changeset(%{
          "owner_id" => owner_id,
          "title" => "Initial",
          "type_key" => type_key,
          "status" => "draft"
        })
        |> Contract.Repo.insert()

      {doc_id, owner_id}
    end

    defp set_attr_change(doc_id, base_revision, key, value, opts \\ []) do
      %Change{
        document_id: doc_id,
        command_kind: "set_attr_doc",
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: base_revision,
        result_revision: nil,
        idempotency_key: Keyword.get(opts, :idempotency_key, "set-#{key}-#{base_revision}"),
        payload: [
          %{
            "op" => "set_attr",
            "target_type" => "document",
            "target_id" => doc_id,
            "args" => %{"key" => Atom.to_string(key), "value" => value}
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

    test "type_key set_attr propagates for an untyped document" do
      {doc_id, _owner_id} = setup_document_row(nil, type_key: nil)
      lease = acquire_lease(doc_id)

      change =
        set_attr_change(doc_id, 0, :type_key, "service_agreement_v1",
          idempotency_key: "set-type-#{doc_id}"
        )

      assert {:ok, _} = Store.append(doc_id, change, lease.fencing_token)

      row = Contract.Repo.get(Contract.Documents.Document, doc_id)
      assert row.type_key == "service_agreement_v1"
      assert row.title == "Initial"
      assert row.status == :draft
    end

    test "type_key set_attr replacement is rejected for an already typed document" do
      {doc_id, _owner_id} = setup_document_row()
      lease = acquire_lease(doc_id)

      change =
        set_attr_change(doc_id, 0, :type_key, "service_agreement_v1",
          idempotency_key: "replace-type-#{doc_id}"
        )

      assert {:error, :document_type_already_set} =
               Store.append(doc_id, change, lease.fencing_token)

      row = Contract.Repo.get(Contract.Documents.Document, doc_id)
      assert row.type_key == "nda_v1"
      assert row.title == "Initial"
      assert row.status == :draft
      assert {:ok, 0} = Store.latest_revision(doc_id)
    end

    test "multiple non-type set_attr ops in one Change all propagate" do
      {doc_id, _owner_id} = setup_document_row()
      lease = acquire_lease(doc_id)

      change = %Change{
        document_id: doc_id,
        command_kind: "bulk_set_attr",
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: 0,
        result_revision: nil,
        idempotency_key: "bulk-#{doc_id}",
        payload: [
          %{
            "op" => "set_attr",
            "target_type" => "document",
            "target_id" => doc_id,
            "args" => %{"key" => "title", "value" => "Bulk Title"}
          },
          %{
            "op" => "set_attr",
            "target_type" => "document",
            "target_id" => doc_id,
            "args" => %{"key" => "status", "value" => "reviewing"}
          }
        ],
        marks: [],
        message: nil,
        affected_refs: [],
        preimage: %{},
        inverse: [],
        status: :active
      }

      assert {:ok, _} = Store.append(doc_id, change, lease.fencing_token)

      row = Contract.Repo.get(Contract.Documents.Document, doc_id)
      assert row.title == "Bulk Title"
      assert row.type_key == "nda_v1"
      assert row.status == :reviewing
    end

    test "non-attr ops (e.g. create_node) leave the documents row untouched" do
      {doc_id, _owner_id} = setup_document_row()
      lease = acquire_lease(doc_id)

      # build_create_change builds a :create_node op, NOT a :set_attr op.
      change = build_create_change(doc_id, idempotency_key: "create-only")
      assert {:ok, _} = Store.append(doc_id, change, lease.fencing_token)

      row = Contract.Repo.get(Contract.Documents.Document, doc_id)
      # untouched — title/type_key/status are still the seed values
      assert row.title == "Initial"
      assert row.type_key == "nda_v1"
      assert row.status == :draft
    end

    test "Documents.get/2 reflects the propagated title" do
      {doc_id, owner_id} = setup_document_row()
      lease = acquire_lease(doc_id)

      # The seeded matter has tenant_id: nil so any non-nil scope can
      # read it via the ACL gate.
      scope = %Contract.Context{
        user: %Contract.Accounts.User{id: owner_id, email: "owner@x"},
        tenant: nil
      }

      assert {:ok, _} =
               Store.append(
                 doc_id,
                 set_attr_change(doc_id, 0, :title, "After Propagation"),
                 lease.fencing_token
               )

      assert {:ok, %Documents.Document{title: "After Propagation"}} =
               Documents.get(scope, doc_id)
    end
  end

  describe "change_to_input/1" do
    test "decodes string ops back into Operation structs with atom kinds" do
      doc = new_document_id()
      lease = acquire_lease(doc)
      assert {:ok, persisted} = Store.append(doc, build_create_change(doc), lease.fencing_token)

      input = Store.change_to_input(persisted)
      assert input.action_kind == :create_document
      assert [%Operation{op: :create_node, target_type: :document}] = input.ops
    end
  end

  describe "load/1 projection decode (JSONB → atom coercion)" do
    # When a Snapshot row's projection blob round-trips through Postgres
    # JSONB, atoms come back as strings. The renderer (PreviewOverlay) pattern-
    # matches on atom `kind`, so without coercion every node falls through to
    # the catch-all <div> clause. These tests pin the coercion contract at the
    # Store decode boundary.

    defp insert_raw_snapshot(document_id, projection) do
      {:ok, _} =
        %Contract.Snapshot{}
        |> Contract.Snapshot.changeset(%{
          document_id: document_id,
          revision: 1,
          projection: projection,
          r2_key: "documents/#{document_id}/snapshots/1.json"
        })
        |> Contract.Repo.insert()
    end

    test "coerces node kind from string to atom via allow-list" do
      doc = new_document_id()

      # JSONB-shaped projection: string keys all the way down, string kinds.
      projection = %{
        "title" => "Real Doc",
        "type_key" => "nda",
        "metadata" => %{},
        "nodes" => %{
          "node:1" => %{
            "id" => "node:1",
            "kind" => "heading",
            "attrs" => %{"level" => 1},
            "content" => "Article 1"
          },
          "node:2" => %{
            "id" => "node:2",
            "kind" => "paragraph",
            "content" => "Body text"
          },
          "node:3" => %{
            "id" => "node:3",
            "kind" => "table",
            "attrs" => %{"rows" => [["a", "b"]]}
          },
          "node:4" => %{
            "id" => "node:4",
            "kind" => "list_item",
            "attrs" => %{"ordered" => true}
          }
        },
        "node_order" => ["node:1", "node:2", "node:3", "node:4"],
        "fields" => %{},
        "marks" => %{},
        "refs" => %{}
      }

      insert_raw_snapshot(doc, projection)

      assert {:ok, %Runtime.State{projection: proj}} = Store.load(doc)

      # Outer node-map keys atomized.
      assert %{kind: :heading, id: "node:1", attrs: %{level: 1}, content: "Article 1"} =
               proj.nodes["node:1"]

      assert %{kind: :paragraph} = proj.nodes["node:2"]
      assert %{kind: :table, attrs: %{rows: [["a", "b"]]}} = proj.nodes["node:3"]
      assert %{kind: :list_item, attrs: %{ordered: true}} = proj.nodes["node:4"]

      # node_order preserved verbatim (string ids).
      assert proj.node_order == ["node:1", "node:2", "node:3", "node:4"]
    end

    test "falls back unknown node kinds to :paragraph" do
      doc = new_document_id()

      projection = %{
        "nodes" => %{
          "node:x" => %{
            "id" => "node:x",
            "kind" => "weird_made_up_kind",
            "content" => "?"
          }
        },
        "node_order" => ["node:x"]
      }

      insert_raw_snapshot(doc, projection)

      assert {:ok, %Runtime.State{projection: proj}} = Store.load(doc)
      assert proj.nodes["node:x"].kind == :paragraph
    end

    test "atomizes mark intent/source/target_type/confidence via existing atoms" do
      doc = new_document_id()

      # Force the intent atoms to be loaded by referencing them as literals.
      _ = [:assertion, :question, :risk, :user, :high]

      projection = %{
        "marks" => %{
          "mark:1" => %{
            "id" => "mark:1",
            "intent" => "assertion",
            "source" => "user",
            "target_type" => "node",
            "target_id" => "node:1",
            "confidence" => "high",
            "text" => "hi"
          }
        }
      }

      insert_raw_snapshot(doc, projection)

      assert {:ok, %Runtime.State{projection: proj}} = Store.load(doc)

      assert %{
               id: "mark:1",
               intent: :assertion,
               source: :user,
               target_type: :node,
               confidence: :high,
               text: "hi"
             } = proj.marks["mark:1"]
    end

    test "in-memory atoms passed back through decode are preserved" do
      doc = new_document_id()

      projection = %{
        nodes: %{
          "node:1" => %{id: "node:1", kind: :heading, attrs: %{level: 2}}
        },
        node_order: ["node:1"]
      }

      insert_raw_snapshot(doc, projection)

      assert {:ok, %Runtime.State{projection: proj}} = Store.load(doc)
      assert %{kind: :heading, attrs: %{level: 2}} = proj.nodes["node:1"]
    end
  end
end
