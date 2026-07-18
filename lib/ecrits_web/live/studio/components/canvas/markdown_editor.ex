defmodule EcritsWeb.Live.Studio.Components.Canvas.MarkdownEditor do
  @moduledoc """
  Editable Markdown document surface with a live MDEx-rendered preview.

  Markdown is plain text (no engine, no WASM, no LibreOffice): the canonical
  workspace `.md`/`.markdown` file is loaded as text into an editable `<textarea>`
  source pane, and a live preview shows the GFM render. The render reuses the
  shared MDEx helper (`EcritsWeb.Markdown.to_safe_html/1`) — the same renderer the
  chat rail uses — and is styled by the shared `<.markdown_prose>` wrapper.

  `Ecrits.MarkdownEditorState` owns source, selection, dirty, and view
  state. The colocated bridge reports browser selection coordinates and the save
  chord; HEEx forms transmit source changes to LiveView.
  """

  use EcritsWeb, :html

  alias Ecrits.DocumentCanvasState

  attr :id, :string, required: true
  attr :state, :any, required: true

  def render(%{state: %DocumentCanvasState{} = state} = assigns) do
    assigns =
      assigns
      |> assign(
        :form,
        to_form(%{"source" => state.markdown_editor.source}, as: :markdown_editor)
      )

    ~H"""
    <div
      id={@id}
      class="flex h-full min-h-0 flex-col overflow-hidden bg-base-100"
      data-component="canvas-markdown-editor"
      data-renderer="markdown"
      data-role="markdown-editor"
      data-canvas-state={DocumentCanvasState.encode(@state)}
    >
      <%!-- No header here: the PREVIEW <-> SOURCE toggle lives in the shared
            quick toolbar and updates the server-owned editor state. --%>

      <%!-- Source pane: editable plain-text markdown. LiveView owns the form
            value; the bridge reports only browser selection and save signals. --%>
      <.form
        for={@form}
        id={"#{@id}-source-form"}
        phx-change="document.markdown.source_changed"
        class={[
          "min-h-0 flex-1",
          if(@state.markdown_editor.view == :source, do: "flex", else: "hidden")
        ]}
      >
        <.input
          field={@form[:source]}
          id={"#{@id}-source"}
          type="textarea"
          data-role="markdown-editor-source"
          phx-hook=".MarkdownSelectionBridge"
          phx-debounce="200"
          spellcheck="false"
          autocomplete="off"
          autocapitalize="off"
          wrapper_class="contents"
          label_class="contents"
          class="min-h-0 flex-1 resize-none border-0 bg-base-100 p-4 font-mono text-[13px] leading-relaxed text-base-content outline-none focus:outline-none"
        />
      </.form>

      <%!-- Preview pane: live Observex render of the current source (GFM +
            math/TikZ tex-islands). Visible by default. The ObservexPreview hook
            re-renders the islands (MathJax/TikZJax) after every diff. --%>
      <.markdown_prose
        id={"#{@id}-preview"}
        data-role="markdown-editor-preview"
        phx-hook=".ObservexPreview"
        class={[
          "min-h-0 flex-1 overflow-auto p-6 text-[15px] leading-[1.7]",
          if(@state.markdown_editor.view == :preview, do: "block", else: "hidden")
        ]}
      >
        <div data-editor-zoomable>
          {@state.markdown_preview_html}
        </div>
      </.markdown_prose>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".MarkdownSelectionBridge">
        export default {
          mounted() {
            const transmitSelection = () => {
              this.pushEvent("document.markdown.selection_changed", {
                start: this.el.selectionStart,
                end: this.el.selectionEnd
              })
            }

            this.el.addEventListener("select", transmitSelection)
            this.el.addEventListener("keyup", transmitSelection)
            this.el.addEventListener("mouseup", transmitSelection)
            this.el.addEventListener("keydown", event => {
              if (!(event.metaKey || event.ctrlKey) || String(event.key).toLowerCase() !== "s") return
              event.preventDefault()
              this.pushEvent("document.markdown.save_requested", {source: this.el.value})
            })
          },

          updated() {
            if (document.activeElement !== this.el) return
            const host = this.el.closest("[data-canvas-state]")
            let state = {}
            try { state = JSON.parse(host?.dataset?.canvasState || "{}") }
            catch (_error) {}
            const start = Number(state.markdownEditor?.selectionStart)
            const end = Number(state.markdownEditor?.selectionEnd)
            if (Number.isInteger(start) && Number.isInteger(end)) {
              this.el.setSelectionRange(start, end)
            }
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".ObservexPreview">
        export default {
          mounted() {
            this.renderIslands()
          },
          updated() {
            this.renderIslands()
          },
          renderIslands() {
            if (!window.Observex) return
            window.Observex.render(this.el).catch(error => {
              console.warn("[observex_preview]", error)
            })
          }
        }
      </script>
    </div>
    """
  end
end
