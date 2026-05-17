defmodule ContractWeb.DashboardLiveTest do
  @moduledoc """
  DashboardLive test surface — re-baselined for v0.5/design-v31 +
  2026-05-17 owner directive.

  The dashboard is a Google-Docs-style document library
  (DESIGN.md §4): document grid only, no metric cards, no recent
  activity feed, no left sidebar. The `새 문서` button does NOT create
  a document or open a modal — it navigates the user to `/studio`,
  where Canvas.Empty hosts upload + blank + recent + agent-discussion
  affordances per SPEC.md §4.2 + §4.4.

  Anti-regression tests below pin:

    * no `다음 질문` text on document cards (banned per DESIGN.md §7)
    * no metric-count substring like `최근 7일`
    * no `계약서 업로드` anywhere on the dashboard surface (the upload
      affordance now lives entirely inside /studio)
  """
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contract.Documents

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/dashboard")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "dashboard chrome (DESIGN.md §4)" do
    setup :register_and_log_in_user

    test "renders top-row title and the new-document button", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # H1 + the single primary action button live in the dashboard
      # content header. No `계약서 업로드` button — that moved to /studio.
      # Heading is `모든 문서` (the dashboard surfaces the full library,
      # not a "recent N" slice — 2026-05-17 owner directive).
      assert html =~ "모든 문서"
      assert html =~ "새 문서"
      assert html =~ ~s(data-role="dashboard-new-document")
      refute html =~ ~s(data-role="dashboard-upload-trigger")
      # And the old `최근 문서` heading must not return.
      refute html =~ ~s(<h1 class="dashboard-v31__title">최근 문서)
    end

    test "renders tabs row: 모든 문서 (active) / 즐겨찾기", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "모든 문서"
      assert html =~ "즐겨찾기"
      assert html =~ ~s(role="tablist")
      # Active tab must announce itself via aria-selected="true".
      assert html =~ ~s(aria-selected="true")
    end

    test "renders the empty state when the owner has no documents", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="documents-empty")
      # Primary action + tabs are still visible in the empty state.
      assert html =~ "새 문서"
      assert html =~ "모든 문서"
      # And NO document-grid cards.
      refute html =~ ~s(data-role="document-card")
    end

    test "renders one card per owned document", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "용역계약서 초안"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="document-grid")
      assert html =~ ~s(data-role="document-card")
      assert html =~ "용역계약서 초안"
      # 수정일 label appears on each card.
      assert html =~ "수정일"
    end

    test "renders ALL owner-scoped documents (not just a recent slice)", %{
      conn: conn,
      scope: scope
    } do
      # Create more docs than the legacy @recent_documents_limit (20) so a
      # naive `list_recent_for_scope(limit: 20)` call would visibly drop
      # entries. The dashboard should still surface every one.
      titles =
        for i <- 1..25 do
          title = "문서 #{i}"
          {:ok, _} = Documents.create(scope, %{title: title})
          title
        end

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      for title <- titles do
        assert html =~ title, "expected dashboard to render document title #{inspect(title)}"
      end
    end
  end

  describe "new_document action" do
    setup :register_and_log_in_user

    test "navigates to /studio without creating a document", %{
      conn: conn,
      scope: scope
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      # Owner starts with zero documents.
      assert Documents.list_recent_for_scope(scope, 5) == []

      lv |> element(~s([data-role="dashboard-new-document"])) |> render_click()

      # The dashboard must NOT mint a document — that responsibility moved
      # to /studio's Canvas.Empty surface (2026-05-17 owner directive).
      assert Documents.list_recent_for_scope(scope, 5) == []
      assert_redirect(lv, ~p"/studio")
    end
  end

  describe "anti-regression (binding feedback + DESIGN.md §7)" do
    setup :register_and_log_in_user

    test "document cards never contain `다음 질문`", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "Engagement letter"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "다음 질문"
    end

    test "dashboard has no metric-count tiles (no `최근 7일`)", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "stat-bait"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "최근 7일"
      refute html =~ "발행됨"
      # The old "Active matters" stat row never returns.
      refute html =~ "Active matters"
    end

    test "dashboard has no recent activity feed", %{conn: conn, scope: scope} do
      {:ok, doc} = Documents.create(scope, %{title: "Activity bait"})

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc.id,
        command_kind: "edit_document",
        actor_type: :user,
        actor_id: scope.user.id,
        result_revision: 1,
        message: "this message must NOT appear on the dashboard"
      })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ ~s(id="activity-feed")
      refute html =~ ~s(id="recent-activity")
      refute html =~ "this message must NOT appear on the dashboard"
    end

    test "global navbar does NOT carry a `계약서 업로드` action", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # The navbar must not surface upload as an anchor/link.
      refute html =~ ~r/<a[^>]*>\s*계약서 업로드/u
    end

    test "dashboard surface does NOT contain `계약서 업로드` anywhere", %{conn: conn} do
      # The 2026-05-17 owner directive moves the upload affordance entirely
      # into /studio. The dashboard must NOT mention `계약서 업로드` —
      # neither in a button, nor in copy, nor in the empty-state hint.
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "계약서 업로드"
    end
  end
end
