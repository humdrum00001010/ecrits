defmodule EcritsWeb.Plugs.CrossOriginIsolationPlug do
  @moduledoc """
  Opt-in cross-origin isolation for the LibreOffice->WASM client editor.

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
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if isolate?(conn) do
      conn
      |> put_resp_header("cross-origin-opener-policy", "same-origin")
      |> put_resp_header("cross-origin-embedder-policy", "credentialless")
      |> put_resp_header("cross-origin-resource-policy", "same-origin")
    else
      conn
    end
  end

  # Isolate the workspace HTML page (which hosts the WasmOfficeEditor hook) and
  # the office WASM static artifacts it fetches. Everything else is untouched.
  defp isolate?(%Plug.Conn{request_path: path}) do
    path == "/workspace" or String.starts_with?(path, "/assets/office/")
  end
end
