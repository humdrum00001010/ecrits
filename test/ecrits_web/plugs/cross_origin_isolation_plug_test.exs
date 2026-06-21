defmodule EcritsWeb.Plugs.CrossOriginIsolationPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias EcritsWeb.Plugs.CrossOriginIsolationPlug

  # Simulate a prior plug setting cache-control so these assertions prove the
  # WASM asset responses replace it with the no-cache policy.
  defp run(path) do
    conn =
      conn(:get, path)
      |> put_req_header("accept-encoding", "identity")
      |> put_resp_header("cache-control", "public")
      |> CrossOriginIsolationPlug.call([])

    if conn.halted do
      conn
    else
      send_resp(conn, 200, "")
    end
  end

  defp run_head(path, accept_encoding) do
    conn =
      conn(:head, path)
      |> put_req_header("accept-encoding", accept_encoding)
      |> put_resp_header("cache-control", "public")
      |> CrossOriginIsolationPlug.call([])

    if conn.halted do
      conn
    else
      send_resp(conn, 200, "")
    end
  end

  test "office WASM artifacts are isolated AND forced to revalidate (no stale-mixed bundle)" do
    conn = run("/assets/office/soffice.wasm")

    assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
    assert get_resp_header(conn, "cross-origin-embedder-policy") == ["require-corp"]
    # The matched glue/wasm/data set must never be served stale-mixed, so the
    # before_send overrides Plug.Static's `public` with `no-cache`.
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
  end

  test "office WASM artifacts ignore optional brotli scratch siblings" do
    conn = run_head("/assets/office/soffice.wasm", "br")

    assert get_resp_header(conn, "content-encoding") == []
    assert get_resp_header(conn, "vary") == []
  end

  test "HWP WASM artifacts are forced to revalidate without office isolation" do
    conn = run("/assets/rhwp/rhwp_bg.wasm")

    assert get_resp_header(conn, "cross-origin-opener-policy") == []
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
  end

  test "HWP wasm-bindgen module is served without office isolation" do
    conn = run("/assets/rhwp/rhwp.js")

    assert get_resp_header(conn, "content-type") == ["text/javascript; charset=utf-8"]
    assert get_resp_header(conn, "cross-origin-opener-policy") == []
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
  end

  test "the workspace page is isolated but its cache-control is left untouched" do
    conn = run("/workspace")

    assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
    assert get_resp_header(conn, "cache-control") == ["public"]
  end

  test "unrelated assets get neither isolation nor the revalidation override" do
    conn = run("/assets/js/app.js")

    assert get_resp_header(conn, "cross-origin-opener-policy") == []
    assert get_resp_header(conn, "cache-control") == ["public"]
  end
end
