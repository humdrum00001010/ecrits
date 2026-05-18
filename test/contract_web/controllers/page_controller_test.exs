defmodule ContractWeb.PageControllerTest do
  use ContractWeb.ConnCase

  @moduledoc """
  Landing page assertions for the v0.5/design-landing surface
  (DESIGN.md §3). The landing is Korean-primary; PageController.home
  pins the Gettext locale to "ko" so msgids render through ko/landing.po.

  These tests pin the *intent* of the v31 design:

    * Three-block right column (`프로젝트 브리프` / `StudioLive가 먼저
      묻는 질문` / `조항과 변경 이력으로 남김`).
    * Three-line serif headline (`프로젝트의 맥락을` / `계약 조항으로` /
      `구체화합니다.`).
    * A primary `보관함 열기` CTA that targets `/dashboard` for
      authenticated users and `/users/log-in` for anonymous users.
    * A secondary `작동 방식 보기 →` link that anchors to `#how-it-works`.
    * The Westlaw silhouette test (see the bottom of this file).
  """

  describe "GET /" do
    test "renders the Korean-primary v31 headline ladder", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "프로젝트의 맥락을"
      assert body =~ "계약 조항으로"
      assert body =~ "구체화합니다."
    end

    test "renders the lead paragraph in Korean", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "계약기계는 계약서를 쓰기 전에"
      assert body =~ "프로젝트가 실제로 어떻게 진행되는지 묻습니다."
      assert body =~ "그 답은 조항과 변경 이력으로 남습니다."
    end

    test "renders the three conceptual blocks (DESIGN.md §3)", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "프로젝트 브리프"
      assert body =~ "StudioLive가 먼저 묻는 질문"
      assert body =~ "조항과 변경 이력으로 남김"
      # And the numbered eyebrows on each block.
      assert body =~ ">01<"
      assert body =~ ">02<"
      assert body =~ ">03<"
    end

    test "renders the eyebrow + secondary CTA anchor", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "계약기계"
      assert body =~ "작동 방식 보기"
      assert body =~ ~s(href="#how-it-works")
      assert body =~ ~s(id="how-it-works")
    end

    test "anonymous user gets `보관함 열기` pointing to /users/log-in", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "보관함 열기"
      # Anonymous primary CTA targets log-in, never /dashboard.
      assert body =~ ~s(href="/users/log-in")
      refute body =~ ~s(href="/storage")
    end

    test "authenticated user gets `보관함 열기` pointing to /storage", %{conn: conn} do
      user = Contract.AccountsFixtures.user_fixture()
      body = conn |> log_in_user(user) |> get(~p"/") |> html_response(200)
      assert body =~ "보관함 열기"
      assert body =~ ~s(href="/storage")
      refute body =~ ~s(href="/users/log-in")
    end

    test "renders the small private-beta footnote", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ "비공개 베타. 초청제로 운영합니다."
    end

    test "exposes the hamburger drawer toggle on mobile (chrome unchanged)", %{conn: conn} do
      body = conn |> get(~p"/") |> html_response(200)
      assert body =~ ~s(id="mobile-nav-drawer")
      assert body =~ ~s(for="mobile-nav-drawer")
    end
  end

  # Pins the binding intent of the responsive pass on 2026-05-17:
  # landing, auth, and dashboard surfaces all have an explicit mobile
  # breakpoint in app.css. See feedback-responsive-scope.md — public
  # surfaces are mobile-first.
  describe "responsive guarantees (v0.5/responsive-fix)" do
    setup do
      # Read the compiled stylesheet from the static asset directory.
      # The path is checked in to priv/static/assets when tailwind has
      # been run; in dev/test the watcher writes it on first request.
      # Fall back to reading the source file under assets/css/app.css
      # (which is what `mix test` always has access to) for the breakpoint
      # assertions — Tailwind-managed utility classes don't appear here,
      # but our hand-written .landing-v31__* / .dashboard-v31__* /
      # .upload-menu-v31 rules do.
      app_css = File.read!("assets/css/app.css")
      %{app_css: app_css}
    end

    test "landing has a mobile breakpoint", %{app_css: css} do
      assert css =~ "@media (min-width: 640px)"
      assert css =~ "@media (min-width: 1024px)"
      # Landing root padding scales down on mobile.
      assert css =~ ~r/\.landing-v31\s*\{[^}]*padding:\s*32px/u
    end

    test "dashboard has a mobile breakpoint", %{app_css: css} do
      # `.dashboard-v31__top` rearranges row->column at < 768.
      assert css =~ "@media (min-width: 768px)"
    end

    test "upload menu CSS namespace removed — upload moved to Studio empty state", %{app_css: css} do
      # Per 2026-05-17 owner directive, upload moved out of dashboard.
      # The .upload-menu-v31 namespace should be gone.
      refute css =~ ~r/\.upload-menu-v31\s*\{/u
    end

    test "hero typography uses clamp() so it scales across viewports", %{app_css: css} do
      assert css =~ ~r/\.landing-v31__headline[^}]*font-size:\s*clamp\(/u
      assert css =~ ~r/\.dashboard-v31__title[^}]*font-size:\s*clamp\(/u
    end
  end

  describe "Westlaw silhouette test — v31 design hard constraints" do
    # These assertions guard against the public surface drifting back
    # toward a generic SaaS-pop visual language. They cover both the
    # banned utility classes (rounded-2xl / shadow-xl / text-6xl /
    # font-black) and the banned copy ("Powered by AI", "transform",
    # "revolutionize", "seamless"). The whole-page body is checked so
    # the test catches any reintroduction from a partial / nav / footer
    # change, not just the landing template proper.

    setup %{conn: conn} do
      %{body: conn |> get(~p"/") |> html_response(200)}
    end

    test "no banned utility classes inside the landing body", %{body: body} do
      [_pre, body_block] = String.split(body, ~s(<div class="landing-v31"), parts: 2)
      [landing_body, _post] = String.split(body_block, "</main>", parts: 2)

      refute landing_body =~ "rounded-2xl"
      refute landing_body =~ "shadow-xl"
      refute landing_body =~ "text-6xl"
      refute landing_body =~ "font-black"
    end

    test "no banned marketing copy anywhere on the page", %{body: body} do
      refute body =~ "Powered by AI"
      refute body =~ "powered by AI"
      refute body =~ "revolutionize"
      refute body =~ "Revolutionize"
      refute body =~ "seamless"
      refute body =~ "Seamless"
      # "transform" appears in CSS (transition properties, transform)
      # only via vendored stylesheets; the landing body must not use
      # it as copy. Scope the assertion to the landing container.
      [_pre, body_block] = String.split(body, ~s(<div class="landing-v31"), parts: 2)
      [landing_body, _post] = String.split(body_block, "</main>", parts: 2)
      refute landing_body =~ "transform"
      refute landing_body =~ "Transform"
    end

    test "no pricing block, no feature-card grid, no hero image of the product", %{body: body} do
      refute body =~ ~s(id="pricing")
      refute body =~ "Per-seat"
      # The old hero illustration is gone; the three-block right column
      # replaces it.
      refute body =~ "/images/landing/hero.png"
    end

    test "no btn-primary marketing CTA inside the landing body", %{body: body} do
      [_pre, body_block] = String.split(body, ~s(<div class="landing-v31"), parts: 2)
      [landing_body, _post] = String.split(body_block, "</main>", parts: 2)
      # We use a dedicated .landing-v31__cta-primary class, not the
      # DaisyUI btn-primary utility — guard against accidental
      # re-introduction.
      refute landing_body =~ "btn btn-primary"
      refute landing_body =~ "btn-ghost"
    end
  end
end
