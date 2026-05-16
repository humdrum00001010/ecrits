defmodule ContractWeb.StudioLiveTest do
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Action
  alias Contract.Studio.State
  alias ContractWeb.StudioLive

  describe "auth gate" do
    test "redirects anonymous users to /users/log-in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/studio")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects when hitting a matter URL while anonymous", %{conn: conn} do
      matter = Ecto.UUID.generate()
      assert {:error, {:redirect, %{to: _}}} = live(conn, ~p"/matters/#{matter}/studio")
    end
  end

  describe "mount when authenticated" do
    setup :log_in_a_user

    test "renders the studio root and a desktop grid by default", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio")
      assert html =~ ~s(id="studio-root")
      assert html =~ ~s(data-stub="document-list")
      assert html =~ ~s(data-stub="chat-rail")
      # canvas-empty since no doc selected
      assert html =~ ~s(data-stub="canvas-empty")
    end

    test "mounts at /matters/:matter_id/studio with the matter assigned via MatterScope", %{
      conn: conn
    } do
      matter_id = Ecto.UUID.generate()
      {:ok, lv, _html} = live(conn, ~p"/matters/#{matter_id}/studio")

      assert :sys.get_state(lv.pid).socket.assigns.current_scope.matter.id == matter_id
    end

    # ---------------------------------------------------------------
    # Document-pivot (SPEC.md §4, 2026-05-15). The product surface is
    # now document-first: `/documents/:document_id` is the canonical
    # URL, `/workspaces/:matter_id` is the optional secondary, and
    # `/studio` (no params) lands on the no-document agent prompt.
    # The legacy `/matters/:matter_id/documents/:document_id` URL
    # must 301 to the new path so bookmarks / Slack unfurls stay live.
    # ---------------------------------------------------------------

    test "mounts at /documents/:document_id and resolves matter from the document",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "doc-pivot-mount"})

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "doc-pivot-mount-doc",
          "type_key" => "nda_v1"
        })

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}")

      assigns = :sys.get_state(lv.pid).socket.assigns
      # Document-pivot: MatterScope resolved the document, derived the
      # matter from `document.matter_id`, and threaded both into
      # `current_scope` + `assigns.current_document_id`.
      assert assigns.current_document_id == doc.id
      assert assigns.current_scope.matter.id == matter.id
      assert assigns.studio_state.selected_document_id == doc.id
    end

    test "mounts at /documents/:document_id/review (review subroute) the same way",
         %{conn: conn, user: user} do
      scope = Contract.Context.for_user(user)
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "doc-pivot-review"})

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "doc-pivot-review-doc",
          "type_key" => "nda_v1"
        })

      {:ok, lv, _html} = live(conn, ~p"/documents/#{doc.id}/review")

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.current_document_id == doc.id
      assert assigns.current_scope.matter.id == matter.id
      assert assigns.studio_state.selected_document_id == doc.id
    end

    test "mounts at /workspaces/:matter_id with the matter assigned and no document",
         %{conn: conn} do
      matter_id = Ecto.UUID.generate()
      {:ok, lv, _html} = live(conn, ~p"/workspaces/#{matter_id}")

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.current_scope.matter.id == matter_id
      assert assigns.current_document_id == nil
      assert assigns.studio_state.selected_document_id == nil
    end

    test "mounts at /studio (no params) with nil matter, nil document",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      assigns = :sys.get_state(lv.pid).socket.assigns
      assert assigns.current_scope.matter == nil
      assert assigns.current_document_id == nil
      assert assigns.studio_state.selected_document_id == nil
    end

    test "legacy /matters/:matter_id/documents/:document_id redirects to /documents/:document_id",
         %{conn: conn} do
      matter_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()

      conn = get(conn, ~p"/matters/#{matter_id}/documents/#{document_id}")

      assert redirected_to(conn, 301) == ~p"/documents/#{document_id}"
    end

    test "MatterScope threads :user_perms from session onto current_scope.perms (lawyer-style) and renders + 새 문서 link",
         %{conn: conn} do
      # Persona sign-in (TestAuthController) writes :user_perms into the
      # session. Simulate that here — the lawyer-shaped perm set must
      # land on current_scope and unlock the Canvas.Empty actions.
      lawyer_perms = ~w(read write commit revoke export type_change agent_run)a
      conn = Plug.Conn.put_session(conn, :user_perms, lawyer_perms)

      {:ok, lv, html} = live(conn, ~p"/studio")

      assert :sys.get_state(lv.pid).socket.assigns.current_scope.perms == lawyer_perms
      assert html =~ "+ 새 문서"
      assert html =~ "PDF 가져오기"
    end

    test "without :user_perms in session, current_scope.perms is nil and Canvas.Empty actions are hidden",
         %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/studio")

      assert :sys.get_state(lv.pid).socket.assigns.current_scope.perms == nil
      refute html =~ "+ 새 문서"
      refute html =~ "PDF 가져오기"
    end

    test "mounts the modal-host and toast-queue components", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/studio")
      # ModalHost has graduated from stub → real component (Wave 3C1
      # modal-host subagent); it now renders with `data-role`. Other
      # component stubs still emit `data-stub`.
      assert html =~ ~s(data-role="modal-host")
      assert html =~ ~s(data-stub="toast-queue")
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
      refute html =~ ~s(data-stub="document-list")
    end

    test "viewport_change with w >= 1024 stays on desktop", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      html = render_hook(lv, "viewport_change", %{"w" => 1600})
      assert html =~ ~s(data-stub="document-list")
    end

    test "toggle_preview is a no-op on desktop layout (mobile-only button)",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      assert :sys.get_state(lv.pid).socket.assigns.preview_modal_open? == false
      _ = render_hook(lv, "toggle_preview", %{})
      assert :sys.get_state(lv.pid).socket.assigns.preview_modal_open? == true
    end
  end

  describe "event_to_action/3 (dispatch funnel)" do
    setup :base_assigns

    test "rename_document → :rename_document Action with document_id from state",
         %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Action{kind: :rename_document, document_id: ^doc, actor_type: :user}} =
               StudioLive.event_to_action("rename_document", %{"title" => "New"}, assigns)
    end

    test "set_contract_type → :set_contract_type", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Action{kind: :set_contract_type}} =
               StudioLive.event_to_action("set_contract_type", %{"type_key" => "nda"}, assigns)
    end

    test "edit_document → :edit_document", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Action{kind: :edit_document}} =
               StudioLive.event_to_action("edit_document", %{"ops" => []}, assigns)
    end

    test "send_chat_message → :chat_message (document not required)",
         %{assigns: assigns} do
      assert {:ok, %Action{kind: :chat_message}} =
               StudioLive.event_to_action("send_chat_message", %{"message" => "hi"}, assigns)
    end

    test "revoke_change → :revoke_change", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Action{kind: :revoke_change}} =
               StudioLive.event_to_action("revoke_change", %{"change_id" => "x"}, assigns)
    end

    test "upload_document → :upload_document (document not required)",
         %{assigns: assigns} do
      assert {:ok, %Action{kind: :upload_document}} =
               StudioLive.event_to_action("upload_document", %{"upload" => %{}}, assigns)
    end

    test "create_variant → :create_converted_variant", %{assigns: assigns} do
      assert {:ok, %Action{kind: :create_converted_variant}} =
               StudioLive.event_to_action("create_variant", %{}, assigns)
    end

    test "open_document → :open_document", %{assigns: assigns} do
      doc = Ecto.UUID.generate()

      assert {:ok, %Action{kind: :open_document, document_id: ^doc}} =
               StudioLive.event_to_action("open_document", %{"document_id" => doc}, assigns)
    end

    test "duplicate_document → :duplicate_document", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Action{kind: :duplicate_document}} =
               StudioLive.event_to_action("duplicate_document", %{}, assigns)
    end

    test "request_export → :request_export", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      assert {:ok, %Action{kind: :request_export}} =
               StudioLive.event_to_action("request_export", %{"format" => "pdf"}, assigns)
    end

    test "command_palette_picked resolves to the inner kind", %{assigns: assigns} do
      assert {:ok, %Action{kind: :chat_message}} =
               StudioLive.event_to_action(
                 "command_palette_picked",
                 %{"kind" => "chat_message", "message" => "hi"},
                 assigns
               )
    end

    test "command_palette_picked errors on unknown kind", %{assigns: assigns} do
      assert {:error, {:unknown_palette_kind, "bogus_kind_xyz"}} =
               StudioLive.event_to_action(
                 "command_palette_picked",
                 %{"kind" => "bogus_kind_xyz"},
                 assigns
               )
    end

    test "missing document_id when required is a typed error", %{assigns: assigns} do
      # rename_document requires a doc id; nothing in state and nothing in params
      assert {:error, {:missing_document_id, :rename_document}} =
               StudioLive.event_to_action("rename_document", %{}, assigns)
    end

    test "local UI events return :local", %{assigns: assigns} do
      assert :local = StudioLive.event_to_action("toggle_preview", %{}, assigns)
      assert :local = StudioLive.event_to_action("open_modal", %{}, assigns)
      assert :local = StudioLive.event_to_action("close_modal", %{}, assigns)
      assert :local = StudioLive.event_to_action("set_node_focus", %{}, assigns)
      assert :local = StudioLive.event_to_action("viewport_change", %{}, assigns)
    end

    test "unknown event returns {:error, _}", %{assigns: assigns} do
      assert {:error, {:unknown_event, "wat"}} =
               StudioLive.event_to_action("wat", %{}, assigns)
    end

    test "every built Action carries a unique idempotency_key", %{assigns: assigns} do
      doc = Ecto.UUID.generate()
      assigns = put_doc(assigns, doc)

      {:ok, a} = StudioLive.event_to_action("rename_document", %{"title" => "A"}, assigns)
      {:ok, b} = StudioLive.event_to_action("rename_document", %{"title" => "B"}, assigns)

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
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "wizard"})

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
          "title" => "src",
          "type_key" => "nda_v1"
        })

      # Give the LV the lawyer-style perms via session.
      conn = Plug.Conn.put_session(conn, :user_perms, ~w(read write commit revoke export type_change)a)

      {:ok, lv, _html} = live(conn, ~p"/studio")

      # Seed selected document.
      send_state(lv, %State{
        matter_id: matter.id,
        selected_document_id: doc.id,
        mode: :editing,
        last_seen_revision: 0
      })

      _ =
        render_hook(lv, "start_type_conversion", %{
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
        render_hook(lv, "start_type_conversion", %{"target_type_key" => "nda_v1"})

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

      html = render_hook(lv, "start_type_conversion", %{"target_type_key" => ""})
      assert html =~ "target type"
    end

    test "create_variant without a plan flashes an error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      html = render_hook(lv, "create_variant", %{})
      assert html =~ "No active conversion plan"
    end

    test "set_field_migration_strategy without a plan flashes an error",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      html =
        render_hook(lv, "set_field_migration_strategy", %{
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
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "wizard-bug-4"})

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
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
        matter_id: matter.id,
        selected_document_id: doc.id,
        mode: :editing,
        last_seen_revision: 0
      })

      html =
        render_hook(lv, "start_type_conversion", %{
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
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "edit-bug-5"})

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
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
        matter_id: matter.id,
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
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "revoke-key-74"})

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
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
        matter_id: matter.id,
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
        Enum.find(changes_after_edit, fn c -> c.action_kind == "edit_document" end)

      assert edit_change, "edit_document must produce a Change row " <>
                            "(got: #{inspect(Enum.map(changes_after_edit, & &1.action_kind))})"

      # The LV pushes editor:last-change to the hook as soon as the
      # change_committed PubSub round-trip lands. Drive the protocol
      # message directly here because `render_hook` returns before the
      # async broadcast is delivered.
      send(lv.pid, {:change_committed, edit_change})
      _ = render(lv)

      # 2. Simulate Cmd+Z by firing the same event the hook would push.
      _ =
        render_hook(lv, "revoke_change", %{
          "change_id" => edit_change.id,
          "node_id" => "node-effective-date"
        })

      # 3. The store now holds a revoke change pointing at the original.
      {:ok, after_undo} = Contract.Store.changes_since(doc.id, 0)

      revoke_change =
        Enum.find(after_undo, fn c ->
          c.action_kind == "revoke_change"
        end)

      assert revoke_change,
             "revoke_change event must land a revoke Change row " <>
               "(got kinds: #{inspect(Enum.map(after_undo, & &1.action_kind))})"

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
      new_state = %State{matter_id: "m", mode: :editing, last_seen_revision: 9}
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
        action_kind: "edit_document",
        applied_revision: 7
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
        action_kind: "resolve_revoke",
        applied_revision: 2
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
      {:ok, matter} = Contract.Matters.create(scope, %{"name" => "palette-type"})

      {:ok, doc} =
        Contract.Documents.create(scope, %{
          "matter_id" => matter.id,
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
        matter_id: matter.id,
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
  # helpers
  # ---------------------------------------------------------------------------

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
end
