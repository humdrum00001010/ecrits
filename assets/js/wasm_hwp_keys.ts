// Keyboard / IME / text-input subsystem for the HWP browser editor.
//
// Extracted from wasm_hwp_editor.ts (same split pattern as wasm_ops.ts).
// These are HOOK methods: they run with `this` bound to the WasmHwpEditor
// instance (they are spread into it), so they read `this.doc` / `this.caret`
// and call the editor's other methods (refreshCursorRect, drawCaret,
// saveLocalDocument, moveHorizontal, hasSelection, ...) directly. Covers the
// IME proxy binding, composition (Korean) input, plain-text input, the
// keydown dispatch (Backspace/Delete/Enter/arrows/Tab), the edit actions
// (delete/merge/split at caret), and the Ctrl/Cmd+S save shortcut.
export const keyboardSubsystem = {
  bindEditing() {
    if (!this.imeProxy) return
    this.onBeforeInput = e => this.handleBeforeInput(e)
    this.onInput = e => this.handleInput(e)
    this.onCompositionStart = e => this.handleCompositionStart(e)
    this.onCompositionUpdate = e => this.handleCompositionUpdate(e)
    this.onCompositionEnd = e => this.handleCompositionEnd(e)
    this.onKeyDown = e => this.handleKeyDown(e)
    this.onCopy = e => this.handleCopy(e)
    this.onPaste = e => this.handlePaste(e)

    this.imeProxy.addEventListener("beforeinput", this.onBeforeInput)
    this.imeProxy.addEventListener("input", this.onInput)
    this.imeProxy.addEventListener("compositionstart", this.onCompositionStart)
    this.imeProxy.addEventListener("compositionupdate", this.onCompositionUpdate)
    this.imeProxy.addEventListener("compositionend", this.onCompositionEnd)
    this.imeProxy.addEventListener("keydown", this.onKeyDown)
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
    this.imeProxy.removeEventListener("copy", this.onCopy)
    this.imeProxy.removeEventListener("paste", this.onPaste)
  },

  // beforeinput lets us swallow the proxy's own echo (we never want the textarea
  // to accumulate text — the document IS the model). We still let composition
  // events flow through input/composition* handlers.
  handleBeforeInput(_event) {
    // No-op: input handler reads `event.data`/`inputType` directly and we clear
    // the proxy after each commit, so we don't need to preventDefault here
    // (preventing it would also block compositionupdate on some IMEs).
  },

  // Plain text (ASCII / paste) — fires for non-composing input. Korean text is
  // handled by the composition* path and must be skipped here.
  handleInput(event) {
    if (!this.doc || !this.caret) return

    const type = event.inputType || ""
    const compositionInput = type === "insertCompositionText" || type === "insertReplacementText"
    if (this.composing) {
      if (compositionInput || event.isComposing) {
        this.replaceComposing(this.currentCompositionText(event))
      }
      return
    }
    if (event.isComposing) return
    if (this.swallowTrailingCompositionInput(event)) {
      this.imeProxy.value = ""
      return
    }

    if (type === "insertText" || type === "insertFromPaste" ||
        compositionInput) {
      const data = event.data != null ? event.data : this.imeProxy.value
      // Typing over a selection replaces it: delete the range, then insert.
      if (data) {
        if (this.hasSelection()) this.deleteSelection()
        this.insertPlainTextAtCaret(data)
      }
    }
    // Always drain the proxy so it never accumulates state.
    this.imeProxy.value = ""
  },

  // Korean IME — compositionstart arms a provisional (empty) region at the caret.
  handleCompositionStart(_event) {
    if (!this.doc || !this.caret) return
    // Composing over a selection replaces it first.
    if (this.hasSelection()) this.deleteSelection()
    this.skipNextCompositionInput = null
    this.composing = { start: this.caret.offset, length: 0 }
  },

  // compositionupdate — replace the provisional composing string IN the document
  // (in-document composing, not a separate overlay). We delete the previous
  // provisional run and insert the new one, then re-render + reposition caret.
  handleCompositionUpdate(event) {
    if (!this.doc || !this.caret || !this.composing) return
    this.replaceComposing(this.currentCompositionText(event))
  },

  // compositionend — commit. The final string is already in the document from
  // the last compositionupdate; we just finalize the region and clear the proxy
  // (the OS IME target).
  handleCompositionEnd(event) {
    if (!this.doc || !this.caret) return
    if (this.composing) {
      const str = this.currentCompositionText(event)
      // Ensure the committed string matches the final composition (some IMEs
      // send a final compositionend with the resolved text).
      this.replaceComposing(str)
      this.composing = null
      this.armTrailingCompositionInputGuard(str)
    }
    this.imeProxy.value = ""
    this.scheduleSnapshot()
  },

  currentCompositionText(event) {
    const data = event && event.data != null ? String(event.data) : ""
    const value = this.imeProxy ? String(this.imeProxy.value || "") : ""
    const normalize = (text) => {
      try { return text.normalize("NFC") } catch (_) { return text }
    }
    const dataText = normalize(data)
    const valueText = normalize(value)
    if (!dataText) return valueText
    if (!valueText) return dataText
    if (dataText === valueText) return dataText

    const jamoOnly = (text) => /^[\u3130-\u318F]+$/u.test(text)
    const hasHangulSyllable = (text) => /[\uAC00-\uD7AF]/u.test(text)
    if (hasHangulSyllable(valueText) && jamoOnly(dataText)) return valueText
    if (hasHangulSyllable(dataText) && jamoOnly(valueText)) return dataText

    return [...valueText].length >= [...dataText].length ? valueText : dataText
  },

  // Delete the current provisional composing run (if any) then insert `str` as
  // the new provisional run, leaving the caret AFTER it. Keeps the in-document
  // composing region in sync with the OS IME buffer on every keystroke.
  replaceComposing(str) {
    const c = this.caret
    const start = this.composing.start
    const prevLen = this.composing.length

    if (prevLen > 0) {
      this.applyDelete(c.section, c.paragraph, start, prevLen)
    }
    if (str.length > 0) {
      this.applyInsert(c.section, c.paragraph, start, str)
    }
    this.composing.length = [...str].length
    // Caret sits at the end of the provisional run.
    c.offset = start + this.composing.length
    this.refreshCursorRect()
    this.renderCaretPage()
    this.drawCaret(c)
    this.anchorProxy()
  },

  armTrailingCompositionInputGuard(text) {
    const value = String(text || "")
    this.skipNextCompositionInput = value ? { value, at: performance.now() } : null
  },

  swallowTrailingCompositionInput(event) {
    const pending = this.skipNextCompositionInput
    if (!pending) return false

    const type = event.inputType || ""
    const data = String(event.data != null ? event.data : (this.imeProxy && this.imeProxy.value) || "")
    const age = performance.now() - pending.at
    const compositionInput = type === "insertCompositionText" || type === "insertReplacementText"
    const sameImmediateText = data === pending.value && age >= 0 && age < 500

    this.skipNextCompositionInput = null
    return compositionInput || sameImmediateText
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
      this.deleteSelection()
      if (event.key === "Enter") this.splitAtCaret()
      return
    }

    switch (event.key) {
      case "Backspace":
        event.preventDefault()
        this.deleteBackward()
        break
      case "Delete":
        event.preventDefault()
        this.deleteForward()
        break
      case "Enter":
        event.preventDefault()
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
    this.renderCaretPage()
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
    this.renderCaretPage()
    this.drawCaret(c)
    this.anchorProxy()
    this.scheduleSnapshot()
  },

  saveShortcut(event) {
    return (event.metaKey || event.ctrlKey) && (event.key === "s" || event.key === "S")
  },
}
