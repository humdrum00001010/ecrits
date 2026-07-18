defmodule EcritsWeb.WorkspaceRootTest do
  use EcritsWeb.ConnCase

  import Phoenix.LiveViewTest

  describe "GET /" do
    test "renders the local workspace mount screen for anonymous users", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      assert has_element?(lv, "#mount-root")
      assert has_element?(lv, "#mount-picker-surface[data-role='mount-picker-surface']")

      assert has_element?(
               lv,
               "#native-directory-picker[data-role='native-directory-picker']"
             )

      assert has_element?(lv, "#mount-choose[type='button']", "Open folder")

      assert has_element?(
               lv,
               "#native-directory-picker #path-form[phx-submit='workspace.path.open']"
             )

      assert has_element?(
               lv,
               "#path-input[name='mount_path[path]']"
             )

      assert has_element?(
               lv,
               "#path-submit[type='submit'][aria-label='Open path'][title='Open this path']"
             )

      assert has_element?(lv, "#path-submit", "Open")
      refute has_element?(lv, "#manual-path-picker")
      refute has_element?(lv, "#provider-picker[data-role='provider-picker']")
      refute has_element?(lv, "#agent-provider-picker")
      refute has_element?(lv, "#directory-picker[data-role='directory-picker']")
      refute has_element?(lv, "#mount-submit")
      refute has_element?(lv, "#mount-form")
      refute has_element?(lv, "#mount-path")
    end

    test "renders the same mount screen when stale auth session data is present", %{conn: conn} do
      {:ok, lv, _html} =
        conn
        |> Phoenix.ConnTest.init_test_session(%{user_token: "retired-token"})
        |> live(~p"/")

      assert has_element?(lv, "#mount-root")
      assert has_element?(lv, "#mount-picker-surface[data-role='mount-picker-surface']")

      assert has_element?(
               lv,
               "#native-directory-picker[data-role='native-directory-picker']"
             )

      assert has_element?(lv, "#mount-choose[type='button']", "Open folder")

      assert has_element?(
               lv,
               "#native-directory-picker #path-form[phx-submit='workspace.path.open']"
             )

      assert has_element?(
               lv,
               "#path-input[name='mount_path[path]']"
             )

      assert has_element?(
               lv,
               "#path-submit[type='submit'][aria-label='Open path'][title='Open this path']"
             )

      assert has_element?(lv, "#path-submit", "Open")
      refute has_element?(lv, "#manual-path-picker")
      refute has_element?(lv, "#provider-picker[data-role='provider-picker']")
      refute has_element?(lv, "#agent-provider-picker")
      refute has_element?(lv, "#directory-picker[data-role='directory-picker']")
      refute has_element?(lv, "#mount-submit")
      refute has_element?(lv, "#mount-form")
      refute has_element?(lv, "#mount-path")
      refute has_element?(lv, ~s(a[href="/users/log-in"]))
    end
  end
end
