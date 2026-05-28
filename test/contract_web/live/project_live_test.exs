defmodule ContractWeb.ProjectLiveTest do
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contract.Documents
  alias Contract.Projects

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/projects/#{Ecto.UUID.generate()}")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "project detail" do
    setup :register_and_log_in_user

    test "renders attached documents and compact document actions", %{conn: conn, scope: scope} do
      {:ok, project} =
        Projects.create_project(scope, %{
          "title" => "서비스 계약",
          "counterparty" => "Gamma Inc.",
          "status" => "active"
        })

      {:ok, document} = Documents.create(scope, %{title: "서비스계약서 원본"})
      {:ok, _project_document} = Projects.attach_document(scope, project.id, document.id)

      {:ok, lv, _html} = live(conn, ~p"/projects/#{project.id}")

      assert has_element?(lv, ~s(a[href="/storage"]))
      assert has_element?(lv, "#projects-root h1", "서비스 계약")
      assert has_element?(lv, "#projects-root header #project-new-document", "새 문서")
      assert has_element?(lv, "table.table tbody#project-documents-table")
      assert has_element?(lv, "#attached-document-#{document.id}", "서비스계약서 원본")
      assert has_element?(lv, "#attached-document-#{document.id}.hover\\:bg-base-200\\/60")
      assert has_element?(lv, "#attached-document-#{document.id} td.cursor-pointer")
      refute has_element?(lv, "#attached-document-#{document.id}.cursor-pointer")

      refute has_element?(
               lv,
               ~s(#attached-document-#{document.id} a[href="/documents/#{document.id}"])
             )

      assert render(lv) =~ "/documents/#{document.id}"
      refute has_element?(lv, "table.table th", "상태")
      refute has_element?(lv, "#projects-root table.table-zebra")
      refute has_element?(lv, "#projects-root header p")
      refute has_element?(lv, "#projects-root", "Gamma Inc.")
      refute has_element?(lv, "#project-documents-panel h2")
      refute has_element?(lv, "#projects-root", "문서들")
      refute has_element?(lv, "#project-documents-panel h2", "연결된 문서")
      refute has_element?(lv, "#projects-root", "상태 없음")
      refute has_element?(lv, "#projects-root", "진행 중")
      refute has_element?(lv, "#project-attach-panel")
      refute has_element?(lv, "#project-reference-form")
      refute has_element?(lv, "#reference_document_id")
      refute has_element?(lv, "#project-reference-submit")
      refute has_element?(lv, "#detach-document-#{document.id}")
    end

    test "새 문서 opens Studio type picker with project context and creates no document yet", %{
      conn: conn,
      scope: scope
    } do
      {:ok, project} =
        Projects.create_project(scope, %{
          "title" => "신규 문서 프로젝트",
          "counterparty" => "Delta Inc.",
          "status" => "active"
        })

      {:ok, lv, _html} = live(conn, ~p"/projects/#{project.id}")

      lv
      |> element("#project-new-document")
      |> render_click()

      {:ok, loaded} = Projects.get_project(scope, project.id)
      assert loaded.documents == []
      assert Documents.list_recent_for_scope(scope, 1) == []
      assert_redirect(lv, ~p"/studio?project_id=#{project.id}")
    end

    test "renders backend-attached reference document without reference picker", %{
      conn: conn,
      scope: scope
    } do
      {:ok, current_project} =
        Projects.create_project(scope, %{
          "title" => "현재 프로젝트",
          "counterparty" => "Current",
          "status" => "active"
        })

      {:ok, other_project} =
        Projects.create_project(scope, %{
          "title" => "다른 프로젝트",
          "counterparty" => "Other",
          "status" => "active"
        })

      {:ok, reference_doc} = Documents.create(scope, %{title: "다른 프로젝트 문서"})

      {:ok, _project_document} =
        Projects.attach_document(scope, other_project.id, reference_doc.id)

      {:ok, _project_document} =
        Projects.attach_document(scope, current_project.id, reference_doc.id, %{role: "reference"})

      {:ok, lv, _html} = live(conn, ~p"/projects/#{current_project.id}")

      assert has_element?(lv, "#attached-document-#{reference_doc.id}", "다른 프로젝트 문서")
      assert render(lv) =~ "/documents/#{reference_doc.id}"

      refute has_element?(
               lv,
               ~s(#attached-document-#{reference_doc.id} a[href="/documents/#{reference_doc.id}"])
             )

      {:ok, loaded} = Projects.get_project(scope, current_project.id)
      assert Enum.any?(loaded.documents, &(&1.id == reference_doc.id))

      project_document =
        Contract.Repo.get_by!(Contract.Projects.ProjectDocument,
          project_id: current_project.id,
          document_id: reference_doc.id
        )

      assert project_document.role == "reference"
      refute has_element?(lv, "#project-attach-panel")
      refute has_element?(lv, "#project-reference-form")
      refute has_element?(lv, "#reference_document_id")
      refute has_element?(lv, "#project-reference-submit")
    end

    test "does not open another user's project", %{conn: conn} do
      other_user = Contract.AccountsFixtures.user_fixture()
      other_scope = Contract.Context.for_user(other_user)

      {:ok, project} =
        Projects.create_project(other_scope, %{
          "title" => "타인 프로젝트",
          "counterparty" => "Other",
          "status" => "active"
        })

      assert {:error, {:live_redirect, %{to: "/storage"}}} =
               live(conn, ~p"/projects/#{project.id}")
    end
  end
end
