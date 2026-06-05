defmodule EcritsWeb.Live.Studio.Components.Canvas.LocalOfficeWasm do
  @moduledoc """
  Client-WASM office document surface — the SOLE office renderer (LibreOffice->
  WASM in the browser), the office counterpart to the HWP `LocalHwpPages`/
  `WasmHwpEditor` path.

  This surface loads the document bytes into a LibreOffice WASM build IN THE
  BROWSER and renders pages/slides to per-page `<canvas>` elements via the
  build's `paintTile`/`getDocumentSize`/`getParts` exports. The
  `WasmOfficeEditor` hook (assets/js/wasm_office_editor.js) owns the DOM under
  `[data-role='office-wasm-pages']` and fetches the raw bytes from
  `bytes_url` (the same `/local/document-bytes` controller the HWP hook uses).

  All office documents (docx/pptx/xlsx) route here; there is no server-side
  LibreOfficeKit render/edit path.
  """

  use EcritsWeb, :html

  attr :id, :string, required: true
  attr :document_id, :string, required: true
  attr :local_document_format, :string, required: true
  attr :local_document_revision, :integer, required: true
  attr :bytes_url, :string, default: nil

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="relative h-full min-h-0 overflow-auto bg-base-200"
      data-component="canvas-local-office-wasm"
      data-renderer="libreoffice-wasm"
      data-role="office-wasm-viewer"
      data-document-id={@document_id}
      data-local-document-format={@local_document_format}
      data-local-document-revision={@local_document_revision}
      data-bytes-url={@bytes_url}
      phx-hook="WasmOfficeEditor"
    >
      <div
        data-role="office-wasm-status"
        class="px-5 py-2 text-sm text-base-content/60"
      >
        Loading office engine…
      </div>

      <%!-- The hook owns this stack (one page <canvas> per page/slide, painted by
            the in-browser LibreOffice WASM `paintTile`). --%>
      <div
        id={"#{@id}-pages"}
        data-role="office-wasm-pages"
        class="flex min-h-full flex-col items-center gap-4 py-4"
        phx-update="ignore"
      >
      </div>
    </div>
    """
  end
end
