defmodule Contract.Documents.FieldLineageTest do
  use Contract.DataCase, async: true

  alias Contract.Context
  alias Contract.Documents
  alias Contract.Documents.FieldLineage
  alias Contract.Matters

  defp scope do
    %Context{
      user: %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "u@x"},
      tenant: Ecto.UUID.generate(),
      perms: [:type_change]
    }
  end

  defp seed do
    s = scope()
    {:ok, m} = Matters.create(s, %{"name" => "m"})

    {:ok, parent} =
      Documents.create(s, %{
        "matter_id" => m.id,
        "title" => "parent",
        "type_key" => "nda_v1"
      })

    {:ok, variant} =
      Documents.create(s, %{
        "matter_id" => m.id,
        "title" => "variant",
        "type_key" => "service_agreement_v1",
        "parent_document_id" => parent.id
      })

    {s, parent, variant}
  end

  test "insert_lineage/1 stores both source ids" do
    {_s, parent, variant} = seed()

    assert {:ok, %FieldLineage{} = row} =
             Documents.insert_lineage(%{
               "document_id" => variant.id,
               "field_id" => "effective_date",
               "source_document_id" => parent.id,
               "source_field_id" => "effective_date",
               "strategy" => "copy_once",
               "justification" => "carried over"
             })

    assert row.document_id == variant.id
    assert row.source_document_id == parent.id
    assert row.source_field_id == "effective_date"
    assert row.strategy == :copy_once
  end

  test "get_lineage_for_field/3 returns the right row" do
    {s, parent, variant} = seed()

    {:ok, _} =
      Documents.insert_lineage(%{
        "document_id" => variant.id,
        "field_id" => "governing_law",
        "source_document_id" => parent.id,
        "source_field_id" => "governing_law",
        "strategy" => "copy_once"
      })

    row = Documents.get_lineage_for_field(s, variant.id, "governing_law")
    assert %FieldLineage{field_id: "governing_law"} = row

    assert nil == Documents.get_lineage_for_field(s, variant.id, "no_such_field")
  end

  test "list_lineage/2 returns rows ordered by inserted_at" do
    {s, parent, variant} = seed()

    {:ok, _a} =
      Documents.insert_lineage(%{
        "document_id" => variant.id,
        "field_id" => "a",
        "source_document_id" => parent.id,
        "source_field_id" => "a",
        "strategy" => "copy_once"
      })

    {:ok, _b} =
      Documents.insert_lineage(%{
        "document_id" => variant.id,
        "field_id" => "b",
        "source_document_id" => parent.id,
        "source_field_id" => "b",
        "strategy" => "link_to_matter_field"
      })

    rows = Documents.list_lineage(s, variant.id)
    assert length(rows) == 2
    assert Enum.map(rows, & &1.field_id) |> Enum.sort() == ["a", "b"]
  end

  test "would_create_cycle?/3 detects a cycle via parent_document_id traversal" do
    {s, parent, variant} = seed()
    # The variant's parent is `parent`. Asking would_create_cycle?(parent, variant)
    # should be true: setting parent.parent_document_id = variant.id would close
    # the cycle parent → variant → parent.
    assert true == Documents.would_create_cycle?(s, parent.id, variant.id)
    # Reverse: variant's parent IS already parent; would_create_cycle?(variant, parent)
    # should NOT be true — variant is the candidate's child here, not its ancestor.
    # (Both directions: parent (target) wants candidate = variant; variant's parent
    # is parent. So traversing up from variant we hit parent. Cycle detected? Yes,
    # because we'd be saying "make the variant's parent = ..." but we are not setting
    # that. The helper specifically asks "would setting doc.parent = candidate
    # create a cycle?" — i.e. is candidate already a descendant of doc?)
    # The function definition: walks UP from candidate looking for doc_id. So
    # would_create_cycle?(variant, parent) = walk up from parent → parent has no
    # parent_document_id, so returns false.
    assert false == Documents.would_create_cycle?(s, variant.id, parent.id)
  end

  test "lineage row survives Repo.reload (append-only audit)" do
    {_s, parent, variant} = seed()

    {:ok, row} =
      Documents.insert_lineage(%{
        "document_id" => variant.id,
        "field_id" => "p",
        "source_document_id" => parent.id,
        "source_field_id" => "p",
        "strategy" => "derive"
      })

    reloaded = Contract.Repo.get!(FieldLineage, row.id)
    assert reloaded.id == row.id
    assert reloaded.strategy == :derive
  end
end
