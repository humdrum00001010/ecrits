defmodule ContractWeb.RetiredControllerTest do
  use ContractWeb.ConnCase, async: true

  @retired_get_paths [
    "/storage",
    "/dashboard",
    "/packets/packet-id",
    "/studio",
    "/studio/document-id",
    "/documents/document-id",
    "/documents/document-id/review",
    "/documents/document-id/rhwp-snapshots/1.hwp",
    "/settings",
    "/settings/api-tokens",
    "/users/register",
    "/users/log-in",
    "/users/log-in/token",
    "/users/settings",
    "/users/settings/confirm-email/token"
  ]

  test "hosted browser GET routes are retired", %{conn: conn} do
    for path <- @retired_get_paths do
      conn = get(conn, path)

      assert conn.status == 410
      assert conn.resp_body =~ "hosted route has been retired"
    end
  end

  test "hosted browser mutation routes are retired", %{conn: conn} do
    assert conn
           |> put_req_header("content-type", "application/octet-stream")
           |> put("/documents/direct-upload", "bytes")
           |> response(410)

    assert conn |> post("/users/log-in", %{}) |> response(410)
    assert conn |> post("/users/update-password", %{}) |> response(410)
    assert conn |> delete("/users/log-out") |> response(410)
  end
end
