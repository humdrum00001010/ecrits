defmodule EcritsWeb.WorkspaceEditPreviewControllerTest do
  use EcritsWeb.ConnCase, async: false

  setup do
    root =
      Path.join(System.tmp_dir!(), "ecrits-edit-preview-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    File.cp!("test/fixtures/hwpx/real_contract.hwpx", Path.join(root, "contract.hwpx"))
    File.cp!("test/fixtures/office/table.docx", Path.join(root, "table.docx"))
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "renders a cropped HWPX edit descriptor as PNG", %{conn: conn, root: root} do
    params = %{
      "path" => root,
      "document" => "contract.hwpx",
      "ref" => Jason.encode!(%{"section" => 0, "paragraph" => 0, "offset" => 0})
    }

    conn = get(conn, ~p"/local/edit-preview?#{params}")

    assert response_content_type(conn, :png) =~ "image/png"
    assert ["ehwp"] = get_resp_header(conn, "x-ecrits-preview-backend")
    assert <<137, "PNG", 13, 10, 26, 10, _::binary>> = response(conn, 200)
  end

  test "renders a cropped Writer edit descriptor as PNG", %{conn: conn, root: root} do
    params = %{"path" => root, "document" => "table.docx", "ref" => "p0"}
    conn = get(conn, ~p"/local/edit-preview?#{params}")

    assert response_content_type(conn, :png) =~ "image/png"
    assert ["libreofficex"] = get_resp_header(conn, "x-ecrits-preview-backend")
    assert <<137, "PNG", 13, 10, 26, 10, _::binary>> = response(conn, 200)
  end

  test "does not render documents outside the declared workspace", %{conn: conn, root: root} do
    conn =
      get(
        conn,
        ~p"/local/edit-preview?#{%{"path" => root, "document" => "../contract.hwpx"}}"
      )

    assert response(conn, 404) == ""
  end
end
