defmodule ContractWeb.Live.Studio.Components.ModalHostTest do
  @moduledoc """
  Component-level tests for the Studio modal host (Wave 3C1).

  Uses `render_component/2` for the markup-only assertions and the
  fully-mounted Studio LV via `live/2` for the live-event assertions
  (close button, Esc dismissal). The live tests piggyback on
  `~p"/studio"` so the parent's existing `update_modal/3` plumbing is
  exercised end-to-end.
  """
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias Contract.Studio.State
  alias ContractWeb.Live.Studio.Components.ModalHost

  # ---------------------------------------------------------------------
  # render_component/2 — markup-only assertions
  # ---------------------------------------------------------------------

  describe "render_component/2 — no modal flag set" do
    test "renders the host shell but no modal dialog" do
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :no_document},
          current_scope: scope_for_user()
        )

      assert html =~ ~s(data-role="modal-host")
      assert html =~ ~s(data-any-open="false")
      refute html =~ ~s(class="modal modal-open")
    end
  end

  describe "render_component/2 — one flag per modal" do
    test "document_picker_open? renders the picker" do
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :briefing, document_picker_open?: true},
          current_scope: scope_for_user(),
          documents: [
            %{id: "doc-1", title: "NDA draft", type_key: "nda_v1"},
            %{id: "doc-2", title: "Master agreement", type_key: "msa_v1"}
          ]
        )

      assert html =~ ~s(data-modal="document_picker")
      assert html =~ ~s(data-role="document-picker-list")
      assert html =~ "NDA draft"
      assert html =~ "Master agreement"
      assert html =~ ~s(phx-click="open_document")
      # Search input
      assert html =~ ~s(data-role="document-picker-search")
    end

    test "metadata_panel_open? renders the metadata editor with the three forms" do
      projection = %{
        title: "Draft v2",
        type_key: "nda_v1",
        metadata: %{notes: "Internal review pending."}
      }

      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing, metadata_panel_open?: true},
          current_scope: scope_for_user(),
          projection: projection
        )

      assert html =~ ~s(data-modal="metadata")
      assert html =~ ~s(data-role="metadata-rename-form")
      assert html =~ ~s(data-role="metadata-type-form")
      assert html =~ ~s(data-role="metadata-notes-form")
      assert html =~ ~s(value="Draft v2")
      assert html =~ "Internal review pending."
      assert html =~ ~s(phx-submit="rename_document")
      assert html =~ ~s(phx-submit="set_contract_type")
      assert html =~ ~s(phx-submit="update_metadata")
    end

    test "upload_panel_open? renders the upload form" do
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :no_document, upload_panel_open?: true},
          current_scope: scope_for_user()
        )

      assert html =~ ~s(data-modal="upload")
      assert html =~ ~s(data-role="upload-form")
      assert html =~ ~s(data-role="upload-file-input")
      assert html =~ ~s(phx-submit="upload_document")
    end

    test "migration_panel_open? renders the 3-step wizard at step 1" do
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing, migration_panel_open?: true},
          current_scope: scope_for_user()
        )

      assert html =~ ~s(data-modal="migration")
      assert html =~ ~s(data-role="migration-steps")
      assert html =~ ~s(data-role="migration-step-plan")
      assert html =~ ~s(data-step="plan")
      assert html =~ ~s(data-role="migration-target-select")
      # Wave 4: planner has not run yet, so a prompt (not a summary) is rendered.
      assert html =~ ~s(data-role="migration-plan-prompt")
    end

    test "migration_panel_open? with a Plan renders the plan summary" do
      plan = %Contract.Conversion.Plan{
        source_document_id: Ecto.UUID.generate(),
        source_type_key: "nda_v1",
        target_type_key: "service_agreement_v1",
        strategies: Contract.Conversion.allowed_strategies(),
        field_plans: [
          %Contract.Conversion.FieldPlan{
            source_field_id: "party_a",
            target_field_id: "party_a",
            strategy: :link_to_matter_field,
            justification: "Party identity is matter-level fact."
          }
        ],
        impact: %{compatible?: true, source_field_count: 1, target_field_count: 1}
      }

      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing, migration_panel_open?: true},
          current_scope: scope_for_user(),
          migration_plan: plan
        )

      assert html =~ ~s(data-role="migration-plan-summary")
      assert html =~ "nda_v1"
      assert html =~ "service_agreement_v1"
    end

    test "reconcile_modal_open? renders the conflict diff + two buttons" do
      request = %{id: "req-abc-123", change_id: "chg-1", conflict: :touched_same_node}

      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing},
          current_scope: scope_for_user(),
          reconcile_modal_open?: true,
          reconcile_request: request
        )

      assert html =~ ~s(data-modal="reconcile")
      assert html =~ ~s(data-role="reconcile-diff")
      # The diff dump contains the request.
      assert html =~ "req-abc-123"
      assert html =~ "touched_same_node"
      # Two resolution buttons emitting resolve_revoke.
      assert html =~ ~s(data-role="reconcile-cancel")
      assert html =~ ~s(data-role="reconcile-force")
      assert html =~ ~s(phx-click="resolve_revoke")
      assert html =~ ~s(phx-value-resolution="cancel")
      assert html =~ ~s(phx-value-resolution="force")
    end

    test "initial_modal_param=\"new_document\" renders the new-document modal" do
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :no_document},
          current_scope: scope_for_user(),
          initial_modal_param: "new_document"
        )

      assert html =~ ~s(data-modal="new_document")
      assert html =~ ~s(data-role="new-document-form")
      # Routed through command_palette_picked with kind=create_document.
      assert html =~ ~s(phx-submit="command_palette_picked")
      assert html =~ ~s(name="kind" value="create_document")
    end

    test "initial_modal_param=\"export\" renders the export format picker" do
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing},
          current_scope: scope_for_user(),
          initial_modal_param: "export"
        )

      assert html =~ ~s(data-modal="export")
      assert html =~ ~s(data-role="export-format-list")
      assert html =~ "PDF"
      assert html =~ "Word (DOCX)"
      assert html =~ "한글 (HWPX)"
      assert html =~ "HTML"
      assert html =~ ~s(phx-click="request_export")
      assert html =~ ~s(phx-value-format="pdf")
      assert html =~ ~s(phx-value-format="hwpx")
    end
  end

  # ---------------------------------------------------------------------
  # Migration wizard step progression
  # ---------------------------------------------------------------------

  describe "migration wizard step progression" do
    test "step :plan shows the Run planner button disabled until a target is picked" do
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing, migration_panel_open?: true},
          current_scope: scope_for_user()
        )

      assert html =~ ~s(data-role="migration-run-planner")
      # `disabled` and `data-role` can land in either order; assert
      # both attributes appear on the same opening tag.
      assert html =~ ~r/<button[^>]*disabled[^>]*data-role="migration-run-planner"|<button[^>]*data-role="migration-run-planner"[^>]*disabled/
    end

    test "step :plan with an existing Plan shows the Next: field strategies button" do
      plan = %Contract.Conversion.Plan{
        source_document_id: Ecto.UUID.generate(),
        target_type_key: "service_agreement_v1",
        strategies: Contract.Conversion.allowed_strategies(),
        field_plans: [],
        impact: %{compatible?: true}
      }

      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing, migration_panel_open?: true},
          current_scope: scope_for_user(),
          migration_plan: plan
        )

      assert html =~ ~s(data-role="migration-next-fields")
      assert html =~ ~s(data-role="migration-plan-summary")
    end

    test "initial_migration_step=:fields renders the strategy table" do
      plan = %Contract.Conversion.Plan{
        source_document_id: Ecto.UUID.generate(),
        source_type_key: "nda_v1",
        target_type_key: "service_agreement_v1",
        strategies: Contract.Conversion.allowed_strategies(),
        field_plans: [
          %Contract.Conversion.FieldPlan{
            source_field_id: "effective_date",
            target_field_id: "effective_date",
            strategy: :link_to_matter_field,
            justification: "Date is matter-level fact."
          }
        ],
        impact: %{compatible?: true}
      }

      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing, migration_panel_open?: true},
          current_scope: scope_for_user(),
          initial_migration_step: :fields,
          migration_plan: plan
        )

      assert html =~ ~s(data-role="migration-step-fields")
      assert html =~ ~s(data-role="migration-fields-table")
      assert html =~ ~s(data-role="migration-next-confirm")
      assert html =~ "effective_date"
      # Each strategy option shows up.
      assert html =~ "Copy once"
      assert html =~ "Link to matter field"
      assert html =~ "Derive"
      assert html =~ "Reference only"
      assert html =~ "Ignore"
      assert html =~ "Ask user"
    end

    test "initial_migration_step=:confirm renders the create-variant form" do
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing, migration_panel_open?: true},
          current_scope: scope_for_user(),
          initial_migration_step: :confirm
        )

      assert html =~ ~s(data-role="migration-step-confirm")
      assert html =~ ~s(data-role="migration-create-form")
      assert html =~ ~s(data-role="migration-create-variant")
      assert html =~ ~s(phx-submit="create_variant")
    end
  end

  # ---------------------------------------------------------------------
  # Live LV — close button + Esc bubble to parent
  # ---------------------------------------------------------------------

  describe "close-modal interactions via the parent LV" do
    setup :log_in_a_user

    test "close button on the document picker fires close_modal and flips the flag",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      # Flip the flag by simulating the parent's open_modal event.
      _ = render_hook(lv, "open_modal", %{"modal" => "document_picker"})
      assert assigns(lv).studio_state.document_picker_open? == true

      # The close X button inside the rendered picker emits close_modal.
      _ = render_hook(lv, "close_modal", %{"modal" => "document_picker"})
      assert assigns(lv).studio_state.document_picker_open? == false
    end

    test "Esc on metadata modal bubbles close_modal up via the window keydown" do
      # Component-level: the metadata modal's keydown stub renders the
      # phx-window-keydown attribute with phx-key="Escape" and the
      # modal name as its value.
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing, metadata_panel_open?: true},
          current_scope: scope_for_user()
        )

      assert html =~
               ~s(phx-window-keydown="close_modal" phx-key="Escape" phx-value-modal="metadata")
    end

    test "reconcile modal close button flips reconcile_modal_open?", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      send(lv.pid, {:revoke_requested, %{id: "r-1", change_id: "c-1"}})
      _ = render(lv)
      assert assigns(lv).reconcile_modal_open? == true

      _ = render_hook(lv, "close_modal", %{"modal" => "reconcile"})
      assert assigns(lv).reconcile_modal_open? == false
    end

    test "Esc colocated hook is mounted on the modal host shell" do
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :no_document},
          current_scope: scope_for_user()
        )

      # LV 1.1 expands the colocated hook name `.ModalEsc` to the
      # fully-qualified `<Module>.ModalEsc` on the `phx-hook` attribute.
      assert html =~ "phx-hook=\"ContractWeb.Live.Studio.Components.ModalHost.ModalEsc\""
    end
  end

  # ---------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------

  defp scope_for_user(perms \\ ~w(read write commit revoke export type_change)a) do
    %Context{
      user: %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "x@example.com"},
      perms: perms,
      matter: %{id: Ecto.UUID.generate(), name: "Matter A"}
    }
  end

  defp log_in_a_user(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp assigns(lv), do: :sys.get_state(lv.pid).socket.assigns
end
