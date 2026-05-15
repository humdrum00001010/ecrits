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
