defmodule EcritsWeb.WorkspaceDocumentBytesController do
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

  alias Ecrits.Document.ByteSpool
  alias Ecrits.Document

  @max_upload_bytes 256 * 1024 * 1024
  @read_length 1 * 1024 * 1024
  @read_timeout 30_000

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

  def create(conn, _params) do
    with {:ok, token, path} <- ByteSpool.reserve(),
         {:ok, bytes} <- write_request_body(conn, path) do
      json(conn, %{ok: true, bytes_token: token, bytes: bytes})
    else
      {:error, :too_large} ->
        conn
        |> put_status(:payload_too_large)
        |> json(%{ok: false, error: "document bytes upload is too large"})

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{ok: false, error: inspect(reason)})
    end
  end

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

  defp write_request_body(conn, path) do
    result =
      File.open(path, [:write, :binary], fn io ->
        read_body_to_file(conn, io, 0)
      end)

    case result do
      {:ok, {:ok, bytes}} ->
        {:ok, bytes}

      {:ok, {:error, reason}} ->
        _ = File.rm(path)
        {:error, reason}

      {:error, reason} ->
        _ = File.rm(path)
        {:error, reason}
    end
  end

  defp read_body_to_file(conn, io, total) do
    case Plug.Conn.read_body(conn,
           length: @read_length,
           read_length: @read_length,
           read_timeout: @read_timeout
         ) do
      {:ok, chunk, _conn} ->
        write_chunk(io, chunk, total)

      {:more, chunk, conn} ->
        case write_chunk(io, chunk, total) do
          {:ok, next_total} -> read_body_to_file(conn, io, next_total)
          {:error, _reason} = error -> error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_chunk(_io, chunk, total) when total + byte_size(chunk) > @max_upload_bytes,
    do: {:error, :too_large}

  defp write_chunk(io, chunk, total) do
    :ok = IO.binwrite(io, chunk)
    {:ok, total + byte_size(chunk)}
  end
end
