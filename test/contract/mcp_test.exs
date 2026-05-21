defmodule Contract.MCPTest do
  use Contract.DataCase, async: false

  alias Contract.Change
  alias Contract.Command
  alias Contract.Context
  alias Contract.EvidenceSnapshot
  alias Contract.MCP
  alias Contract.Repo
  alias Contract.RouteRef
  alias Contract.Runtime
  alias Contract.SourceDocument

  describe "list_tools/2" do
    test "includes expanded document/source/law/evidence/collab tools" do
      assert %{"tools" => tools} = MCP.list_tools(%Context{}, nil)
      names = Enum.map(tools, & &1["name"])

      assert length(names) >= 20
      assert "document.open" in names
      assert "document.read" in names
      assert "document.search" in names
      assert "document.submit_command" in names
      assert "document.revoke_change" in names
      assert "source_document.read" in names
      assert "source_document.search_regions" in names
      assert "source_document.propose_claims" in names
      assert "source_document.confirm_claim" in names
      assert "source_document.correct_claim" in names
      assert "source_document.reject_claim" in names
      assert "source_document.link_claim_to_document" in names
      assert "law.search" in names
      assert "law.get_text" in names
      assert "law.search_precedents" in names
      assert "law.verify_citation" in names
      assert "evidence.attach_mark" in names
      assert "collab.ask_user" in names
      assert "collab.fetch_slack_context" in names
    end
  end

  describe "list_resources/2 and read_resource/3" do
    test "returns owner-scoped document/source/evidence resources" do
      owner = scope()
      foreign = scope()
      doc_id = create_doc(owner, title: "Owner MCP Resource")
      foreign_doc_id = create_doc(foreign, title: "Foreign MCP Resource")
      source = insert_source(owner, document_id: doc_id)
      foreign_source = insert_source(foreign, document_id: foreign_doc_id)
      evidence = insert_evidence(owner, document_id: doc_id, source_document_id: source.id)
      foreign_evidence = insert_evidence(foreign, document_id: foreign_doc_id)

      assert %{"resources" => resources} = MCP.list_resources(owner, nil)
      uris = Enum.map(resources, & &1["uri"])

      assert "document://#{doc_id}/state" in uris
      assert "source_document://#{source.id}" in uris
      assert "evidence://#{evidence.id}" in uris
      refute "document://#{foreign_doc_id}/state" in uris
      refute "source_document://#{foreign_source.id}" in uris
      refute "evidence://#{foreign_evidence.id}" in uris

      assert {:ok, doc_payload} = MCP.read_resource(owner, nil, "document://#{doc_id}/state")
      assert %{"contents" => [%{"uri" => "document://" <> _, "text" => doc_text}]} = doc_payload
      assert {:ok, %{"document_id" => ^doc_id}} = Jason.decode(doc_text)

      assert {:ok, source_payload} =
               MCP.read_resource(owner, nil, "source_document://#{source.id}")

      [%{"text" => source_text}] = source_payload["contents"]
      assert {:ok, %{"id" => source_id}} = Jason.decode(source_text)
      assert source_id == source.id

      assert {:ok, evidence_payload} = MCP.read_resource(owner, nil, "evidence://#{evidence.id}")
      [%{"text" => evidence_text}] = evidence_payload["contents"]
      assert {:ok, %{"id" => evidence_id}} = Jason.decode(evidence_text)
      assert evidence_id == evidence.id

      assert {:error, :forbidden} =
               MCP.read_resource(owner, nil, "document://#{foreign_doc_id}/state")

      assert {:error, :forbidden} =
               MCP.read_resource(owner, nil, "source_document://#{foreign_source.id}")

      assert {:error, :forbidden} =
               MCP.read_resource(owner, nil, "evidence://#{foreign_evidence.id}")
    end
  end

  describe "call_tool/4" do
    test "document.submit_command emits a Command through Runtime with owner ACL" do
      owner = scope()
      foreign = scope()
      doc_id = create_doc(owner, title: "Before MCP Rename")
      foreign_doc_id = create_doc(foreign, title: "Foreign Before MCP Rename")

      args = %{
        "command" => %{
          "kind" => "rename_document",
          "document_id" => doc_id,
          "base_revision" => 1,
          "idempotency_key" => "mcp-submit-command-1",
          "payload" => %{"title" => "After MCP Rename"}
        }
      }

      assert {:ok, %{"command_kind" => "rename_document", "result_revision" => 2}} =
               MCP.call_tool(owner, nil, "document.submit_command", args)

      assert {:ok, doc} = Contract.Documents.get(owner, doc_id)
      assert doc.title == "After MCP Rename"

      foreign_args = put_in(args, ["command", "document_id"], foreign_doc_id)

      assert {:error, :forbidden} =
               MCP.call_tool(owner, nil, "document.submit_command", foreign_args)

      assert {:ok, foreign_doc} = Contract.Documents.get(foreign, foreign_doc_id)
      assert foreign_doc.title == "Foreign Before MCP Rename"
    end

    test "route_ref-only access does not bypass owner ACL" do
      owner = scope()
      doc_id = create_doc(owner, title: "Route Ref Only")

      route_ref = %RouteRef{
        document_id: doc_id,
        purpose: "mcp-test",
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.utc_now() |> DateTime.add(3600, :second),
        scopes: ["read", "write"]
      }

      ctx = %Context{perms: %{route_ref: route_ref}}

      assert {:error, :forbidden} =
               MCP.read_resource(ctx, route_ref, "document://#{doc_id}/state")

      assert {:error, :forbidden} =
               MCP.call_tool(ctx, route_ref, "document.submit_command", %{
                 "command" => %{
                   "kind" => "rename_document",
                   "document_id" => doc_id,
                   "base_revision" => 1,
                   "idempotency_key" => "route-ref-only-denied",
                   "payload" => %{"title" => "Should Not Apply"}
                 }
               })
    end
  end

  describe "call_tool/4 — agent doc.* mutation tools" do
    setup do
      owner = scope()
      doc_id = create_doc(owner, title: "Agent Doc Tools")
      route_ref = doc_mcp_route_ref(owner, doc_id)
      {:ok, owner: owner, doc_id: doc_id, route_ref: route_ref}
    end

    test "doc.insert_block lowers paragraph into insert_paragraph + insert_text", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      args = %{
        "sec" => 0,
        "para" => 0,
        "kind" => "paragraph",
        "text" => "Hello from MCP"
      }

      assert {:ok, %{"ok" => true, "applied" => "insert_block", "revision" => rev}} =
               MCP.call_tool(owner, route_ref, "doc.insert_block", args)

      assert is_integer(rev) and rev >= 2

      [change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))
      kinds = change.payload |> Enum.map(&Map.get(&1, "op"))
      assert "insert_paragraph" in kinds
      assert "insert_text" in kinds
    end

    test "doc.insert_block rejects kind=table (no rhwp create-table op yet)", %{
      owner: owner,
      route_ref: route_ref
    } do
      args = %{"sec" => 0, "para" => 0, "kind" => "table", "rows" => 2, "cols" => 2}

      assert {:error, {:not_supported, _}} =
               MCP.call_tool(owner, route_ref, "doc.insert_block", args)
    end

    test "doc.delete_block lowers to merge_paragraph", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      args = %{"sec" => 0, "para" => 3}

      assert {:ok, %{"ok" => true, "applied" => "delete_block", "revision" => rev}} =
               MCP.call_tool(owner, route_ref, "doc.delete_block", args)

      assert is_integer(rev)

      [change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))
      assert [%{"op" => "merge_paragraph"}] = change.payload
    end

    test "doc.delete_block refuses para=0 (no predecessor to merge into)", %{
      owner: owner,
      route_ref: route_ref
    } do
      assert {:error, {:invalid_params, _}} =
               MCP.call_tool(owner, route_ref, "doc.delete_block", %{"sec" => 0, "para" => 0})
    end

    test "doc.edit_table lowers row_insert into table_row_insert", %{
      owner: owner,
      doc_id: doc_id,
      route_ref: route_ref
    } do
      args = %{
        "sec" => 0,
        "para" => 2,
        "control_index" => 0,
        "op" => "row_insert",
        "at_row" => 1
      }

      assert {:ok, %{"ok" => true, "applied" => "edit_table", "revision" => rev}} =
               MCP.call_tool(owner, route_ref, "doc.edit_table", args)

      assert is_integer(rev)

      [change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))
      assert [%{"op" => "table_row_insert", "args" => op_args}] = change.payload
      assert op_args["at_row"] == 1
      assert op_args["control_index"] == 0
    end

    test "doc.set_field_value lowers to delete+insert at the field's tracked position", %{
      owner: owner,
      route_ref: route_ref
    } do
      doc_id = doc_with_tracked_field(owner)
      route_ref = %{route_ref | document_id: doc_id}

      args = %{"id" => "field-1", "value" => "Acme Corp"}

      assert {:ok, %{"ok" => true, "applied" => "set_field_value", "revision" => _rev}} =
               MCP.call_tool(owner, route_ref, "doc.set_field_value", args)

      [change] = changes_for(doc_id) |> Enum.filter(&(&1.command_kind == "edit_text"))
      kinds = change.payload |> Enum.map(&Map.get(&1, "op"))
      assert "delete_text" in kinds
      assert "insert_text" in kinds
    end

    test "doc.set_field_value 404s on unknown field id", %{
      owner: owner,
      route_ref: route_ref
    } do
      assert {:error, {:not_found, _}} =
               MCP.call_tool(owner, route_ref, "doc.set_field_value", %{
                 "id" => "no-such-field",
                 "value" => "anything"
               })
    end

    # auth rejections — one per tool: route_ref without :agent_doc scope
    # should be rebuffed at authorize_doc_mcp/1 before any DB work.
    test "doc.insert_block rejects route_ref missing :agent_doc scope", %{
      owner: owner,
      doc_id: doc_id
    } do
      assert {:error, {:forbidden, :missing_scope_agent_doc}} =
               MCP.call_tool(owner, weak_route_ref(doc_id), "doc.insert_block", %{
                 "sec" => 0,
                 "para" => 0,
                 "kind" => "paragraph"
               })
    end

    test "doc.delete_block rejects route_ref missing :agent_doc scope", %{
      owner: owner,
      doc_id: doc_id
    } do
      assert {:error, {:forbidden, :missing_scope_agent_doc}} =
               MCP.call_tool(owner, weak_route_ref(doc_id), "doc.delete_block", %{
                 "sec" => 0,
                 "para" => 1
               })
    end

    test "doc.edit_table rejects route_ref missing :agent_doc scope", %{
      owner: owner,
      doc_id: doc_id
    } do
      assert {:error, {:forbidden, :missing_scope_agent_doc}} =
               MCP.call_tool(owner, weak_route_ref(doc_id), "doc.edit_table", %{
                 "sec" => 0,
                 "para" => 0,
                 "op" => "row_insert",
                 "at_row" => 0
               })
    end

    test "doc.set_field_value rejects route_ref missing :agent_doc scope", %{
      owner: owner,
      doc_id: doc_id
    } do
      assert {:error, {:forbidden, :missing_scope_agent_doc}} =
               MCP.call_tool(owner, weak_route_ref(doc_id), "doc.set_field_value", %{
                 "id" => "field-1",
                 "value" => "x"
               })
    end
  end

  describe "initialize/1" do
    test "returns MCP capabilities for tools and resources" do
      assert %{"protocolVersion" => _, "serverInfo" => server, "capabilities" => caps} =
               MCP.initialize(%{})

      assert server["name"] == "contract-studio"
      assert is_map(caps["tools"])
      assert is_map(caps["resources"])
    end
  end

  defp create_doc(%Context{} = ctx, opts) do
    doc_id = Ecto.UUID.generate()
    title = Keyword.fetch!(opts, :title)

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

  # Build a document whose projection has a tracked field with a `position`
  # rich enough that doc.set_field_value can lower it into a text edit. The
  # field-position info rides on a stub rhwp Snapshot row (the production
  # path — the legacy create_document path only stores opaque field attrs).
  defp doc_with_tracked_field(%Context{} = ctx) do
    doc_id = create_doc(ctx, title: "Tracked Field Doc")

    {:ok, _} =
      %Contract.Snapshot{}
      |> Contract.Snapshot.changeset(%{
        document_id: doc_id,
        revision: 1,
        r2_key: "documents/#{doc_id}/snapshots/1.hwpx",
        projection: %{
          "title" => "Tracked Field Doc",
          "contract_type" => "nda_v1",
          "sections" => [
            %{
              "idx" => 0,
              "paragraphs" => [
                %{"idx" => 0, "text" => "Header"},
                %{"idx" => 1, "text" => "Old Co"}
              ]
            }
          ],
          "fields" => [
            %{
              "id" => "field-1",
              "label" => "party_name",
              "kind" => "text",
              "position" => %{
                "sec" => 0,
                "para" => 1,
                "off_start" => 0,
                "off_end" => 6
              },
              "value" => "Old Co"
            }
          ]
        }
      })
      |> Repo.insert()

    doc_id
  end

  defp doc_mcp_route_ref(%Context{} = ctx, doc_id) do
    %RouteRef{
      document_id: doc_id,
      user_id: ctx.user.id,
      purpose: "agent_doc_mcp",
      scopes: ["agent_doc"],
      issued_at: DateTime.utc_now(),
      expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
    }
  end

  defp weak_route_ref(doc_id) do
    %RouteRef{
      document_id: doc_id,
      purpose: "mcp-test",
      scopes: ["read", "write"],
      issued_at: DateTime.utc_now(),
      expires_at: DateTime.utc_now() |> DateTime.add(3600, :second)
    }
  end

  defp changes_for(doc_id) do
    import Ecto.Query
    Repo.all(from c in Change, where: c.document_id == ^doc_id, order_by: [asc: c.result_revision])
  end

  defp insert_source(%Context{} = ctx, attrs) do
    {:ok, source} =
      %SourceDocument{}
      |> SourceDocument.changeset(%{
        owner_id: ctx.user.id,
        document_id: Keyword.get(attrs, :document_id),
        blob_ref_id: Ecto.UUID.generate(),
        mime_type: "application/pdf",
        original_filename: "source.pdf",
        regions: [%{"id" => "r1", "text" => "Party A"}],
        status: "ready"
      })
      |> Repo.insert()

    source
  end

  defp insert_evidence(%Context{} = ctx, attrs) do
    {:ok, evidence} =
      %EvidenceSnapshot{}
      |> EvidenceSnapshot.changeset(%{
        owner_id: ctx.user.id,
        document_id: Keyword.get(attrs, :document_id),
        source_document_id: Keyword.get(attrs, :source_document_id),
        provider: "test-law",
        query: %{"q" => "contract"},
        result: %{"summary" => "citation"},
        result_hash: Ecto.UUID.generate(),
        captured_at: DateTime.utc_now(:second)
      })
      |> Repo.insert()

    evidence
  end

  defp scope do
    user_id = Ecto.UUID.generate()

    %Context{
      user: %Contract.Accounts.User{
        id: user_id,
        email: "mcp-#{user_id}@example.test"
      }
    }
  end
end
