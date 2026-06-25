defmodule EcritsWeb.LocalRootTest do
  use EcritsWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "GET /" do
    test "renders the local workspace mount screen for anonymous users", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#local-mount-root")
      assert has_element?(lv, "#local-mount-picker-surface[data-role='mount-picker-surface']")

      assert has_element?(
               lv,
               "#local-native-directory-picker[data-role='native-directory-picker']"
             )

      assert has_element?(lv, "#local-mount-choose[type='button']", "Open folder")
      assert has_element?(lv, "#local-native-directory-picker #local-path-form[method='get']")

      assert has_element?(
               lv,
               "#local-path-input[name='path']"
             )

      assert has_element?(
               lv,
               "#local-path-submit[type='submit'][aria-label='Open path'][title='Open this path']"
             )

      assert has_element?(lv, "#local-path-submit", "Open")
      refute has_element?(lv, "#local-manual-path-picker")
      refute has_element?(lv, "#local-provider-picker[data-role='provider-picker']")
      refute has_element?(lv, "#local-agent-provider-picker")
      refute has_element?(lv, "#local-directory-picker[data-role='directory-picker']")
      refute has_element?(lv, "#local-mount-submit")
      refute has_element?(lv, "#local-mount-form")
      refute has_element?(lv, "#local-mount-path")
    end

    test "renders the same mount screen when stale auth session data is present", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> Phoenix.ConnTest.init_test_session(%{user_token: "retired-token"})
        |> live(~p"/")

      assert has_element?(lv, "#local-mount-root")
      assert has_element?(lv, "#local-mount-picker-surface[data-role='mount-picker-surface']")

      assert has_element?(
               lv,
               "#local-native-directory-picker[data-role='native-directory-picker']"
             )

      assert has_element?(lv, "#local-mount-choose[type='button']", "Open folder")
      assert has_element?(lv, "#local-native-directory-picker #local-path-form[method='get']")

      assert has_element?(
               lv,
               "#local-path-input[name='path']"
             )

      assert has_element?(
               lv,
               "#local-path-submit[type='submit'][aria-label='Open path'][title='Open this path']"
             )

      assert has_element?(lv, "#local-path-submit", "Open")
      refute has_element?(lv, "#local-manual-path-picker")
      refute has_element?(lv, "#local-provider-picker[data-role='provider-picker']")
      refute has_element?(lv, "#local-agent-provider-picker")
      refute has_element?(lv, "#local-directory-picker[data-role='directory-picker']")
      refute has_element?(lv, "#local-mount-submit")
      refute has_element?(lv, "#local-mount-form")
      refute has_element?(lv, "#local-mount-path")
      refute has_element?(lv, ~s(a[href="/users/log-in"]))
    end
  end
end
