defmodule Contract.DocumentsTest do
  use Contract.DataCase, async: true

  alias Contract.Context
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Matters

  defp scope(opts \\ []) do
    tenant =
      case Keyword.get(opts, :tenant, :auto) do
        :auto -> Ecto.UUID.generate()
        nil -> nil
        explicit -> explicit
      end

    user_id = Keyword.get(opts, :user_id, Ecto.UUID.generate())

    %Context{
      user: %Contract.Accounts.User{id: user_id, email: "u#{System.unique_integer([:positive])}@x"},
      tenant: tenant
    }
  end

  defp setup_matter(s, opts \\ []) do
    name = Keyword.get(opts, :name, "M-#{System.unique_integer([:positive])}")
    {:ok, m} = Matters.create(s, %{"name" => name})
    m
  end

  defp create_doc(s, m, opts \\ []) do
    attrs = %{
      "matter_id" => m.id,
      "title" => Keyword.get(opts, :title, "Doc-#{System.unique_integer([:positive])}"),
      "type_key" => Keyword.get(opts, :type_key, "nda_v1")
    }

    {:ok, doc} = Documents.create(s, attrs)
    doc
  end

  describe "create/2" do
    test "creates a document in a matter the scope can see" do
      s = scope()
      m = setup_matter(s)
      assert {:ok, %Document{matter_id: mid, title: "T", type_key: "nda_v1"}} =
               Documents.create(s, %{
                 "matter_id" => m.id,
                 "title" => "T",
                 "type_key" => "nda_v1"
               })

      assert mid == m.id
    end

    test "cross-tenant create is forbidden" do
      a = scope()
      b = scope()
      m_a = setup_matter(a)

      assert {:error, :forbidden} =
               Documents.create(b, %{
                 "matter_id" => m_a.id,
                 "title" => "X",
                 "type_key" => "nda_v1"
               })
    end

    test "missing matter is :not_found" do
      s = scope()

      assert {:error, :not_found} =
               Documents.create(s, %{
                 "matter_id" => Ecto.UUID.generate(),
                 "title" => "X",
                 "type_key" => "nda_v1"
               })
    end

    # SPEC.md §18: contract type is set AFTER creation. The create
    # path must accept `type_key: nil` so the document can be opened,
    # read, and then typed via `Action(:set_contract_type)` later.
    test "accepts nil :type_key — untyped document is valid" do
      s = scope()
      m = setup_matter(s)

      assert {:ok, %Document{type_key: nil, title: "T"}} =
               Documents.create(s, %{
                 "matter_id" => m.id,
                 "title" => "T",
                 "type_key" => nil
               })
    end

    test "accepts missing :type_key — defaults to nil" do
      s = scope()
      m = setup_matter(s)

      assert {:ok, %Document{type_key: nil, title: "T"}} =
               Documents.create(s, %{
                 "matter_id" => m.id,
                 "title" => "T"
               })
    end
  end

  describe "list_for_matter/2 + list_recent_for_scope/2" do
    test "lists matter docs in order" do
      s = scope()
      m = setup_matter(s)
      d1 = create_doc(s, m, title: "alpha")
      d2 = create_doc(s, m, title: "beta")

      ids = s |> Documents.list_for_matter(m.id) |> Enum.map(& &1.id)
      assert d1.id in ids
      assert d2.id in ids
    end

    test "cross-tenant list returns empty" do
      a = scope()
      b = scope()
      m_a = setup_matter(a)
      _ = create_doc(a, m_a)

      assert [] = Documents.list_for_matter(b, m_a.id)
    end

    test "list_recent_for_scope returns docs the scope can see across matters" do
      s = scope()
      m1 = setup_matter(s)
      m2 = setup_matter(s)
      _ = create_doc(s, m1)
      _ = create_doc(s, m2)

      recent = Documents.list_recent_for_scope(s, 10)
      assert length(recent) == 2
    end
  end

  describe "get/2" do
    test "fetches a document the scope can see" do
      s = scope()
      m = setup_matter(s)
      d = create_doc(s, m)

      assert {:ok, %Document{id: id}} = Documents.get(s, d.id)
      assert id == d.id
    end

    test "cross-tenant get is :forbidden" do
      a = scope()
      b = scope()
      m_a = setup_matter(a)
      d = create_doc(a, m_a)

      assert {:error, :forbidden} = Documents.get(b, d.id)
    end

    test "unknown id is :not_found" do
      assert {:error, :not_found} = Documents.get(scope(), Ecto.UUID.generate())
    end
  end

  describe "archive/2 + set_type/3" do
    test "archives a doc" do
      s = scope()
      m = setup_matter(s)
      d = create_doc(s, m)
      assert {:ok, %Document{status: :archived}} = Documents.archive(s, d.id)
    end

    test "set_type updates the type_key" do
      s = scope()
      m = setup_matter(s)
      d = create_doc(s, m, type_key: "nda_v1")
      assert {:ok, %Document{type_key: "service_agreement_v1"}} =
               Documents.set_type(s, d.id, "service_agreement_v1")
    end

    # SPEC.md §18: this is the canonical flow — create a doc untyped,
    # then call `Action(:set_contract_type)` (which ultimately routes
    # to `Documents.set_type/3`) to fill in the key.
    test "set_type promotes an untyped document to a typed one" do
      s = scope()
      m = setup_matter(s)

      {:ok, %Document{type_key: nil} = d} =
        Documents.create(s, %{"matter_id" => m.id, "title" => "Untyped"})

      assert {:ok, %Document{type_key: "nda_v1"}} =
               Documents.set_type(s, d.id, "nda_v1")
    end
  end

  describe "touch_revision/2" do
    test "bumps latest_revision atomically (no decreases)" do
      s = scope()
      m = setup_matter(s)
      d = create_doc(s, m)

      :ok = Documents.touch_revision(d.id, 5)
      reloaded = Contract.Repo.get!(Document, d.id)
      assert reloaded.latest_revision == 5

      # Replaying a lower revision is a no-op.
      :ok = Documents.touch_revision(d.id, 2)
      reloaded = Contract.Repo.get!(Document, d.id)
      assert reloaded.latest_revision == 5
    end

    test "non-existent document is silently ignored" do
      assert :ok = Documents.touch_revision(Ecto.UUID.generate(), 1)
    end
  end

  describe "parent / variant" do
    test "variant document can be created with parent_document_id" do
      s = scope()
      m = setup_matter(s)
      parent = create_doc(s, m)

      assert {:ok, %Document{parent_document_id: pid}} =
               Documents.create(s, %{
                 "matter_id" => m.id,
                 "title" => "variant",
                 "type_key" => "service_agreement_v1",
                 "parent_document_id" => parent.id
               })

      assert pid == parent.id
    end

    test "would_create_cycle?/3 detects a direct cycle" do
      s = scope()
      m = setup_matter(s)
      a = create_doc(s, m)

      # Creating "b" with parent=a, then checking if a → b would close
      # back: would_create_cycle?(a, b) should be true because b's
      # parent_document_id is a, and we're asking "would a's parent
      # become b?"
      _b = b = create_doc(s, m, title: "B")

      _ =
        b
        |> Document.changeset(%{"parent_document_id" => a.id})
        |> Contract.Repo.update!()

      assert true == Documents.would_create_cycle?(s, a.id, b.id)
    end

    test "no cycle when parent points elsewhere" do
      s = scope()
      m = setup_matter(s)
      a = create_doc(s, m)
      b = create_doc(s, m)

      assert false == Documents.would_create_cycle?(s, a.id, b.id)
    end
  end
end
