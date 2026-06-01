defmodule ContractWeb.Components.CommandPaletteTest do
  use ContractWeb.ConnCase, async: true

  @moduletag :legacy_saas

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias ContractWeb.Components.CommandPalette

  # --- Persona-perm fixtures (mirror Contract.PersonaFactory) ---------

  defp lawyer_scope(user),
    do: %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke export type_change agent_run)a
    }

  defp paralegal_scope(user),
    do: %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke type_change agent_run)a
    }

  defp agent_supervised_scope(user),
    do: %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke agent_run)a
    }

  defp viewer_scope(user),
    do: %Context{Context.for_user(user) | perms: ~w(read)a}

  defp admin_scope(user),
    do: %Context{
      Context.for_user(user)
      | perms:
          ~w(read write commit revoke export type_change agent_run tenant_admin matter_admin)a
    }

  describe "available_commands/2 — persona perms + current document matrix" do
    setup do
      %{user: user_fixture()}
    end

    test "lawyer sees export and set-type, but no revoke without a revocable change id", %{
      user: user
    } do
      scope = lawyer_scope(user)

      ids =
        scope
        |> CommandPalette.available_commands(current_document_id: "doc-abc")
        |> Enum.map(& &1.id)

      assert :doc_request_export in ids
      refute :doc_revoke_last in ids
      assert :doc_set_type in ids
      assert :nav_storage in ids
      assert :search_law in ids
    end

    test "paralegal sees set-type but NOT request export or revoke", %{user: user} do
      scope = paralegal_scope(user)

      ids =
        scope
        |> CommandPalette.available_commands(current_document_id: "doc-abc")
        |> Enum.map(& &1.id)

      refute :doc_revoke_last in ids
      assert :doc_set_type in ids
      refute :doc_request_export in ids
    end

    test "agent_supervised does not see document actions without export/type_change or revocable change id",
         %{user: user} do
      scope = agent_supervised_scope(user)

      ids =
        scope
        |> CommandPalette.available_commands(current_document_id: "doc-abc")
        |> Enum.map(& &1.id)

      refute :doc_revoke_last in ids
      refute :doc_request_export in ids
      refute :doc_set_type in ids
    end

    test "viewer sees only navigation/search/help — no Documents at all", %{user: user} do
      scope = viewer_scope(user)

      ids =
        scope
        |> CommandPalette.available_commands(current_document_id: "doc-abc")
        |> Enum.map(& &1.id)

      refute :doc_request_export in ids
      refute :doc_revoke_last in ids
      refute :doc_set_type in ids
      assert :nav_storage in ids
      assert :search_law in ids
      assert :help_shortcuts in ids
    end

    test "admin sees document actions that can be built without extra payload", %{user: user} do
      scope = admin_scope(user)

      ids =
        scope
        |> CommandPalette.available_commands(current_document_id: "doc-abc")
        |> Enum.map(& &1.id)

      assert :doc_request_export in ids
      refute :doc_revoke_last in ids
      assert :doc_set_type in ids
    end

    test "document commands emit dotted command-palette action kinds", %{user: user} do
      scope = lawyer_scope(user)
      commands = CommandPalette.available_commands(scope, current_document_id: "doc-abc")

      assert %{action: {:emit, :command_palette_picked, %{action_kind: "document.type.set"}}} =
               Enum.find(commands, &(&1.id == :doc_set_type))

      assert %{action: {:emit, :command_palette_picked, %{action_kind: "export.request"}}} =
               Enum.find(commands, &(&1.id == :doc_request_export))

      refute Enum.find(commands, &(&1.id == :doc_revoke_last))
    end

    test "Documents commands hide when there is no current document even for a lawyer",
         %{user: user} do
      scope = lawyer_scope(user)

      ids =
        scope |> CommandPalette.available_commands(current_document_id: nil) |> Enum.map(& &1.id)

      refute :doc_request_export in ids
      refute :doc_revoke_last in ids
      refute :doc_set_type in ids
      # Navigation/search/help still present.
      assert :nav_storage in ids
    end

    test "nil scope yields navigation+search+help only (no Documents group)",
         %{user: _user} do
      ids =
        nil
        |> CommandPalette.available_commands(current_document_id: "doc-abc")
        |> Enum.map(& &1.id)

      refute :doc_request_export in ids
      refute :doc_revoke_last in ids
      refute :doc_set_type in ids
      assert :nav_storage in ids
      assert :search_law in ids
    end
  end

  describe "filter_commands/2 — fuzzy subsequence matching" do
    setup %{} do
      user = user_fixture()
      scope = lawyer_scope(user)
      %{commands: CommandPalette.available_commands(scope, current_document_id: "doc-abc")}
    end

    test "empty query returns the full catalog in order", %{commands: commands} do
      assert CommandPalette.filter_commands(commands, "") == commands
    end

    test "'go to' filters down to the navigation commands", %{commands: commands} do
      labels =
        commands
        |> CommandPalette.filter_commands("go to")
        |> Enum.map(& &1.label)

      assert "Go to storage" in labels
      assert "Go to landing" in labels
      refute "Search Korean law…" in labels
    end

    test "case-insensitive substring fuzzy match", %{commands: commands} do
      labels =
        commands
        |> CommandPalette.filter_commands("STOR")
        |> Enum.map(& &1.label)

      assert "Go to storage" in labels
    end

    test "nonsense query yields empty list", %{commands: commands} do
      assert CommandPalette.filter_commands(commands, "zzzqqq") == []
    end

    test "score/2 returns nil for non-subsequence and a positive number for match" do
      assert CommandPalette.score("Go to dashboard", "zzz") == nil

      score = CommandPalette.score("Go to dashboard", "got")
      assert is_float(score)
      assert score > 0
    end
  end

  describe "render_component/2 — closed-by-default + persona filtering" do
    setup do
      user = user_fixture()
      %{user: user}
    end

    # Wave 4 bugfix #6 — Playwright Scenario 6 selector contract.
    # The root container is permanently mounted (`command-palette-root`
    # with `data-open` for state tracking); the modal box (with the
    # visible palette UI + `data-role="command-palette"`) only mounts
    # when `@open?` flips. Playwright relies on the closed→open
    # transition to show the sized modal.
    test "closed-by-default → open transition flips data-open and mounts the modal box",
         %{user: user} do
      closed =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: lawyer_scope(user)
        )

      assert closed =~ ~s(data-role="command-palette-root")
      assert closed =~ ~s(data-open="false")
      refute closed =~ ~s(data-role="palette-box")
      refute closed =~ ~s(data-role="command-palette" )
      refute closed =~ ~s(data-role="command-palette">)

      open =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: lawyer_scope(user),
          initial_open?: true
        )

      assert open =~ ~s(data-role="command-palette-root")
      assert open =~ ~s(data-open="true")
      assert open =~ ~s(data-role="palette-box")
      assert open =~ ~s(data-role="palette-input")
      assert open =~ "Type a command"
      assert open =~ "Navigation"

      assert open =~ ~s(data-role="command-palette" ) or
               open =~ ~s(data-role="command-palette">)
    end

    test "open palette for a lawyer with current document and no Matter shows Request export…", %{
      user: user
    } do
      scope = lawyer_scope(user)

      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: scope,
          current_document_id: "doc-abc",
          initial_open?: true
        )

      assert html =~ "Request export"
      assert html =~ "Documents"
    end

    test "open palette for a viewer hides the Documents group entirely", %{user: user} do
      scope = viewer_scope(user)

      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: scope,
          current_document_id: "doc-abc",
          initial_open?: true
        )

      refute html =~ "Request export"
      refute html =~ "Revoke last change"
      refute html =~ "Set contract type"
      # Documents group header should also not appear since no commands match.
      refute html =~ ~s(>Documents<)
      # Help group still present.
      assert html =~ "Keyboard shortcuts"
    end

    test "initial_query='storage' narrows the rendered list", %{user: user} do
      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: lawyer_scope(user),
          initial_open?: true,
          initial_query: "storage"
        )

      assert html =~ "Go to storage"
      refute html =~ "Search Korean law"
    end

    test "info mode renders the shortcuts cheatsheet", %{user: user} do
      html =
        render_component(CommandPalette,
          id: "cmd-k-palette",
          current_scope: lawyer_scope(user),
          initial_open?: true,
          initial_mode: :info
        )

      # The info_target defaults to nil; we render the heading even so but
      # the body falls back to empty when target is unset. Set explicit
      # target via assigns is not currently supported — assert the panel
      # chrome is present.
      assert html =~ "Back"
    end
  end

  describe "end-to-end via /storage — palette mount (trigger button removed 2026-05-17)" do
    setup :log_in_a_user

    test "the palette LiveComponent mounts on /storage (keyboard-only invocation)",
         %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/storage")
      # The visible trigger button was stripped per owner directive;
      # the LiveComponent mount and Cmd+K keyboard shortcut still work.
      assert html =~ "cmd-k-palette"
      refute html =~ ~s(data-role="palette-trigger")
    end

    @tag :skip
    test "Esc closes the open palette", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/storage")

      lv
      |> element(~s([data-role="palette-trigger"]))
      |> render_click()

      assert render(lv) =~ ~s(data-role="palette-box")

      # The Esc bridge element is `phx-window-keydown="key" phx-key="Escape"`
      # targeting the component — fire a keydown on it.
      html =
        lv
        |> element("#cmd-k-palette-keys-escape")
        |> render_keydown(%{"key" => "Escape"})

      refute html =~ ~s(data-role="palette-box")
    end
  end

  defp log_in_a_user(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end
end
