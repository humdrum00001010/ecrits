defmodule ContractWeb.StudioLiveTest do
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures
  import Ecto.Query
  import Mox

  alias Contract.ChatThread
  alias Contract.Command
  alias Contract.Repo
  alias Contract.RhwpSnapshot.Record, as: RhwpSnapshotRecord
  alias Contract.Studio.State
  alias ContractWeb.StudioLive

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/studio")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects when hitting a document URL while anonymous", %{conn: conn} do
      document_id = Ecto.UUID.generate()
      assert {:error, {:redirect, %{to: _}}} = live(conn, ~p"/documents/#{document_id}")
    end
  end

  describe "mount when authenticated" do
    setup :log_in_a_user

    test "renders the studio root and a desktop grid by default", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio")
      assert html =~ ~s(id="studio-root")
      assert html =~ ~s(id="studio-document-header")
      refute html =~ ~s(data-role="context-reservoir")
      assert html =~ ~s(data-stub="chat-rail")
      # canvas-empty since no doc selected
      assert html =~ ~s(data-stub="canvas-empty")
    end

    test "mounts at /documents/:document_id with current_document_id assigned", %{
      conn: conn,
      user: user
    } do
      scope = Contract.Context.for_user(user)
      {:ok, doc} = Contract.Documents.create(scope, %{title: "Mounted"})
      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

      assert :sys.get_state(lv.pid).socket.assigns.current_document_id == doc.id
    end

    # ---------------------------------------------------------------
    # Document-pivot (SPEC.md §4, 2026-05-15). The product surface is
    # now document-first: `/documents/:document_id` is the canonical
    # URL, `/studio` (no params) lands on the no-document agent prompt.
    # ---------------------------------------------------------------

    test "mounts at /documents/:document_id and selects the document",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "title" => "doc-pivot-mount-doc",
          "type_key" => "nda_v1"
        })

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.current_document_id == doc.id
      assert assigns.studio_state.selected_document_id == doc.id
    end

    test "mounts at /documents/:document_id/review (review subroute) the same way",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "title" => "doc-pivot-review-doc",
          "type_key" => "nda_v1"
        })

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}/review")

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.current_document_id == doc.id
      assert assigns.studio_state.selected_document_id == doc.id
    end

    test "snapshot upload refreshes the current snapshot assigns and hook attributes", %{
      conn: conn,
      user: user
    } do
      old_drivers = Application.get_env(:contract, :io_drivers, [])

      Application.put_env(
        :contract,
        :io_drivers,
        Keyword.put(old_drivers, :r2, Contract.IO.R2Stub)
      )

      Contract.IO.R2Stub.reset()

      on_exit(fn ->
        Application.put_env(:contract, :io_drivers, old_drivers)
        Contract.IO.R2Stub.reset()
      end)

      scope = Contract.Context.for_user(user)
      document_id = create_typed_document!(scope, "Snapshot freshness")
      update_document_metadata!(scope, document_id, 1)
      insert_rhwp_snapshot!(document_id, 1)

      {:ok, lv, html} = live(conn, ~p"/documents/#{document_id}")

      assert html =~ ~s(data-snapshot-revision="1")
      assert :sys.get_state(lv.pid).socket.assigns.rhwp_snapshot.revision == 1
      assert {:ok, 2} = Contract.Store.latest_revision(document_id)

      html =
        render_hook(lv, "rhwp.snapshot.upload", %{
          "bytes_base64" => Base.encode64("new-native-hwp"),
          "format" => "hwp",
          "ir" => %{"metadata" => %{"lamport_max" => 268}}
        })

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.rhwp_snapshot.revision == 2
      assert [%{revision: 2}, %{revision: 1}] = assigns.rhwp_snapshot_candidates
      assert html =~ ~s(data-snapshot-revision="2")
      assert html =~ ~s(/documents/#{document_id}/rhwp-snapshots/2.hwp)
    end

    test "mount replays doc_write text events newer than the rhwp snapshot", %{
      conn: conn,
      user: user
    } do
      scope = Contract.Context.for_user(user)
      document_id = create_typed_document!(scope, "Doc write replay")
      update_document_metadata!(scope, document_id, 1)
      insert_rhwp_snapshot!(document_id, 2)

      command = %Command{
        kind: :doc_write,
        actor_type: :agent,
        actor_id: user.id,
        document_id: document_id,
        base_revision: 2,
        idempotency_key: "doc-write-replay-#{Ecto.UUID.generate()}",
        payload: %{
          "type" => "paragraph",
          "sec" => 0,
          "para" => 12,
          "payload" => %{
            "cmd" => "insert_after_match",
            "payload" => %{"text" => "DOC-WRITE-REPLAY"}
          },
          "resolved" => %{"off" => 10}
        }
      }

      assert {:ok, %Contract.Change{command_kind: "doc_write", result_revision: 3}} =
               Contract.Runtime.apply(scope, command)

      {:ok, lv, _html} = live(conn, ~p"/documents/#{document_id}")

      assert [
               %{
                 "kind" => "insert_text",
                 "revision" => 3,
                 "sec" => 0,
                 "para" => 12,
                 "off" => 10,
                 "text" => "DOC-WRITE-REPLAY"
               }
             ] = assigns(lv).rhwp_text_events
    end

    test "mounts at /studio (no params) with no document",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.current_document_id == nil
      assert assigns.studio_state.selected_document_id == nil
    end

    test "empty /studio canvas offers type choices that start a typed document",
         %{conn: conn, user: user} do
      conn =
        Plug.Conn.put_session(
          conn,
          :user_perms,
          ~w(read write commit revoke export type_change agent_run)a
        )

      {:ok, lv, _html} = live(conn, ~p"/studio")

      assert has_element?(lv, ~s([data-role="canvas-empty-type-picker"]))
      refute has_element?(lv, ~s([data-role="canvas-empty-upload-action"]))

      {:ok, specs} = Contract.ContractTypes.list()
      visible_specs = Enum.reject(specs, &(&1.source == :custom))

      for spec <- visible_specs do
        assert has_element?(
                 lv,
                 ~s([data-role="canvas-empty-type-option"][phx-value-type_key="#{spec.key}"]),
                 Contract.ContractTypes.display_name(spec)
               )
      end

      first_spec = hd(visible_specs)

      lv
      |> element(
        ~s([data-role="canvas-empty-type-option"][phx-value-type_key="#{first_spec.key}"])
      )
      |> render_click()

      [doc] =
        user
        |> Contract.Context.for_user()
        |> Contract.Documents.list_recent_for_scope(1)

      assert doc.type_key == first_spec.key
      assert_redirect(lv, "/studio/#{doc.id}")
    end

    test "empty /studio with project_id keeps picker and attaches typed document to project",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, project} = Contract.Projects.create_project(scope, %{"title" => "프로젝트 문서"})

      conn =
        Plug.Conn.put_session(
          conn,
          :user_perms,
          ~w(read write commit revoke export type_change agent_run)a
        )

      {:ok, lv, _html} = live(conn, ~p"/studio?project_id=#{project.id}")

      assert assigns(lv).studio_state.selected_document_id == nil
      assert assigns(lv).project_id == project.id
      assert has_element?(lv, ~s([data-role="canvas-empty-type-picker"]))
      assert Contract.Documents.list_recent_for_scope(scope, 1) == []

      {:ok, specs} = Contract.ContractTypes.list()
      first_spec = specs |> Enum.reject(&(&1.source == :custom)) |> hd()

      lv
      |> element(
        ~s([data-role="canvas-empty-type-option"][phx-value-type_key="#{first_spec.key}"])
      )
      |> render_click()

      [doc] = Contract.Documents.list_recent_for_scope(scope, 1)
      assert doc.type_key == first_spec.key

      {:ok, loaded_project} = Contract.Projects.get_project(scope, project.id)
      assert Enum.any?(loaded_project.documents, &(&1.id == doc.id))

      project_document =
        Contract.Repo.get_by!(Contract.Projects.ProjectDocument,
          project_id: project.id,
          document_id: doc.id
        )

      assert project_document.role == "primary"
      assert_redirect(lv, ~p"/documents/#{doc.id}")
    end

    test "DocumentScope threads :user_perms from session onto current_scope.perms",
         %{conn: conn} do
      # Persona sign-in (TestAuthController) writes :user_perms into the
      # session. Simulate that here — the lawyer-shaped perm set must
      # land on current_scope and unlock the Canvas.Empty actions.
      lawyer_perms = ~w(read write commit revoke export type_change agent_run)a
      conn = Plug.Conn.put_session(conn, :user_perms, lawyer_perms)

      {:ok, lv, html} = live(conn, ~p"/studio")

      assert :sys.get_state(lv.pid).socket.assigns.current_scope.perms == lawyer_perms
      assert html =~ "계약 유형 선택"
      assert html =~ ~s(data-role="canvas-empty-type-picker")
    end

    test "without :user_perms in session, current_scope.perms is nil and Canvas.Empty actions are hidden",
         %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/studio")

      assert :sys.get_state(lv.pid).socket.assigns.current_scope.perms == nil
      refute html =~ "빈 문서로 시작"
      refute html =~ ~s(data-role="canvas-empty-upload-form")
      refute html =~ "에이전트와 먼저 상의하기"
    end

    test "mounts the modal-host and toast-queue components", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio")
      # ModalHost has graduated from stub → real component (Wave 3C1
      # modal-host subagent); it now renders with `data-role`. Other
      # component stubs still emit `data-stub`.
      assert html =~ ~s(data-role="modal-host")
      assert html =~ ~s(data-stub="toast-queue")
    end

    test "no-document chat form is visible but does not submit without a selected document", %{
      conn: conn,
      user: user
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      assert has_element?(lv, "#chat-rail-form")
      refute has_element?(lv, "#chat-rail-form[phx-submit]")

      refute Repo.exists?(
               from t in ChatThread,
                 where: t.owner_id == ^user.id and is_nil(t.document_id)
             )
    end

    # Wave 4 bugfix #6 — Playwright Scenario 6 selector contract.
    # The global Cmd+K palette mounts through Layouts.app's
    # `CommandPalette.mount_if_live/1` wrapper. Studio's rendered HTML
    # must expose the root data-role so the JS hook can bind. The
    # modal-box `data-role="command-palette"` (without `-root`) only
    # appears once the user has pressed Cmd/Ctrl+K.
    test "studio LV exposes the global command palette root",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio")
      assert html =~ ~s(data-role="command-palette-root")
    end

    test "viewport defaults to :desktop until the JS hook reports otherwise",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.viewport == :desktop
    end

    test "viewport_change event swaps to mobile layout when w < 1024", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      html =
        lv
        |> render_hook("viewport_change", %{"w" => 600})

      assert html =~ ~s(data-stub="chat-rail")
      refute html =~ ~s(data-role="context-reservoir")
    end

    test "viewport_change with w >= 1024 stays on desktop", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      html = render_hook(lv, "viewport_change", %{"w" => 1600})
      assert html =~ ~s(id="studio-document-header")
      refute html =~ ~s(data-role="context-reservoir")
    end

    # -------------------------------------------------------------------------
    # Owner directive 2026-05-17 — Studio LV is full-bleed on mobile.
    # "The chat should fill the whole screen in mobile, not being part of a
    # page." When @viewport == :mobile, Layouts.app's chrome (top navbar,
    # breadcrumbs, footer) must NOT render; #studio-root becomes a fixed
    # inset-0 surface with 100dvh + safe-area insets. The chat rail's own
    # header carries the 문서 toggle, so the floating preview FAB is dropped
    # to avoid duplicate affordances.
    # -------------------------------------------------------------------------
    test "desktop viewport renders Layouts.app chrome (navbar + breadcrumbs)",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio")

      # Top navbar lives inside Layouts.app — fixed header at top.
      assert html =~
               "navbar fixed top-0 left-0 right-0 z-40 h-14 min-h-[60px]"

      assert html =~ "supports-[backdrop-filter]:backdrop-blur-md"
      # Studio document header (Document / title / Dashboard link) is present.
      assert html =~ ~s(id="studio-document-header")
      # Desktop root has the calc-based height (not fixed inset-0).
      assert html =~ ~s(data-viewport="desktop")
      refute html =~ ~s(data-viewport="mobile")
    end

    test "mobile viewport bypasses Layouts.app chrome — full-bleed surface",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      html = render_hook(lv, "viewport_change", %{"w" => 600})

      # The full-bleed wrapper is fixed inset-0 with 100dvh + z-50.
      assert html =~ ~s(data-viewport="mobile")
      assert html =~ ~s(fixed inset-0)
      assert html =~ "100dvh"
      assert html =~ "env(safe-area-inset-top"

      # The page-level Document / Dashboard header is desktop-only.
      refute html =~ ~s(id="studio-document-header")

      # Breadcrumbs nav (rendered by Layouts.app) must NOT appear on mobile.
      refute html =~ ~s(aria-label="Breadcrumb")
    end

    test "rotating mobile → desktop restores Layouts.app chrome",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      _ = render_hook(lv, "viewport_change", %{"w" => 600})
      html = render_hook(lv, "viewport_change", %{"w" => 1600})

      assert html =~ ~s(data-viewport="desktop")
      assert html =~ ~s(id="studio-document-header")
      assert html =~ "navbar fixed top-0 left-0 right-0 z-40 h-14 min-h-[60px]"
      assert html =~ "supports-[backdrop-filter]:backdrop-blur-md"
      refute html =~ ~s(fixed inset-0)
    end
  end

  # ---------------------------------------------------------------------------
  # Auto-grill seed on cold document open. When the user lands on a document
  # that has body content + an empty chat thread + no running agent, the LV
  # should dispatch a hidden `:chat_message` Command carrying
  # `payload["grill_seed"] => true` so the agent speaks first.
  # ---------------------------------------------------------------------------
  describe "auto-grill seed on cold document open" do
    setup :log_in_a_user

    test "mount on a fresh document with body content dispatches the grill seed",
         %{conn: conn, user: user} do
      test_pid = self()

      # Stub OpenAI to capture that the agent run started and signal back to
      # the test (without that signal, the stub returns instantly and the
      # run reaches :completed before we can observe the agent_run_id on
      # the LV's state).
      Contract.IO.OpenAIMock
      |> stub(:stream_chat, fn params, _opts ->
        send(test_pid, {:stream_chat_called, params})
        # Empty stream — never emits :stream_done, so the run hangs and
        # the agent_run_id stays set on studio_state long enough to
        # assert on it.
        stream =
          Stream.repeatedly(fn ->
            Process.sleep(1000)
            nil
          end)
          |> Stream.reject(&is_nil/1)

        {:ok, %{stream: stream, task_pid: self()}}
      end)

      doc = seed_document_with_paragraph(user, "비밀유지계약서 본문")

      conn =
        Plug.Conn.put_session(
          conn,
          :user_perms,
          ~w(read write commit revoke export type_change agent_run)a
        )

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

      # The OpenAI driver MUST have been invoked — i.e. the grill seed
      # was dispatched all the way through Runtime.apply → Agent.start.
      assert_receive {:stream_chat_called, params}, 1500

      # The instructions carried the Korean grill-intro system prompt
      # (NOT the regular grill-me JSON-envelope prompt).
      assert params.instructions =~ "당신이 먼저 말을 걸어야"
      assert params.instructions =~ "1-3개의 질문"
      # The document body the LV passed through carries our seeded
      # paragraph.
      assert hd(params.input).content =~ "비밀유지계약서 본문"
      # Grill-intro path drops the JSON-object format constraint.
      refute Map.has_key?(params, :text)

      # The dispatch flow folds the Agent.Run id back into studio_state.
      assert eventually(fn ->
               %State{agent_run_id: run_id} = assigns(lv).studio_state
               is_binary(run_id)
             end)

      run_id = assigns(lv).studio_state.agent_run_id
      html = render(lv)
      assert html =~ ~s(id="chat-msg-agent-#{run_id}-streaming")
      assert html =~ ~s(data-role="agent-loading")

      # The hidden seed was persisted with role "system" so it never
      # reaches the visible rail.
      ctx = Contract.Context.for_user(user)
      state = %State{selected_document_id: doc.id, mode: :editing}
      visible = Contract.ChatThreads.list_visible_messages(ctx, state)
      refute Enum.any?(visible, &(&1.role == :system))
    end

    test "mount on a document with existing chat messages does NOT dispatch",
         %{conn: conn, user: user} do
      doc = seed_document_with_paragraph(user, "이미 대화가 있는 문서")
      seed_thread_with_user_message(user, doc, "Earlier user turn")

      conn =
        Plug.Conn.put_session(
          conn,
          :user_perms,
          ~w(read write commit revoke export type_change agent_run)a
        )

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

      # `agent_run_id` must remain nil — no auto-grill should have been
      # triggered, even though the projection has body content.
      Process.sleep(50)
      assert assigns(lv).studio_state.agent_run_id == nil
    end

    test "mount on an empty document (no projection nodes) does NOT dispatch",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      # An empty document — no edit_document command applied, so
      # projection.nodes stays %{}.
      {:ok, doc} =
        Contract.Documents.create(scope, %{"title" => "empty-doc", "type_key" => "nda_v1"})

      conn =
        Plug.Conn.put_session(
          conn,
          :user_perms,
          ~w(read write commit revoke export type_change agent_run)a
        )

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

      Process.sleep(50)
      assert assigns(lv).studio_state.agent_run_id == nil
    end
  end

  # ---------------------------------------------------------------------------
  # SPEC.md §10 — no-document agent prompt (Wave Document-Pivot Impl D)
  # ---------------------------------------------------------------------------
  describe "agent_option_picked (no-document quick-start, SPEC.md §10)" do
    setup :log_in_a_user

    test "renders main empty-screen creation actions and no ChatRail no-doc dialog at /studio",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio")

      assert html =~ ~s(data-role="canvas-empty-type-picker")
      refute html =~ ~s(data-role="canvas-empty-upload-action")
      refute html =~ ~s(data-role="chat-no-doc-welcome")
    end

    test "recent option opens the document-picker modal", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      assert :sys.get_state(lv.pid).socket.assigns.studio_state.document_picker_open? == false

      _ = render_hook(lv, "agent_option_picked", %{"key" => "recent"})

      assert :sys.get_state(lv.pid).socket.assigns.studio_state.document_picker_open? == true
    end

    test "draft_from_discussion option flashes a stub info message", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      html = render_hook(lv, "agent_option_picked", %{"key" => "draft_from_discussion"})

      assert html =~ "논의 모드는 곧 추가됩니다."
    end

    test "variant_from_other option opens the document-picker with the variant-source flag",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      _ = render_hook(lv, "agent_option_picked", %{"key" => "variant_from_other"})

      state = :sys.get_state(lv.pid).socket.assigns.studio_state
      assert state.document_picker_open? == true
      assert Map.get(state, :variant_source_picker?) == true
    end
  end

  describe "event_to_command/3 (dispatch funnel)" do
    setup :base_assigns

    test "document.rename → :rename_document Command with document_id from state",
         %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Command{kind: :rename_document, document_id: ^doc, actor_type: :user}} =
               StudioLive.event_to_command("document.rename", %{"title" => "New"}, assigns)
    end

    test "document.type.set → :set_contract_type", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Command{kind: :set_contract_type}} =
               StudioLive.event_to_command("document.type.set", %{"type_key" => "nda"}, assigns)
    end

    test "document.metadata.update → :update_metadata", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok,
              %Command{kind: :update_metadata, document_id: ^doc, payload: %{"notes" => "review"}}} =
               StudioLive.event_to_command(
                 "document.metadata.update",
                 %{"notes" => "review"},
                 assigns
               )
    end

    test "chat.submit → :chat_message (document not required)",
         %{assigns: assigns} do
      assert {:ok, %Command{kind: :chat_message}} =
               StudioLive.event_to_command("chat.submit", %{"message" => "hi"}, assigns)
    end

    test "document.open → :open_document", %{assigns: assigns} do
      doc = Ecto.UUID.generate()

      assert {:ok, %Command{kind: :open_document, document_id: ^doc}} =
               StudioLive.event_to_command("document.open", %{"document_id" => doc}, assigns)
    end

    test "document.duplicate → :duplicate_document", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Command{kind: :duplicate_document}} =
               StudioLive.event_to_command("document.duplicate", %{}, assigns)
    end

    test "command_palette_picked resolves to the inner kind", %{assigns: assigns} do
      assert {:ok, %Command{kind: :chat_message}} =
               StudioLive.event_to_command(
                 "command_palette_picked",
                 %{"kind" => "chat_message", "message" => "hi"},
                 assigns
               )
    end

    test "command_palette_picked resolves dotted document.create", %{assigns: assigns} do
      assert {:ok, %Command{kind: :create_document, payload: %{"title" => "Blank"}}} =
               StudioLive.event_to_command(
                 "command_palette_picked",
                 %{"kind" => "document.create", "title" => "Blank"},
                 assigns
               )
    end

    test "command_palette_picked errors on unknown kind", %{assigns: assigns} do
      assert {:error, {:unknown_palette_kind, "bogus_kind_xyz"}} =
               StudioLive.event_to_command(
                 "command_palette_picked",
                 %{"kind" => "bogus_kind_xyz"},
                 assigns
               )
    end

    test "missing document_id when required is a typed error", %{assigns: assigns} do
      # rename_document requires a doc id; nothing in state and nothing in params
      assert {:error, {:missing_document_id, :rename_document}} =
               StudioLive.event_to_command("document.rename", %{}, assigns)
    end

    test "local UI events return :local", %{assigns: assigns} do
      assert :local = StudioLive.event_to_command("open_modal", %{}, assigns)
      assert :local = StudioLive.event_to_command("close_modal", %{}, assigns)
      assert :local = StudioLive.event_to_command("viewport_change", %{}, assigns)
    end

    test "unknown event returns {:error, _}", %{assigns: assigns} do
      assert {:error, {:unknown_event, "wat"}} =
               StudioLive.event_to_command("wat", %{}, assigns)
    end

    test "every built Action carries a unique idempotency_key", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      {:ok, a} = StudioLive.event_to_command("rename_document", %{"title" => "A"}, assigns)
      {:ok, b} = StudioLive.event_to_command("rename_document", %{"title" => "B"}, assigns)

      assert is_binary(a.idempotency_key)
      assert is_binary(b.idempotency_key)
      assert a.idempotency_key != b.idempotency_key
    end
  end

  describe "handle_info protocol (driven through the live LV process)" do
    setup :log_in_a_user

    test "{:studio_loaded, state} swaps the studio_state assign", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      new_state = %State{mode: :editing, last_seen_revision: 9}
      send(lv.pid, {:studio_loaded, new_state})
      _ = render(lv)
      assert assigns(lv).studio_state == new_state
    end

    test "{:change_committed, change} bumps last_seen_revision", %{conn: conn} do
      doc = Ecto.UUID.generate()
      {:ok, lv, _html} = live(conn, ~p"/studio")

      # Seed the LV with a selected document so :change_committed makes sense.
      send_state(lv, %State{selected_document_id: doc, mode: :editing, last_seen_revision: 0})

      change = %Contract.Change{
        id: Ecto.UUID.generate(),
        document_id: doc,
        command_kind: "edit_document",
        result_revision: 7
      }

      send(lv.pid, {:change_committed, change})
      _ = render(lv)
      assert assigns(lv).studio_state.last_seen_revision == 7
    end

    test "{:change_committed, edit_text} appends RHWP replay events for ignored canvas attrs",
         %{conn: conn} do
      doc = Ecto.UUID.generate()
      {:ok, lv, _html} = live(conn, ~p"/studio")

      send_state(lv, %State{selected_document_id: doc, mode: :editing, last_seen_revision: 0})

      change = %Contract.Change{
        id: Ecto.UUID.generate(),
        document_id: doc,
        command_kind: "edit_text",
        result_revision: 2,
        idempotency_key: "mcp:test:edit_text",
        payload: [
          %{
            "op" => "delete_text",
            "args" => %{
              "field_id" => "contract_period",
              "sec" => 0,
              "para" => 12,
              "off" => 10,
              "len" => 28
            }
          },
          %{
            "op" => "insert_text",
            "args" => %{
              "field_id" => "contract_period",
              "sec" => 0,
              "para" => 12,
              "off" => 10,
              "text" => "CHAT-LONG-VERIFY"
            }
          }
        ]
      }

      send(lv.pid, {:change_committed, change})
      _ = render(lv)

      assert [
               %{"kind" => "delete_text", "revision" => 2, "field_id" => "contract_period"},
               %{
                 "kind" => "insert_text",
                 "revision" => 2,
                 "field_id" => "contract_period",
                 "text" => "CHAT-LONG-VERIFY"
               }
             ] = assigns(lv).rhwp_text_events
    end

    test "{:agent_completed, _, _} surfaces the final answer", %{conn: conn} do
      run_id = Ecto.UUID.generate()
      {:ok, lv, _html} = live(conn, ~p"/studio")

      send_state(lv, %State{mode: :briefing, last_seen_revision: 0, agent_run_id: run_id})

      send(lv.pid, {:agent_completed, run_id, "Final answer."})

      html = render(lv)
      assert html =~ "Final answer."
      # The synthetic `kind: :thinking` placeholder row has been removed;
      # loading state is owned by the reasoning bubble (see Bug B fix).
      refute html =~ ~s(id="chat-msg-thinking-#{run_id}")
      refute html =~ ~s(data-role="agent-thinking")
    end

    test "{:agent_reasoning_done, _, text} renders completed thinking content", %{conn: conn} do
      run_id = Ecto.UUID.generate()
      {:ok, lv, _html} = live(conn, ~p"/studio")

      send_state(lv, %State{mode: :briefing, last_seen_revision: 0, agent_run_id: run_id})
      send(lv.pid, {:agent_reasoning_done, run_id, "Checked the title position."})

      html = render(lv)
      assert html =~ ~s(id="chat-msg-reasoning-#{run_id}")
      assert html =~ ~s(id="tool-trace-reasoning-#{run_id}")
      assert html =~ ~s(data-role="agent-reasoning-text")
      assert html =~ "Thinking:"
      assert html =~ "Checked the title position."
    end

    test "{:change_committed, agent_change} stamps :recently_authored_agent for node ops",
         %{conn: conn} do
      doc = Ecto.UUID.generate()
      {:ok, lv, _html} = live(conn, ~p"/studio")

      send_state(lv, %State{selected_document_id: doc, mode: :editing, last_seen_revision: 0})

      change = %Contract.Change{
        id: Ecto.UUID.generate(),
        document_id: doc,
        command_kind: "agent_change",
        actor_type: :agent,
        result_revision: 9,
        payload: [
          %{op: :replace_content, target_type: :node, target_id: "node-x", args: %{}},
          # A field-target op should be ignored — only node-shaped ops
          # drive the IR-canvas typing animation.
          %{op: :set_field, target_type: :field, target_id: "field-y", args: %{}}
        ]
      }

      send(lv.pid, {:change_committed, change})
      _ = render(lv)

      map = assigns(lv).studio_state.recently_authored_agent
      assert Map.has_key?(map, "node-x")
      refute Map.has_key?(map, "field-y")
    end

    test "{:change_committed, user_change} does not stamp :recently_authored_agent",
         %{conn: conn} do
      doc = Ecto.UUID.generate()
      {:ok, lv, _html} = live(conn, ~p"/studio")

      send_state(lv, %State{selected_document_id: doc, mode: :editing, last_seen_revision: 0})

      change = %Contract.Change{
        id: Ecto.UUID.generate(),
        document_id: doc,
        command_kind: "edit_document",
        actor_type: :user,
        result_revision: 2,
        payload: [%{op: :replace_content, target_type: :node, target_id: "node-x", args: %{}}]
      }

      send(lv.pid, {:change_committed, change})
      _ = render(lv)

      assert assigns(lv).studio_state.recently_authored_agent == %{}
    end

    test "{:marks_changed, marks} replaces projection.marks", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      marks = %{"m1" => %{id: "m1", intent: :assertion, source: :user}}
      send(lv.pid, {:marks_changed, marks})
      _ = render(lv)
      assert assigns(lv).projection.marks == marks
    end

    test "{:agent_failed, _, _} clears agent_run_id", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      run = Ecto.UUID.generate()

      send_state(lv, %State{
        agent_run_id: run,
        mode: :editing,
        last_seen_revision: 0
      })

      send(lv.pid, {:agent_failed, run, :boom})
      _ = render(lv)
      assert assigns(lv).studio_state.agent_run_id == nil
    end

    test "cancel_agent cancels the Agent.Document attempt and removes transient rows",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, doc} = Contract.Documents.create(scope, %{"title" => "중지할 문서"})
      stub_blocking_agent_stream(self())
      on_exit(fn -> Contract.Agent.Document.suspend(scope, doc.id) end)

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")
      _ = render_hook(lv, "chat.submit", %{"message" => "검토해줘"})
      assert_receive {:agent_stream_started, _pid}, 1_500

      assert eventually(fn -> is_binary(assigns(lv).studio_state.agent_run_id) end)
      run_id = assigns(lv).studio_state.agent_run_id

      html = render(lv)
      assert html =~ ~s(id="chat-msg-agent-#{run_id}-streaming")
      assert html =~ ~s(id="chat-msg-reasoning-#{run_id}")

      _html =
        lv
        |> element(~s([data-role="chat-stop"]))
        |> render_click()

      assert assigns(lv).studio_state.agent_run_id == nil
      assert {:ok, status} = Contract.Agent.Document.status(scope, doc.id)
      assert status.current_attempt == nil
      assert status.queue == []

      html = render(lv)
      refute html =~ ~s(id="chat-msg-agent-#{run_id}-streaming")
      refute html =~ ~s(id="chat-msg-reasoning-#{run_id}")
      refute html =~ "Agent failed"
    end

    test "chat.submit subscribes the LiveView to the new agent run PubSub topic",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, doc} = Contract.Documents.create(scope, %{"title" => "구독할 문서"})
      stub_blocking_agent_stream(self(), ["응답 완료"])
      on_exit(fn -> Contract.Agent.Document.suspend(scope, doc.id) end)

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")
      _ = render_hook(lv, "chat.submit", %{"message" => "검토해줘"})
      assert_receive {:agent_stream_started, stream_pid}, 1_500

      assert eventually(fn -> is_binary(assigns(lv).studio_state.agent_run_id) end)
      run_id = assigns(lv).studio_state.agent_run_id

      send(stream_pid, :release_stream)

      assert eventually(fn ->
               html = render(lv)

               assigns(lv).studio_state.agent_run_id == nil and
                 html =~ "응답 완료" and
                 html =~ ~s(id="chat-msg-agent-#{run_id}-streaming") and
                 not String.contains?(html, ~s(id="chat-msg-reasoning-#{run_id}"))
             end)
    end

    test "reasoning delta broadcast reaches the selected details body and visible thinking line",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, doc} = Contract.Documents.create(scope, %{"title" => "생각 표시 문서"})
      stub_blocking_agent_stream(self())
      on_exit(fn -> Contract.Agent.Document.suspend(scope, doc.id) end)

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")
      _ = render_hook(lv, "chat.submit", %{"message" => "계약명을 봐줘"})
      assert_receive {:agent_stream_started, _stream_pid}, 1_500

      assert eventually(fn -> is_binary(assigns(lv).studio_state.agent_run_id) end)
      run_id = assigns(lv).studio_state.agent_run_id
      html = render(lv)
      fragment = LazyHTML.from_fragment(html)
      details_selector = "#tool-trace-reasoning-#{run_id}-details > div:nth-child(1)"

      assert LazyHTML.attribute(
               LazyHTML.query(fragment, "#chat-msg-reasoning-#{run_id}"),
               "hidden"
             ) == [""]

      refute html =~ "생각 중"

      details_body = LazyHTML.query(fragment, details_selector)
      assert LazyHTML.attribute(details_body, "data-role") == ["agent-reasoning-details-content"]

      assert LazyHTML.attribute(details_body, "data-message-id") == [
               "chat-msg-reasoning-#{run_id}"
             ]

      Phoenix.PubSub.broadcast(
        Contract.PubSub,
        "agent:#{run_id}",
        {:agent_reasoning_delta, run_id, "계약명을 검토 중"}
      )

      reasoning_message_id = "chat-msg-reasoning-#{run_id}"

      assert_push_event(
        lv,
        "agent_reasoning_append",
        %{message_id: ^reasoning_message_id, piece: "계약명을 검토 중"},
        500
      )
    end

    test "{:agent_failed, _, :cancelled} removes transient rows without an error toast",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      run_id = Ecto.UUID.generate()

      send_state(lv, %State{
        agent_run_id: run_id,
        mode: :editing,
        last_seen_revision: 0
      })

      send(lv.pid, {:agent_text_delta, run_id, "검토 중"})

      html = render(lv)
      assert html =~ ~s(id="chat-msg-agent-#{run_id}-streaming")

      send(lv.pid, {:agent_failed, run_id, :cancelled})
      html = render(lv)

      assert assigns(lv).studio_state.agent_run_id == nil
      refute html =~ ~s(id="chat-msg-agent-#{run_id}-streaming")
      refute html =~ "Agent failed"
    end

    test "submitting a replacement chat suspends the current Document attempt before starting the next",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, doc} = Contract.Documents.create(scope, %{"title" => "교체할 문서"})
      stub_blocking_agent_stream(self())
      on_exit(fn -> Contract.Agent.Document.suspend(scope, doc.id) end)

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")
      _ = render_hook(lv, "chat.submit", %{"message" => "첫 요청"})
      assert_receive {:agent_stream_started, _first_pid}, 1_500
      assert eventually(fn -> is_binary(assigns(lv).studio_state.agent_run_id) end)
      first_run_id = assigns(lv).studio_state.agent_run_id

      _ = render_hook(lv, "chat.submit", %{"message" => "두 번째 요청"})
      assert eventually(fn -> assigns(lv).studio_state.agent_run_id != first_run_id end)
      second_run_id = assigns(lv).studio_state.agent_run_id

      assert {:ok, status} = Contract.Agent.Document.status(scope, doc.id)
      assert status.current_attempt.id == second_run_id
      assert status.queue == []
    end

    test "chat rail keeps Agent.Document status internal to composer controls",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, doc} = Contract.Documents.create(scope, %{"title" => "상태를 표시할 문서"})
      stub_blocking_agent_stream(self())
      on_exit(fn -> Contract.Agent.Document.suspend(scope, doc.id) end)

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")
      _ = render_hook(lv, "chat.submit", %{"message" => "상태 확인"})
      assert_receive {:agent_stream_started, _pid}, 1_500
      assert eventually(fn -> is_binary(assigns(lv).studio_state.agent_run_id) end)

      run_id = assigns(lv).studio_state.agent_run_id

      assert {:ok, status} = Contract.Agent.Document.status(scope, doc.id)
      assert status.current_attempt.id == run_id
      assert status.queue == []

      refute has_element?(lv, ~s([data-role="agent-status"]))
      assert has_element?(lv, ~s([data-role="chat-stop"]))
    end

    test "tool-call protocol messages render structured operation blocks", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      run_id = Ecto.UUID.generate()
      tool_id = Ecto.UUID.generate()

      send(lv.pid, {:tool_call_started, run_id, %{id: tool_id, tool_name: "law.search"}})
      html = render(lv)

      assert html =~ ~s(id="tool-trace-tool-#{run_id}-#{tool_id}")
      assert html =~ ~s(data-role="tool-trace")
      assert html =~ ~s(data-status="running")
      assert html =~ "law.search"
      refute html =~ "Tool started: law.search"

      send(lv.pid, {:tool_call_completed, run_id, tool_id, %{summary: "Found 2 clauses"}})
      html = render(lv)

      assert html =~ ~s(id="tool-trace-tool-#{run_id}-#{tool_id}")
      assert html =~ ~s(data-status="completed")
      assert html =~ "Found 2 clauses"
    end

    test "failed tool-call protocol map keeps compact error summary", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      run_id = Ecto.UUID.generate()
      tool_id = Ecto.UUID.generate()

      send(lv.pid, {
        :tool_call_failed,
        run_id,
        tool_id,
        %{
          "id" => tool_id,
          "name" => "doc.write",
          "agent_run_id" => run_id,
          "error" => "{:invalid_params, \"match is ambiguous in paragraph\"}"
        }
      })

      fragment = render(lv) |> LazyHTML.from_fragment()

      summary =
        fragment
        |> LazyHTML.query(
          ~s(#tool-trace-tool-#{run_id}-#{tool_id} [data-role="tool-trace-summary"])
        )
        |> LazyHTML.text()
        |> String.trim()

      assert summary == ~s({:invalid_params, "match is ambiguous in paragraph"})
      refute summary =~ "agent_run_id"
      refute summary =~ "%{"
    end

    test "freshly broadcast tool_call article toggles via client-side JS — details rendered + hidden",
         %{conn: conn} do
      # Regression: tool_call rows broadcast mid-conversation wouldn't
      # expand until the user reloaded the page. Root cause was that
      # `phx-update="stream"` items don't re-render when outer assigns
      # change, so the server-side expand `MapSet` never reached the DOM
      # after the row's first insertion. Fix moves the toggle to a
      # `Phoenix.LiveView.JS` command on the article that flips
      # `hidden` on the always-rendered details panel — pure client-side,
      # no server roundtrip, works on fresh inserts and after reload.
      {:ok, lv, _html} = live(conn, ~p"/studio")
      run_id = Ecto.UUID.generate()
      tool_id = Ecto.UUID.generate()

      send(lv.pid, {:tool_call_started, run_id, %{id: tool_id, tool_name: "doc.find"}})

      send(
        lv.pid,
        {:tool_call_completed, run_id, tool_id, %{summary: "Found", details: %{q: "delivery"}}}
      )

      html = render(lv)
      dom_id = "chat-msg-tool-#{run_id}-#{tool_id}"
      operation_id = "tool-#{run_id}-#{tool_id}"

      fragment = LazyHTML.from_fragment(html)

      [article_phx_click] =
        fragment
        |> LazyHTML.query("##{dom_id}")
        |> LazyHTML.attribute("phx-click")

      assert article_phx_click =~ "toggle_attr"
      assert article_phx_click =~ ~s(tool-trace-#{operation_id}-details)

      # JS toggle is on the article itself — no LiveComponent cid round-trip.
      assert LazyHTML.query(fragment, "##{dom_id}") |> LazyHTML.attribute("phx-target") == []

      assert has_element?(
               lv,
               "#tool-trace-#{operation_id}-expand[data-role='tool-trace-expand']:not([phx-click])"
             )

      # Details panel is rendered AND starts `hidden` — survives fresh
      # broadcast inserts (the original bug) and reloads alike.
      details =
        fragment
        |> LazyHTML.query("#tool-trace-#{operation_id}-details")

      [details_hidden] = LazyHTML.attribute(details, "hidden")
      assert details_hidden == "" or details_hidden == "hidden"
      assert html =~ ~s(data-role="tool-trace-details")
    end

    test "unknown messages are ignored without crashing", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      send(lv.pid, {:totally_unknown, 1, 2})
      # If this crashed, `render` would raise.
      assert render(lv) =~ ~s(id="studio-root")
    end
  end

  # ---------------------------------------------------------------------------
  # Cmd+K palette → "Set contract type…" → type-picker modal (bug #75).
  # Pushing `command_palette_picked` with `kind=set_contract_type` and no
  # `type_key` must NOT dispatch an Action (it would fail validation) — it
  # must open the type-picker modal on the ModalHost so the user can pick.
  # ---------------------------------------------------------------------------
  describe "dev/test operation block QA synthesis" do
    setup :log_in_a_user

    test "authenticated browser hook synthesizes a tool_call row with a client-side JS toggle", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      conn = post(conn, ~p"/test/studio/operation_blocks")
      assert %{"ok" => true, "operation_ids" => [operation_id | _]} = json_response(conn, 200)

      html = render(lv)
      fragment = LazyHTML.from_fragment(html)

      # The synthesized operation is a `tool_call`, so it renders via the
      # tool-trace branch of `operation_block` (codex-style inline row),
      # not the `<section data-role="operation-block">` branch.
      assert html =~ ~s(id="tool-trace-#{operation_id}")
      assert html =~ "Synthetic QA operation"
      # Details panel is rendered up-front + `hidden`; the article-level
      # JS toggle on the chat message flips it client-side.
      assert html =~ ~s(id="tool-trace-#{operation_id}-details")

      details =
        fragment
        |> LazyHTML.query("#tool-trace-#{operation_id}-details")

      [details_hidden] = LazyHTML.attribute(details, "hidden")
      assert details_hidden == "" or details_hidden == "hidden"

      [article_phx_click] =
        fragment
        |> LazyHTML.query("#chat-msg-#{operation_id}")
        |> LazyHTML.attribute("phx-click")

      assert article_phx_click =~ "toggle_attr"
      assert article_phx_click =~ ~s(tool-trace-#{operation_id}-details)
    end

    test "operation block QA synthesis requires an authenticated session" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> post(~p"/test/studio/operation_blocks")

      assert %{"ok" => false, "error" => "unauthenticated"} = json_response(conn, 401)
    end
  end

  describe "command_palette_picked → set_contract_type opens the type-picker" do
    setup :log_in_a_user

    test "without type_key, opens the type-picker modal and lists the supported contract types",
         %{conn: conn} do
      conn =
        Plug.Conn.put_session(
          conn,
          :user_perms,
          ~w(read write commit revoke export type_change)a
        )

      {:ok, lv, _html} = live(conn, ~p"/studio")

      html =
        render_hook(lv, "command_palette_picked", %{
          "kind" => "set_contract_type",
          "action_kind" => "set_contract_type"
        })

      # The type-picker modal renders with the data-role the Playwright
      # spec selects on (`[data-role="type-picker"]`).
      assert html =~ ~s(data-role="type-picker")
      assert html =~ ~s(data-modal="type_picker")
      assert html =~ ~s(data-role="type-picker-list")

      # All supported contract-type keys from the ContractTypes registry render
      # as rows. Sourcing from the registry keeps this list in sync with
      # priv/contract_types/*.toml.
      {:ok, specs} = Contract.ContractTypes.list()
      visible_specs = Enum.reject(specs, &(&1.source == :custom))
      assert length(visible_specs) == 3
      refute Enum.any?(specs, &(&1.key == "web_novel_v1"))
      refute Enum.any?(specs, &(&1.key == "franchise_v1"))
      refute Enum.any?(specs, &(&1.key == "franchise_chicken_v2024_12"))
      refute Enum.any?(specs, &(&1.key == "supply_v1"))
      refute html =~ ~s(data-type-key="web_novel_v1")
      refute html =~ ~s(phx-value-type_key="web_novel_v1")
      refute html =~ ~s(data-type-key="custom_v1")
      refute html =~ ~s(phx-value-type_key="custom_v1")
      refute html =~ ~s(data-type-key="franchise_v1")
      refute html =~ ~s(phx-value-type_key="franchise_v1")
      refute html =~ ~s(data-type-key="franchise_chicken_v2024_12")
      refute html =~ ~s(phx-value-type_key="franchise_chicken_v2024_12")
      refute html =~ ~s(data-type-key="supply_v1")
      refute html =~ ~s(phx-value-type_key="supply_v1")

      for %{key: key} <- visible_specs do
        assert html =~ ~s(data-type-key="#{key}")
        assert html =~ ~s(phx-value-type_key="#{key}")
      end
    end

    test "with a type_key, does not replace an already typed document",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      document_id = Ecto.UUID.generate()

      assert {:ok, %Contract.Change{document_id: ^document_id}} =
               Contract.Runtime.apply(scope, %Command{
                 kind: :create_document,
                 document_id: document_id,
                 actor_type: :user,
                 actor_id: user.id,
                 base_revision: 0,
                 payload: %{"title" => "typed", "type_key" => "employment_v1"}
               })

      conn =
        Plug.Conn.put_session(
          conn,
          :user_perms,
          ~w(read write commit revoke export type_change)a
        )

      {:ok, lv, _html} = live(conn, ~p"/studio/#{document_id}")
      assert assigns(lv).projection.type_key == "employment_v1"

      html =
        render_hook(lv, "command_palette_picked", %{
          "kind" => "set_contract_type",
          "type_key" => "service_agreement_v1"
        })

      refute html =~ ~s(data-role="type-picker")
      assert assigns(lv).projection.type_key == "employment_v1"
      assert Repo.get!(Contract.Documents.Document, document_id).type_key == "employment_v1"
    end

    test "typed document header renders an immutable type badge without replacement rows",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      document_id = Ecto.UUID.generate()

      assert {:ok, %Contract.Change{document_id: ^document_id}} =
               Contract.Runtime.apply(scope, %Command{
                 kind: :create_document,
                 document_id: document_id,
                 actor_type: :user,
                 actor_id: user.id,
                 base_revision: 0,
                 payload: %{"title" => "typed", "type_key" => "employment_v1"}
               })

      {:ok, lv, _html} = live(conn, ~p"/studio/#{document_id}")
      assert assigns(lv).projection.type_key == "employment_v1"

      assert has_element?(
               lv,
               ~s(#document-type-badge[data-role="document-type-badge"]),
               Contract.ContractTypes.display_name("employment_v1")
             )

      refute has_element?(lv, ~s(#document-type-picker))
      refute has_element?(lv, ~s([data-role="document-type-picker"]))
      refute has_element?(lv, ~s(button[phx-click="set_contract_type"]))
    end

    test "set_contract_type event leaves an already typed document unchanged",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      document_id = Ecto.UUID.generate()

      assert {:ok, %Contract.Change{document_id: ^document_id}} =
               Contract.Runtime.apply(scope, %Command{
                 kind: :create_document,
                 document_id: document_id,
                 actor_type: :user,
                 actor_id: user.id,
                 base_revision: 0,
                 payload: %{"title" => "typed", "type_key" => "employment_v1"}
               })

      {:ok, lv, _html} = live(conn, ~p"/documents/#{document_id}")
      assert assigns(lv).projection.type_key == "employment_v1"

      assert has_element?(
               lv,
               ~s(#document-type-badge[data-role="document-type-badge"]),
               Contract.ContractTypes.display_name("employment_v1")
             )

      html = render_hook(lv, "set_contract_type", %{"type_key" => "service_agreement_v1"})

      assert html =~ Contract.ContractTypes.display_name("employment_v1")
      assert assigns(lv).projection.type_key == "employment_v1"
      assert Repo.get!(Contract.Documents.Document, document_id).type_key == "employment_v1"

      assert has_element?(
               lv,
               ~s(#document-type-badge[data-role="document-type-badge"]),
               Contract.ContractTypes.display_name("employment_v1")
             )
    end
  end

  # ---------------------------------------------------------------------------
  # Document-pivot breadcrumb shape (SPEC.md 2026-05-15).
  #
  # The Studio trail is now 2-level: `Storage > Document.title` (or
  # `Storage > Studio` when no document is loaded). The Matter level
  # is gone from the breadcrumbs — Matter is internal context.
  # ---------------------------------------------------------------------------
  describe "Document-pivot — Studio breadcrumb trail is 2-level" do
    setup :log_in_a_user

    test "mounting /studio (no document) gives a 2-crumb trail: Storage > Studio",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      trail = :sys.get_state(lv.pid).socket.assigns.breadcrumbs

      assert length(trail) == 2
      assert Enum.at(trail, 0).label == "Storage"
      assert Enum.at(trail, 0).navigate == "/storage"
      assert Enum.at(trail, 1).label == "Studio"
      assert Enum.at(trail, 1).current? == true

      # Sanity — no crumb labelled "Matter" or with the seeded matter
      # name should ever appear.
      refute Enum.any?(trail, &(&1.label == "Matter"))
    end

    test "mounting a document route gives Storage > Document breadcrumbs", %{
      conn: conn,
      user: user
    } do
      scope = Contract.Context.for_user(user)
      {:ok, doc} = Contract.Documents.create(scope, %{title: "Breadcrumb draft"})
      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

      trail = :sys.get_state(lv.pid).socket.assigns.breadcrumbs

      assert length(trail) == 2
      assert Enum.at(trail, 0).label == "Storage"
      assert Enum.at(trail, 0).navigate == "/storage"
      assert Enum.at(trail, 1).label == "Breadcrumb draft"
      refute Enum.any?(trail, &(&1.label == "Matter"))
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp stub_blocking_agent_stream(parent, chunks \\ []) do
    Contract.IO.OpenAIMock
    |> stub(:stream_chat, fn _params, _opts ->
      stream =
        Stream.resource(
          fn ->
            send(parent, {:agent_stream_started, self()})
            :running
          end,
          fn
            :running ->
              receive do
                :release_stream ->
                  {build_stream(chunks), :done}
              after
                5_000 ->
                  {[], :running}
              end

            :done ->
              {:halt, :done}
          end,
          fn _ -> :ok end
        )

      {:ok, %{stream: stream, task_pid: self()}}
    end)
  end

  defp build_stream(chunks) do
    Enum.map(chunks, fn chunk ->
      %{type: "response.output_text.delta", data: %{"delta" => chunk}}
    end)
  end

  defp log_in_a_user(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp base_assigns(_ctx) do
    user = %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "x@example.com"}
    scope = Contract.Context.for_user(user)
    state = %State{mode: :no_document, last_seen_revision: 0}
    %{assigns: %{current_scope: scope, studio_state: state}}
  end

  defp put_doc(assigns, doc) do
    %State{} = state = assigns.studio_state
    new_state = %{state | selected_document_id: doc, last_seen_revision: 1, mode: :editing}
    %{assigns | studio_state: new_state}
  end

  defp assigns(lv) do
    :sys.get_state(lv.pid).socket.assigns
  end

  defp send_state(lv, %State{} = state) do
    send(lv.pid, {:studio_loaded, state})
    _ = render(lv)
    :ok
  end

  # Creates a document and lands a single `:create_node` op so the
  # projection has a real paragraph (`map_size(projection.nodes) > 0`).
  defp seed_document_with_paragraph(user, content) do
    scope = Contract.Context.for_user(user)

    {:ok, doc} =
      Contract.Documents.create(scope, %{
        "title" => "seeded-doc-#{System.unique_integer([:positive])}",
        "type_key" => "nda_v1"
      })

    command = %Command{
      kind: :edit_document,
      actor_type: :user,
      actor_id: user.id,
      document_id: doc.id,
      base_revision: 0,
      idempotency_key: "seed-paragraph-#{Ecto.UUID.generate()}",
      payload: %{
        "ops" => [
          %{
            "op" => "create_node",
            "target_type" => "node",
            "target_id" => "node-1",
            "args" => %{
              "kind" => "paragraph",
              "content" => content
            }
          }
        ]
      }
    }

    {:ok, %Contract.Change{}} = Contract.Runtime.apply(scope, command)
    doc
  end

  defp create_typed_document!(scope, title) do
    document_id = Ecto.UUID.generate()

    command = %Command{
      kind: :create_document,
      actor_type: :user,
      actor_id: scope.user.id,
      document_id: document_id,
      base_revision: 0,
      idempotency_key: "create-typed-#{document_id}",
      payload: %{"title" => title, "type_key" => "nda_v1"}
    }

    {:ok, %Contract.Change{}} = Contract.Runtime.apply(scope, command)
    document_id
  end

  defp update_document_metadata!(scope, document_id, base_revision) do
    command = %Command{
      kind: :update_metadata,
      actor_type: :user,
      actor_id: scope.user.id,
      document_id: document_id,
      base_revision: base_revision,
      idempotency_key: "snapshot-freshness-metadata-#{Ecto.UUID.generate()}",
      payload: %{"metadata" => %{"snapshot_test" => true}}
    }

    {:ok, %Contract.Change{}} = Contract.Runtime.apply(scope, command)
  end

  defp insert_rhwp_snapshot!(document_id, revision) do
    Repo.insert!(%RhwpSnapshotRecord{
      document_id: document_id,
      revision: revision,
      format: "hwp",
      content_type: "application/x-hwp",
      r2_key: "documents/#{document_id}/snapshots/#{revision}.hwp",
      ir_r2_key: "documents/#{document_id}/snapshots/#{revision}.ir.json",
      projection: %{"revision" => revision}
    })
  end

  defp seed_thread_with_user_message(user, document, message_text) do
    %ChatThread{}
    |> ChatThread.changeset(%{
      owner_id: user.id,
      document_id: document.id,
      title: "Discussion",
      messages: [
        %{
          "id" => Ecto.UUID.generate(),
          "role" => "user",
          "content" => message_text,
          "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
        }
      ],
      status: "active",
      last_message_at: DateTime.utc_now(:second)
    })
    |> Repo.insert!()
  end

  # Polls a predicate up to ~1 second. Used to ride out the async
  # round-trip between mount-time grill seed dispatch and the
  # `agent_run_id` landing on `studio_state`.
  defp eventually(fun, retries \\ 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, retries) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, retries - 1)
    end
  end
end
