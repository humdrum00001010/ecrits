defmodule EcritsWeb.EndpointWasmAssetTest do
  use EcritsWeb.ConnCase, async: true

  test "serves Office browser WASM metadata from libreofficex priv", %{conn: conn} do
    path = Application.app_dir(:libreofficex, "priv/wasm/soffice.data.js.metadata")

    conn = get(conn, "/assets/office/soffice.data.js.metadata")

    assert response(conn, 200) == File.read!(path)
    assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
  end

  test "serves HWP browser WASM from ehwp priv", %{conn: conn} do
    path = Application.app_dir(:ehwp, "priv/wasm/rhwp_bg.wasm")

    conn = get(conn, "/assets/rhwp/rhwp_bg.wasm")

    assert response(conn, 200) == File.read!(path)
    assert get_resp_header(conn, "cross-origin-opener-policy") == []
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
  end

  test "serves HWP wasm-bindgen module from ehwp priv", %{conn: conn} do
    path = Application.app_dir(:ehwp, "priv/wasm/rhwp.js")

    conn = get(conn, "/assets/rhwp/rhwp.js")

    assert response(conn, 200) == File.read!(path)
    assert get_resp_header(conn, "content-type") == ["text/javascript; charset=utf-8"]
    assert get_resp_header(conn, "cross-origin-opener-policy") == []
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
  end
end
