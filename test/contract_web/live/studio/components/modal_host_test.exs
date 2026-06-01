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

  @moduletag :legacy_saas

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
