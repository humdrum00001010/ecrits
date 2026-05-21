defmodule ContractWeb.LandingMobileTest do
  @moduledoc """
  Wallaby smoke for the v0.5/design-landing surface at a mobile
  viewport. Asserts that the hamburger drawer toggle is present on
  `< lg` widths (375×667 — the iPhone SE baseline) and that the
  three-block right column from DESIGN.md §3 still renders below the
  copy column when the layout collapses to one column.

  Tagged `:browser` so it stays out of the default `mix test` run; CI /
  sprite runs `mix test --include browser`.
  """

  use ContractWeb.FeatureCase, async: false

  @moduletag :browser

  feature "hamburger drawer toggle is visible on mobile viewport", %{session: session} do
    session
    |> Wallaby.Browser.resize_window(375, 667)
    |> Wallaby.Browser.visit("/")
    |> assert_has(Query.css("label[for='mobile-nav-drawer']"))
    |> assert_has(Query.css("input#mobile-nav-drawer", visible: false))
  end

  feature "v31 three-block system renders on mobile viewport", %{session: session} do
    session
    |> Wallaby.Browser.resize_window(375, 667)
    |> Wallaby.Browser.visit("/")
    |> assert_has(Query.css("[data-landing-block]", count: 3))
    |> assert_has(Query.css("#how-it-works"))
  end
end
