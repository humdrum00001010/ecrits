defmodule ContractWeb.PageControllerTest do
  use ContractWeb.ConnCase

  test "GET / renders the landing page in Korean-primary copy", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    # Top-nav chrome stays English (not gettext-wrapped in layouts.ex).
    assert body =~ "Contract Studio"

    # Body copy: Korean is the rendered language under the pinned locale.
    # We assert on the headline and one commitment label to cover both
    # the above-fold and the definition-list sections.
    assert body =~ "검토를 묻는 초안"
    assert body =~ "법제처 인용 검증"
    assert body =~ "확약"
  end

  test "GET / embeds the small accompanying hero image", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "/images/landing/hero.png"
  end

  test "GET / has no pricing block (Wave 3C0-E removed it)", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    refute body =~ ~s(id="pricing")
    refute body =~ "Per-seat"
    refute body =~ "TBD"
  end

  test "GET / has no marketing button-CTAs on landing (links only)", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    # We allow `btn btn-primary` in the top-nav (Register button) and
    # in the mobile drawer; assert there's no `btn btn-primary` inside
    # the landing body container itself.
    [_pre, body_block] = String.split(body, ~s(<div class="max-w-4xl), parts: 2)
    [landing_body, _post] = String.split(body_block, "</main>", parts: 2)
    refute landing_body =~ "btn btn-primary"
    refute landing_body =~ "btn-ghost"
  end

  test "GET / exposes the hamburger drawer toggle on mobile", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    # The drawer toggle is the input + label pair used by DaisyUI's drawer.
    assert body =~ ~s(id="mobile-nav-drawer")
    assert body =~ ~s(for="mobile-nav-drawer")
  end
end
