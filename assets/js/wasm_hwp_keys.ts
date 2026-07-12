// Keyboard / IME / text-input subsystem for the HWP browser editor.
//
// Extracted from wasm_hwp_editor.ts (same split pattern as wasm_ops.ts).
// These are HOOK methods: they run with `this` bound to the WasmHwpEditor
// instance (they are spread into it), so they read `this.doc` / `this.caret`
// and call the editor's other methods (refreshCursorRect, drawCaret,
// saveLocalDocument, moveHorizontal, hasSelection, ...) directly. Covers the
// IME proxy binding, composition (Korean) input, plain-text input, the
// keydown dispatch (Backspace/Delete/Enter/arrows/Tab), the edit actions
// (delete/merge/split at caret), and the Ctrl/Cmd+S / undo / redo shortcuts.
export const keyboardSubsystem = {
  bindEditing() {
    if (!this.imeProxy) return
    this.onBeforeInput = e => this.handleBeforeInput(e)
    this.onInput = e => this.handleInput(e)
    this.onCompositionStart = e => this.handleCompositionStart(e)
    this.onCompositionUpdate = e => this.handleCompositionUpdate(e)
    this.onCompositionEnd = e => this.handleCompositionEnd(e)
    this.onKeyDown = e => this.handleKeyDown(e)
    this.onProxyFocus = () => this.activateKeyboardShortcuts()
    this.onCopy = e => this.handleCopy(e)
    this.onPaste = e => this.handlePaste(e)

    this.imeProxy.addEventListener("beforeinput", this.onBeforeInput)
    this.imeProxy.addEventListener("input", this.onInput)
    this.imeProxy.addEventListener("compositionstart", this.onCompositionStart)
    this.imeProxy.addEventListener("compositionupdate", this.onCompositionUpdate)
    this.imeProxy.addEventListener("compositionend", this.onCompositionEnd)
    this.imeProxy.addEventListener("keydown", this.onKeyDown)
    this.imeProxy.addEventListener("focus", this.onProxyFocus)
    this.imeProxy.addEventListener("copy", this.onCopy)
    this.imeProxy.addEventListener("paste", this.onPaste)
  },

  unbindEditing() {
    if (!this.imeProxy) return
    this.imeProxy.removeEventListener("beforeinput", this.onBeforeInput)
    this.imeProxy.removeEventListener("input", this.onInput)
    this.imeProxy.removeEventListener("compositionstart", this.onCompositionStart)
    this.imeProxy.removeEventListener("compositionupdate", this.onCompositionUpdate)
    this.imeProxy.removeEventListener("compositionend", this.onCompositionEnd)
    this.imeProxy.removeEventListener("keydown", this.onKeyDown)
    this.imeProxy.removeEventListener("focus", this.onProxyFocus)
    this.imeProxy.removeEventListener("copy", this.onCopy)
    this.imeProxy.removeEventListener("paste", this.onPaste)
    this.shortcutActive = false
  },

  activateKeyboardShortcuts() {
    if (!this.mirror) this.shortcutActive = true
  },

  handleDocumentPointerDown(event) {
    if (this.mirror) return
    const target = event && event.target
    if (target && this.el && this.el.contains && this.el.contains(target)) {
      this.activateKeyboardShortcuts()
      return
    }
    if (target !== this.imeProxy) this.shortcutActive = false
  },

  handleDocumentKeyDown(event) {
    if (event.defaultPrevented || !this.documentShortcutTarget(event)) return
    if (this.saveShortcut(event)) {
      event.preventDefault()
      event.stopPropagation()
      this.saveLocalDocument({})
      return
    }
    this.handleHwpEditShortcut(event)
  },

  documentShortcutTarget(event) {
    if (!this.shortcutActive) return false
    if (!this.doc) return false
    const target = event && event.target
    if (target === this.imeProxy) return false
    if (this.eventTargetIsEditable(target)) return false
    if (target && this.el && this.el.contains && this.el.contains(target)) return true

    const active = document.activeElement
    if (active && this.el && this.el.contains && this.el.contains(active)) return true
    return !active || active === document.body || active === document.documentElement
  },

  eventTargetIsEditable(target) {
    if (!target || target === this.imeProxy || !target.closest) return false
    return !!target.closest("input, textarea, select, [contenteditable=''], [contenteditable='true']")
  },

  // beforeinput lets us swallow the proxy's own echo (we never want the textarea
  // to accumulate text — the document IS the model). We still let composition
  // events flow through input/composition* handlers.
  handleBeforeInput(_event) {
    // No-op: input handler reads `event.data`/`inputType` directly and we clear
    // the proxy after each commit, so we don't need to preventDefault here
    // (preventing it would also block compositionupdate on some IMEs).
  },

  hwpNativeImeAvailable() {
    return !!(this.doc &&
      typeof this.doc.beginImeComposition === "function" &&
      typeof this.doc.updateImeComposition === "function" &&
      typeof this.doc.commitImeComposition === "function" &&
      typeof this.doc.cancelImeComposition === "function")
  },

  hwpImeAnchor() {
    const c = this.caret
    if (!c || c.note) return null

    if (c.cell) {
      if (Array.isArray(c.cell.cellPath) && c.cell.cellPath.length > 1) {
        return {
          kind: "cellPath",
          sectionIdx: c.section,
          parentParaIdx: c.cell.parentParaIndex,
          cellPath: c.cell.cellPath,
          charOffset: c.offset,
        }
      }

      return {
        kind: "cell",
        sectionIdx: c.section,
        parentParaIdx: c.cell.parentParaIndex,
        controlIdx: c.cell.controlIndex,
        cellIdx: c.cell.cellIndex,
        cellParaIdx: c.cell.cellParaIndex,
        charOffset: c.offset,
      }
    }

    return {
      kind: "body",
      sectionIdx: c.section,
      paraIdx: c.paragraph,
      charOffset: c.offset,
    }
  },

  hwpCompositionText(event) {
    const normalize = (text) => {
      const value = String(text || "")
      try { return value.normalize("NFC") } catch (_) { return value }
    }

    if (event && event.data != null) return normalize(event.data)

    return normalize(this.imeProxy ? this.imeProxy.value : "")
  },

  hwpCharCount(text) {
    return [...String(text || "")].length
  },

  hwpParseNativeJson(raw) {
    if (!raw) return {}
    if (typeof raw === "object") return raw
    try {
      return JSON.parse(String(raw))
    } catch (_) {
      return {}
    }
  },

  hwpRenderImePages(info, options = {}) {
    const parsed = this.hwpParseNativeJson(info)
    const pages = Array.isArray(parsed.invalidatedPages)
      ? parsed.invalidatedPages.map(Number).filter(Number.isInteger)
      : []
    if (Number.isInteger(Number(parsed.pageIndex))) pages.push(Number(parsed.pageIndex))
    const unique = [...new Set(pages)]
    if (unique.length) {
      unique.forEach(page => this.renderPage(page))
      return unique
    }
    if (options.fallbackCaret !== false) this.renderCaretPage()
    return []
  },

  hwpApplyImeCaret(info) {
    const result = this.hwpParseNativeJson(info)
    const offset = Number(result?.edit?.charOffset ?? result?.charOffset)
    if (!this.caret || !Number.isInteger(offset)) return result
    this.caret.offset = offset
    this.caret.preferredX = -1
    this.refreshCursorRect()
    if (this.caret) this.drawCaret(this.caret)
    this.anchorProxy()
    return result
  },

  hwpNativeImeInfo() {
    if (!this.hwpNativeImeAvailable() || typeof this.doc.getImeCompositionRenderInfo !== "function") {
      return {}
    }
    try {
      return this.hwpParseNativeJson(this.doc.getImeCompositionRenderInfo())
    } catch (_) {
      return {}
    }
  },

  hwpNativeImeActive() {
    return this.hwpNativeImeInfo().active === true
  },

  hwpClearNativeIme() {
    if (!this.hwpNativeImeAvailable()) return
    const before = this.hwpNativeImeInfo()
    if (before.active !== true) return
    try {
      const raw = this.doc.cancelImeComposition()
      this.hwpApplyImeCaret(raw)
      const rendered = this.hwpRenderImePages(raw, { fallbackCaret: false })
      if (Number.isInteger(Number(before.pageIndex)) && !rendered.includes(Number(before.pageIndex))) {
        this.renderPage(Number(before.pageIndex))
      }
    } catch (error) {
      console.error("[wasm-hwp] cancelImeComposition failed", error)
    }
  },

  hwpCommitNativeIme(text) {
    const before = this.hwpNativeImeInfo()
    const raw = this.doc.commitImeComposition(text)
    this.hwpFinishImeCommit(raw, text, before)
  },

  hwpFinishImeCommit(raw, text, before = null) {
    const result = this.hwpParseNativeJson(raw)
    const c = this.caret
    if (c && result && result.committed !== false) {
      const edit = result.edit && typeof result.edit === "object" ? result.edit : {}
      const offset = Number(edit.charOffset ?? edit.offset)
      c.offset = Number.isInteger(offset) ? offset : c.offset + this.hwpCharCount(text)
      c.preferredX = -1
      this.refreshCursorRect()
    }
    const rendered = this.hwpRenderImePages(result)
    if (before && before.active === true && Number.isInteger(Number(before.pageIndex)) &&
        !rendered.includes(Number(before.pageIndex))) {
      this.renderPage(Number(before.pageIndex))
    }
    if (this.caret) this.drawCaret(this.caret)
    this.anchorProxy()
    if (result.committed !== false) {
      this.recordOp("TextInserted", { text })
      this.scheduleSnapshot()
    }
  },

  // Plain text (ASCII / paste) — fires for non-composing input. Korean text is
  // routed to the native IME carrier through composition events and must be
  // skipped here so the browser textarea never becomes the document model.
  handleInput(event) {
    if (!this.doc || !this.caret) return

    const type = event.inputType || ""
    const compositionInput = type === "insertCompositionText" || type === "insertReplacementText"
    if (compositionInput || event.isComposing) {
      if (this.hwpNativeImeAvailable() && this.hwpNativeImeActive()) {
        const str = this.hwpCompositionText(event)
        try {
          if (event.isComposing) {
            const raw = this.doc.updateImeComposition(str, this.hwpCharCount(str))
            this.hwpApplyImeCaret(raw)
            this.hwpRenderImePages(raw)
          } else {
            this.hwpCommitNativeIme(str)
          }
        } catch (error) {
          console.error("[wasm-hwp] composition input fallback failed", error)
          this.hwpClearNativeIme()
        }
      }
      if (!event.isComposing) this.imeProxy.value = ""
      return
    }

    if (type === "insertText" || type === "insertFromPaste" ||
        compositionInput) {
      const data = event.data != null ? event.data : this.imeProxy.value
      // Typing over a selection replaces it: delete the range, then insert.
      if (data) {
        this.pushHwpUndoCheckpoint("input")
        if (this.hasSelection()) this.deleteSelection()
        this.insertPlainTextAtCaret(data)
      }
    }
    // Always drain the proxy so it never accumulates state.
    this.imeProxy.value = ""
  },

  // Korean IME — composition events are routed to rhwp_core. JS owns neither
  // the live composition text nor its document position; it only forwards the
  // event text and follows the native edit cursor.
  handleCompositionStart(_event) {
    if (!this.doc || !this.caret) return
    if (!this.hwpNativeImeAvailable()) return
    this.hwpClearNativeIme()
    const anchor = this.hwpImeAnchor()
    if (!anchor) return
    this.pushHwpUndoCheckpoint("composition")
    if (this.hasSelection()) this.deleteSelection()
    try {
      const raw = this.doc.beginImeComposition(JSON.stringify(this.hwpImeAnchor() || anchor))
      this.hwpRenderImePages(raw, { fallbackCaret: false })
    } catch (error) {
      console.error("[wasm-hwp] beginImeComposition failed", error)
    }
  },

  handleCompositionUpdate(event) {
    if (!this.doc || !this.caret || !this.hwpNativeImeAvailable()) return
    const str = this.hwpCompositionText(event)
    try {
      const raw = this.doc.updateImeComposition(str, this.hwpCharCount(str))
      this.hwpApplyImeCaret(raw)
      this.hwpRenderImePages(raw)
    } catch (error) {
      console.error("[wasm-hwp] updateImeComposition failed", error)
    }
  },

  handleCompositionEnd(event) {
    if (!this.doc || !this.caret) return
    const str = this.hwpCompositionText(event)
    if (this.hwpNativeImeAvailable()) {
      try {
        this.hwpCommitNativeIme(str)
      } catch (error) {
        console.error("[wasm-hwp] commitImeComposition failed", error)
        this.hwpClearNativeIme()
      }
      this.imeProxy.value = ""
      return
    }

    if (str) {
      this.pushHwpUndoCheckpoint("composition")
      if (this.hasSelection()) this.deleteSelection()
      this.insertPlainTextAtCaret(str)
    }
    this.imeProxy.value = ""
  },

  // Insert plain text at the caret, route to cell when inside a table cell.
  insertAtCaret(text) {
    const c = this.caret
    this.applyInsert(c.section, c.paragraph, c.offset, text)
    c.offset += [...text].length
    c.preferredX = -1
    this.refreshCursorRect()
    this.renderCaretPage()
    this.drawCaret(c)
    this.anchorProxy()
    this.scheduleSnapshot()
  },

  // ─── Low-level apply helpers (body vs cell routing) ──────────────────────

  applyInsert(section, paragraph, offset, text) {
    const c = this.caret
    try {
      if (c.note) {
        // Caret in a footnote — route typing into the note body, not the host
        // paragraph (engine put the caret here via the native caret hit).
        this.doc.insertTextInFootnote(
          section, paragraph, c.note.controlIndex, c.note.innerParaIndex, offset, text
        )
      } else if (c.cell) {
        this.doc.insertTextInCell(
          section, c.cell.parentParaIndex, c.cell.controlIndex,
          c.cell.cellIndex, c.cell.cellParaIndex, offset, text
        )
      } else {
        this.doc.insertText(section, paragraph, offset, text)
      }
      this.recordOp("TextInserted", { section, para: paragraph, offset, text })
    } catch (error) {
      console.error("[wasm-hwp] insertText failed", error)
    }
  },

  applyDelete(section, paragraph, offset, count) {
    const c = this.caret
    try {
      if (c.note) {
        this.doc.deleteTextInFootnote(
          section, paragraph, c.note.controlIndex, c.note.innerParaIndex, offset, count
        )
      } else if (c.cell) {
        this.doc.deleteTextInCell(
          section, c.cell.parentParaIndex, c.cell.controlIndex,
          c.cell.cellIndex, c.cell.cellParaIndex, offset, count
        )
      } else {
        this.doc.deleteText(section, paragraph, offset, count)
      }
      this.recordOp("TextDeleted", { section, para: paragraph, offset, count })
    } catch (error) {
      console.error("[wasm-hwp] deleteText failed", error)
    }
  },

  // ─── Editing keys (keydown, non-composing) ───────────────────────────────

  handleKeyDown(event) {
    if (this.saveShortcut(event)) {
      event.preventDefault()
      event.stopPropagation()
      this.saveLocalDocument({})
      return
    }
    if (!this.doc) return
    if (event.isComposing) return // IME owns the keystroke
    if (this.hwpClearNativeIme) this.hwpClearNativeIme()
    if (this.handleHwpEditShortcut(event)) return
    if (this.handleSelectedImageDeleteKey(event)) return
    if (!this.caret) return
    if (event.metaKey || event.ctrlKey || event.altKey) return // unhandled shortcuts pass through
    if (event.key === "Tab") {
      event.preventDefault()
      event.stopPropagation()
      if (this.imeProxy) this.imeProxy.focus({ preventScroll: true })
      this.anchorProxy()
      return
    }

    // A non-empty selection makes Backspace/Delete/Enter act on the whole range.
    if (this.hasSelection() &&
        (event.key === "Backspace" || event.key === "Delete" || event.key === "Enter")) {
      event.preventDefault()
      this.pushHwpUndoCheckpoint(event.key === "Enter" ? "selection-enter" : "selection-delete")
      this.deleteSelection()
      if (event.key === "Enter") this.splitAtCaret()
      return
    }

    switch (event.key) {
      case "Backspace":
        event.preventDefault()
        this.pushHwpUndoCheckpoint("backspace")
        this.deleteBackward()
        break
      case "Delete":
        event.preventDefault()
        this.pushHwpUndoCheckpoint("delete")
        this.deleteForward()
        break
      case "Enter":
        event.preventDefault()
        this.pushHwpUndoCheckpoint("enter")
        this.splitAtCaret()
        break
      case "ArrowLeft":
        event.preventDefault()
        this.collapseSelection()
        this.moveHorizontal(-1)
        break
      case "ArrowRight":
        event.preventDefault()
        this.collapseSelection()
        this.moveHorizontal(1)
        break
      case "ArrowUp":
        event.preventDefault()
        this.collapseSelection()
        this.moveVertical(-1)
        break
      case "ArrowDown":
        event.preventDefault()
        this.collapseSelection()
        this.moveVertical(1)
        break
      default:
        break
    }
  },

  handleSelectedImageDeleteKey(event) {
    if (event.metaKey || event.ctrlKey || event.altKey) return false
    if (event.key !== "Backspace" && event.key !== "Delete") return false
    if (!this.localImagePick || !/image|picture/i.test(this.localImagePick.type || "")) return false

    event.preventDefault()
    event.stopPropagation()
    if (this.deleteSelectedImage()) {
      if (this.imeProxy) this.imeProxy.value = ""
    }
    return true
  },

  selectedImageTarget() {
    if (!this.localImagePick || !/image|picture/i.test(this.localImagePick.type || "")) return null
    let ref = this.localImagePick.ref
    if (typeof ref === "string") {
      try {
        ref = JSON.parse(ref)
      } catch (_) {
        return null
      }
    }
    if (!ref || typeof ref !== "object") return null

    const section = Number(ref.section ?? ref.sectionIndex ?? 0)
    const paragraph = Number(ref.paragraph ?? ref.paragraphIndex)
    const control = Number(ref.control ?? ref.controlIndex)
    if (![section, paragraph, control].every(Number.isInteger)) return null
    return { section, paragraph, control }
  },

  deleteSelectedImage() {
    const target = this.selectedImageTarget()
    if (!target || !this.doc) return false

    this.pushHwpUndoCheckpoint("image-delete")
    try {
      this.doc.deletePictureControl(target.section, target.paragraph, target.control)
    } catch (error) {
      console.error("[wasm-hwp] deletePictureControl failed", error)
      return false
    }

    this.localImagePick = null
    this.clearSelection()
    this.clearSelectionOverlays()
    this.recordOp("PictureDeleted", {
      section: target.section,
      paragraph: target.paragraph,
      control: target.control
    })
    this.finishAgentEdit({})
    return true
  },

  handleCopy(event) {
    const text = this.selectedText ? this.selectedText() : ""
    if (!text || !event.clipboardData) return
    event.preventDefault()
    event.clipboardData.setData("text/plain", text)
    if (this.imeProxy) this.imeProxy.value = ""
  },

  handlePaste(event) {
    if (!this.doc || !this.caret) return
    const text = event.clipboardData && event.clipboardData.getData("text/plain")
    if (!text) return
    event.preventDefault()
    this.pushHwpUndoCheckpoint("paste")
    if (this.hasSelection()) this.deleteSelection()
    this.insertPlainTextAtCaret(text)
  },

  insertPlainTextAtCaret(text) {
    const value = String(text || "").replace(/\r\n?/g, "\n")
    if (!value) return
    const parts = value.split("\n")
    parts.forEach((part, index) => {
      if (part) this.insertAtCaret(part)
      if (index < parts.length - 1) this.splitAtCaret()
    })
  },

  deleteBackward() {
    const c = this.caret
    if (c.offset > 0) {
      const newOffset = c.offset - 1
      this.applyDelete(c.section, c.paragraph, newOffset, 1)
      c.offset = newOffset
      c.preferredX = -1
      this.refreshCursorRect()
      this.renderCaretPage()
      this.drawCaret(c)
      this.anchorProxy()
      this.scheduleSnapshot()
    } else {
      this.mergeBackward()
    }
  },

  deleteForward() {
    const c = this.caret
    // Delete one char forward at the caret (engine clamps at paragraph end).
    this.applyDelete(c.section, c.paragraph, c.offset, 1)
    c.preferredX = -1
    this.refreshCursorRect()
    this.renderCaretPage()
    this.drawCaret(c)
    this.anchorProxy()
    this.scheduleSnapshot()
  },

  // Backspace at offset 0: merge this paragraph into the previous one. The
  // engine returns the merge point so the caret lands at the join.
  mergeBackward() {
    const c = this.caret
    if (c.cell) {
      if (c.cell.cellParaIndex <= 0) return // nothing before in the cell
      try {
        const raw = this.doc.mergeParagraphInCell(
          c.section, c.cell.parentParaIndex, c.cell.controlIndex,
          c.cell.cellIndex, c.cell.cellParaIndex
        )
        const r = JSON.parse(raw)
        c.cell.cellParaIndex = r.cellParaIndex
        c.offset = r.charOffset
        this.recordOp("ParagraphMerged", { section: c.section, para: c.cell.cellParaIndex })
      } catch (error) {
        console.error("[wasm-hwp] mergeParagraphInCell failed", error)
        return
      }
    } else {
      if (c.paragraph <= 0) return // top of document
      try {
        const raw = this.doc.mergeParagraph(c.section, c.paragraph)
        const r = JSON.parse(raw)
        c.paragraph = r.paraIdx
        c.offset = r.charOffset
        this.recordOp("ParagraphMerged", { section: c.section, para: c.paragraph })
      } catch (error) {
        console.error("[wasm-hwp] mergeParagraph failed", error)
        return
      }
    }
    c.preferredX = -1
    this.refreshCursorRect()
    this.renderCaretPage({ refreshVisible: true })
    this.drawCaret(c)
    this.anchorProxy()
    this.scheduleSnapshot()
  },

  splitAtCaret() {
    const c = this.caret
    try {
      if (c.cell) {
        const raw = this.doc.splitParagraphInCell(
          c.section, c.cell.parentParaIndex, c.cell.controlIndex,
          c.cell.cellIndex, c.cell.cellParaIndex, c.offset
        )
        const r = JSON.parse(raw)
        c.cell.cellParaIndex = r.cellParaIndex
        c.offset = r.charOffset
      } else {
        const raw = this.doc.splitParagraph(c.section, c.paragraph, c.offset)
        const r = JSON.parse(raw)
        c.paragraph = r.paraIdx
        c.offset = r.charOffset
      }
      this.recordOp("ParagraphSplit", { section: c.section, para: c.paragraph, offset: c.offset })
    } catch (error) {
      console.error("[wasm-hwp] splitParagraph failed", error)
      return
    }
    c.preferredX = -1
    this.refreshCursorRect()
    this.renderCaretPage({ refreshVisible: true })
    this.drawCaret(c)
    this.anchorProxy()
    this.scheduleSnapshot()
  },

  saveShortcut(event) {
    return (event.metaKey || event.ctrlKey) && this.shortcutKey(event) === "s"
  },

  shortcutKey(event) {
    const key = String(event && event.key || "").toLowerCase()
    if (/^[a-z]$/.test(key)) return key

    const code = String(event && event.code || "")
    const match = /^Key([A-Z])$/.exec(code)
    return match ? match[1].toLowerCase() : key
  },

  handleHwpEditShortcut(event) {
    if (event.altKey || !(event.metaKey || event.ctrlKey)) return false
    const key = this.shortcutKey(event)
    const undo = key === "z" && !event.shiftKey
    const redo = (key === "z" && event.shiftKey) || (key === "y" && event.ctrlKey && !event.metaKey)
    if (!undo && !redo) return false

    event.preventDefault()
    event.stopPropagation()
    if (undo) this.runHwpUndo()
    else this.runHwpRedo()
    return true
  },
}
