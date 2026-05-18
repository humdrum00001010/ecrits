defmodule ContractWeb.LayoutsTopNavTest do
  @moduledoc """
  Heex render assertions for `ContractWeb.Layouts.top_nav/1` — guards against
  baseline-wobble regressions in the navbar row.

  The user-visible symptom this test prevents: nav items rendering at slightly
  different vertical centers because direct flex children disagree on height
  (e.g. a btn-sm at h-8 next to a plain `<a>` text link with line-height
  ~20px next to a custom theme-toggle pill with border-2 + p-2). The fix
  pins both the row (`h-14 items-center`) and every direct child
  (`inline-flex items-center h-9`) so the row centers them on a single axis.

  Tests are pure render-string assertions — no LiveView, no Wallaby,
  fast and deterministic.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ContractWeb.Layouts

  defp scope(user \\ %{id: 1, email: "lawyer@example.com"}) do
    %{user: user}
  end

  # Anti-regression for the baseline-wobble bug: the row + every direct
  # child must share `flex items-center` + the canonical heights (h-14
  # row, h-9 children) so nav items center on a single axis.
  describe "top_nav/1 row + child alignment baseline" do
    test "row and direct children share flex + items-center + canonical row height" do
      for scope_arg <- [nil, scope()] do
        html = render_component(&Layouts.top_nav/1, current_scope: scope_arg)

        assert html =~ "flex"
        assert html =~ "items-center"
        assert html =~ "h-14"
        assert html =~ "flex-nowrap"
      end

      anon = render_component(&Layouts.top_nav/1, current_scope: nil)
      assert anon =~ "btn btn-primary"
      assert anon =~ "h-9 min-h-9"
    end
  end

  # Cmd+K trigger was removed from the navbar per 2026-05-17 owner directive.
  # Keyboard shortcut still works (palette mount stays). No visible button.
  describe "top_nav/1 — Cmd+K trigger is NOT in the navbar (removed)" do
    test "signed-in: no palette trigger button visible" do
      html = render_component(&Layouts.top_nav/1, current_scope: scope())
      refute html =~ ~s(data-role="palette-trigger")
    end
  end

  describe "theme_toggle/1 — embedded in the navbar row" do
    test "outer pill has explicit h-9 + inline-flex items-center (matches row baseline)" do
      html = render_component(&Layouts.theme_toggle/1, %{})

      # The pill must NOT introduce its own height — h-9 keeps it aligned
      # with the other row items.
      assert html =~ "inline-flex"
      assert html =~ "items-center"
      assert html =~ "h-9"
      # Each segment button must center its icon (was `flex p-2` only,
      # which left the icon top-aligned on tall lines).
      assert html =~ ~r/<button[^>]*class="[^"]*inline-flex[^"]*items-center[^"]*justify-center/
    end
  end

  describe "mobile_nav/1 — drawer integrity" do
    test "drawer renders the right nav landmarks for signed-in + anonymous scopes" do
      signed_in = render_component(&Layouts.mobile_nav/1, current_scope: scope())
      assert signed_in =~ "<aside"
      assert signed_in =~ "Storage"
      assert signed_in =~ "Studio"
      assert signed_in =~ "Settings"

      anon = render_component(&Layouts.mobile_nav/1, current_scope: nil)
      assert anon =~ "<aside"
      assert anon =~ "Docs"
      assert anon =~ "Changelog"
    end
  end
end
