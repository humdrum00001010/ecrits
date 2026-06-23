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
  attr :document_path, :string, default: nil
  attr :local_document_format, :string, required: true
  attr :bytes_url, :string, default: nil
  attr :mirror?, :boolean, default: false
  attr :preview_turn_id, :string, default: nil
  attr :preview_text, :string, default: ""
  attr :preview_delta_count, :integer, default: 0

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "relative h-full min-h-0 bg-base-200",
        @mirror? && "overflow-hidden pointer-events-none",
        !@mirror? && "overflow-auto"
      ]}
      data-component="canvas-local-office-wasm"
      data-renderer="libreoffice-wasm"
      data-role="office-wasm-viewer"
      data-document-id={@document_id}
      data-document-path={@document_path}
      data-local-document-format={@local_document_format}
      data-office-asset-version={office_asset_version()}
      data-bytes-url={@bytes_url}
      data-editor-mirror={to_string(@mirror?)}
      data-preview-turn-id={@preview_turn_id}
      data-preview-text={@preview_text}
      data-preview-delta-count={@preview_delta_count}
      phx-hook="WasmOfficeEditor"
    >
      <%!-- The OS IME needs an editable element to compose into (Korean editing).
            Kept TRULY INVISIBLE — transparent text AND caret — and glued to the
            WASM caret so the OS candidate window anchors there. phx-update="ignore"
            so LiveView patches keep it. Mirrors the HWP arm's ime-proxy. --%>
      <textarea
        id={"#{@id}-ime-proxy"}
        data-role="office-wasm-ime-proxy"
        autocomplete="off"
        autocorrect="off"
        autocapitalize="off"
        spellcheck="false"
        aria-hidden="true"
        tabindex="-1"
        rows="1"
        phx-update="ignore"
        class="absolute left-0 top-0 m-0 p-0 border-0 outline-none bg-transparent resize-none overflow-hidden"
        style="width:1.5em;height:1em;color:transparent;caret-color:transparent;white-space:pre;line-height:1;font-size:16px;z-index:20;pointer-events:none"
      ></textarea>

      <div
        data-role="office-wasm-status"
        class="px-5 py-2 text-sm text-base-content/60"
      >
      </div>

      <%!-- The hook owns this stack (one page <canvas> per page/slide, painted by
            the in-browser LibreOffice WASM `paintTile`). --%>
      <div
        id={"#{@id}-pages"}
        data-role="office-wasm-pages"
        data-editor-zoomable
        class="flex min-h-full flex-col items-center gap-4 py-4"
        phx-update="ignore"
      >
      </div>
    </div>
    """
  end

  defp office_asset_version do
    # Hash the matched LibreOffice WASM set from the canonical dep priv dir so
    # glue, engine, metadata, or data-only redeploys all bust the browser cache.
    stats =
      for name <- ["soffice.js", "soffice.wasm", "soffice.data", "soffice.data.js.metadata"] do
        path = Application.app_dir(:libreofficex, "priv/wasm/#{name}")

        case File.stat(path) do
          {:ok, %File.Stat{mtime: mtime, size: size}} -> {name, mtime, size}
          {:error, reason} -> {name, :missing, reason}
        end
      end

    stats |> :erlang.phash2() |> Integer.to_string(36)
  end
end
