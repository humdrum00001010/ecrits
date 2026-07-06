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
import {LOCAL_EDITOR_COMMAND_EVENT} from "./editor_events.ts"
import {SEL} from "./selectors.ts"

const MarkdownEditor = {
  mounted() {
    // Seed the editor with the loaded file contents (the server can't set the
    // value of a phx-update="ignore" textarea, so we do it here).
    this.el.value = this.el.dataset.initialSource || ""
    this.debounce = null
    this.documentId = this.el.dataset.localDocumentId || this.el.dataset.documentId || ""

    this.onInput = () => {
      this.userEdited = true
      this.scheduleSync()
    }
    this.onKeyDown = e => this.handleKeyDown(e)
    this.onToolbarCommand = event => this.handleToolbarCommand(event.detail || {})

    this.el.addEventListener("input", this.onInput)
    this.el.addEventListener("keydown", this.onKeyDown)
    document.addEventListener(LOCAL_EDITOR_COMMAND_EVENT, this.onToolbarCommand)

    this.handleEvent("markdown_saved", payload => this.onSaved(payload))

    // Render the initial preview from whatever was just seeded (covers the case
    // where the seeded source differs from the server's first-paint assign).
    this.sync()
  },

  updated() {
    // A fresh document was opened in the same hook element: reseed if the
    // server handed us a new initial source.
    const next = this.el.dataset.initialSource
    if (typeof next === "string" && next !== this.lastSeeded && document.activeElement !== this.el) {
      this.el.value = next
      this.userEdited = false
      this.sync()
    }
  },

  destroyed() {
    if (this.debounce) clearTimeout(this.debounce)
    this.el.removeEventListener("input", this.onInput)
    this.el.removeEventListener("keydown", this.onKeyDown)
    document.removeEventListener(LOCAL_EDITOR_COMMAND_EVENT, this.onToolbarCommand)
  },

  scheduleSync() {
    if (this.debounce) clearTimeout(this.debounce)
    this.debounce = setTimeout(() => this.sync(), DEBOUNCE_MS)
  },

  sync() {
    this.lastSeeded = this.el.value
    this.pushEvent("markdown.source_changed", {source: this.el.value, dirty: !!this.userEdited})
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
    if (!payload || payload.ok !== false) {
      this.userEdited = false
      return
    }
    // Surface a non-fatal save error in the console; the server keeps the file
    // intact on failure.
    console.warn("[markdown_editor] save failed:", payload.error)
  },

  handleToolbarCommand(detail) {
    if (!this.activeToolbarTarget() || !this.toolbarCommandMatchesDocument(detail)) return

    switch (detail.command) {
      case "bold":
        this.wrapSelection("**", "**", "bold")
        break
      case "italic":
        this.wrapSelection("*", "*", "italic")
        break
      default:
        break
    }
  },

  activeToolbarTarget() {
    const root = this.el.closest(SEL.markdownEditor)
    return !!(root && root.isConnected)
  },

  toolbarCommandMatchesDocument(detail) {
    const commandDocumentId = detail && (detail.document_id || detail.documentId)
    if (!commandDocumentId) return true
    return !!(this.documentId && String(commandDocumentId) === String(this.documentId))
  },

  wrapSelection(prefix, suffix, fallback) {
    const start = this.el.selectionStart || 0
    const end = this.el.selectionEnd || start
    const selected = this.el.value.slice(start, end) || fallback

    if (selected.startsWith(prefix) && selected.endsWith(suffix) && selected.length >= prefix.length + suffix.length) {
      const inner = selected.slice(prefix.length, selected.length - suffix.length)
      this.replaceRange(start, end, inner, start, start + inner.length)
      return
    }

    if (
      start >= prefix.length &&
      this.el.value.slice(start - prefix.length, start) === prefix &&
      this.el.value.slice(end, end + suffix.length) === suffix
    ) {
      const nextStart = start - prefix.length
      this.replaceRange(nextStart, end + suffix.length, selected, nextStart, nextStart + selected.length)
      return
    }

    this.replaceRange(
      start,
      end,
      prefix + selected + suffix,
      start + prefix.length,
      start + prefix.length + selected.length
    )
  },

  replaceRange(start, end, text, selectionStart = null, selectionEnd = null) {
    this.el.value = this.el.value.slice(0, start) + text + this.el.value.slice(end)
    const nextStart = selectionStart == null ? start + text.length : selectionStart
    const nextEnd = selectionEnd == null ? nextStart : selectionEnd
    this.el.setSelectionRange(nextStart, nextEnd)
    this.userEdited = true
    this.sync()
  }
}

export {MarkdownEditor}
