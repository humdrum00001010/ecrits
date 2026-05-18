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

    test "renders top-row title plus 새 문서 dropdown with standard types + 사설 계약서",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/storage")

      # H1 + single new-document picker (2026-05-18 directive). The
      # picker carries one option per standard type plus a final
      # "사설 계약서 (업로드 필요)" row that re-uses the hidden
      # live_file_input. Heading stays `모든 문서`.
      assert html =~ "모든 문서"
      assert html =~ "새 문서"
      assert html =~ "사설 계약서"
      assert html =~ ~s(data-role="dashboard-new-document")
      assert html =~ ~s(data-role="dashboard-new-document-picker")
      assert html =~ ~s(data-role="dashboard-new-document-upload")
      assert html =~ ~s(data-role="dashboard-upload-input")
      # The picker dropdown lists at least one standard type by display
      # name (locale-aware; English `Untyped` is the placeholder for
      # nil so it must NOT leak here).
      assert html =~ ~s(data-role="dashboard-new-document-option")
      # The dedicated free-standing 계약서 업로드 button is gone — the
      # upload affordance now lives inside the dropdown only.
      refute html =~ ~s(data-role="dashboard-upload-trigger")
      # And the old `최근 문서` heading must not return.
      refute html =~ ~s(<h1 class="dashboard-v31__title">최근 문서)
    end

    test "renders tabs row: 모든 문서 (active) / 즐겨찾기", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/storage")

      assert html =~ "모든 문서"
      assert html =~ "즐겨찾기"
      assert html =~ ~s(role="tablist")
      # Active tab must announce itself via aria-selected="true".
      assert html =~ ~s(aria-selected="true")
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
      assert html =~ ~s(class="document-grid")
      assert html =~ ~s(data-role="document-card")
      assert html =~ "용역계약서 V1"
      # Card chrome
      assert html =~ "document-card__thumb"
      assert html =~ "document-card__title"
      assert html =~ "document-card__menu"
    end

    test "cards do NOT render a status label or status dot (2026-05-18 directive)",
         %{conn: conn, scope: scope} do
      # Owner directive: "없애기로 한 초안이 돌아왔고" — strip the
      # 초안/진행 중/검토 대기 status badge that re-appeared after the
      # card restoration.
      {:ok, _doc} = Documents.create(scope, %{title: "No-status-badge document"})

      {:ok, _lv, html} = live(conn, ~p"/storage")

      refute html =~ "status-dot--draft"
      refute html =~ "document-card__meta"
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

    test "사설 계약서 option is a <label> wrapping the hidden live_file_input with PDF/DOCX/HWP accept",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/storage")

      # The "사설 계약서" row inside the 새 문서 dropdown is a <label
      # for=...> bound to the hidden live_file_input. Clicking it
      # opens the OS file picker without any JS hook.
      assert html =~ ~s(data-role="dashboard-new-document-upload")
      assert html =~ ~s(data-role="dashboard-upload-input")
      assert html =~ ~s(phx-change="contract_upload_validate")
      # `accept` is encoded as a comma-separated MIME/ext list by
      # live_file_input; we just pin one ext from each family.
      assert html =~ ".pdf"
      assert html =~ ".docx"
      assert html =~ ".hwp"
    end
  end

  describe "card styling (DESIGN §4 + feedback-review-adds-tests)" do
    setup :register_and_log_in_user

    @app_css "assets/css/app.css"

    test "card has a hover rule that lifts the surface" do
      css = File.read!(@app_css)
      assert css =~ ".document-card:hover"
      # Hover rule must lift the card and swap to the stronger border.
      assert css =~ "border-color: var(--cs-line-strong)"
    end

    test "card has a focus-visible outline rule" do
      css = File.read!(@app_css)
      assert css =~ ".document-card:focus-visible"
    end

    test "preview-line styling exists for the thumb body" do
      css = File.read!(@app_css)

      assert css =~ ".document-card__thumb--lines"
      assert css =~ ".document-card__thumb-line"
      assert css =~ ".document-card__thumb-fade"
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

  describe "new_document action (2026-05-18 directive)" do
    setup :register_and_log_in_user

    test "picking a standard type from the dropdown creates a blank document with that type_key and redirects",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, ~p"/storage")

      # Owner starts with zero documents.
      assert Documents.list_recent_for_scope(scope, 5) == []

      # Pick the service_agreement_v1 row in the new-document dropdown.
      lv
      |> element(~s([data-role="dashboard-new-document-option"][data-type-key="service_agreement_v1"]))
      |> render_click()

      # Exactly one new document, stamped with the picked type_key.
      assert [%{type_key: "service_agreement_v1"} = doc] =
               Documents.list_recent_for_scope(scope, 5)

      assert_redirect(lv, ~p"/documents/#{doc.id}")
    end

    test "사설 계약서 row in the dropdown does NOT mint a document by itself — it just opens the file picker",
         %{conn: conn, scope: scope} do
      {:ok, _lv, html} = live(conn, ~p"/storage")

      # The label has no phx-click (so a stray click can't create a
      # document); its only behavior is `<label for=upload-input>`,
      # which the browser turns into a file-picker open.
      assert html =~ ~s(data-role="dashboard-new-document-upload")
      refute html =~ ~s(data-role="dashboard-new-document-upload" phx-click)

      # No documents created until the user actually uploads a file.
      assert Documents.list_recent_for_scope(scope, 5) == []
    end

    test "custom_v1 (사설 계약서) sentinel is never offered as a blank-document seed",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/storage")

      # Dropdown option buttons must not include the custom sentinel —
      # only the standard types are pickable for blank creation.
      refute html =~ ~s(data-role="dashboard-new-document-option" data-type-key="custom_v1")
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

      # The navbar must not surface upload as an anchor/link — the
      # affordance lives in the page header's action cluster (a label
      # over a hidden file input), not in the navbar.
      refute html =~ ~r/<a[^>]*>\s*계약서 업로드/u
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
