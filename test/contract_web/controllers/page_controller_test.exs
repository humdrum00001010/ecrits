defmodule ContractWeb.PageControllerTest do
  use ContractWeb.ConnCase, async: true

  describe "GET /" do
    test "serves the v33 landing page as a dead view for anonymous users", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      # AppShell topbar + brand + nav.
      assert html =~ ~s(class="topbar")
      assert html =~ ~s(href="/")
      assert html =~ "Contract Studio"
      assert html =~ ~s(href="/dashboard")
      assert html =~ "대시보드"
      assert html =~ "스튜디오"

      # v33 landing body.
      assert html =~ ~s(id="landing-page")
      assert html =~ ~s(class="landing-page")
      assert html =~ ~s(id="landing-headline")
      assert html =~ "프로젝트의 맥락을"
      assert html =~ "계약 조항으로"
      assert html =~ "구체화합니다."

      assert html =~ "Contract Studio는 계약서를 쓰기 전에"
      assert html =~ "프로젝트가 실제로 어떻게 진행되는지 묻습니다."
      assert html =~ "그 답은 조항과 변경 이력으로 남습니다."

      # CTAs.
      assert html =~ "대시보드 열기"
      assert html =~ "작동 방식 보기"
      refute html =~ ~s(href="/users/log-in">대시보드 열기)

      # Dossier panels (01/02/03).
      assert html =~ "project-context-panel"
      assert html =~ "agent-questions-panel"
      assert html =~ "change-history-panel"
      assert html =~ "프로젝트 맥락"
      assert html =~ "중요 질문"
      assert html =~ "조항과 변경 이력"
    end

    test "topbar does not surface dashboard-only actions on the landing page", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      refute html =~ ~r/<header[^>]*class="[^"]*topbar[^"]*"[^>]*>.*계약서 업로드.*<\/header>/su
      refute html =~ ~r/<header[^>]*class="[^"]*topbar[^"]*"[^>]*>.*새 문서.*<\/header>/su
    end

    test "landing body has no implementation-jargon leaks", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      landing_html = landing_body(html)

      refute landing_html =~ "IR"
      refute landing_html =~ "MCP"
      refute landing_html =~ "patch"
      refute landing_html =~ "tool call"
      refute landing_html =~ "ledger"
    end
  end

  defp landing_body(html) do
    [_before, rest] = String.split(html, ~s(<main class="landing-page"), parts: 2)
    [body, _after] = String.split(rest, "</main>", parts: 2)
    body
  end
end
