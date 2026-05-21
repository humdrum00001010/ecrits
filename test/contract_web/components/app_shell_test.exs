defmodule ContractWeb.Components.AppShellTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias ContractWeb.Components.AppShell

  describe "app_shell/1" do
    test "renders v33 shared topbar with brand icon + 보관함 link, and no 스튜디오 state span or upload action" do
      inner_block = [
        %{
          __slot__: :inner_block,
          inner_block: fn _, _ -> Phoenix.HTML.raw(~s(<main id="shell-content">문서 목록</main>)) end
        }
      ]

      html =
        render_component(&AppShell.app_shell/1,
          active: "보관함",
          inner_block: inner_block
        )

      assert html =~ ~s(href="/")
      # Brand wears the brand-mark SVG to the left of the wordmark.
      assert html =~ ~s(src="/assets/icons/brand-mark.svg")
      assert html =~ "계약기계"
      assert html =~ ~s(href="/storage")
      assert html =~ "보관함"
      # The legacy 대시보드 label was renamed to 보관함 (2026-05-18 directive).
      refute html =~ "대시보드"
      refute html =~ ~s(href="/dashboard")
      assert html =~ "shell-content"
      assert html =~ "문서 목록"
      # Active surface marker → font-semibold weight + full-strength text color.
      assert html =~ "text-base-content font-semibold"
      # 2026-05-17 owner directive: 스튜디오 state span removed from topbar.
      refute html =~ "스튜디오"
      refute html =~ "계약서 업로드"
      refute html =~ "새 문서"
      # No current_scope passed → account menu is omitted.
      refute html =~ ~s(data-role="user-menu")
    end

    test "renders the account menu when current_scope is signed in" do
      inner_block = [
        %{
          __slot__: :inner_block,
          inner_block: fn _, _ -> Phoenix.HTML.raw("") end
        }
      ]

      scope = %{user: %{id: 1, email: "lawyer@example.com"}}

      html =
        render_component(&AppShell.app_shell/1,
          active: "보관함",
          current_scope: scope,
          inner_block: inner_block
        )

      assert html =~ ~s(data-role="user-menu")
      assert html =~ "lawyer@example.com"
      assert html =~ ~s(href="/users/settings")
      assert html =~ ~s(href="/users/log-out")

      # 2026-05-18 owner directive: the brand link must take a signed-in
      # user back to their library at /storage rather than the marketing
      # landing page. The brand <a> carries the 계약기계 aria-label so we
      # use that as the structural anchor instead of a since-migrated
      # `.brand` class.
      assert html =~ ~r/<a[^>]*href="\/storage"[^>]*aria-label="계약기계"/u
    end

    test "anonymous brand link points to / (landing page)" do
      inner_block = [
        %{
          __slot__: :inner_block,
          inner_block: fn _, _ -> Phoenix.HTML.raw("") end
        }
      ]

      html =
        render_component(&AppShell.app_shell/1,
          active: nil,
          current_scope: nil,
          inner_block: inner_block
        )

      assert html =~ ~r/<a[^>]*href="\/"[^>]*aria-label="계약기계"/u
    end

    test "v33 icon source assets are tracked outside generated static assets" do
      app_root = Path.expand("../../..", __DIR__)
      icon_dir = Path.join(app_root, "priv/static/images/icons")

      for icon <-
            ~w(brand-mark document upload search chevron-down more-vertical send check clock history) do
        path = Path.join(icon_dir, "#{icon}.svg")
        relative_path = Path.relative_to(path, app_root)

        assert File.exists?(path)
        assert {_, 1} = System.cmd("git", ["check-ignore", "-q", relative_path], cd: app_root)
      end
    end
  end
end
