defmodule EcritsWeb.Plugs.CrossOriginIsolationPlug do
  @moduledoc """
  Opt-in cross-origin isolation for the LibreOffice->WASM client editor, plus
  pre-compressed (brotli) serving of the large office WASM artifacts.

  ## Cross-origin isolation

  The office WASM build (`assets/vendor/office/soffice.wasm`) is an Emscripten
  PThreads build: it allocates a *shared* `WebAssembly.Memory` (`shared: true`),
  which requires `SharedArrayBuffer`, which the browser only exposes when the
  page is **cross-origin isolated** (`crossOriginIsolated === true`). That in turn
  requires the document response to carry:

      Cross-Origin-Opener-Policy:   same-origin
      Cross-Origin-Embedder-Policy: credentialless

  We set these ONLY on the local workspace page and the `/assets/office/*` WASM
  artifacts (not the whole app) to keep the blast radius small — COOP/COEP can
  block cross-origin embeds elsewhere. `credentialless` (vs `require-corp`) lets
  cross-origin no-cors subresources (e.g. provider favicons in the chat rail)
  still load without the remote opting in via CORP, while keeping isolation.

  We also stamp `Cross-Origin-Resource-Policy: same-origin` so the same-origin
  WASM/data files remain loadable from the isolated page.

  ## Brotli pre-compression

  `soffice.wasm` (~138 MB) and `soffice.data` (~96 MB) are served UNCOMPRESSED by
  Plug.Static, which only does gzip (`.gz`) and not brotli. Pre-compressed `.br`
  siblings (`soffice.wasm.br`, `soffice.data.br`, ...) shrink the transfer ~3-4x.
  When a request for one of these office artifacts accepts `br` AND a `<file>.br`
  exists on disk, this plug serves the `.br` bytes directly with
  `content-encoding: br` (plus the correct `content-type`, the isolation/CORP
  headers, and `cache-control: no-cache`) and halts BEFORE Plug.Static. If `br`
  is not accepted or no `.br` sibling exists, we fall through to Plug.Static which
  serves the identity file (still stamped with the isolation + no-cache headers
  via `register_before_send/2` below).
  """

  @behaviour Plug

  import Plug.Conn

  @office_prefix "/assets/office/"

  # Static root on disk for the office artifacts.
  @office_dir Application.app_dir(:ecrits, "priv/static/assets/office")

  # Only these extensions are eligible for brotli pre-compression.
  @brotli_exts ~w(.wasm .data .js .metadata)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> maybe_isolate()
    |> maybe_serve_brotli()
  end

  defp maybe_isolate(conn) do
    if isolate?(conn) do
      conn
      |> put_resp_header("cross-origin-opener-policy", "same-origin")
      |> put_resp_header("cross-origin-embedder-policy", "credentialless")
      |> put_resp_header("cross-origin-resource-policy", "same-origin")
    else
      conn
    end
  end

  # Serve a pre-compressed `.br` sibling for the large office artifacts when the
  # client accepts brotli and the file exists. Halts before Plug.Static. When we
  # do NOT short-circuit, we still register the office cache-control override so
  # Plug.Static's identity response gets `cache-control: no-cache`.
  defp maybe_serve_brotli(%Plug.Conn{request_path: path} = conn) do
    cond do
      not String.starts_with?(path, @office_prefix) ->
        conn

      conn.method not in ["GET", "HEAD"] ->
        revalidate_office(conn)

      true ->
        case brotli_file(path) do
          {:ok, br_path, content_type} when conn.method == "GET" ->
            if accepts_brotli?(conn), do: send_brotli(conn, br_path, content_type), else: revalidate_office(conn)

          # HEAD with a .br available: advertise br + content-type but no body.
          {:ok, _br_path, content_type} ->
            if accepts_brotli?(conn) do
              conn
              |> put_resp_header("content-type", content_type)
              |> put_resp_header("content-encoding", "br")
              |> delete_resp_header("vary")
              |> put_resp_header("vary", "accept-encoding")
              |> put_resp_header("cache-control", "no-cache")
              |> send_resp(200, "")
              |> halt()
            else
              revalidate_office(conn)
            end

          :error ->
            revalidate_office(conn)
        end
    end
  end

  defp send_brotli(conn, br_path, content_type) do
    case File.read(br_path) do
      {:ok, bytes} ->
        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("content-encoding", "br")
        |> delete_resp_header("vary")
        |> put_resp_header("vary", "accept-encoding")
        |> put_resp_header("cache-control", "no-cache")
        |> send_resp(200, bytes)
        |> halt()

      {:error, _} ->
        # Disk read failed unexpectedly — fall back to identity via Plug.Static.
        revalidate_office(conn)
    end
  end

  # Map a request path under /assets/office/ to its on-disk `.br` sibling and the
  # content-type to advertise. Returns `:error` when the extension is ineligible,
  # the path escapes the office dir, or no `.br` file exists.
  defp brotli_file(request_path) do
    rel = String.trim_leading(request_path, @office_prefix)

    with ext when ext in @brotli_exts <- Path.extname(rel),
         false <- String.contains?(rel, ".."),
         abs = Path.join(@office_dir, rel),
         br = abs <> ".br",
         true <- File.regular?(br) do
      {:ok, br, content_type_for(ext)}
    else
      _ -> :error
    end
  end

  defp content_type_for(".wasm"), do: "application/wasm"
  defp content_type_for(".js"), do: "text/javascript; charset=utf-8"
  defp content_type_for(".data"), do: "application/octet-stream"
  defp content_type_for(".metadata"), do: "application/json; charset=utf-8"
  defp content_type_for(_), do: "application/octet-stream"

  defp accepts_brotli?(conn) do
    conn
    |> get_req_header("accept-encoding")
    |> Enum.any?(fn header ->
      header
      |> String.downcase()
      |> String.split(",")
      |> Enum.map(&(&1 |> String.split(";") |> hd() |> String.trim()))
      |> Enum.member?("br")
    end)
  end

  # The office WASM is a MATCHED SET of large, independently-cached files
  # (`soffice.js` glue + `soffice.wasm` + `soffice.data`). Plug.Static serves them
  # `cache-control: public` with only heuristic freshness, so after the artifacts
  # are rebuilt a browser can serve a STALE-MIXED set — old glue against a new
  # wasm — which breaks the Emscripten PThreads bootstrap ("Cannot read properties
  # of undefined (reading 'postMessage')"). Force revalidation so every load
  # resolves to the current, consistent set: the etag yields a 304 when unchanged,
  # so the 144MB wasm is NOT re-downloaded — only a cheap conditional request. The
  # `before_send` runs after Plug.Static, overriding the cache-control it set.
  defp revalidate_office(%Plug.Conn{request_path: path} = conn) do
    if String.starts_with?(path, @office_prefix) do
      register_before_send(conn, &put_resp_header(&1, "cache-control", "no-cache"))
    else
      conn
    end
  end

  # Isolate the workspace HTML page (which hosts the WasmOfficeEditor hook) and
  # the office WASM static artifacts it fetches. Everything else is untouched.
  defp isolate?(%Plug.Conn{request_path: path}) do
    path == "/workspace" or String.starts_with?(path, @office_prefix)
  end
end
