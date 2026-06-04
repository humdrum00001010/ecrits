defmodule EcritsWeb.Live.Studio.Components.Canvas.LocalMarkdownEditor do
  @moduledoc """
  Editable Markdown document surface with a live MDEx-rendered preview.

  Markdown is plain text (no engine, no WASM, no LibreOffice): the canonical
  workspace `.md`/`.markdown` file is loaded as text into an editable `<textarea>`
  source pane, and a live preview pane shows the GFM render. The render reuses the
  shared MDEx helper (`EcritsWeb.Markdown.to_safe_html/1`) — the same renderer the
  chat rail uses — and is styled with the existing `.chat-markdown` CSS.

  The `MarkdownEditor` hook (assets/js/markdown_editor.js) owns the source
  textarea:

    * input -> debounced `markdown.source_changed` -> server re-renders the
      preview (`@preview_html`) -> LiveView diffs the preview pane
    * Ctrl/Cmd+S -> `markdown.save` -> server `Document.save` (atomic canonical write)

  The textarea is `phx-update="ignore"` so LiveView diffs never clobber the user's
  caret/selection while typing; the hook seeds it from `data-initial-source`.
  """

  use EcritsWeb, :html

  attr :id, :string, required: true
  attr :document_id, :string, required: true
  attr :local_document_format, :string, required: true
  attr :local_document_revision, :integer, required: true
  attr :source, :string, default: ""
  attr :preview_html, :any, default: ""

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="grid h-full min-h-0 grid-cols-2 overflow-hidden bg-base-100"
      data-component="canvas-local-markdown-editor"
      data-renderer="markdown"
      data-role="markdown-editor"
      data-local-document-id={@document_id}
      data-local-document-format={@local_document_format}
      data-local-document-revision={@local_document_revision}
    >
      <%!-- Source pane: editable plain-text markdown. The hook seeds the value
            from data-initial-source, debounces input -> markdown.source_changed,
            and binds Ctrl/Cmd+S -> markdown.save. phx-update="ignore" keeps the
            user's caret stable across preview diffs. --%>
      <section class="flex min-h-0 flex-col overflow-hidden border-r border-base-300">
        <header class="flex min-h-8 shrink-0 items-center border-b border-base-300 bg-base-200/60 px-3 text-[11px] font-medium uppercase tracking-wide text-base-content/55">
          Source
        </header>
        <textarea
          id={"#{@id}-source"}
          data-role="markdown-editor-source"
          data-initial-source={@source}
          phx-hook="MarkdownEditor"
          phx-update="ignore"
          spellcheck="false"
          autocomplete="off"
          autocapitalize="off"
          autocorrect="off"
          class="min-h-0 flex-1 resize-none border-0 bg-base-100 p-4 font-mono text-[13px] leading-relaxed text-base-content outline-none focus:outline-none"
        ></textarea>
      </section>

      <%!-- Preview pane: live MDEx render of the current source. Styled with the
            shared .chat-markdown CSS (full-width here). --%>
      <section class="flex min-h-0 flex-col overflow-hidden">
        <header class="flex min-h-8 shrink-0 items-center justify-between border-b border-base-300 bg-base-200/60 px-3 text-[11px] font-medium uppercase tracking-wide text-base-content/55">
          <span>Preview</span>
        </header>
        <div
          id={"#{@id}-preview"}
          data-role="markdown-editor-preview"
          class="chat-markdown min-h-0 flex-1 overflow-auto p-6 text-[15px] leading-[1.7]"
        >{@preview_html}</div>
      </section>
    </div>
    """
  end
end
