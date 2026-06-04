// Markdown (.md/.markdown) source-pane hook.
//
// The editable counterpart for plain-text markdown documents. Unlike the office
// (LOK tile) or HWP (WASM) editors, markdown has no engine: this hook owns the
// source <textarea> and the server owns the live preview render (MDEx) + the
// canonical file persistence.
//
//   input      -> debounced pushEvent("markdown.source_changed", {source})
//                 -> server re-renders @preview_html -> LiveView diffs the preview
//   Ctrl/Cmd+S -> pushEvent("markdown.save", {source})
//                 -> server Document.save (atomic canonical write)
//                 -> server pushes "markdown_saved" {ok}
//
// The textarea is phx-update="ignore", so we seed its value once from
// data-initial-source on mount and never let LiveView diffs clobber the caret.

const DEBOUNCE_MS = 200

const MarkdownEditor = {
  mounted() {
    // Seed the editor with the loaded file contents (the server can't set the
    // value of a phx-update="ignore" textarea, so we do it here).
    this.el.value = this.el.dataset.initialSource || ""
    this.debounce = null

    this.onInput = () => this.scheduleSync()
    this.onKeyDown = e => this.handleKeyDown(e)

    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keydown", this.onKeyDown)

    this.handleEvent("markdown_saved", payload => this.onSaved(payload))

    // Render the initial preview from whatever was just seeded (covers the case
    // where the seeded source differs from the server's first-paint assign).
    this.sync()
  },

  updated() {
    // A fresh document was opened in the same hook element: reseed if the
    // server handed us a new initial source (the canvas id changes per document,
    // so this mostly guards in-place revision bumps after save).
    const next = this.el.dataset.initialSource
    if (typeof next === "string" && next !== this.lastSeeded && document.activeElement !== this.el) {
      this.el.value = next
      this.sync()
    }
  },

  destroyed() {
    if (this.debounce) clearTimeout(this.debounce)
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keydown", this.onKeyDown)
  },

  scheduleSync() {
    if (this.debounce) clearTimeout(this.debounce)
    this.debounce = setTimeout(() => this.sync(), DEBOUNCE_MS)
  },

  sync() {
    this.lastSeeded = this.el.value
    this.pushEvent("markdown.source_changed", {source: this.el.value})
  },

  handleKeyDown(e) {
    if ((e.metaKey || e.ctrlKey) && (e.key === "s" || e.key === "S")) {
      e.preventDefault()
      // Flush any pending debounce so the saved bytes match the preview.
      if (this.debounce) {
        clearTimeout(this.debounce)
        this.debounce = null
      }
      this.lastSeeded = this.el.value
      this.pushEvent("markdown.save", {source: this.el.value})
    }
  },

  onSaved(payload) {
    if (!payload || payload.ok !== false) return
    // Surface a non-fatal save error in the console; the server keeps the file
    // intact on failure.
    console.warn("[markdown_editor] save failed:", payload.error)
  }
}

export {MarkdownEditor}
