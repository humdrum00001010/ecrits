defmodule EcritsWeb.Plugs.CrossOriginIsolationPlugTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias EcritsWeb.Plugs.CrossOriginIsolationPlug

  # Simulate the real pipeline: Plug.Static would set `cache-control: public`
  # before the response is sent; the plug's before_send must override it for
  # office assets. send_resp/3 fires the registered before_send callbacks.
  defp run(path) do
    conn(:get, path)
    |> put_resp_header("cache-control", "public")
    |> CrossOriginIsolationPlug.call([])
    |> send_resp(200, "")
  end

  test "office WASM artifacts are isolated AND forced to revalidate (no stale-mixed bundle)" do
    conn = run("/assets/office/soffice.wasm")

    assert get_resp_header(conn, "cross-origin-opener-policy") == ["same-origin"]
    assert get_resp_header(conn, "cross-origin-embedder-policy") == ["credentialless"]
    # The matched glue/wasm/data set must never be served stale-mixed, so the
    # before_send overrides Plug.Static's `public` with `no-cache`.
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
