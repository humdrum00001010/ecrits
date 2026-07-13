defmodule EcritsWeb.WorkspaceDocumentBytesControllerTest do
  use EcritsWeb.ConnCase, async: true

  alias Ecrits.Document.ByteSpool

  test "uploads raw document bytes to a server temp token", %{conn: conn} do
    bytes = "browser exported document bytes"

    conn =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("x-csrf-token", Plug.CSRFProtection.get_csrf_token())
      |> post(~p"/local/document-bytes", bytes)

    assert %{"ok" => true, "bytes_token" => token, "bytes" => byte_size} =
             json_response(conn, 200)

    assert byte_size == byte_size(bytes)
    assert {:ok, ^bytes} = ByteSpool.decode(%{"bytes_token" => token})
  end
end
