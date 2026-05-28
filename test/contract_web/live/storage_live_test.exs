defmodule ContractWeb.StorageLiveTest do
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contract.Projects

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/storage")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "project library" do
    setup :register_and_log_in_user

    test "renders project table and opens create modal", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/storage")

      assert has_element?(lv, "#storage-root")
      assert has_element?(lv, "#open-project-create-modal", "생성")
      assert has_element?(lv, "table.table tbody#projects-table")
      assert has_element?(lv, "table.table th", "프로젝트")
      assert has_element?(lv, "table.table th", "수정일")
      assert has_element?(lv, "#projects-empty")
      assert html =~ "보관함"

      refute has_element?(lv, "#project-create-form")
      refute has_element?(lv, "#storage-root table.table-zebra")
      refute has_element?(lv, "[data-role='document-card']")
      refute has_element?(lv, "[data-role='project-card']")
      refute has_element?(lv, "table.table th", "상대방")
      refute has_element?(lv, "table.table th", "상태")

      lv
      |> element("#open-project-create-modal")
      |> render_click()

      assert has_element?(lv, "#project-create-modal")
      assert has_element?(lv, "#project-create-form")
      assert has_element?(lv, ~s(#project-create-form input[name="project[title]"]))
      refute has_element?(lv, ~s(#project-create-form input[name="project[counterparty]"]))
      refute has_element?(lv, ~s(#project-create-form select[name="project[status]"]))
      refute has_element?(lv, "#project-create-form", "계약서 업로드")
    end

    test "lists owned projects and row click navigates to project detail", %{
      conn: conn,
      scope: scope
    } do
      {:ok, project} =
        Projects.create_project(scope, %{
          "title" => "공급계약 검토",
          "counterparty" => "Acme Korea",
          "status" => "active"
        })

      {:ok, lv, _html} = live(conn, ~p"/storage")

      html = render(lv)

      assert has_element?(lv, "table.table tbody#projects-table")
      assert has_element?(lv, "#project-row-#{project.id}", "공급계약 검토")
      assert has_element?(lv, "#project-row-#{project.id}.hover\\:bg-base-200\\/60")
      assert has_element?(lv, "#project-row-#{project.id}.cursor-pointer")
      refute has_element?(lv, ~s(#project-row-#{project.id} a[href="/projects/#{project.id}"]))
      assert html =~ "/projects/#{project.id}"
      refute html =~ "Acme Korea"
      refute html =~ "진행 중"
      refute has_element?(lv, "table.table th", "상대방")
      refute has_element?(lv, "table.table th", "상태")
      refute has_element?(lv, "[data-role='project-card']")
      refute has_element?(lv, "#projects-table .rounded-full")
      refute has_element?(lv, "#storage-root table.table-zebra")
    end

    test "creates a project from the modal form", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/storage")

      lv
      |> element("#open-project-create-modal")
      |> render_click()

      lv
      |> form("#project-create-form",
        project: %{
          title: "NDA 검토"
        }
      )
      |> render_submit()

      [project] = Projects.list_projects_for_scope(scope)
      assert project.title == "NDA 검토"
      assert_redirect(lv, ~p"/projects/#{project.id}")
    end
  end
end
