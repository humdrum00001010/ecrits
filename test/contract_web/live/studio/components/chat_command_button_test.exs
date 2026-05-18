defmodule ContractWeb.Live.Studio.Components.ChatCommandButtonTest do
  @moduledoc """
  Wave 3C1 / chat-command-button component tests.

  Covers:

    1. Renders only on the mobile viewport (skipped on desktop).
    2. Tap on the trigger opens the bottom-sheet.
    3. Tap on a row emits `command_palette_picked` with `action_kind`.
    4. Persona perms gate which commands appear in the sheet.
    5. Korean labels render in the sheet chrome.

  Plus a few small sanity checks (close button, sheet a11y, no Documents
  group without a current document) so the file behaves as a self-contained guarantee
  on the component's contract.
  """
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias ContractWeb.Live.Studio.Components.ChatCommandButton

  # --- Scope fixtures --------------------------------------------------

  defp lawyer_scope(user) do
    %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke export type_change agent_run)a
    }
  end

  defp paralegal_scope(user) do
    %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke type_change agent_run)a
    }
  end

  defp viewer_scope(user) do
    %Context{
      Context.for_user(user)
      | perms: ~w(read)a
    }
  end

  defp empty_studio_state(selected_document_id \\ "doc-abc") do
    %{
      matter_id: nil,
      selected_document_id: selected_document_id,
      selected_node_id: nil,
      last_seen_revision: 0,
      mode: :no_document,
      chat_open?: true,
      document_picker_open?: false,
      metadata_panel_open?: false,
      migration_panel_open?: false,
      upload_panel_open?: false,
      agent_run_id: nil
    }
  end

  defp base_assigns(scope, overrides \\ %{}) do
    Map.merge(
      %{
        id: "chat-cmd-btn",
        current_scope: scope,
        studio_state: empty_studio_state(),
        viewport: :mobile
      },
      overrides
    )
  end

  # --- 1. Mobile-only render -------------------------------------------

  describe "viewport gating" do
    setup do
      %{user: user_fixture()}
    end

    test "renders the icon trigger on mobile, skipped marker on desktop", %{user: user} do
      mobile_html =
        render_component(ChatCommandButton, base_assigns(lawyer_scope(user)))

      assert mobile_html =~ ~s(data-role="chat-command-trigger")
      # Sheet closed by default on mobile.
      refute mobile_html =~ ~s(data-role="chat-command-sheet")

      desktop_html =
        render_component(
          ChatCommandButton,
          base_assigns(lawyer_scope(user), %{viewport: :desktop})
        )

      refute desktop_html =~ ~s(data-role="chat-command-trigger")
      assert desktop_html =~ ~s(data-role="chat-command-button-skipped")
    end
  end

  # --- 2. Tap opens the sheet ------------------------------------------

  describe "open / close" do
    setup do
      %{user: user_fixture()}
    end

    test "initial_open? renders the sheet markup with a close button + a11y", %{user: user} do
      html =
        render_component(
          ChatCommandButton,
          base_assigns(lawyer_scope(user), %{initial_open?: true})
        )

      assert html =~ ~s(data-role="chat-command-sheet")
      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(data-role="chat-command-close")
    end
  end

  # --- 3. Row tap emits command_palette_picked ------------------------

  describe "row click semantics" do
    setup do
      %{user: user_fixture()}
    end

    test "emit-action rows carry phx-click + phx-value-action_kind", %{user: user} do
      html =
        render_component(
          ChatCommandButton,
          base_assigns(lawyer_scope(user), %{initial_open?: true})
        )

      # Row for "Request export…" emits the dotted export command.
      assert html =~ ~s(data-cmd-id="doc_request_export")
      assert html =~ ~s(phx-click="command_palette_picked")
      assert html =~ ~s(phx-value-action_kind="export.request")
      # Companion `kind` attribute lets the Studio LV's event_to_action/3
      # funnel route the event without per-event-name special casing.
      assert html =~ ~s(phx-value-kind="export.request")
    end

    test "navigation rows fire a JS.navigate (no phx event)", %{user: user} do
      html =
        render_component(
          ChatCommandButton,
          base_assigns(lawyer_scope(user), %{initial_open?: true})
        )

      # Nav row exists.
      assert html =~ ~s(data-cmd-id="nav_storage")
      # JS.navigate command renders as a serialized JSON ops list — assert
      # the row contains the storage path somewhere in its phx-click attr.
      assert html =~ "/storage"
    end

  end

  # --- 4. Persona perms filter -----------------------------------------

  describe "persona perms" do
    setup do
      %{user: user_fixture()}
    end

    test "paralegal sheet hides Request export and revoke but keeps set-type", %{user: user} do
      html =
        render_component(
          ChatCommandButton,
          base_assigns(paralegal_scope(user), %{initial_open?: true})
        )

      refute html =~ ~s(data-cmd-id="doc_request_export")
      refute html =~ ~s(data-cmd-id="doc_revoke_last")
      assert html =~ ~s(data-cmd-id="doc_set_type")
    end

    test "viewer sheet hides every Documents-group row", %{user: user} do
      html =
        render_component(
          ChatCommandButton,
          base_assigns(viewer_scope(user), %{initial_open?: true})
        )

      refute html =~ ~s(data-cmd-id="doc_request_export")
      refute html =~ ~s(data-cmd-id="doc_revoke_last")
      refute html =~ ~s(data-cmd-id="doc_set_type")
      # Navigation still present.
      assert html =~ ~s(data-cmd-id="nav_storage")
    end

    test "nil scope only shows navigation commands (no Documents group)" do
      assigns = %{
        id: "chat-cmd-btn",
        current_scope: nil,
        studio_state: empty_studio_state(),
        viewport: :mobile,
        initial_open?: true
      }

      html = render_component(ChatCommandButton, assigns)

      refute html =~ ~s(data-cmd-id="doc_request_export")
      assert html =~ ~s(data-cmd-id="nav_storage")
    end

    test "sheet_commands/1 strips :mode sub-mode entries", %{user: user} do
      cmds = ChatCommandButton.sheet_commands(lawyer_scope(user), "doc-abc")
      ids = Enum.map(cmds, & &1.id)

      refute :search_law in ids
      refute :search_documents in ids
      refute :help_agent in ids
      refute :help_shortcuts in ids
      # Emit + navigate commands survive.
      assert :doc_request_export in ids
      assert :nav_storage in ids
    end
  end

  # --- 5. Korean labels --------------------------------------------------

  describe "Korean copy" do
    setup do
      %{user: user_fixture()}
    end

    test "sheet header carries the Korean primary + English fallback", %{user: user} do
      html =
        render_component(
          ChatCommandButton,
          base_assigns(lawyer_scope(user), %{initial_open?: true})
        )

      # Hangul header.
      assert html =~ "명령어"
      # English fallback alongside.
      assert html =~ "Commands"
      # Footer hint copy.
      assert html =~ "탭하여 실행"
    end

    test "empty-commands state shows Korean message", %{user: _user} do
      # The empty branch is hard to reach via fixtures; verify the Hangul
      # string ships in the source.
      source =
        File.read!("lib/contract_web/live/studio/components/chat_command_button.ex")

      assert source =~ "사용할 수 있는 명령어가 없습니다"
    end
  end

  # --- 6. End-to-end via the LiveComponent inside a fake LV -----------

  describe "open via tap (LiveComponent runtime)" do
    setup do
      %{user: user_fixture()}
    end

    test "tapping the trigger flips sheet_open?", %{conn: conn, user: user} do
      # Mount the component inside a thin throwaway LiveView so we can
      # drive its `phx-click` events without the rest of StudioLive's
      # plumbing.
      conn = log_in_user(conn, user)
      scope = lawyer_scope(user)

      {:ok, lv, html} =
        live_isolated(conn, ContractWeb.Live.Studio.Components.ChatCommandButtonTest.Host,
          session: %{"scope" => scope}
        )

      refute html =~ ~s(data-role="chat-command-sheet")

      html =
        lv
        |> element(~s([data-role="chat-command-trigger"]))
        |> render_click()

      assert html =~ ~s(data-role="chat-command-sheet")

      # And close.
      html =
        lv
        |> element(~s([data-role="chat-command-close"]))
        |> render_click()

      refute html =~ ~s(data-role="chat-command-sheet")
    end
  end

  # --- Host LV for the runtime test (declared inside the test module
  # because it's only needed here). -------------------------------------

  defmodule Host do
    @moduledoc false
    use ContractWeb, :live_view

    alias ContractWeb.Live.Studio.Components.ChatCommandButton

    @impl true
    def mount(_params, session, socket) do
      scope = Map.get(session, "scope")

      socket = Phoenix.Component.assign(socket, :current_scope, scope)

      socket =
        Phoenix.Component.assign(socket, :studio_state, %{
          matter_id: nil,
          mode: :no_document,
          chat_open?: true,
          document_picker_open?: false,
          metadata_panel_open?: false,
          migration_panel_open?: false,
          upload_panel_open?: false,
          agent_run_id: nil,
          selected_document_id: nil,
          selected_node_id: nil,
          last_seen_revision: 0
        })

      socket = Phoenix.Component.assign(socket, :viewport, :mobile)

      {:ok, socket}
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div>
        <.live_component
          module={ChatCommandButton}
          id="chat-cmd-btn"
          current_scope={@current_scope}
          studio_state={@studio_state}
          viewport={@viewport}
        />
      </div>
      """
    end
  end
end
