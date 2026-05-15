defmodule ContractWeb.ThemeToggleTest do
  @moduledoc """
  Wallaby smoke for the theme toggle on the landing page. The Wave 0.5
  rename of the daisyUI theme values (`light|dark` → `studio|studio-dark`)
  left the JS handler out-of-sync; Wave 3C0-E reworked the handler to
  use a delegated click listener that works on dead views too. This
  test exists to prevent a future regression.

  Asserts:
    1. Click the dark-theme button → `<html data-theme="studio-dark">`.
    2. Click the light-theme button → `<html data-theme="studio">`.
    3. Reload after picking dark → the preference persists in
       localStorage and the attribute is re-applied on boot.

  Tagged `:browser` so it stays out of the default `mix test` run.
  """

  use ContractWeb.FeatureCase, async: false

  @moduletag :browser

  feature "dark button switches to data-theme=studio-dark", %{session: session} do
    session
    |> Wallaby.Browser.resize_window(1280, 800)
    |> Wallaby.Browser.visit("/")
    |> Wallaby.Browser.click(Query.css(~s([data-phx-theme="studio-dark"])))
    |> assert_has(Query.css(~s(html[data-theme="studio-dark"]), visible: false))
  end

  feature "light button switches to data-theme=studio", %{session: session} do
    session
    |> Wallaby.Browser.resize_window(1280, 800)
    |> Wallaby.Browser.visit("/")
    |> Wallaby.Browser.click(Query.css(~s([data-phx-theme="studio-dark"])))
    |> Wallaby.Browser.click(Query.css(~s([data-phx-theme="studio"])))
    |> assert_has(Query.css(~s(html[data-theme="studio"]), visible: false))
  end

  feature "theme preference persists across reload", %{session: session} do
    session
    |> Wallaby.Browser.resize_window(1280, 800)
    |> Wallaby.Browser.visit("/")
    |> Wallaby.Browser.click(Query.css(~s([data-phx-theme="studio-dark"])))
    |> assert_has(Query.css(~s(html[data-theme="studio-dark"]), visible: false))
    |> Wallaby.Browser.visit("/")
    |> assert_has(Query.css(~s(html[data-theme="studio-dark"]), visible: false))
  end
end
