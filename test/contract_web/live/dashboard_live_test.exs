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

    # 2026-05-15 directive: a lawyer is not a programmer — counts add
    # noise without value. The dashboard renders only the greeting +
    # subtitle now; the stat row is gone.
    test "renders the welcome heading + subtitle, with no stat cards", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Good day"

      # The stat row container is gone.
      refute html =~ ~s(id="dashboard-stats")
      # And none of the old stat labels appear as standalone stat-card
      # text. We intentionally do NOT refute "Documents" / "Active matters"
      # here — those words still occur as table-column headers and as
      # the matters/recent-documents section titles. The structural
      # `id="dashboard-stats"` refute above is the load-bearing assert.
      refute html =~ "Open agent runs"
    end

    test "renders the new subtitle (no 'new matter' wording)", %{conn: conn} do
      # Tests run under `:ui_locale, "en"` (config/test.exs). The new
      # subtitle drops "open a new matter" in favour of "start a new
      # document" since Matter is now hidden from the lawyer.
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Pick up where you left off, or start a new document."
      refute html =~ "Pick up where you left off, or open a new matter."
    end

    test "shows the persona dropdown with the user's email in the navbar",
         %{conn: conn, user: user} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")
      assert html =~ user.email
      assert html =~ "Log out"
    end
  end

  # 2026-05-15: the stat row was replaced with a "Resume your most-recent
  # document" affordance. When the scope has a recent document the link
  # renders; when it doesn't, the slot is skipped entirely (the Documents
  # section's empty state already covers the no-docs case).
  describe "resume affordance" do
    setup :log_in_a_user

    test "does NOT render the Resume slot when there is no recent document",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ ~s(id="dashboard-resume")
      refute html =~ ~s(data-role="dashboard-resume-link")
    end

    test "renders the Resume link to the most-recent document when one exists",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _older} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Older draft",
          "type_key" => "nda_v1"
        })

      {:ok, latest} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Latest draft",
          "type_key" => "nda_v1"
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="dashboard-resume")
      assert html =~ ~s(data-role="dashboard-resume-link")
      # Title of the most-recent document is in the link.
      assert html =~ "Latest draft"
      # And it points at the document URL.
      assert html =~ "/matters/#{matter.id}/documents/#{latest.id}"
    end

    test "renders the Resume label (English source-of-truth)",
         %{conn: conn, user: user} do
      # `:ui_locale, "en"` is pinned in config/test.exs. We assert on the
      # English msgid (source-of-truth); the Korean translation is
      # exercised structurally by the .po file diff alone — flipping the
      # locale in an async test would leak the env to concurrent tests
      # in other modules (auth tests broke before this was reworked).
      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "재개할 문서",
          "type_key" => "nda_v1"
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Resume your most recent document"
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

  describe "new-document modal (SPEC.md §18 — type set later)" do
    setup :log_in_a_user

    test "opens the modal with a title input — no contract-type picker", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      refute render(lv) =~ ~s(id="new-document-modal")

      html =
        lv
        |> element("button", "New Document")
        |> render_click()

      assert html =~ ~s(id="new-document-modal")
      # Title input is the only required field; no type list anymore.
      assert html =~ ~s(data-role="new-document-form")
      assert html =~ ~s(name="title")
      # Hint copy is shipped.
      assert html =~ ~s(data-role="new-document-type-hint")

      # The old contract-type picker must NOT render — no type-key
      # buttons, no `id="contract-type-list"`, and no raw type keys.
      refute html =~ ~s(id="contract-type-list")
      refute html =~ ~s(phx-click="pick_type")
      refute html =~ ~s(phx-value-type_key="nda_v1")
    end

    test "closing the modal hides it again", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("button", "New Document") |> render_click()
      assert render(lv) =~ ~s(id="new-document-modal")

      lv |> element(~s(button[aria-label="Close"])) |> render_click()
      refute render(lv) =~ ~s(id="new-document-modal")
    end

    # Submitting a title creates an untyped document and flashes the
    # "set type via Cmd+K or agent" prompt. This is the headline
    # behaviour of the subagent fix.
    test "submitting a title creates an untyped document", %{conn: conn, user: user} do
      # The dashboard's fallback path needs at least one matter the
      # scope can see; seed one before opening the modal.
      scope = Contract.Context.for_user(user)
      {:ok, _matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("button", "New Document") |> render_click()

      lv
      |> form(~s(form[data-role="new-document-form"]), %{"title" => "Quick draft"})
      |> render_submit()

      # The success branch push_navigates to the document — the LiveView
      # process exits with `{:live_redirect, ...}`. The flash and the
      # persisted document are still observable.

      # And a document was actually persisted, untyped.
      docs = Contract.Documents.list_recent_for_scope(scope, 5)
      assert Enum.any?(docs, fn d -> d.title == "Quick draft" and d.type_key == nil end)
    end

    # SPEC.md Document-primary pivot (2026-05-15): a user with no
    # existing Workspace can still create a Document. The backend
    # auto-creates a hidden Workspace; the dashboard's matters table
    # MUST NOT surface it.
    test "submitting with no matter context auto-creates a hidden Workspace",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      # No matter seeded — this is the pure document-first path.

      {:ok, lv, _html} = live(conn, ~p"/dashboard")
      lv |> element("button", "New Document") |> render_click()

      lv
      |> form(~s(form[data-role="new-document-form"]), %{"title" => "Auto-NDA"})
      |> render_submit()

      # The document was persisted, untyped, attached to a hidden matter.
      docs = Contract.Documents.list_recent_for_scope(scope, 5)
      assert Enum.any?(docs, fn d -> d.title == "Auto-NDA" and d.type_key == nil end)

      # The auto-matter exists in the table — but is hidden by default.
      visible_ids =
        scope |> Contract.Matters.list_for_scope() |> Enum.map(& &1.id) |> MapSet.new()

      all_ids =
        scope
        |> Contract.Matters.list_for_scope(include_hidden: true)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      # At least one matter that is hidden-only (i.e. in all_ids but not
      # visible_ids).
      assert MapSet.size(MapSet.difference(all_ids, visible_ids)) >= 1
    end

    test "modal renders the 워크스페이스가 자동으로 생성됩니다 hint", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard")

      html =
        lv
        |> element("button", "New Document")
        |> render_click()

      assert html =~ ~s(data-role="new-document-workspace-hint")
      assert html =~ "워크스페이스가 자동으로 생성됩니다"
    end

    # The auto-matter is filtered out of the dashboard's matters table.
    # If we create a document with no pre-existing matter, the table
    # should STILL render the empty-state (because the only matter that
    # was created is hidden).
    test "dashboard matters table does not show the auto-matter",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)

      {:ok, _doc, hidden_matter} =
        Contract.Documents.create_with_auto_matter(scope, %{"title" => "Auto-NDA"})

      # Sanity: the matter we just synthesized is flagged hidden.
      assert hidden_matter.metadata["hidden_from_user"] == true

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # The empty-state illustration still renders — the hidden matter
      # never made it into the visible list.
      assert html =~ ~s(id="matters-empty")
      refute html =~ ~s(id="matters-table")
      refute html =~ "Workspace · Auto-NDA"
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

      # The stat row is gone (2026-05-15 directive).
      refute html =~ ~s(id="dashboard-stats")
      refute html =~ "Open agent runs"
    end
  end

  # ---------------------------------------------------------------------------
  # Wave 4.6: dashboard renders Matters + Recent documents as hairline tables.
  #
  # These tests pin the structural shape (`<table>` not `<.card>` divs) so a
  # future refactor can't silently regress us back to a card-grid. Per the
  # mature-visual-language memory, legal users scan tables, not bento boxes.
  # ---------------------------------------------------------------------------
  describe "matters table (populated state)" do
    setup :log_in_a_user

    test "renders a <table> (not a card-grid) when matters exist",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, _matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # New table-based markup.
      assert html =~ ~s(id="matters-table")
      assert html =~ "<table"
      # Old card-grid markup must not reappear.
      refute html =~ ~s(id="matters-grid")
    end

    test "renders the expected column headers + a row per matter",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, _m1} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})
      {:ok, _m2} = Contract.Matters.create(scope, %{"name" => "Doe Estate"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Column headers (via dgettext). Some headers span multiple lines
      # in the .heex source (long class strings), so we match on the
      # header label alone — the surrounding <th> markup is exercised
      # by the structural `<table` / `matters-table` checks above.
      assert html =~ "Name"
      assert html =~ "Status"
      assert html =~ "Documents"
      assert html =~ "Last activity"

      # Both matter names render as table-cell content.
      assert html =~ "Acme v Smith"
      assert html =~ "Doe Estate"

      # Matter status badge — default is :active → "In progress".
      assert html =~ "In progress"
    end

    test "populated state still renders the empty illustration when there are no matters",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # The illustration empty-state survives untouched.
      assert html =~ ~s(id="matters-empty")
      assert html =~ "No matters yet"
      # And the table is NOT rendered.
      refute html =~ ~s(id="matters-table")
    end

    test "the matters table uses hairline borders + responsive column hiding",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, _m} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Structural mobile-responsive hint: at least the Documents column
      # is hidden on <sm. We can't run a real viewport here (that's
      # Playwright's job per feedback-responsive-scope.md) — just pin that
      # the class is present somewhere in the table markup.
      assert html =~ "hidden sm:table-cell"
      # Hairline-borders, no zebra-stripes: the wrapper carries
      # `border-base-200`, never `table-zebra`.
      assert html =~ "border-base-200"
      refute html =~ "table-zebra"
    end
  end

  describe "recent documents table (populated state)" do
    setup :log_in_a_user

    test "renders a <table> with Title / Type / Status / Matter / Last revision columns",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Engagement letter",
          "type_key" => "nda_v1"
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Table shell.
      assert html =~ ~s(id="documents-list")
      assert html =~ "<table"

      # Column headers (label-only match — see matters table test for rationale).
      assert html =~ "Title"
      assert html =~ "Type"
      assert html =~ "Matter"
      assert html =~ "Last revision"

      # Document title + matter name both render in the row.
      assert html =~ "Engagement letter"
      assert html =~ "Acme v Smith"
    end

    # SPEC.md §18 — `feat/no-type-at-create`: when a document is
    # created untyped (type_key: nil), the Type column renders the
    # locale-aware "유형 미지정" placeholder so the row still
    # parses at a glance.
    test "renders 유형 미지정 placeholder for untyped documents under :ko locale",
         %{conn: conn, user: user} do
      previous = Application.get_env(:contract, :ui_locale, "en")
      Application.put_env(:contract, :ui_locale, "ko")
      on_exit(fn -> Application.put_env(:contract, :ui_locale, previous) end)

      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Untyped draft"
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "Untyped draft"
      assert html =~ "유형 미지정"
    end

    # Wave 5: the subagent fix — the Type column used to render the raw
    # `type_key` ("nda_v1") regardless of locale. With locale-aware
    # `Contract.ContractTypes.display_name/1`, Korean lawyers should see
    # the Korean name from the TOML spec.
    test "renders the localized contract-type name in the Type column under :ko locale",
         %{conn: conn, user: user} do
      previous = Application.get_env(:contract, :ui_locale, "en")
      Application.put_env(:contract, :ui_locale, "ko")
      on_exit(fn -> Application.put_env(:contract, :ui_locale, previous) end)

      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "Acme v Smith"})

      {:ok, _doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "Engagement letter",
          "type_key" => "nda_v1"
        })

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      # Korean name from priv/contract_types/nda_v1.toml.
      {:ok, spec} = Contract.ContractTypes.get(nil, "nda_v1")
      assert html =~ spec.name_ko

      # The Type cell badge text is now the Korean label, not raw
      # "nda_v1". The key is still present as a `title=` tooltip for
      # power users, so the bare-key assertion would still spuriously
      # match — pin the badge slot specifically.
      assert html =~ ~s(badge badge-ghost badge-sm" title="nda_v1")
    end
  end

  defp log_in_a_user(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end
end
