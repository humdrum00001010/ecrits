defmodule Contract.ProjectsTest do
  use Contract.DataCase, async: false

  alias Contract.Context
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Projects
  alias Contract.Projects.Project
  alias Contract.Projects.ProjectDocument

  defp scope do
    %Context{
      user: %Contract.Accounts.User{
        id: Ecto.UUID.generate(),
        email: "u#{System.unique_integer([:positive])}@x"
      }
    }
  end

  defp create_project!(scope, attrs \\ %{}) do
    attrs = Map.merge(%{title: "Project #{System.unique_integer([:positive])}"}, attrs)
    {:ok, project} = Projects.create_project(scope, attrs)
    project
  end

  defp create_document!(scope, attrs \\ %{}) do
    attrs = Map.merge(%{title: "Doc #{System.unique_integer([:positive])}"}, attrs)
    {:ok, document} = Documents.create(scope, attrs)
    document
  end

  describe "create/list/update" do
    test "creates owner-scoped projects and lists only owned projects" do
      owner = scope()
      other = scope()

      project =
        create_project!(owner, %{
          owner_id: other.user.id,
          title: "Acme NDA",
          counterparty: "Acme",
          metadata: %{"source" => "test"}
        })

      _hidden = create_project!(other, %{title: "Hidden"})

      assert project.owner_id == owner.user.id
      assert project.title == "Acme NDA"
      assert project.counterparty == "Acme"
      assert project.status == "active"
      assert project.metadata == %{"source" => "test"}

      assert [%Project{id: id}] = Projects.list_projects_for_scope(owner)
      assert id == project.id
      assert Projects.list_projects_for_scope(%Context{user: nil}) == []
    end

    test "anonymous create is forbidden" do
      assert {:error, :forbidden} =
               Projects.create_project(%Context{user: nil}, %{title: "Nope"})
    end

    test "update_project/3 enforces owner ACL" do
      owner = scope()
      other = scope()
      project = create_project!(owner, %{title: "Old"})

      assert {:ok, %Project{title: "New"}} =
               Projects.update_project(owner, project, %{title: "New"})

      assert {:error, :forbidden} =
               Projects.update_project(other, project, %{title: "Other"})
    end
  end

  describe "delete_project/2" do
    test "deletes owned project and memberships without deleting documents" do
      owner = scope()
      project = create_project!(owner)
      document = create_document!(owner)
      {:ok, _project_document} = Projects.attach_document(owner, project.id, document.id)

      assert {:ok, %Project{id: deleted_id}} = Projects.delete_project(owner, project.id)
      assert deleted_id == project.id

      assert {:error, :not_found} = Projects.get_project(owner, project.id)
      assert {:ok, %Document{id: document_id}} = Documents.get(owner, document.id)
      assert document_id == document.id
      assert Repo.get_by(ProjectDocument, project_id: project.id, document_id: document.id) == nil
    end

    test "delete_project/2 enforces owner ACL" do
      owner = scope()
      other = scope()
      project = create_project!(owner)

      assert {:error, :forbidden} = Projects.delete_project(other, project.id)
      assert {:error, :forbidden} = Projects.delete_project(%Context{user: nil}, project.id)
      assert {:ok, %Project{id: project_id}} = Projects.get_project(owner, project.id)
      assert project_id == project.id
    end
  end

  describe "get_project/2" do
    test "enforces owner ACL and preloads linked documents" do
      owner = scope()
      other = scope()
      project = create_project!(owner)
      document = create_document!(owner)
      {:ok, _project_document} = Projects.attach_document(owner, project.id, document.id)

      assert {:ok, %Project{} = loaded} = Projects.get_project(owner, project.id)
      assert Enum.map(loaded.documents, & &1.id) == [document.id]

      assert [%ProjectDocument{document: %Document{id: document_id}}] =
               loaded.project_documents

      assert document_id == document.id
      assert {:error, :forbidden} = Projects.get_project(other, project.id)
      assert {:error, :not_found} = Projects.get_project(owner, Ecto.UUID.generate())
    end
  end

  describe "project documents" do
    test "same document can be attached to two projects" do
      owner = scope()
      first = create_project!(owner, %{title: "First"})
      second = create_project!(owner, %{title: "Second"})
      document = create_document!(owner)

      assert {:ok, %ProjectDocument{}} = Projects.attach_document(owner, first.id, document.id)
      assert {:ok, %ProjectDocument{}} = Projects.attach_document(owner, second.id, document.id)

      count =
        ProjectDocument
        |> where([pd], pd.document_id == ^document.id)
        |> Repo.aggregate(:count)

      assert count == 2
    end

    test "cannot attach another owner's document" do
      owner = scope()
      other = scope()
      project = create_project!(owner)
      other_document = create_document!(other)

      assert {:error, :forbidden} =
               Projects.attach_document(owner, project.id, other_document.id)

      assert Repo.aggregate(ProjectDocument, :count) == 0
    end

    test "re-attaching same document returns existing join row" do
      owner = scope()
      project = create_project!(owner)
      document = create_document!(owner)

      assert {:ok, %ProjectDocument{} = first} =
               Projects.attach_document(owner, project.id, document.id, %{role: "source"})

      assert {:ok, %ProjectDocument{} = second} =
               Projects.attach_document(owner, project.id, document.id, %{role: "review"})

      assert second.id == first.id
      assert second.role == "source"
      assert Repo.aggregate(ProjectDocument, :count) == 1
    end

    test "detach removes membership and available docs excludes attached docs" do
      owner = scope()
      project = create_project!(owner)
      attached = create_document!(owner, %{title: "Attached"})
      available = create_document!(owner, %{title: "Available"})

      assert available_document_ids(owner, project.id) == Enum.sort([available.id, attached.id])

      assert {:ok, _project_document} = Projects.attach_document(owner, project.id, attached.id)
      assert available_document_ids(owner, project.id) == [available.id]

      assert :ok = Projects.detach_document(owner, project.id, attached.id)
      assert available_document_ids(owner, project.id) == Enum.sort([available.id, attached.id])

      assert :ok = Projects.detach_document(owner, project.id, attached.id)
    end
  end

  defp available_document_ids(scope, project_id) do
    scope
    |> Projects.list_available_documents(project_id)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end
end
