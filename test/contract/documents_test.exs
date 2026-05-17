defmodule Contract.DocumentsTest do
  use Contract.DataCase, async: true

  alias Contract.Context
  alias Contract.Documents
  alias Contract.Documents.Document

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
    test "archive/2 and set_type/3 enforce owner ACL" do
      owner = scope()
      other = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Draft"})

      assert {:error, :forbidden} = Documents.archive(other, doc.id)
      assert {:ok, %Document{status: :archived}} = Documents.archive(owner, doc.id)
      assert {:ok, %Document{type_key: "nda_v1"}} = Documents.set_type(owner, doc.id, "nda_v1")
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
end
