defmodule EcritsWeb.Plugs.CrossOriginIsolationPlug do
  @moduledoc """
  Serves browser WASM engine artifacts from their canonical dependency priv
  directories and opts the LibreOffice->WASM client editor into cross-origin
  isolation.

  ## Cross-origin isolation

  The office WASM build (`libreofficex/priv/wasm/soffice.wasm`) is an Emscripten
  PThreads build: it allocates a *shared* `WebAssembly.Memory` (`shared: true`),
  which requires `SharedArrayBuffer`, which the browser only exposes when the
  page is **cross-origin isolated** (`crossOriginIsolated === true`). That in turn
  requires the document response to carry:

      Cross-Origin-Opener-Policy:   same-origin
      Cross-Origin-Embedder-Policy: require-corp

  We set these ONLY on the local workspace page and the `/assets/office/*` WASM
  artifacts (not the whole app) to keep the blast radius small — COOP/COEP can
  block cross-origin embeds elsewhere. `require-corp` has broader browser
  support than `credentialless`, and the local workspace uses same-origin assets
  for the chrome needed by the office editor.

  We also stamp `Cross-Origin-Resource-Policy: same-origin` so the same-origin
  WASM/data files remain loadable from the isolated page.

  ## Asset delivery

  `soffice.wasm` and `soffice.data` are served from the `:libreofficex`
  application priv directory. Always serve the canonical identity file from the
  dep checkout. Pre-compressed `.br` siblings are local/generated scratch output
  and can become stale or corrupt relative to the raw LFS artifact; serving one
  with `content-encoding: br` breaks browser WASM validation before the Office
  runtime can start.
  """

  @behaviour Plug

  import Plug.Conn

  @office_prefix "/assets/office/"
  @rhwp_prefix "/assets/rhwp/"

  @office_files ~w(soffice.js soffice.wasm soffice.data soffice.data.js.metadata)
  @rhwp_files ~w(rhwp.js rhwp_bg.wasm)

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> maybe_isolate()
    |> maybe_serve_wasm_asset()
  end

  defp maybe_isolate(conn) do
    if isolate?(conn) do
      conn
      |> put_resp_header("cross-origin-opener-policy", "same-origin")
      |> put_resp_header("cross-origin-embedder-policy", "require-corp")
      |> put_resp_header("cross-origin-resource-policy", "same-origin")
    else
      conn
    end
  end

  # Serve dependency-owned WASM assets directly.
  defp maybe_serve_wasm_asset(%Plug.Conn{method: method, request_path: path} = conn)
       when method in ["GET", "HEAD"] do
    with {:ok, raw_path, content_type} <- asset_file(path) do
      send_asset(conn, raw_path, content_type)
    else
      :error -> conn
    end
  end

  defp maybe_serve_wasm_asset(conn), do: conn

  defp send_asset(conn, path, content_type) do
    conn =
      conn
      |> put_resp_header("content-type", content_type)
      |> put_resp_header("cache-control", "no-cache")

    case conn.method do
      "HEAD" ->
        conn
        |> send_resp(200, "")
        |> halt()

      _ ->
        conn
        |> send_file(200, path)
        |> halt()
    end
  end

  defp asset_file(path) do
    cond do
      String.starts_with?(path, @office_prefix) ->
        path
        |> String.trim_leading(@office_prefix)
        |> asset_file(office_dir(), @office_files)

      String.starts_with?(path, @rhwp_prefix) ->
        path
        |> String.trim_leading(@rhwp_prefix)
        |> asset_file(rhwp_dir(), @rhwp_files)

      true ->
        :error
    end
  end

  defp asset_file(rel, dir, allowed_files) do
    with true <- rel in allowed_files,
         raw_path = Path.join(dir, rel),
         true <- File.regular?(raw_path) do
      {:ok, raw_path, content_type_for(Path.extname(rel))}
    else
      _ -> :error
    end
  end

  defp content_type_for(".wasm"), do: "application/wasm"
  defp content_type_for(".js"), do: "text/javascript; charset=utf-8"
  defp content_type_for(".data"), do: "application/octet-stream"
  defp content_type_for(".metadata"), do: "application/json; charset=utf-8"
  defp content_type_for(_), do: "application/octet-stream"

  defp office_dir, do: Application.app_dir(:libreofficex, "priv/wasm")
  defp rhwp_dir, do: Application.app_dir(:ehwp, "priv/wasm")

  # Isolate the workspace HTML page (which hosts the WasmOfficeEditor hook) and
  # the office WASM static artifacts it fetches. Everything else is untouched.
  defp isolate?(%Plug.Conn{request_path: path}) do
    path == "/workspace" or String.starts_with?(path, @office_prefix)
  end
end
