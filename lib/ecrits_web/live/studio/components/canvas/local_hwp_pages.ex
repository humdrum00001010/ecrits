defmodule EcritsWeb.Live.Studio.Components.Canvas.LocalHwpPages do
  @moduledoc """
  Local HWP/HWPX page stack rendered by the in-browser rhwp_core WASM engine.

  The server no longer renders SVG (the `ehwp` NIF is gone). Instead the
  `WasmHwpEditor` hook loads rhwp_core's WASM build, fetches the document's raw
  bytes from the `local/document-bytes` route, and renders + hit-tests each page
  to a `<canvas>` locally. The hook owns the page-stack DOM (`phx-update="ignore"`)
  and creates one `<canvas>` (+ caret overlay) per page; this template only
  provides the host element, the IME proxy, and the document metadata the hook
  reads to know which bytes to fetch.
  """

  use EcritsWeb, :html

  attr :id, :string, required: true
  attr :pages, :any, required: true
  attr :page_count, :integer, default: 0
  attr :spec, :map, required: true
  attr :document_id, :string, required: true
  attr :document_path, :string, default: nil
  attr :bytes_url, :string, default: nil
  attr :local_document_format, :string, required: true
  attr :scroll_top, :any, default: nil
  attr :scroll_left, :any, default: nil
  attr :mirror?, :boolean, default: false
  attr :preview_turn_id, :string, default: nil
  attr :preview_text, :string, default: ""
  attr :preview_delta_count, :integer, default: 0
  attr :preview_highlights, :string, default: "[]"

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="WasmHwpEditor"
      role="region"
      tabindex={if(@mirror?, do: "-1", else: "0")}
      aria-label={if(@mirror?, do: "Document preview", else: "Document pages")}
      class={[
        "relative h-full min-h-0 bg-white",
        @mirror? && "overflow-hidden pointer-events-none",
        !@mirror? && "overflow-auto"
      ]}
      data-component="canvas-local-hwp-pages"
      data-renderer="rhwp-wasm"
      data-role="local-hwp-editor"
      data-document-id={@document_id}
      data-document-path={@document_path || template_path(@spec)}
      data-scroll-top={@scroll_top}
      data-scroll-left={@scroll_left}
      data-document-name={template_name(@spec)}
      data-contract-type-key={@spec.key}
      data-local-document-id={@document_id}
      data-local-document-format={@local_document_format}
      data-bytes-url={@bytes_url}
      data-editor-mirror={to_string(@mirror?)}
      data-preview-turn-id={@preview_turn_id}
      data-preview-text={@preview_text}
      data-preview-delta-count={@preview_delta_count}
      data-preview-highlights={@preview_highlights}
    >
      <%!-- The OS IME needs an editable element to compose into (Korean editing,
            a later phase). Parked offscreen because browser IME marked text
            can paint outside normal DOM/CSS styling; the visible composition is
            rendered by rhwp_core through the canvas render API.
            phx-update="ignore" so LiveView patches keep it. --%>
      <textarea
        id={"#{@id}-ime-proxy"}
        data-role="local-hwp-ime-proxy"
        autocomplete="off"
        autocorrect="off"
        autocapitalize="off"
        spellcheck="false"
        aria-hidden="true"
        tabindex="-1"
        rows="1"
        phx-update="ignore"
        class="fixed m-0 p-0 border-0 outline-none bg-transparent resize-none overflow-hidden"
        style="left:-10000px;top:-10000px;width:1px;height:1px;max-width:1px;max-height:1px;color:transparent;-webkit-text-fill-color:transparent;caret-color:transparent;opacity:0;clip-path:inset(50%);white-space:pre;line-height:1px;font-size:1px;z-index:-1;pointer-events:none"
      ></textarea>
      <%!-- The WASM hook owns this canvas stack: it creates one <canvas> per page
            (+ a caret overlay) and renders near-viewport pages on demand, so
            LiveView must not patch it. --%>
      <div
        id={"#{@id}-pages"}
        data-role="local-hwp-pages"
        data-editor-zoomable
        class="ehwp-document-stack ehwp-document-stack--local flex min-h-full flex-col items-center overflow-auto bg-[#f4f4f5]"
        phx-update="ignore"
      >
      </div>
    </div>
    """
  end

  defp template_path(%{template_hwp_path: path}) when is_binary(path) and path != "", do: path
  defp template_path(%{template_hwpx_path: path}) when is_binary(path) and path != "", do: path

  defp template_name(%{name: name}) when is_binary(name) and name != "", do: name

  defp template_name(spec) do
    spec
    |> template_path()
    |> Path.basename()
  end
end
