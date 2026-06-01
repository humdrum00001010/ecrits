defmodule Contract.Session.ReducerTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  alias Contract.{Change, ChangeInput, MarkInput, Operation, Runtime}
  alias Contract.Command
  alias Contract.Session.Reducer

  doctest Contract.Session.Reducer

  # ----------------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------------

  defp new_state(opts \\ []) do
    %Runtime.State{
      document_id: Keyword.get(opts, :document_id, "doc-0000-0000-0000-000000000000"),
      revision: Keyword.get(opts, :revision, 0),
      projection: Keyword.get(opts, :projection, Runtime.State.empty_projection())
    }
  end

  defp uuid(seed) do
    digits = String.pad_leading(Integer.to_string(seed), 12, "0")
    "11111111-1111-1111-1111-#{digits}"
  end

  defp existing_atom?(value) do
    _ = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end

  defp action(kind, attrs \\ %{}) do
    base = %Command{
      kind: kind,
      document_id: uuid(1),
      actor_type: :user,
      actor_id: uuid(2),
      base_revision: 0,
      payload: %{}
    }

    Map.merge(base, Map.new(attrs))
  end

  defp run_pipeline(action, state) do
    {:ok, input} = Reducer.compile(action, state)
    {:ok, :ok} = Reducer.validate(input, state)
    {:ok, pre} = Reducer.preimage(input, state)
    {:ok, inv} = Reducer.inverse(input, pre)
    {:ok, refs} = Reducer.affected_refs(input, state)
    %ChangeInput{} = input = %{input | preimage: pre, inverse_ops: inv, affected_refs: refs}
    {:ok, new_state} = Reducer.apply(input, state)
    {input, new_state}
  end

  defp doc_write_payload(cmd, payload, off) do
    %{
      "sec" => 0,
      "para" => 0,
      "type" => "paragraph",
      "payload" => %{"cmd" => cmd, "payload" => payload},
      "resolved" => %{"off" => off}
    }
  end

  # ============================================================================
  # compile/2 — supported kinds
  # ============================================================================

  describe "compile/2 — create_document" do
    test "produces one create_node op for the document" do
      state = new_state()

      action =
        action(:create_document,
          document_id: uuid(10),
          payload: %{"title" => "NDA Draft", "type_key" => "nda"}
        )

      {:ok, %ChangeInput{} = input} = Reducer.compile(action, state)

      assert input.action_kind == :create_document
      assert length(input.ops) == 1
      [op] = input.ops
      assert op.op == :create_node
      assert op.target_type == :document
      assert op.target_id == uuid(10)
      assert op.args.title == "NDA Draft"
      assert op.args.type_key == "nda"
    end
  end

  describe "compile/2 — create_document with nodes (Wave 7 materialization)" do
    test "compiles to 1 doc op + N create_node ops + 1 node_order set_attr op" do
      state = new_state()

      a =
        action(:create_document,
          document_id: uuid(10),
          payload: %{
            "title" => "NDA",
            "type_key" => "nda_v1",
            "nodes" => [
              %{"id" => "n1", "kind" => "paragraph", "content" => "Hello world"},
              %{"id" => "n2", "kind" => "heading", "content" => "Article 1"}
            ],
            "node_order" => ["n2", "n1"]
          }
        )

      {:ok, input} = Reducer.compile(a, state)

      # 1 document create_node + 2 node create_nodes + 1 node_order set_attr
      assert length(input.ops) == 4
      [doc_op, n1_op, n2_op, order_op] = input.ops

      assert doc_op.op == :create_node and doc_op.target_type == :document
      assert n1_op.op == :create_node and n1_op.target_type == :node
      assert n1_op.target_id == "n1"
      assert n1_op.args.kind == :paragraph
      assert n2_op.op == :create_node and n2_op.target_type == :node
      assert n2_op.args.kind == :heading
      assert order_op.op == :set_attr
      assert order_op.args.key == :node_order
      assert order_op.args.value == ["n2", "n1"]
    end

    test "apply materializes nodes into projection.nodes map" do
      state = new_state()

      a =
        action(:create_document,
          document_id: uuid(10),
          payload: %{
            "title" => "NDA",
            "type_key" => "nda_v1",
            "nodes" => [
              %{"id" => "n1", "kind" => "paragraph", "content" => "Hello"},
              %{"id" => "n2", "kind" => "heading", "content" => "Title"}
            ]
          }
        )

      {_input, new_state} = run_pipeline(a, state)

      assert Map.has_key?(new_state.projection.nodes, "n1")
      assert Map.has_key?(new_state.projection.nodes, "n2")
      assert new_state.projection.nodes["n1"].kind == :paragraph
      assert new_state.projection.nodes["n1"].content == "Hello"
      assert new_state.projection.nodes["n2"].kind == :heading
      # Title + type_key still set on the projection.
      assert new_state.projection.title == "NDA"
      assert new_state.projection.type_key == "nda_v1"
    end

    test "apply preserves node_order from payload" do
      state = new_state()

      a =
        action(:create_document,
          document_id: uuid(10),
          payload: %{
            "title" => "NDA",
            "type_key" => "nda_v1",
            "nodes" => [
              %{"id" => "n1", "kind" => "paragraph", "content" => "A"},
              %{"id" => "n2", "kind" => "paragraph", "content" => "B"}
            ],
            "node_order" => ["n2", "n1"]
          }
        )

      {_input, new_state} = run_pipeline(a, state)
      assert new_state.projection.node_order == ["n2", "n1"]
    end

    test "empty nodes list produces only the document-level op" do
      state = new_state()

      a =
        action(:create_document,
          document_id: uuid(10),
          payload: %{"title" => "NDA", "type_key" => "nda_v1", "nodes" => []}
        )

      {:ok, input} = Reducer.compile(a, state)
      assert length(input.ops) == 1
      [op] = input.ops
      assert op.op == :create_node and op.target_type == :document
    end

    test "inverse of create_document with nodes produces :delete_node ops" do
      state = new_state()

      a =
        action(:create_document,
          document_id: uuid(10),
          payload: %{
            "title" => "NDA",
            "type_key" => "nda_v1",
            "nodes" => [
              %{"id" => "n1", "kind" => "paragraph", "content" => "Hello"},
              %{"id" => "n2", "kind" => "heading", "content" => "Title"}
            ],
            "node_order" => ["n1", "n2"]
          }
        )

      {input, new_state} = run_pipeline(a, state)

      # inverse_ops should include a :delete_node for each :create_node.
      delete_node_ops =
        Enum.filter(input.inverse_ops, fn op ->
          op.op == :delete_node and op.target_type == :node
        end)

      assert length(delete_node_ops) == 2

      # Applying the inverse removes the node entries from the projection.
      inverse_input = %ChangeInput{input | ops: input.inverse_ops}
      {:ok, restored} = Reducer.apply(inverse_input, new_state)
      assert restored.projection.nodes == %{}
      assert restored.projection.node_order == []
    end

    test "UTF-8 Korean content survives compile + apply" do
      state = new_state()
      korean = "이 계약은 갑과 을 사이에 체결된다."

      a =
        action(:create_document,
          document_id: uuid(10),
          payload: %{
            "title" => "표준계약서",
            "type_key" => "service_agreement_v1",
            "nodes" => [
              %{"id" => "n1", "kind" => "paragraph", "content" => korean}
            ]
          }
        )

      {_input, new_state} = run_pipeline(a, state)
      assert new_state.projection.title == "표준계약서"
      assert new_state.projection.nodes["n1"].content == korean
    end

    test "preimage captures the pre-create node_order for the inverse" do
      proj = Map.put(Runtime.State.empty_projection(), :node_order, ["preexisting"])
      state = new_state(projection: proj)

      a =
        action(:create_document,
          document_id: uuid(10),
          payload: %{
            "title" => "NDA",
            "type_key" => "nda_v1",
            "nodes" => [%{"id" => "n1", "kind" => "paragraph", "content" => "x"}],
            "node_order" => ["n1"]
          }
        )

      {:ok, input} = Reducer.compile(a, state)
      {:ok, pre} = Reducer.preimage(input, state)

      # The set_attr :node_order op is the last op; its preimage captures
      # the pre-mutation node_order list.
      order_op_idx = length(input.ops) - 1
      order_pre = Map.get(pre, {order_op_idx, uuid(10)})
      assert order_pre.op == :set_attr
      assert order_pre.key == :node_order
      assert order_pre.value == ["preexisting"]
    end
  end

  describe "compile/2 — rename_document" do
    test "produces a set_attr title op" do
      state = new_state()
      a = action(:rename_document, payload: %{"title" => "Renamed"})

      {:ok, input} = Reducer.compile(a, state)

      assert [%Operation{op: :set_attr, args: %{key: :title, value: "Renamed"}}] = input.ops
    end

    test "does not create atoms for unknown payload keys" do
      state = new_state()
      unknown_key = "unsafe_payload_key_#{System.unique_integer([:positive])}"
      refute existing_atom?(unknown_key)

      a =
        action(:rename_document,
          payload: %{"title" => "Renamed", unknown_key => "ignored"}
        )

      assert {:ok, %ChangeInput{} = input} = Reducer.compile(a, state)
      assert [%Operation{op: :set_attr, args: %{key: :title, value: "Renamed"}}] = input.ops
      refute existing_atom?(unknown_key)
    end
  end

  describe "compile/2 — update_metadata" do
    test "merges new metadata with current" do
      proj = Map.put(Runtime.State.empty_projection(), :metadata, %{client: "Acme"})
      state = new_state(projection: proj)

      a =
        action(:update_metadata,
          payload: %{"metadata" => %{"jurisdiction" => "NY"}}
        )

      {:ok, input} = Reducer.compile(a, state)
      [op] = input.ops
      assert op.args.key == :metadata
      assert op.args.value == %{"client" => "Acme", "jurisdiction" => "NY"}
    end

    test "incoming metadata replaces existing string/atom key equivalent" do
      proj =
        Map.put(Runtime.State.empty_projection(), :metadata, %{
          :rhwp_field_values => %{"service_contract_name" => "atom-old"},
          "rhwp_field_values" => %{"service_contract_name" => "old"}
        })

      state = new_state(projection: proj)

      a =
        action(:update_metadata,
          payload: %{
            "metadata" => %{
              "rhwp_field_values" => %{
                "payment_advance_ratio" => "15",
                "service_contract_name" => "new"
              }
            }
          }
        )

      {:ok, input} = Reducer.compile(a, state)
      [op] = input.ops
      refute Map.has_key?(op.args.value, :rhwp_field_values)

      assert op.args.value["rhwp_field_values"] == %{
               "payment_advance_ratio" => "15",
               "service_contract_name" => "new"
             }
    end
  end

  describe "compile/2 — set_contract_type" do
    test "produces type change plus document-state reset ops" do
      state =
        new_state(
          projection: %{
            Runtime.State.empty_projection()
            | metadata: %{
                "rhwp_field_values" => %{"old" => "value"},
                :rhwp_field_values => %{"atom-old" => "value"},
                "notes" => "keep"
              },
              nodes: %{"n1" => %{id: "n1", kind: :paragraph, content: "old"}},
              node_order: ["n1"],
              fields: %{"f1" => %{id: "f1", value: "old"}},
              marks: %{"m1" => %{id: "m1", intent: :flag, source: :user}},
              refs: %{"r1" => %{id: "r1", source_node_id: "n1", target_id: "x"}}
          }
        )

      a = action(:set_contract_type, payload: %{"type_key" => "msa"})

      {:ok, input} = Reducer.compile(a, state)

      assert [
               %Operation{op: :set_attr, args: %{key: :type_key, value: "msa"}},
               %Operation{op: :set_attr, args: %{key: :metadata, value: %{"notes" => "keep"}}},
               %Operation{op: :set_attr, args: %{key: :nodes, value: %{}}},
               %Operation{op: :set_attr, args: %{key: :node_order, value: []}},
               %Operation{op: :set_attr, args: %{key: :fields, value: %{}}},
               %Operation{op: :set_attr, args: %{key: :marks, value: %{}}},
               %Operation{op: :set_attr, args: %{key: :refs, value: %{}}}
             ] = input.ops
    end

    test "validate/2 allows selecting a type when the document is untyped" do
      state =
        new_state(projection: %{Runtime.State.empty_projection() | type_key: nil})

      a = action(:set_contract_type, payload: %{"type_key" => "nda_v1"})
      {:ok, input} = Reducer.compile(a, state)

      assert {:ok, :ok} = Reducer.validate(input, state)
    end

    test "validate/2 rejects replacing an existing type_key" do
      typed_state =
        new_state(
          projection: %{Runtime.State.empty_projection() | type_key: "service_agreement_v1"}
        )

      a = action(:set_contract_type, payload: %{"type_key" => "nda_v1"})
      {:ok, input} = Reducer.compile(a, typed_state)

      assert {:error, :document_type_already_set} = Reducer.validate(input, typed_state)
    end

    test "apply/2 sets type and clears document projection state for first selection" do
      state =
        new_state(
          projection: %{
            Runtime.State.empty_projection()
            | metadata: %{"rhwp_field_values" => %{"service_contract_name" => "old"}},
              nodes: %{"n1" => %{id: "n1", kind: :paragraph, content: "old"}},
              node_order: ["n1"],
              fields: %{"f1" => %{id: "f1", value: "old"}},
              marks: %{"m1" => %{id: "m1", intent: :flag, source: :user}},
              refs: %{"r1" => %{id: "r1", source_node_id: "n1", target_id: "x"}}
          }
        )

      {_input, new_state} =
        action(:set_contract_type, payload: %{"type_key" => "employment_v1"})
        |> run_pipeline(state)

      assert new_state.projection.type_key == "employment_v1"
      assert new_state.projection.metadata == %{}
      assert new_state.projection.nodes == %{}
      assert new_state.projection.node_order == []
      assert new_state.projection.fields == %{}
      assert new_state.projection.marks == %{}
      assert new_state.projection.refs == %{}
    end
  end

  describe "compile/2 — edit_document and agent_change" do
    test "ops are parsed from the payload" do
      state = new_state()

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "create_node",
                "target_type" => "node",
                "target_id" => uuid(99),
                "args" => %{"kind" => "paragraph", "content" => "hi"}
              }
            ],
            "marks" => [
              %{"intent" => "label", "source" => "user", "text" => "intro"}
            ]
          }
        )

      {:ok, input} = Reducer.compile(a, state)

      assert length(input.ops) == 1
      assert length(input.marks) == 1
      assert [%Operation{op: :create_node}] = input.ops
      assert [%MarkInput{intent: :label}] = input.marks
    end

    test "agent_change behaves like edit_document" do
      state = new_state()

      a =
        action(:agent_change,
          payload: %{
            "ops" => [
              %{
                "op" => "replace_content",
                "target_type" => "node",
                "target_id" => uuid(7),
                "args" => %{"content" => "new text"}
              }
            ]
          }
        )

      {:ok, input} = Reducer.compile(a, state)
      assert [%Operation{op: :replace_content}] = input.ops
    end
  end

  # ============================================================================
  # compile/2 — unsupported kinds
  # ============================================================================

  describe "compile/2 — unsupported kinds raise" do
    for kind <- [
          :open_document,
          :upload_document,
          :duplicate_document,
          :start_type_conversion,
          :set_field_migration_strategy,
          :create_converted_variant,
          :chat_message,
          :request_export,
          :revoke_change,
          :resolve_revoke,
          :add_mark,
          :update_mark,
          :source_claim_confirm,
          :source_claim_correct,
          :source_claim_reject,
          :source_claim_link_to_document,
          :source_claim_unlink_from_document
        ] do
      test "Reducer.compile/2 rejects #{kind}" do
        state = new_state()

        assert_raise ArgumentError, fn ->
          Reducer.compile(action(unquote(kind)), state)
        end
      end
    end
  end

  # ============================================================================
  # validate/2
  # ============================================================================

  describe "validate/2 — revision concurrency" do
    test "matching base_revision returns :ok" do
      state = new_state(revision: 3)
      a = action(:rename_document, base_revision: 3, payload: %{"title" => "x"})
      {:ok, input} = Reducer.compile(a, state)
      assert {:ok, :ok} = Reducer.validate(input, state)
    end

    test "mismatched base_revision returns {:error, {:revision_conflict, ...}}" do
      state = new_state(revision: 3)
      a = action(:rename_document, base_revision: 1, payload: %{"title" => "x"})
      {:ok, input} = Reducer.compile(a, state)
      assert {:error, {:revision_conflict, expected: 3, got: 1}} = Reducer.validate(input, state)
    end

    test "nil base_revision skips revision check" do
      state = new_state(revision: 7)
      a = action(:rename_document, base_revision: nil, payload: %{"title" => "x"})
      {:ok, input} = Reducer.compile(a, state)
      assert {:ok, :ok} = Reducer.validate(input, state)
    end
  end

  describe "validate/2 — op shape" do
    test "edit_document requires :content on replace_content" do
      state = new_state()

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "replace_content",
                "target_type" => "node",
                "target_id" => uuid(9),
                "args" => %{}
              }
            ]
          }
        )

      {:ok, input} = Reducer.compile(a, state)
      assert {:error, {:invalid_op_args, _}} = Reducer.validate(input, state)
    end

    test "edit_document requires :kind on create_node" do
      state = new_state()

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "create_node",
                "target_type" => "node",
                "target_id" => uuid(9),
                "args" => %{}
              }
            ]
          }
        )

      {:ok, input} = Reducer.compile(a, state)
      assert {:error, {:invalid_op_args, _}} = Reducer.validate(input, state)
    end

    test "edit_document rejects ops whose node target_id is unknown" do
      state = new_state()

      a =
        action(:edit_document,
          payload: %{
            "ops" => [%{"op" => "delete_node", "target_type" => "node", "target_id" => uuid(99)}]
          }
        )

      {:ok, input} = Reducer.compile(a, state)
      assert {:error, {:target_not_found, _}} = Reducer.validate(input, state)
    end
  end

  # ============================================================================
  # apply/2 — projection semantics
  # ============================================================================

  describe "apply/2" do
    test "bumps revision and applies create_document" do
      state = new_state(revision: 4)

      a =
        action(:create_document,
          base_revision: 4,
          payload: %{"title" => "T", "type_key" => "nda"}
        )

      {_input, new_state} = run_pipeline(a, state)
      assert new_state.revision == 5
      assert new_state.projection.title == "T"
      assert new_state.projection.type_key == "nda"
    end

    test "rename_document mutates title only" do
      proj = Map.put(Runtime.State.empty_projection(), :title, "Old")
      state = new_state(projection: proj)
      a = action(:rename_document, payload: %{"title" => "New"})
      {_input, new_state} = run_pipeline(a, state)
      assert new_state.projection.title == "New"
    end

    test "edit_document: create_node then replace_content" do
      state = new_state()
      node_id = uuid(20)

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "create_node",
                "target_type" => "node",
                "target_id" => node_id,
                "args" => %{"kind" => "paragraph", "content" => "hello"}
              },
              %{
                "op" => "replace_content",
                "target_type" => "node",
                "target_id" => node_id,
                "args" => %{"content" => "world"}
              }
            ]
          }
        )

      # `replace_content` will be validated for shape but its target_id is the
      # node we just created — validator runs once against starting state, so
      # the second op's :node target may not yet exist. The targeted lookup is
      # tolerant for create-then-* sequences because validation only checks
      # explicit ID lookups, not chained creation. We use a state pre-seeded
      # to keep validation strict.
      proj =
        Runtime.State.empty_projection()
        |> put_in([:nodes, node_id], %{id: node_id, kind: :paragraph})

      state = %{state | projection: proj}

      {_input, new_state} = run_pipeline(a, state)
      assert new_state.projection.nodes[node_id].content == "world"
    end

    test "set_field writes the key/value pair" do
      state = new_state()
      field_id = uuid(40)

      proj =
        Runtime.State.empty_projection()
        |> put_in([:fields, field_id], %{id: field_id})

      state = %{state | projection: proj}

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "set_field",
                "target_type" => "field",
                "target_id" => field_id,
                "args" => %{key: :amount, value: 1500}
              }
            ]
          }
        )

      {_input, new_state} = run_pipeline(a, state)
      assert new_state.projection.fields[field_id][:amount] == 1500
    end

    test "move_node reorders top-level node_order" do
      node_a = uuid(30)
      node_b = uuid(31)

      proj =
        Runtime.State.empty_projection()
        |> Map.put(:nodes, %{
          node_a => %{id: node_a, kind: :paragraph},
          node_b => %{id: node_b, kind: :paragraph}
        })
        |> Map.put(:node_order, [node_a, node_b])

      state = new_state(projection: proj)

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "move_node",
                "target_type" => "node",
                "target_id" => node_b,
                "args" => %{"position" => 0}
              }
            ]
          }
        )

      {_input, new_state} = run_pipeline(a, state)
      assert new_state.projection.node_order == [node_b, node_a]
    end
  end

  # ============================================================================
  # inverse/2 — round-trip semantics
  # ============================================================================

  describe "inverse/2" do
    test "round-trips a rename_document" do
      proj = Map.put(Runtime.State.empty_projection(), :title, "Old")
      state = new_state(projection: proj)
      a = action(:rename_document, payload: %{"title" => "New"})

      {input, new_state} = run_pipeline(a, state)
      assert new_state.projection.title == "New"

      inverse_input = %ChangeInput{input | ops: input.inverse_ops}
      {:ok, restored} = Reducer.apply(inverse_input, new_state)
      assert restored.projection.title == "Old"
    end

    test "delete_node restores from preimage" do
      node_id = uuid(60)

      proj =
        Runtime.State.empty_projection()
        |> Map.put(:nodes, %{
          node_id => %{id: node_id, kind: :paragraph, content: "keep me"}
        })
        |> Map.put(:node_order, [node_id])

      state = new_state(projection: proj)

      a =
        action(:edit_document,
          payload: %{
            "ops" => [%{"op" => "delete_node", "target_type" => "node", "target_id" => node_id}]
          }
        )

      {input, new_state} = run_pipeline(a, state)
      refute Map.has_key?(new_state.projection.nodes, node_id)

      inverse_input = %ChangeInput{input | ops: input.inverse_ops}
      {:ok, restored} = Reducer.apply(inverse_input, new_state)
      assert restored.projection.nodes[node_id].content == "keep me"
    end
  end

  # ============================================================================
  # affected_refs/2
  # ============================================================================

  describe "affected_refs/2" do
    test "returns refs whose target_id is in an op target" do
      node_id = uuid(70)
      ref_id = uuid(71)

      proj =
        Runtime.State.empty_projection()
        |> Map.put(:nodes, %{node_id => %{id: node_id, kind: :paragraph}})
        |> Map.put(:refs, %{
          ref_id => %{id: ref_id, source_node_id: uuid(72), target_id: node_id, type: :clause}
        })

      state = new_state(projection: proj)

      a =
        action(:edit_document,
          payload: %{
            "ops" => [%{"op" => "delete_node", "target_type" => "node", "target_id" => node_id}]
          }
        )

      {:ok, input} = Reducer.compile(a, state)
      {:ok, refs} = Reducer.affected_refs(input, state)

      assert [%{ref_id: ^ref_id, target_id: ^node_id, type: :clause}] = refs
    end

    test "returns [] when no refs touch the op targets" do
      state = new_state()
      a = action(:rename_document, payload: %{"title" => "x"})
      {:ok, input} = Reducer.compile(a, state)
      {:ok, refs} = Reducer.affected_refs(input, state)
      assert refs == []
    end
  end

  # ============================================================================
  # build_change/3
  # ============================================================================

  describe "build_change/3" do
    test "produces a Change with applied_revision = state.revision + 1" do
      state = new_state(revision: 9)
      a = action(:rename_document, base_revision: 9, payload: %{"title" => "Z"})

      {input, _new_state} = run_pipeline(a, state)
      {:ok, %Change{} = change} = Reducer.build_change(a, input, state)

      assert change.result_revision == 10
      assert change.base_revision == 9
      assert change.command_kind == "rename_document"
      assert change.actor_type == :user
      assert change.status == :active
      assert length(change.payload) == 1
      assert is_map(change.preimage)
      assert is_list(change.inverse)
    end

    test "builds a v0.5 Change with direct command fields" do
      state = new_state(revision: 3)

      a =
        action(:rename_document,
          chat_thread_id: uuid(30),
          agent_run_id: uuid(33),
          base_revision: 3,
          payload: %{"title" => "Direct fields"}
        )

      {input, _new_state} = run_pipeline(a, state)
      {:ok, %Change{} = change} = Reducer.build_change(a, input, state)

      assert change.command_kind == "rename_document"
      assert change.result_revision == 4
      assert change.chat_thread_id == uuid(30)
      assert change.agent_run_id == uuid(33)
      assert change.op == "set_attr"
      assert [%{op: :set_attr}] = change.payload
      assert is_list(change.inverse)
      refute Map.has_key?(Map.from_struct(change), :action_kind)
      refute Map.has_key?(Map.from_struct(change), :source_document_id)
      refute Map.has_key?(Map.from_struct(change), :source_claim_id)
    end

    test "carries idempotency_key through" do
      state = new_state()
      key = "idem-1234567"
      a = action(:rename_document, idempotency_key: key, payload: %{"title" => "y"})

      {input, _ns} = run_pipeline(a, state)
      {:ok, change} = Reducer.build_change(a, input, state)
      assert change.idempotency_key == key
    end
  end

  # ============================================================================
  # IR-richness (task #37): set_attr on table/cell rich attrs.
  # ============================================================================

  describe "set_attr — IR-richness table/cell attrs" do
    test "set_attr :column_widths on a table writes through to attrs.column_widths" do
      table_id = uuid(110)

      proj =
        Runtime.State.empty_projection()
        |> Map.put(:nodes, %{table_id => %{id: table_id, kind: :table, attrs: %{}}})

      state = new_state(projection: proj)

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "set_attr",
                "target_type" => "node",
                "target_id" => table_id,
                "args" => %{"key" => :column_widths, "value" => [2000, 4000, 6000]}
              }
            ]
          }
        )

      {_input, new_state} = run_pipeline(a, state)
      assert new_state.projection.nodes[table_id].attrs.column_widths == [2000, 4000, 6000]
    end

    test "set_attr :border_fill_id on a cell writes through to attrs.border_fill_id" do
      cell_id = uuid(111)

      proj =
        Runtime.State.empty_projection()
        |> Map.put(:nodes, %{cell_id => %{id: cell_id, kind: :cell, attrs: %{}}})

      state = new_state(projection: proj)

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "set_attr",
                "target_type" => "node",
                "target_id" => cell_id,
                "args" => %{"key" => :border_fill_id, "value" => "9"}
              }
            ]
          }
        )

      {_input, new_state} = run_pipeline(a, state)
      assert new_state.projection.nodes[cell_id].attrs.border_fill_id == "9"
    end

    test "set_attr rejects :column_widths whose value is not a list of positive ints" do
      table_id = uuid(112)

      proj =
        Runtime.State.empty_projection()
        |> Map.put(:nodes, %{table_id => %{id: table_id, kind: :table, attrs: %{}}})

      state = new_state(projection: proj)

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "set_attr",
                "target_type" => "node",
                "target_id" => table_id,
                "args" => %{"key" => :column_widths, "value" => [100, -1, 200]}
              }
            ]
          }
        )

      {:ok, input} = Reducer.compile(a, state)

      assert {:error, {:invalid_attr_value, _}} = Reducer.validate(input, state)
    end

    test "set_attr rejects :vertical_alignment that isn't :top/:center/:bottom" do
      cell_id = uuid(113)

      proj =
        Runtime.State.empty_projection()
        |> Map.put(:nodes, %{cell_id => %{id: cell_id, kind: :cell, attrs: %{}}})

      state = new_state(projection: proj)

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "set_attr",
                "target_type" => "node",
                "target_id" => cell_id,
                "args" => %{"key" => :vertical_alignment, "value" => :diagonal}
              }
            ]
          }
        )

      {:ok, input} = Reducer.compile(a, state)
      assert {:error, {:invalid_attr_value, _}} = Reducer.validate(input, state)
    end

    test "set_attr is additive: existing kinds (paragraph) still accept arbitrary attr keys" do
      # Guarantee that we did not tighten validation for non-table/non-cell kinds.
      para_id = uuid(114)

      proj =
        Runtime.State.empty_projection()
        |> Map.put(:nodes, %{para_id => %{id: para_id, kind: :paragraph, attrs: %{}}})

      state = new_state(projection: proj)

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "set_attr",
                "target_type" => "node",
                "target_id" => para_id,
                "args" => %{"key" => :anything_goes, "value" => "yes"}
              }
            ]
          }
        )

      {_input, new_state} = run_pipeline(a, state)
      assert new_state.projection.nodes[para_id].attrs.anything_goes == "yes"
    end

    test "set_attr on a cell padding key writes through" do
      cell_id = uuid(115)

      proj =
        Runtime.State.empty_projection()
        |> Map.put(:nodes, %{cell_id => %{id: cell_id, kind: :cell, attrs: %{}}})

      state = new_state(projection: proj)

      a =
        action(:edit_document,
          payload: %{
            "ops" => [
              %{
                "op" => "set_attr",
                "target_type" => "node",
                "target_id" => cell_id,
                "args" => %{"key" => :padding_top, "value" => 250}
              }
            ]
          }
        )

      {_input, new_state} = run_pipeline(a, state)
      assert new_state.projection.nodes[cell_id].attrs.padding_top == 250
    end
  end

  # ============================================================================
  # Property-based tests
  # ============================================================================

  describe "compile/2 — doc_write" do
    test "lowers insert_after_match to internal insert_text at computed offset" do
      command =
        action(:doc_write,
          payload: %{
            "sec" => 0,
            "para" => 0,
            "type" => "paragraph",
            "payload" => %{
              "cmd" => "insert_after_match",
              "payload" => %{"match" => "Beta", "text" => " inserted"}
            },
            "resolved" => %{"off" => 10}
          }
        )

      assert {:ok, %ChangeInput{action_kind: :doc_write, ops: [op]}} =
               Reducer.compile(command, new_state())

      assert %Operation{
               op: :insert_text,
               target_type: :document,
               args: %{sec: 0, para: 0, off: 10, text: " inserted"}
             } = op
    end

    test "missing resolved offset fails closed before ChangeInput" do
      command =
        action(:doc_write,
          payload: %{
            "sec" => 0,
            "para" => 0,
            "type" => "paragraph",
            "payload" => %{
              "cmd" => "insert_after_match",
              "payload" => %{"match" => "Alpha", "text" => "!"}
            }
          }
        )

      assert {:error, {:invalid_params, "resolved.off must be a non-negative integer"}} =
               Reducer.compile(command, new_state())
    end

    test "lowers insert_at_offset to internal insert_text at explicit offset" do
      command =
        action(:doc_write,
          payload: doc_write_payload("insert_at_offset", %{"off" => 5, "text" => "!"}, 5)
        )

      assert {:ok, %ChangeInput{action_kind: :doc_write, ops: [op]}} =
               Reducer.compile(command, new_state())

      assert %Operation{
               op: :insert_text,
               target_type: :document,
               args: %{sec: 0, para: 0, off: 5, text: "!"}
             } = op
    end

    test "lowers insert_paragraph_after through current RHWP text primitives" do
      command =
        action(:doc_write,
          payload: doc_write_payload("insert_paragraph_after", %{"text" => "Next paragraph"}, 5)
        )

      assert {:ok, %ChangeInput{ops: [split, insert]}} = Reducer.compile(command, new_state())
      assert %Operation{op: :insert_paragraph, args: %{sec: 0, para: 0, off: 5}} = split

      assert %Operation{
               op: :insert_text,
               args: %{sec: 0, para: 1, off: 0, text: "Next paragraph"}
             } = insert
    end
  end

  describe "properties" do
    property "apply/2 is deterministic for create_document" do
      check all(
              title <- string(:alphanumeric, min_length: 1, max_length: 40),
              rev <- integer(0..50)
            ) do
        state = new_state(revision: rev)

        a =
          action(:create_document,
            base_revision: rev,
            payload: %{"title" => title, "type_key" => "nda"}
          )

        {:ok, input} = Reducer.compile(a, state)
        {:ok, s1} = Reducer.apply(input, state)
        {:ok, s2} = Reducer.apply(input, state)
        assert s1 == s2
        assert s1.revision == rev + 1
      end
    end

    property "rename_document is round-trippable via inverse_ops" do
      check all(
              old_title <- string(:alphanumeric, min_length: 1, max_length: 20),
              new_title <- string(:alphanumeric, min_length: 1, max_length: 20),
              old_title != new_title
            ) do
        proj = Map.put(Runtime.State.empty_projection(), :title, old_title)
        state = new_state(projection: proj)
        a = action(:rename_document, payload: %{"title" => new_title})

        {input, new_state} = run_pipeline(a, state)
        assert new_state.projection.title == new_title

        inverse_input = %ChangeInput{input | ops: input.inverse_ops}
        {:ok, restored} = Reducer.apply(inverse_input, new_state)
        assert restored.projection.title == old_title
      end
    end

    property "validate/2 rejects any action whose base_revision != state.revision" do
      check all(
              state_rev <- integer(0..100),
              action_rev <- integer(0..100),
              state_rev != action_rev
            ) do
        state = new_state(revision: state_rev)

        a =
          action(:rename_document,
            base_revision: action_rev,
            payload: %{"title" => "X"}
          )

        {:ok, input} = Reducer.compile(a, state)

        assert {:error, {:revision_conflict, expected: ^state_rev, got: ^action_rev}} =
                 Reducer.validate(input, state)
      end
    end

    property "set_attr on a table's :column_widths round-trips through inverse" do
      check all(widths <- list_of(integer(100..10_000), min_length: 1, max_length: 5)) do
        table_id = uuid(200)

        proj =
          Runtime.State.empty_projection()
          |> Map.put(:nodes, %{
            table_id => %{id: table_id, kind: :table, attrs: %{column_widths: [9999]}}
          })

        state = new_state(projection: proj)

        a =
          action(:edit_document,
            payload: %{
              "ops" => [
                %{
                  "op" => "set_attr",
                  "target_type" => "node",
                  "target_id" => table_id,
                  "args" => %{"key" => :column_widths, "value" => widths}
                }
              ]
            }
          )

        {input, new_state} = run_pipeline(a, state)

        assert new_state.projection.nodes[table_id].attrs.column_widths == widths

        inverse_input = %ChangeInput{input | ops: input.inverse_ops}
        {:ok, restored} = Reducer.apply(inverse_input, new_state)
        assert restored.projection.nodes[table_id].attrs.column_widths == [9999]
      end
    end

    property "same Command + same idempotency_key produces identical ChangeInput" do
      check all(
              title <- string(:alphanumeric, min_length: 1, max_length: 20),
              key <- string(:alphanumeric, min_length: 6, max_length: 32)
            ) do
        state = new_state()

        a =
          action(:rename_document,
            idempotency_key: key,
            payload: %{"title" => title}
          )

        {:ok, ci1} = Reducer.compile(a, state)
        {:ok, ci2} = Reducer.compile(a, state)
        assert ci1 == ci2
        assert ci1.idempotency_key == key
      end
    end
  end
end
