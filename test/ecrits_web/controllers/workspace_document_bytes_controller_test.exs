defmodule EcritsWeb.WorkspaceDocumentBytesControllerTest do
  use EcritsWeb.ConnCase, async: true

  alias Ecrits.Document
  alias Ecrits.Document.PreviewSnapshot

  test "the retired upload POST no longer routes", %{conn: conn} do
    response =
      conn
      |> put_req_header("content-type", "application/octet-stream")
      |> post(~p"/document-bytes", "browser exported document bytes")

    assert response.status == 404
  end

  test "serves a document-bound preview snapshot repeatedly after the source changes", %{
    conn: conn
  } do
    root = preview_root()
    relative_path = "preview.hwpx"
    path = Path.join(root, relative_path)
    edit_time_bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")
    later_bytes = rezip_hwpx(edit_time_bytes, "later-version")

    File.mkdir_p!(root)
    File.write!(path, edit_time_bytes)

    document_id = Document.id_for(root, relative_path)
    assert {:ok, snapshot} = PreviewSnapshot.put(document_id, edit_time_bytes)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(Path.dirname(PreviewSnapshot.path(document_id, snapshot.id)))
    end)

    File.write!(path, later_bytes)

    url = snapshot_url(root, relative_path, snapshot.id)
    first = get(conn, url)

    assert response(first, 200) == edit_time_bytes

    assert get_resp_header(first, "cache-control") == [
             "private, max-age=31536000, immutable"
           ]

    assert get_resp_header(first, "etag") == [~s("#{snapshot.id}")]

    second = first |> recycle() |> get(url)
    assert response(second, 200) == edit_time_bytes

    live_url =
      "/document-bytes?" <>
        URI.encode_query(%{"path" => root, "document" => relative_path})

    current = second |> recycle() |> get(live_url)
    assert response(current, 200) == later_bytes

    File.rm!(path)
    refute File.exists?(path)

    after_source_delete = current |> recycle() |> get(url)
    assert response(after_source_delete, 200) == edit_time_bytes
  end

  test "does not serve one document's preview snapshot through another document path", %{
    conn: conn
  } do
    root = preview_root()
    bytes = File.read!("test/fixtures/hwpx/real_contract.hwpx")
    first_path = Path.join(root, "first.hwpx")
    other_path = Path.join(root, "other.hwpx")

    File.mkdir_p!(root)
    File.write!(first_path, bytes)
    File.write!(other_path, bytes)

    first_document_id = Document.id_for(root, "first.hwpx")
    assert {:ok, snapshot} = PreviewSnapshot.put(first_document_id, bytes)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(Path.dirname(PreviewSnapshot.path(first_document_id, snapshot.id)))
    end)

    wrong_document = get(conn, snapshot_url(root, "other.hwpx", snapshot.id))
    assert response(wrong_document, 404) == ""

    replacement = if String.starts_with?(snapshot.id, "0"), do: "1", else: "0"
    tampered_id = replacement <> String.slice(snapshot.id, 1..-1//1)
    tampered = wrong_document |> recycle() |> get(snapshot_url(root, "first.hwpx", tampered_id))

    assert response(tampered, 404) == ""
  end

  defp preview_root do
    Path.join(
      System.tmp_dir!(),
      "ecrits-preview-controller-#{System.unique_integer([:positive, :monotonic])}"
    )
  end

  defp snapshot_url(root, relative_path, snapshot_id) do
    "/document-bytes?" <>
      URI.encode_query(%{
        "path" => root,
        "document" => relative_path,
        "snapshot" => snapshot_id
      })
  end

  defp rezip_hwpx(bytes, marker) do
    assert {:ok, entries} = :zip.unzip(bytes, [:memory])

    entries =
      Enum.reject(entries, fn {name, _contents} -> name == ~c"preview-version.txt" end)

    assert {:ok, {_name, rewritten}} =
             :zip.create(
               ~c"preview-version.hwpx",
               entries ++ [{~c"preview-version.txt", marker}],
               [:memory]
             )

    rewritten
  end
end
