defmodule ContractWeb.DashboardLiveTest do
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/dashboard")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "dashboard chrome" do
    setup :log_in_a_user

    test "renders the welcome heading + the three stat cards", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Good day"
      assert html =~ "Active matters"
      assert html =~ "Documents"
      assert html =~ "Open agent runs"
    end

    test "shows the persona dropdown with the user's email in the navbar",
         %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ user.email
      assert html =~ "Log out"
    end
  end

  describe "matters empty state" do
    setup :log_in_a_user

    test "renders the 'No matters yet' empty state when no matters exist", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ "No matters yet"
      assert html =~ ~s(id="matters-empty")
      refute html =~ ~s(id="matters-grid")
    end

    test "renders the documents empty state when no documents exist", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ ~s(id="documents-empty")
      refute html =~ ~s(id="documents-list")
    end

    test "renders the activity empty state when there are no changes", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ ~s(id="activity-empty")
    end
  end

  describe "new-document modal" do
    setup :log_in_a_user

    test "opens the modal and shows contract-type options", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      refute render(lv) =~ ~s(id="new-document-modal")

      html =
        lv
        |> element("button", "New Document")
        |> render_click()

      assert html =~ ~s(id="new-document-modal")
      assert html =~ "nda_v1"
      assert html =~ "franchise_v1"
      assert html =~ "service_agreement_v1"
    end

    test "closing the modal hides it again", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("button", "New Document") |> render_click()
      assert render(lv) =~ ~s(id="new-document-modal")

      lv |> element(~s(button[aria-label="Close"])) |> render_click()
      refute render(lv) =~ ~s(id="new-document-modal")
    end

    test "picking a type closes the modal and flashes a TODO note", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("button", "New Document") |> render_click()

      html =
        lv
        |> element(~s(button[phx-value-type_key="nda_v1"]))
        |> render_click()

      refute html =~ ~s(id="new-document-modal")
      assert html =~ "Document creation for nda_v1 is queued"
    end
  end

  describe "documents + activity populated state" do
    setup :log_in_a_user

    # Wave 4: the dashboard now reads real Matters + Documents rows.
    # We seed both, plus a couple of Change rows for the activity feed,
    # and assert the populated branches render.
    test "renders the documents list + activity feed when matters and documents exist",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)

      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Test matter"})

      {:ok, doc_a} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Doc A",
          "type_key" => "nda_v1"
        })

      {:ok, doc_b} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Doc B",
          "type_key" => "service_agreement_v1"
        })

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc_a.id,
        action_kind: "create_document",
        actor_type: :user,
        actor_id: user.id,
        applied_revision: 1,
        message: "first commit on A"
      })

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc_a.id,
        action_kind: "rename_document",
        actor_type: :agent,
        actor_id: Ecto.UUID.generate(),
        applied_revision: 2,
        message: "rename"
      })

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc_b.id,
        action_kind: "create_document",
        actor_type: :user,
        actor_id: user.id,
        applied_revision: 1,
        message: "first commit on B"
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Recent-documents section: populated branch.
      assert html =~ ~s(id="documents-list")
      refute html =~ ~s(id="documents-empty")
      assert html =~ "Doc A"
      assert html =~ "Doc B"

      # Activity section: populated branch.
      assert html =~ ~s(id="activity-feed")
      refute html =~ ~s(id="activity-empty")
      assert html =~ "first commit on A"
      assert html =~ "rename"

      # Stat row.
      assert html =~ "Documents"
      assert html =~ "Active matters"
    end
  end

  defp log_in_a_user(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end
end
