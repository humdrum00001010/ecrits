defmodule EcritsWeb.LocalDocumentBytesController do
  @moduledoc """
  Streams the raw bytes of a local workspace document to the browser so an
  in-browser WASM engine can render + edit it on a `<canvas>`:

    * HWP/HWPX -> rhwp_core (`new HwpDocument(bytes)`)
    * docx/pptx/xlsx (office) -> LibreOffice WASM (`loadFromBytes(bytes)`)

  The server stays the source of truth for the bytes (persistence); the browser
  owns render/hit-test/edit.

  Gating: the request carries the workspace root `path` and the document
  `document` relative path. Both are validated through `Document.open_args/3`,
  which normalizes the relative path (rejecting traversal), confirms it resolves
  to a regular file INSIDE the workspace root, and confirms the file is a
  supported HWP/HWPX or office format by magic bytes. Anything else is a 404 —
  this route never serves arbitrary filesystem paths.
  """

  use EcritsWeb, :controller

  alias Ecrits.Local.Document

  def show(conn, %{"path" => workspace_path, "document" => relative_path})
      when is_binary(workspace_path) and is_binary(relative_path) do
    with {:ok, args} <- Document.open_args(workspace_path, relative_path),
         path = Keyword.fetch!(args, :path),
         format = Keyword.fetch!(args, :format),
         true <- Document.ehwp_format?(format) or Document.libreoffice_format?(format),
         {:ok, bytes} <- File.read(path) do
      conn
      |> put_resp_content_type(Document.content_type(format))
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, maybe_flatten_pptx(format, bytes))
    else
      _ -> send_resp(conn, 404, "")
    end
  end

  def show(conn, _params), do: send_resp(conn, 400, "")

  # pptx "build" slides animate overlapping shapes; the static WASM viewer paints
  # all build states at once → ghosted glyphs (#57 D). Serve the animation
  # final-state for VIEWING. Fail-safe: any error serves the original bytes.
  defp maybe_flatten_pptx("pptx", bytes) do
    case Ecrits.Doc.PptxFlatten.flatten_animations(bytes) do
      {:ok, flattened} -> flattened
      _ -> bytes
    end
  end

  defp maybe_flatten_pptx(_format, bytes), do: bytes
end
