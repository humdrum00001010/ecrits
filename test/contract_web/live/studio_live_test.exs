defmodule ContractWeb.StudioLiveTest do
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures
  import Ecto.Query
  import Mox

  alias Contract.ChatThread
  alias Contract.Command
  alias Contract.Repo
  alias Contract.SourceClaim
  alias Contract.SourceDocument
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

    test "mounts at /studio (no params) with no document",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.current_document_id == nil
      assert assigns.studio_state.selected_document_id == nil
    end

    test "DocumentScope threads :user_perms from session onto current_scope.perms (lawyer-style) and unlocks Canvas.Empty actions",
         %{conn: conn} do
      # Persona sign-in (TestAuthController) writes :user_perms into the
      # session. Simulate that here — the lawyer-shaped perm set must
      # land on current_scope and unlock the Canvas.Empty actions.
      lawyer_perms = ~w(read write commit revoke export type_change agent_run)a
      conn = Plug.Conn.put_session(conn, :user_perms, lawyer_perms)

      {:ok, lv, html} = live(conn, ~p"/studio")

      assert :sys.get_state(lv.pid).socket.assigns.current_scope.perms == lawyer_perms
      # Per 2026-05-17 owner directive, the empty state hosts the four
      # onboarding affordances: upload + blank + recent + discuss.
      assert html =~ "빈 문서로 시작"
      assert html =~ "계약서 업로드"
      assert html =~ "최근 문서 열기"
      assert html =~ "에이전트와 먼저 상의하기"
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

    test "no-document chat.submit persists a ChatThread message and reloads it", %{
      conn: conn,
      user: user
    } do
      stub_agent_response("I can help frame the discussion before a draft exists.")

      {:ok, lv, _html} = live(conn, ~p"/studio")

      message = "Let us discuss a distribution agreement before drafting."

      html =
        lv
        |> form("#chat-rail-form", %{"message" => message})
        |> render_submit()

      assert html =~ message

      thread =
        Repo.one!(
          from t in ChatThread,
            where: t.owner_id == ^user.id and is_nil(t.document_id),
            order_by: [desc: t.inserted_at],
            limit: 1
        )

      assert [%{"role" => "user", "content" => ^message, "id" => message_id}] =
               Enum.take(thread.messages, 1)

      assert is_binary(message_id)
      assert thread.last_message_at

      {:ok, _reloaded_lv, reloaded_html} = live(conn, ~p"/studio")

      assert reloaded_html =~ message
      assert reloaded_html =~ ~s(id="chat-msg-#{message_id}")
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

    test "toggle_preview is a no-op on desktop layout (mobile-only button)",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      assert :sys.get_state(lv.pid).socket.assigns.preview_modal_open? == false
      _ = render_hook(lv, "toggle_preview", %{})
      assert :sys.get_state(lv.pid).socket.assigns.preview_modal_open? == true
    end
  end

  # ---------------------------------------------------------------------------
  # SPEC.md §10 — no-document agent prompt (Wave Document-Pivot Impl D)
  # ---------------------------------------------------------------------------
  describe "agent_option_picked (no-document quick-start, SPEC.md §10)" do
    setup :log_in_a_user

    test "renders the 5-option no-document welcome at /studio (no doc selected)",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio")

      assert html =~ ~s(data-role="chat-no-doc-welcome")
      # All 5 chip keys are present.
      assert html =~ ~s(phx-value-key="upload")
      assert html =~ ~s(phx-value-key="recent")
      assert html =~ ~s(phx-value-key="blank")
      assert html =~ ~s(phx-value-key="draft_from_discussion")
      assert html =~ ~s(phx-value-key="variant_from_other")
    end

    test "upload option opens the upload modal", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      assert :sys.get_state(lv.pid).socket.assigns.studio_state.upload_panel_open? == false

      _ = render_hook(lv, "agent_option_picked", %{"key" => "upload"})

      assert :sys.get_state(lv.pid).socket.assigns.studio_state.upload_panel_open? == true
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

    test "document.edit → :edit_document", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Command{kind: :edit_document}} =
               StudioLive.event_to_command("document.edit", %{"ops" => []}, assigns)
    end

    test "chat.submit → :chat_message (document not required)",
         %{assigns: assigns} do
      assert {:ok, %Command{kind: :chat_message}} =
               StudioLive.event_to_command("chat.submit", %{"message" => "hi"}, assigns)
    end

    test "change.revoke → :revoke_change", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Command{kind: :revoke_change, change_id: "x"}} =
               StudioLive.event_to_command("change.revoke", %{"change_id" => "x"}, assigns)
    end

    test "change.revoke without change_id is rejected", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:error, {:missing_change_id, :revoke_change}} =
               StudioLive.event_to_command("change.revoke", %{}, assigns)
    end

    test "document.upload → :upload_document (document not required)",
         %{assigns: assigns} do
      assert {:ok, %Command{kind: :upload_document}} =
               StudioLive.event_to_command("document.upload", %{"upload" => %{}}, assigns)
    end

    test "source_claim.unlink → :source_claim_unlink_from_document", %{assigns: assigns} do
      claim_id = Ecto.UUID.generate()

      assert {:ok, %Command{kind: :source_claim_unlink_from_document, source_claim_id: ^claim_id}} =
               StudioLive.event_to_command(
                 "source_claim.unlink",
                 %{"source_claim_id" => claim_id},
                 assigns
               )
    end

    test "conversion.create_variant → :create_converted_variant", %{assigns: assigns} do
      assert {:ok, %Command{kind: :create_converted_variant}} =
               StudioLive.event_to_command("conversion.create_variant", %{}, assigns)
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

    test "export.request → :request_export", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Command{kind: :request_export}} =
               StudioLive.event_to_command("export.request", %{"format" => "pdf"}, assigns)
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
      assert :local = StudioLive.event_to_command("toggle_preview", %{}, assigns)
      assert :local = StudioLive.event_to_command("open_modal", %{}, assigns)
      assert :local = StudioLive.event_to_command("close_modal", %{}, assigns)
      assert :local = StudioLive.event_to_command("set_node_focus", %{}, assigns)
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

  describe "conversion wizard events (Wave 4)" do
    setup :log_in_a_user

    test "start_type_conversion with a real source document builds a plan and flips migration_panel_open?",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "title" => "src",
          "type_key" => "nda_v1"
        })

      # Give the LV the lawyer-style perms via session.
      conn =
        Plug.Conn.put_session(conn, :user_perms, ~w(read write commit revoke export type_change)a)

      {:ok, lv, _html} = live(conn, ~p"/studio")

      # Seed selected document.
      send_state(lv, %State{
        selected_document_id: doc.id,
        mode: :editing,
        last_seen_revision: 0
      })

      _ =
        render_hook(lv, "conversion.start", %{
          "target_type_key" => "service_agreement_v1"
        })

      assert assigns(lv).studio_state.migration_panel_open? == true

      assert %Contract.Conversion.Plan{target_type_key: "service_agreement_v1"} =
               assigns(lv).migration_plan
    end

    test "start_type_conversion without a selected document flashes an error",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      html =
        render_hook(lv, "conversion.start", %{"target_type_key" => "nda_v1"})

      assert html =~ "No document selected"
    end

    test "start_type_conversion without target flashes an error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      # Seed selected document.
      send_state(lv, %State{
        selected_document_id: Ecto.UUID.generate(),
        mode: :editing,
        last_seen_revision: 0
      })

      html = render_hook(lv, "conversion.start", %{"target_type_key" => ""})
      assert html =~ "target type"
    end

    test "create_variant without a plan flashes an error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      html = render_hook(lv, "conversion.create_variant", %{})
      assert html =~ "No active conversion plan"
    end

    test "set_field_migration_strategy without a plan flashes an error",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      html =
        render_hook(lv, "conversion.field_strategy.set", %{
          "source_field_id" => "party_a",
          "strategy" => "copy_once"
        })

      assert html =~ "No active conversion plan"
    end

    # Wave 4 bugfix #2 + #4: when the wizard opens, the parent LV must
    # have a populated `migration_plan` AND the rendered summary card
    # must use a hairline accent (no emerald block fill — per
    # `feedback-mature-visual-language`).
    test "start_type_conversion renders plan summary with hairline accent (no emerald block)",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "title" => "src-bug-4",
          "type_key" => "nda_v1"
        })

      conn =
        Plug.Conn.put_session(
          conn,
          :user_perms,
          ~w(read write commit revoke export type_change)a
        )

      {:ok, lv, _html} = live(conn, ~p"/studio")

      send_state(lv, %State{
        selected_document_id: doc.id,
        mode: :editing,
        last_seen_revision: 0
      })

      html =
        render_hook(lv, "conversion.start", %{
          "target_type_key" => "service_agreement_v1"
        })

      # Bug 2 — plan is populated.
      plan = assigns(lv).migration_plan
      assert %Contract.Conversion.Plan{target_type_key: "service_agreement_v1"} = plan

      # The wizard must be visible (parent flag flipped).
      assert assigns(lv).studio_state.migration_panel_open? == true
      assert html =~ ~s(data-modal="migration")

      # Bug 4 — restrained hairline summary, NOT a full emerald block.
      assert html =~ ~s(data-role="migration-plan-summary")
      assert html =~ ~s(border-l-2 border-primary)
      refute html =~ "alert alert-success"
      # The previous emerald-block class combo was `bg-primary
      # text-primary-content` on the summary card itself. The header's
      # "CS" badge uses that combo legitimately (small avatar circle),
      # so scope the negative assertion to the summary div.
      [_, summary_chunk] = String.split(html, ~s(data-role="migration-plan-summary"), parts: 2)
      [card_chunk, _] = String.split(summary_chunk, "</div>", parts: 2)
      refute card_chunk =~ "bg-primary text-primary-content"
      refute card_chunk =~ "bg-success"
    end

    # Wave 4 bugfix #5: the Canvas.Editor hook now sends an Engine-shaped
    # `:edit_document` payload (`%{"ops" => [%{"op" => "replace_content", ...}]}`).
    # The parent LV must accept that shape end-to-end — `Studio.submit/3`
    # → `Engine.compile/2` → a Change row landing — without crashing.
    test "edit_document with Engine-shaped ops payload lands a Change row",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "title" => "edit-bug-5-doc",
          "type_key" => "nda_v1"
        })

      conn =
        Plug.Conn.put_session(
          conn,
          :user_perms,
          ~w(read write commit revoke export type_change)a
        )

      {:ok, lv, _html} = live(conn, ~p"/studio")

      send_state(lv, %State{
        selected_document_id: doc.id,
        mode: :editing,
        last_seen_revision: 0
      })

      # Push the realistic payload the hook now sends.
      _ =
        render_hook(lv, "edit_document", %{
          "ops" => [
            %{
              "op" => "replace_content",
              "target_type" => "node",
              "target_id" => "node-1",
              "args" => %{"content" => "hello world"}
            }
          ]
        })

      # The LV must not crash; assigns must remain coherent.
      assigns = assigns(lv)
      assert %State{} = assigns.studio_state
      assert assigns.studio_state.selected_document_id == doc.id
    end

    # Wave 4 bugfix #74 — clean-revoke (Cmd+Z) keyboard path.
    # An `edit_document` followed by a `revoke_change` carrying the
    # committed change's id must drive the parent LV through
    # `Studio.submit → Engine.compile → Store.append`, producing a
    # revoke `Change` row. The Playwright `clean-revoke.spec.ts` Cmd+Z
    # flow rides exactly this path — this test pins the server side
    # contract that the Editor hook depends on (without it, the hook's
    # cached lastChangeId would be useless).
    #
    # Status-flip of the original change to `:revoked` is a separate
    # Store concern (not driven from this LV path); this test asserts
    # only what the LV + Engine compile path is responsible for.
    test "edit_document then revoke_change for the same node lands a revoke Change row",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "title" => "revoke-key-74-doc",
          "type_key" => "nda_v1"
        })

      conn =
        Plug.Conn.put_session(
          conn,
          :user_perms,
          ~w(read write commit revoke export type_change)a
        )

      {:ok, lv, _html} = live(conn, ~p"/studio")

      send_state(lv, %State{
        selected_document_id: doc.id,
        mode: :editing,
        last_seen_revision: 0
      })

      # 1. Land an edit (the same Engine-shaped payload the hook sends).
      _ =
        render_hook(lv, "edit_document", %{
          "ops" => [
            %{
              "op" => "replace_content",
              "target_type" => "node",
              "target_id" => "node-effective-date",
              "args" => %{"content" => "2026-01-01"}
            }
          ]
        })

      # The edit MUST be in the store; grab its id so we can revoke it.
      {:ok, changes_after_edit} = Contract.Store.changes_since(doc.id, 0)

      edit_change =
        Enum.find(changes_after_edit, fn c -> c.command_kind == "edit_document" end)

      assert edit_change,
             "edit_document must produce a Change row " <>
               "(got: #{inspect(Enum.map(changes_after_edit, & &1.command_kind))})"

      # The LV pushes editor:last-change to the hook as soon as the
      # change_committed PubSub round-trip lands. Drive the protocol
      # message directly here because `render_hook` returns before the
      # async broadcast is delivered.
      send(lv.pid, {:change_committed, edit_change})
      _ = render(lv)

      # 2. Simulate Cmd+Z by firing the same event the hook would push.
      _ =
        render_hook(lv, "change.revoke", %{
          "change_id" => edit_change.id,
          "node_id" => "node-effective-date"
        })

      # 3. The store now holds a revoke change pointing at the original.
      {:ok, after_undo} = Contract.Store.changes_since(doc.id, 0)

      revoke_change =
        Enum.find(after_undo, fn c ->
          c.command_kind == "revoke_change"
        end)

      assert revoke_change,
             "revoke_change event must land a revoke Change row " <>
               "(got kinds: #{inspect(Enum.map(after_undo, & &1.command_kind))})"

      # The revoke's explain mark targets the change_id we intended to
      # undo (engine.ex `build_ops_and_marks/:revoke_change`). This is
      # the contract the editor hook's Cmd+Z relies on: the change_id
      # it pushes must match the original edit it means to revoke.
      revoked_target =
        (revoke_change.marks || [])
        |> Enum.find_value(fn
          %{target_type: "change", target_id: id} -> id
          %{"target_type" => "change", "target_id" => id} -> id
          %{target_type: :change, target_id: id} -> id
          _ -> nil
        end)

      assert revoked_target == edit_change.id,
             "revoke Change must target the original edit by id " <>
               "(target=#{inspect(revoked_target)}, expected=#{edit_change.id})"

      # The original edit row must still be retrievable (its status flip
      # to `:revoked` is a separate Store-side concern).
      original = Enum.find(after_undo, fn c -> c.id == edit_change.id end)
      assert original, "the original edit Change must still be present"
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

    test "{:revoke_requested, _} opens the reconcile modal", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      send(lv.pid, {:revoke_requested, %{id: "r1"}})
      _ = render(lv)
      assert assigns(lv).reconcile_modal_open? == true
    end

    test "{:change_reconciled, change} closes the reconcile modal", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      send(lv.pid, {:revoke_requested, %{id: "r1"}})
      _ = render(lv)
      assert assigns(lv).reconcile_modal_open? == true

      change = %Contract.Change{
        id: Ecto.UUID.generate(),
        command_kind: "resolve_revoke",
        result_revision: 2
      }

      send(lv.pid, {:change_reconciled, change})
      _ = render(lv)
      assert assigns(lv).reconcile_modal_open? == false
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

    test "tool-call protocol messages render structured operation blocks", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      run_id = Ecto.UUID.generate()
      tool_id = Ecto.UUID.generate()

      send(lv.pid, {:tool_call_started, run_id, %{id: tool_id, tool_name: "law.search"}})
      html = render(lv)

      assert html =~ ~s(id="operation-block-tool-#{run_id}-#{tool_id}")
      assert html =~ ~s(data-role="operation-block")
      assert html =~ ~s(data-operation-type="tool_call")
      assert html =~ ~s(data-operation-status="running")
      assert html =~ "law.search"
      refute html =~ "Tool started: law.search"

      send(lv.pid, {:tool_call_completed, run_id, tool_id, %{summary: "Found 2 clauses"}})
      html = render(lv)

      assert html =~ ~s(id="operation-block-tool-#{run_id}-#{tool_id}")
      assert html =~ ~s(data-operation-status="completed")
      assert html =~ "Found 2 clauses"
    end

    test "uploaded source document renders interpretation and claim operation blocks", %{
      conn: conn
    } do
      old_drivers = Application.get_env(:contract, :io_drivers, [])

      Application.put_env(
        :contract,
        :io_drivers,
        old_drivers
        |> Keyword.put(:r2, Contract.IO.R2Stub)
        |> Keyword.put(:upstage, Contract.IO.DeterministicParser)
      )

      Contract.IO.R2Stub.reset()

      on_exit(fn ->
        Application.put_env(:contract, :io_drivers, old_drivers)
        Contract.IO.R2Stub.reset()
      end)

      tmp =
        Path.join(
          System.tmp_dir!(),
          "studio-source-upload-#{System.unique_integer([:positive])}.txt"
        )

      File.write!(tmp, "Effective Date: 2026-01-01\nParty A: Acme Corp\n")

      upload = %{
        path: tmp,
        client_name: "counterparty.txt",
        client_type: "text/plain",
        client_size: File.stat!(tmp).size
      }

      {:ok, lv, _html} = live(conn, ~p"/studio")
      html = render_hook(lv, "document.upload", %{"upload" => upload})

      assert html =~ ~s(data-role="source-interpretation-block")
      assert html =~ ~s(data-role="source-claim-block")
      assert html =~ "effective_date"
      assert html =~ "party_a"
      refute html =~ ~s(data-operation-status="parsing")
    end

    test "source-document protocol messages render structured operation blocks", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      source_id = Ecto.UUID.generate()

      send(lv.pid, {:source_document_uploaded, %{id: source_id, title: "Counterparty draft"}})
      html = render(lv)
      assert html =~ ~s(id="operation-block-source-#{source_id}")
      assert html =~ ~s(data-operation-type="source_interpretation")
      assert html =~ ~s(data-operation-status="uploaded")
      assert html =~ "Counterparty draft"

      send(lv.pid, {:source_document_parse_started, source_id})
      html = render(lv)
      assert html =~ ~s(data-operation-status="parsing")

      send(lv.pid, {:source_document_parsed, %{id: source_id, title: "Counterparty draft"}})
      html = render(lv)
      assert html =~ ~s(data-operation-status="parsed")

      claims = [%{id: "claim-1"}, %{id: "claim-2"}]
      send(lv.pid, {:source_interpretation_ready, source_id, claims})
      html = render(lv)
      assert html =~ ~s(id="operation-block-source-#{source_id}-interpretation")
      assert html =~ ~s(data-operation-status="ready")
      assert html =~ "2 claims"

      send(lv.pid, {:source_claim_updated, %{id: "claim-1", status: :confirmed}})
      html = render(lv)
      assert html =~ ~s(id="operation-block-source-claim-claim-1")
      assert html =~ ~s(data-operation-type="source_claim")
      assert html =~ ~s(data-operation-status="confirmed")
    end

    test "source claim controls refresh operation status immediately and after reload", %{
      conn: conn,
      user: user
    } do
      scope = Contract.Context.for_user(user)
      {:ok, document} = Contract.Documents.create(scope, %{title: "Working draft"})
      {:ok, source_document, claim} = seed_source_claim(user, document)
      seed_source_claim_thread(user, document, source_document, claim)

      {:ok, lv, html} = live(conn, ~p"/documents/#{document.id}")
      assert html =~ ~s(id="operation-block-source-claim-#{claim.id}")
      assert html =~ ~s(data-operation-status="proposed")

      html =
        render_hook(lv, "source_claim.confirm", %{
          "source_claim_id" => claim.id,
          "source_document_id" => source_document.id
        })

      assert html =~ ~s(data-operation-status="confirmed")

      html =
        render_hook(lv, "source_claim.reject", %{
          "source_claim_id" => claim.id,
          "source_document_id" => source_document.id,
          "reason" => "wrong field"
        })

      assert html =~ ~s(data-operation-status="rejected")

      html =
        render_hook(lv, "source_claim.link_to_document", %{
          "source_claim_id" => claim.id,
          "source_document_id" => source_document.id,
          "node_id" => "node-effective-date",
          "field_id" => "effective_date"
        })

      assert html =~ ~s(data-operation-status="linked")

      html =
        render_hook(lv, "source_claim.unlink", %{
          "source_claim_id" => claim.id,
          "source_document_id" => source_document.id
        })

      assert html =~ ~s(data-operation-status="unlinked")

      {:ok, _reloaded, reloaded_html} = live(conn, ~p"/documents/#{document.id}")
      assert reloaded_html =~ ~s(data-operation-status="unlinked")
    end

    test "evidence and export-started protocol messages render structured operation blocks", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      evidence_id = Ecto.UUID.generate()
      export_id = Ecto.UUID.generate()

      send(lv.pid, {:evidence_created, %{id: evidence_id, summary: "Article 12 citation"}})
      html = render(lv)
      assert html =~ ~s(id="operation-block-evidence-#{evidence_id}")
      assert html =~ ~s(data-operation-type="evidence")
      assert html =~ ~s(data-operation-status="created")
      assert html =~ "Article 12 citation"

      send(
        lv.pid,
        {:evidence_attached, %{id: evidence_id, summary: "Article 12 citation"}, %{id: "mark-1"}}
      )

      html = render(lv)
      assert html =~ ~s(id="operation-block-evidence-#{evidence_id}-attached-mark-1")
      assert html =~ ~s(data-operation-status="attached")

      send(lv.pid, {:export_started, export_id})
      html = render(lv)
      assert html =~ ~s(id="operation-block-export-#{export_id}")
      assert html =~ ~s(data-operation-type="export_status")
      assert html =~ ~s(data-operation-status="started")
      assert html =~ String.slice(export_id, 0, 8)
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

    test "authenticated browser hook synthesizes operation blocks that can expand", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      conn = post(conn, ~p"/test/studio/operation_blocks")
      assert %{"ok" => true, "operation_ids" => [operation_id | _]} = json_response(conn, 200)

      html = render(lv)
      assert html =~ ~s(id="operation-block-#{operation_id}")
      assert html =~ ~s(data-role="operation-block")
      assert html =~ ~s(id="operation-block-#{operation_id}-toggle")
      refute html =~ ~s(id="operation-block-#{operation_id}-details")

      html =
        lv
        |> element("#operation-block-#{operation_id}-toggle")
        |> render_click()

      assert html =~ ~s(id="operation-block-#{operation_id}-details")
      assert html =~ "Synthetic QA operation"
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

    test "without type_key, opens the type-picker modal and lists all 5 contract types",
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

      # All 5 contract-type keys from the ContractTypes registry render
      # as rows. Sourcing from the registry keeps this list in sync with
      # priv/contract_types/*.toml.
      {:ok, specs} = Contract.ContractTypes.list()
      assert length(specs) == 5

      for %{key: key} <- specs do
        assert html =~ ~s(data-type-key="#{key}")
        assert html =~ ~s(phx-value-type_key="#{key}")
      end
    end

    test "with a type_key, dispatches the set_contract_type Action (no modal)",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "title" => "src",
          "type_key" => "nda_v1"
        })

      conn =
        Plug.Conn.put_session(
          conn,
          :user_perms,
          ~w(read write commit revoke export type_change)a
        )

      {:ok, lv, _html} = live(conn, ~p"/studio")

      send_state(lv, %State{
        selected_document_id: doc.id,
        mode: :editing,
        last_seen_revision: 0
      })

      html =
        render_hook(lv, "command_palette_picked", %{
          "kind" => "set_contract_type",
          "type_key" => "franchise_v1"
        })

      # No type-picker modal — the Action dispatched directly.
      refute html =~ ~s(data-role="type-picker")
    end
  end

  # ---------------------------------------------------------------------------
  # Document-pivot breadcrumb shape (SPEC.md 2026-05-15).
  #
  # The Studio trail is now 2-level: `Dashboard > Document.title` (or
  # `Dashboard > Studio` when no document is loaded). The Matter level
  # is gone from the breadcrumbs — Matter is internal context.
  # ---------------------------------------------------------------------------
  describe "Document-pivot — Studio breadcrumb trail is 2-level" do
    setup :log_in_a_user

    test "mounting /studio (no document) gives a 2-crumb trail: Dashboard > Studio",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      trail = :sys.get_state(lv.pid).socket.assigns.breadcrumbs

      assert length(trail) == 2
      assert Enum.at(trail, 0).label == "Dashboard"
      assert Enum.at(trail, 1).label == "Studio"
      assert Enum.at(trail, 1).current? == true

      # Sanity — no crumb labelled "Matter" or with the seeded matter
      # name should ever appear.
      refute Enum.any?(trail, &(&1.label == "Matter"))
    end

    test "mounting a document route gives Dashboard > Document breadcrumbs", %{
      conn: conn,
      user: user
    } do
      scope = Contract.Context.for_user(user)
      {:ok, doc} = Contract.Documents.create(scope, %{title: "Breadcrumb draft"})
      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

      trail = :sys.get_state(lv.pid).socket.assigns.breadcrumbs

      assert length(trail) == 2
      assert Enum.at(trail, 0).label == "Dashboard"
      assert Enum.at(trail, 1).label == "Breadcrumb draft"
      refute Enum.any?(trail, &(&1.label == "Matter"))
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp stub_agent_response(message) do
    payload =
      Jason.encode!(%{
        "mode" => "grill",
        "questions" => [],
        "ops" => [],
        "marks" => [],
        "message" => message
      })

    Contract.IO.OpenAIMock
    |> stub(:stream_chat, fn _params, _opts ->
      stream = [%{type: "response.output_text.delta", data: %{"delta" => payload}}]
      {:ok, %{stream: stream, task_pid: self()}}
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

  defp seed_source_claim(user, document) do
    {:ok, source_document} =
      %SourceDocument{}
      |> SourceDocument.changeset(%{
        owner_id: user.id,
        document_id: document.id,
        blob_ref_id: Ecto.UUID.generate(),
        status: "ready"
      })
      |> Repo.insert()

    {:ok, claim} =
      %SourceClaim{}
      |> SourceClaim.changeset(%{
        source_document_id: source_document.id,
        region_id: "region-effective-date",
        proposed_kind: "effective_date",
        proposed_value: "2026-01-01",
        confidence: Decimal.new("0.91")
      })
      |> Repo.insert()

    {:ok, source_document, claim}
  end

  defp seed_source_claim_thread(user, document, source_document, claim) do
    message = %{
      "id" => "source-claim-#{claim.id}",
      "role" => "assistant",
      "content" => "",
      "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second)),
      "operation" => %{
        "id" => "source-claim-#{claim.id}",
        "type" => "source_claim",
        "title" => "Effective date",
        "status" => "proposed",
        "details" => %{
          "source_claim_id" => claim.id,
          "source_document_id" => source_document.id,
          "proposed_kind" => claim.proposed_kind,
          "proposed_value" => claim.proposed_value
        }
      }
    }

    %ChatThread{}
    |> ChatThread.changeset(%{
      owner_id: user.id,
      document_id: document.id,
      title: "Discussion",
      messages: [message],
      status: "active",
      last_message_at: DateTime.utc_now(:second)
    })
    |> Repo.insert!()
  end

  defp assigns(lv) do
    :sys.get_state(lv.pid).socket.assigns
  end

  defp send_state(lv, %State{} = state) do
    send(lv.pid, {:studio_loaded, state})
    _ = render(lv)
    :ok
  end
end
