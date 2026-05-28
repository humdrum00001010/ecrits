defmodule ContractWeb.StorageLiveDocumentFirstTest do
  @moduledoc """
  Storage is project-first: `/storage` creates projects, not documents.
  """
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contract.Documents
  alias Contract.Projects

  setup :register_and_log_in_user

  test "storage create form mints a project and never a document", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, html} = live(conn, ~p"/storage")

    assert Documents.list_recent_for_scope(scope, 5) == []

    assert html =~ ~s(id="open-project-create-modal")
    refute html =~ ~s(id="project-create-form")
    refute html =~ "계약서 업로드"

    lv
    |> element("#open-project-create-modal")
    |> render_click()

    lv
    |> form("#project-create-form",
      project: %{title: "프로젝트 우선"}
    )
    |> render_submit()

    assert Documents.list_recent_for_scope(scope, 5) == []
    [project] = Projects.list_projects_for_scope(scope)
    assert project.title == "프로젝트 우선"
    assert_redirect(lv, ~p"/projects/#{project.id}")
  end
end
