defmodule EcritsWeb.Live.Studio.Components.Canvas.LocalMarkdownEditor do
  @moduledoc """
  Editable Markdown document surface with a live MDEx-rendered preview.

  Markdown is plain text (no engine, no WASM, no LibreOffice): the canonical
  workspace `.md`/`.markdown` file is loaded as text into an editable `<textarea>`
  source pane, and a live preview shows the GFM render. The render reuses the
  shared MDEx helper (`EcritsWeb.Markdown.to_safe_html/1`) — the same renderer the
  chat rail uses — and is styled by the shared `<.markdown_prose>` wrapper.

  The surface is a SINGLE pane: a header toggle button switches between PREVIEW
  and SOURCE (mirroring the usual markdown-editor affordance) rather than showing
  them side-by-side. Both panes stay mounted in the DOM (the toggle only flips
  visibility, client-side, via `Phoenix.LiveView.JS`) so the live MDEx preview
  keeps re-rendering while you edit and the source textarea's caret/selection are
  never torn down.

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
  attr :source, :string, default: ""
  attr :preview_html, :any, default: ""

  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex h-full min-h-0 flex-col overflow-hidden bg-base-100"
      data-component="canvas-local-markdown-editor"
      data-renderer="markdown"
      data-role="markdown-editor"
      data-view="preview"
      data-local-document-id={@document_id}
      data-local-document-format={@local_document_format}
    >
      <%!-- No header here: the PREVIEW <-> SOURCE toggle lives in the shared
            quick toolbar (editor_surface.ex), which calls toggle_markdown_view/1
            below. Both panes stay mounted; the toggle only flips visibility. --%>

      <%!-- Source pane: editable plain-text markdown. The hook seeds the value
            from data-initial-source, debounces input -> markdown.source_changed,
            and binds Ctrl/Cmd+S -> markdown.save. phx-update="ignore" keeps the
            user's caret stable across preview diffs. Hidden until the toggle
            switches to SOURCE; stays mounted so the hook isn't torn down. --%>
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
        class="hidden min-h-0 flex-1 resize-none border-0 bg-base-100 p-4 font-mono text-[13px] leading-relaxed text-base-content outline-none focus:outline-none"
      ></textarea>

      <%!-- Preview pane: live Observex render of the current source (GFM +
            math/TikZ tex-islands). Visible by default. The ObservexPreview hook
            re-renders the islands (MathJax/TikZJax) after every diff. --%>
      <.markdown_prose
        id={"#{@id}-preview"}
        data-role="markdown-editor-preview"
        phx-hook="ObservexPreview"
        class="min-h-0 flex-1 overflow-auto p-6 text-[15px] leading-[1.7]"
      >
        <div data-editor-zoomable>
          {@preview_html}
        </div>
      </.markdown_prose>
    </div>
    """
  end

  @doc """
  Single-pane PREVIEW <-> SOURCE toggle, run entirely client-side so it never
  touches the LiveView/document state: flip the `hidden` utility on the two panes
  (addressed by the `<id>-source` / `<id>-preview` element ids) and on the toggle
  button's two icon labels. The button lives in the shared quick toolbar
  (editor_surface.ex), outside this component's container, so the label icons are
  addressed globally by their `data-role`/`data-toggle-label` rather than scoped
  under the container id. Toggling the `hidden` class — rather than JS.toggle's
  inline `display` — lets the flex panes (`flex-1`) keep their natural display
  when shown.
  """
  def toggle_markdown_view(id) do
    %JS{}
    |> JS.toggle_class("hidden", to: "##{id}-source")
    |> JS.toggle_class("hidden", to: "##{id}-preview")
    |> JS.toggle_class("hidden",
      to: "[data-role='markdown-editor-toggle'] [data-toggle-label='preview']"
    )
    |> JS.toggle_class("hidden",
      to: "[data-role='markdown-editor-toggle'] [data-toggle-label='source']"
    )
  end
end
