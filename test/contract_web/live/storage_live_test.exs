defmodule ContractWeb.StorageLiveTest do
  @moduledoc """
  StorageLive test surface — re-baselined for v0.5/design-v31 +
  2026-05-17 owner directive ("공들여 만들었던 문서프리뷰").

  Storage (보관함) is a Google-Docs-style document library
  (DESIGN.md §4): a card GRID, no metric cards, no recent activity
  feed, no left sidebar. Each card's thumb shows the first few lines
  of the actual contract body so the library reads like a Drive
  folder, not a spreadsheet.

  The `새 문서` button does NOT create a document or open a modal —
  it navigates the user to `/studio`, where Canvas.Empty hosts
  upload + blank + recent + agent-discussion affordances per
  SPEC.md §4.2 + §4.4.

  Anti-regression tests below pin:

    * no `다음 질문` text on cards (banned per DESIGN.md §7)
    * no metric-count substring like `최근 7일`
    * no `계약서 업로드` anywhere on the storage surface (the upload
      affordance now lives entirely inside /studio)
    * no dead table-namespace markup left over from the 2026-05-17
      pre-restoration table-only iteration
  """
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contract.Documents

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/storage")
      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end
  end

  describe "storage chrome (DESIGN.md §4)" do
    setup :register_and_log_in_user

    test "renders top-row title plus a single 새 문서 link to Studio",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/storage")

      assert html =~ "모든 문서"
      assert html =~ "새 문서"
      assert html =~ ~s(data-role="dashboard-new-document")
      assert html =~ ~s(href="/studio")

      refute html =~ "사설 계약서"
      refute html =~ "계약서 업로드"
      refute html =~ ~s(data-role="dashboard-new-document-picker")
      refute html =~ ~s(data-role="dashboard-new-document-upload")
      refute html =~ ~s(data-role="dashboard-upload-input")
      refute html =~ ~s(data-role="dashboard-new-document-option")
      refute html =~ ~s(data-role="dashboard-upload-trigger")
      refute html =~ ~s(phx-click="new_document")
      refute html =~ ~s(phx-value-type_key)
      refute html =~ "최근 문서"
    end

    test "does not render unimplemented 즐겨찾기 tab", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/storage")

      assert html =~ "모든 문서"
      assert html =~ ~s(role="tablist")
      assert html =~ ~s(aria-selected="true")
      assert html =~ ~s(data-role="document-selection-actions")
      assert html =~ ~s(ml-auto flex items-center self-center gap-2)
      refute html =~ "즐겨찾기"
    end

    test "renders the empty-state hint when the owner has no documents", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/storage")

      # Empty state is a centred panel, not a card grid.
      assert html =~ ~s(id="documents-empty")
      assert html =~ ~s(data-role="dashboard-documents-empty")
      assert html =~ "아직 문서가 없습니다."
      # Primary action + tabs are still visible in the empty state.
      assert html =~ "새 문서"
      assert html =~ "모든 문서"
      # And NO document cards.
      refute html =~ ~s(data-role="document-card")
    end

    test "renders one card per owned document", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "용역계약서 V1"})

      {:ok, _lv, html} = live(conn, ~p"/storage")

      assert html =~ ~s(id="document-grid")
      assert html =~ ~s(data-role="document-grid")
      assert html =~ ~s(data-role="document-card")
      assert html =~ "용역계약서 V1"
      # Card chrome — pinned via data-role markers (utilities don't grep)
      assert html =~ ~s(data-role="document-card-thumb")
      assert html =~ ~s(data-role="document-card-preview")
      assert html =~ ~s(data-role="document-card-menu")
    end

    test "cards do NOT render a status label or status dot (2026-05-18 directive)",
         %{conn: conn, scope: scope} do
      # Owner directive: "없애기로 한 초안이 돌아왔고" — strip the
      # 초안/진행 중/검토 대기 status badge that re-appeared after the
      # card restoration.
      {:ok, _doc} = Documents.create(scope, %{title: "No-status-badge document"})

      {:ok, _lv, html} = live(conn, ~p"/storage")

      refute html =~ "status-dot--draft"
      # The literal status strings should not appear inside any
      # rendered card body.
      cards_html = card_section(html)
      refute cards_html =~ "초안"
      refute cards_html =~ "진행 중"
      refute cards_html =~ "검토 대기"
    end

    test "clicking a card navigates to /documents/:id", %{conn: conn, scope: scope} do
      {:ok, doc} = Documents.create(scope, %{title: "Card click target"})

      {:ok, _lv, html} = live(conn, ~p"/storage")

      # The card's own anchor overlay carries the navigate href; clicking
      # anywhere on the card hits it.
      assert html =~ ~s(href="/documents/#{doc.id}")
    end

    test "overflow ⋮ button stops propagation so the navigate link does NOT fire",
         %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "Menu propagation"})

      {:ok, _lv, html} = live(conn, ~p"/storage")

      # The card's overflow menu must stop click bubbling so the
      # sibling navigate-link overlay does not also fire.
      assert html =~ ~s(data-role="document-card-menu")
      assert html =~ ~s|onclick="event.stopPropagation()"|
    end

    test "does not render any upload affordance on Storage",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/storage")

      refute html =~ "계약서 업로드"
      refute html =~ "사설 계약서"
      refute html =~ ~s(data-role="dashboard-new-document-upload")
      refute html =~ ~s(data-role="dashboard-upload-trigger")
      refute html =~ ~s(data-role="dashboard-upload-input")
      refute html =~ ~s(phx-change="contract_upload_validate")
    end
  end

  describe "card styling (DESIGN §4 + feedback-review-adds-tests)" do
    setup :register_and_log_in_user

    test "card carries the hover-lift utility chain", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "hover-lift target"})
      {:ok, _lv, html} = live(conn, ~p"/storage")

      # Hover lift utility is wired inline; this pins that the card still
      # has a visible hover behaviour (translate + border swap + shadow).
      assert html =~ "hover:-translate-y-0.5"
      assert html =~ "hover:border-base-content/30"
      assert html =~ "hover:shadow-lg"
    end

    test "card focus carries an outline", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "focus target"})
      {:ok, _lv, html} = live(conn, ~p"/storage")

      assert html =~ "focus-within:outline"
      assert html =~ "focus-within:outline-primary"
    end

    test "preview thumb carries the data-role markers", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "preview markers"})
      {:ok, _lv, html} = live(conn, ~p"/storage")

      assert html =~ ~s(data-role="document-card-thumb")
      assert html =~ ~s(data-role="document-card-preview")
      assert html =~ ~s(data-role="document-card-thumb-lines")
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

      {:ok, _lv, html} = live(conn, ~p"/storage")

      for title <- titles do
        assert html =~ title, "expected dashboard to render document title #{inspect(title)}"
      end
    end
  end

  describe "new document entry point" do
    setup :register_and_log_in_user

    test "새 문서 navigates to Studio and does not mint a document on Storage",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/storage")

      assert Documents.list_recent_for_scope(scope, 5) == []

      lv
      |> element(~s(a[data-role="dashboard-new-document"][href="/studio"]))
      |> render_click()

      assert Documents.list_recent_for_scope(scope, 5) == []
      assert_redirect(lv, ~p"/studio")
    end

    test "standard type rows and custom upload rows are never offered on Storage",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/storage")

      refute html =~ ~s(data-role="dashboard-new-document-option")
      refute html =~ ~s(data-type-key="service_agreement_v1")
      refute html =~ ~s(data-type-key="custom_v1")
      refute html =~ ~s(data-role="dashboard-new-document-upload")
    end
  end

  describe "anti-regression (binding feedback + DESIGN.md §7)" do
    setup :register_and_log_in_user

    test "document rows never contain `다음 질문`", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "Engagement letter"})

      {:ok, _lv, html} = live(conn, ~p"/storage")

      refute html =~ "다음 질문"
    end

    test "storage has no metric-count tiles (no `최근 7일`)", %{conn: conn, scope: scope} do
      {:ok, _doc} = Documents.create(scope, %{title: "stat-bait"})

      {:ok, _lv, html} = live(conn, ~p"/storage")

      refute html =~ "최근 7일"
      refute html =~ "발행됨"
      # The old "Active matters" stat row never returns.
      refute html =~ "Active matters"
    end

    test "storage has no recent activity feed", %{conn: conn, scope: scope} do
      {:ok, doc} = Documents.create(scope, %{title: "Activity bait"})

      Contract.Repo.insert!(%Contract.Change{
        document_id: doc.id,
        command_kind: "edit_document",
        actor_type: :user,
        actor_id: scope.user.id,
        result_revision: 1,
        message: "this message must NOT appear on the dashboard"
      })

      {:ok, _lv, html} = live(conn, ~p"/storage")

      refute html =~ ~s(id="activity-feed")
      refute html =~ ~s(id="recent-activity")
      refute html =~ "this message must NOT appear on the dashboard"
    end

    test "Cmd+K trigger is NOT in the navbar (removed 2026-05-17)", %{conn: conn} do
      # Owner stripped the trigger button; keyboard shortcut still works.
      {:ok, _lv, html} = live(conn, ~p"/storage")
      refute html =~ ~s(data-role="palette-trigger")
    end

    test "global navbar does NOT carry a `계약서 업로드` action", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/storage")

      refute html =~ "계약서 업로드"
    end
  end

  # Slice the `<section id="document-grid">…</section>` out of the
  # rendered HTML so we can run substring assertions against only the
  # card region, free of false matches from layout chrome or copy.
  defp card_section(html) do
    case Regex.run(~r/<section[^>]*id="document-grid"[^>]*>.*?<\/section>/s, html) do
      [match] -> match
      _ -> ""
    end
  end
end
