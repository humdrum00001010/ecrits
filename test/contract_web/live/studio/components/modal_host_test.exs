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
      assert html =~ ~s(phx-click="document.open")
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
      assert html =~ ~s(phx-submit="document.rename")
      assert html =~ ~s(phx-submit="document.type.set")
      assert html =~ ~s(phx-submit="document.metadata.update")
      refute html =~ ~s(phx-submit="update_metadata")
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
      assert html =~ ~s(phx-submit="document.upload")
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
      # Two resolution buttons emitting revoke.resolve.
      assert html =~ ~s(data-role="reconcile-cancel")
      assert html =~ ~s(data-role="reconcile-force")
      assert html =~ ~s(phx-click="revoke.resolve")
      assert html =~ ~s(phx-value-resolution="cancel")
      assert html =~ ~s(phx-value-resolution="force")
    end

    # SPEC.md §18 — subagent fix `feat/no-type-at-create`:
    # New-document modal renders only a title input — no contract-type
    # `<select>` and no matter field. Type is set later via
    # `Action(:set_contract_type)`.
    test "initial_modal_param=\"new_document\" renders title-only form (no type/matter fields)" do
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :no_document},
          current_scope: scope_for_user(),
          initial_modal_param: "new_document"
        )

      assert html =~ ~s(data-modal="new_document")
      assert html =~ ~s(data-role="new-document-form")
      assert html =~ ~s(phx-submit="document.create")
      assert html =~ ~s(name="title")
      assert html =~ "required"
      assert html =~ ~s(data-role="new-document-type-hint")

      # Type/matter MUST be absent — subagent fix `feat/no-type-at-create`.
      refute html =~ ~r/name="type_key"/
      refute html =~ ~s(name="matter_id")
      refute html =~ ~s(data-role="new-document-matter")
      refute html =~ "Choose a type"
      refute html =~ ~s(value="nda_v1")
    end

    # Wave 5: type-picker modal also localizes the headline label.
    test "type-picker modal renders rows headlined by the localized name in :ko locale" do
      previous = Gettext.get_locale(ContractWeb.Gettext)
      Gettext.put_locale(ContractWeb.Gettext, "ko")
      on_exit(fn -> Gettext.put_locale(ContractWeb.Gettext, previous) end)

      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing, type_picker_open?: true},
          current_scope: scope_for_user()
      )

      {:ok, nda} = Contract.ContractTypes.get(nil, "nda_v1")
      assert html =~ ~s(data-role="type-picker")
      # Korean name renders as the headline.
      assert html =~ nda.name_ko
      # Technical key + version still surface as a secondary line.
      assert html =~ "nda_v1 · v#{nda.version}"
      refute html =~ "franchise_chicken_v2024_12"
      refute html =~ "franchise_v1"
      refute html =~ "supply_v1"
      refute html =~ "custom_v1"
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
      assert html =~ "Word (.docx)"
      assert html =~ "Hangul (.hwpx)"
      assert html =~ "Markdown"
      assert html =~ "Lawyer packet"
      assert html =~ ~s(phx-click="export.request")
      assert html =~ ~s(phx-value-format="pdf")
      assert html =~ ~s(phx-value-format="hwpx")
    end
  end

  # ---------------------------------------------------------------------
  # Export-picker — state-driven modal (small-task #77)
  # ---------------------------------------------------------------------

  describe "export-picker (studio_state.export_picker_open?)" do
    setup :log_in_a_user

    test "renders the export-picker dialog when export_picker_open? is true" do
      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing, export_picker_open?: true},
          current_scope: scope_for_user()
        )

      assert html =~ ~s(data-role="export-picker")
      assert html =~ ~s(data-modal="export")
      # Product-facing formats rendered as radio rows.
      assert html =~ ~s(name="format" value="hwpx")
      assert html =~ ~s(name="format" value="pdf")
      assert html =~ ~s(name="format" value="docx")
      assert html =~ ~s(name="format" value="markdown")
      assert html =~ ~s(name="format" value="lawyer_packet")
      # Spec'd labels.
      assert html =~ "Hangul (.hwpx)"
      assert html =~ "PDF"
      assert html =~ "Word (.docx)"
      assert html =~ "Markdown"
      assert html =~ "Lawyer packet"
      # Form submits export.request so the parent funnel can pick up the
      # chosen format and emit Action(:request_export).
      assert html =~ ~s(phx-submit="export.request")
    end

    test "export-picker opens on no-format event, closes on submit (with seeded doc) or cancel",
         %{conn: conn} do
      # Submit path: routes an `export.request` with no format → picker opens;
      # then submits with a format → picker closes.
      {:ok, submit_lv, _} = live(conn, ~p"/studio")
      _ = render_hook(submit_lv, "export.request", %{})
      assert assigns(submit_lv).studio_state.export_picker_open? == true

      # Seed selected_document_id so build_action doesn't bail on missing doc.
      :sys.replace_state(submit_lv.pid, fn liveview ->
        socket = liveview.socket
        state = %{socket.assigns.studio_state | selected_document_id: Ecto.UUID.generate()}
        %{liveview | socket: %{socket | assigns: Map.put(socket.assigns, :studio_state, state)}}
      end)

      _ = render_hook(submit_lv, "export.request", %{"format" => "pdf"})
      assert assigns(submit_lv).studio_state.export_picker_open? == false

      # Cancel path: open the picker then dispatch close_modal{modal=export}.
      {:ok, cancel_lv, _} = live(conn, ~p"/studio")
      _ = render_hook(cancel_lv, "export.request", %{})
      assert assigns(cancel_lv).studio_state.export_picker_open? == true
      _ = render_hook(cancel_lv, "close_modal", %{"modal" => "export"})
      assert assigns(cancel_lv).studio_state.export_picker_open? == false
    end
  end

  # ---------------------------------------------------------------------
  # Migration wizard step progression
  # ---------------------------------------------------------------------

  describe "migration wizard step progression" do
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
            strategy: :link_to_shared_fact,
            justification: "Date is a shared document fact."
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
      assert html =~ ~s(phx-change="conversion.field_strategy.set")
      assert html =~ ~s(value="link_to_shared_fact")
      refute html =~ ~s(value="link_to_matter_field")
      assert html =~ "Link to shared document fact"
      refute html =~ "Link to matter field"
      refute html =~ "Link to document field"
      refute html =~ "Link to workspace field"
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
      assert html =~ ~s(phx-submit="conversion.create_variant")
    end

    # Wave 4 bugfix #3: the wizard's step-3 summary counter
    # ("Fields with explicit strategies: N") must match the seeded
    # strategies map immediately. The parent LV uses send_update/2 to
    # pass `migration_target` + `field_strategies` into ModalHost as
    # soon as the planner returns. In render_component, those assigns
    # are passed directly.
    test "step :confirm with seeded field_strategies + migration_target enables Create variant" do
      strategies = %{
        "effective_date" => "link_to_shared_fact",
        "party_a" => "copy_once",
        "party_b" => "copy_once"
      }

      html =
        render_component(ModalHost,
          id: "modal-host",
          studio_state: %State{mode: :editing, migration_panel_open?: true},
          current_scope: scope_for_user(),
          initial_migration_step: :confirm,
          migration_target: "service_agreement_v1",
          field_strategies: strategies
        )

      assert html =~ ~s(data-role="migration-summary")
      # The summary's "Fields with explicit strategies:" counter should
      # equal the size of the seeded strategies map (3) — not 0.
      assert html =~ ">3<"
      # Target also threads into the hidden form input.
      assert html =~ ~s(name="target_type_key" value="service_agreement_v1")
      # Create variant button must NOT be disabled — bugfix #2 + #3.
      refute html =~
               ~r/<button[^>]*disabled[^>]*data-role="migration-create-variant"|<button[^>]*data-role="migration-create-variant"[^>]*disabled/
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
      perms: perms
    }
  end

  defp log_in_a_user(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp assigns(lv), do: :sys.get_state(lv.pid).socket.assigns
end
