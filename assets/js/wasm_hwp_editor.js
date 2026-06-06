// Browser-WASM HWP/HWPX editor hook.
//
// This is the client half of the migration off the server-side `ehwp` NIF: the
// browser loads rhwp_core's WASM build and does render + hit-test + EDITING
// locally on a per-page `<canvas>`. The server keeps the raw bytes as the
// source of truth (it has no rhwp engine anymore) and receives client snapshots
// of the edited document; everything else (page layout, glyph rendering, caret
// hit-testing, the whole edit loop) runs in WASM here.
//
// THE EDIT LOOP (this file):
//   caret state = { section, paragraph, offset, cursorRect, + optional cell ctx }
//   For each input we:
//     1. apply the edit to the WASM `HwpDocument` (insertText/deleteText/…)
//     2. re-render ONLY the affected page canvas (renderPageToCanvas, no cache)
//     3. recompute the caret rect (from the op result or getCursorRect) and
//        redraw the blinking caret overlay
//   All local, no server round-trip per keystroke. After edits settle (idle /
//   debounced) we export the doc to HWP/HWPX bytes and push a snapshot to the
//   server so a browser close doesn't lose work.
//
// IME: the hidden <textarea> proxy stays the OS IME target. Plain text arrives
// via its `input` event (non-composing); Korean composition is rendered
// IN-DOCUMENT (provisional region replaced on each compositionupdate, committed
// on compositionend) — NOT a separate preview overlay — matching the proven
// server-side ehwp UX.
//
// The wasm-bindgen `--target web` glue exposes `init(wasmUrl)` plus the
// `HwpDocument` class. esbuild bundles `rhwp.js` into app.js; the 5MB
// `rhwp_bg.wasm` is served as a static file under `/assets/rhwp/`.
import init, { HwpDocument } from "../vendor/rhwp/rhwp.js"

const WASM_URL = "/assets/rhwp/rhwp_bg.wasm"

// How long the doc must stay idle (no edits) before we export+snapshot bytes
// to the server. Each edit is instant locally; persistence is debounced so we
// don't serialize the whole document on every keystroke.
const SNAPSHOT_IDLE_MS = 1500

// Module-level singleton: `init()` instantiates the wasm module ONCE per page
// load (every hook instance shares the same wasm memory + HwpDocument class).
let wasmReady = null
function ensureWasm() {
  if (!wasmReady) {
    wasmReady = init(WASM_URL).then(() => {
      window.__rhwpWasmReady = true
      return true
    })
  }
  return wasmReady
}

const WasmHwpEditor = {
  mounted() {
    this.doc = null
    this.pageCount = 0
    this.scale = 1
    // page index -> true once rendered
    this.rendered = new Map()
    // page indices currently near the viewport (IntersectionObserver)
    this.visible = new Set()

    // Caret state. `cell` is the table/textbox context (null for body text).
    //   caret = { section, paragraph, offset, pageIndex, cursorRect,
    //             cell: { parentParaIndex, controlIndex, cellIndex,
    //                     cellParaIndex, cellPath } | null,
    //             preferredX }   // sticky x for Up/Down vertical motion
    this.caret = null
    // Active text selection (drag-select). null when there is no selection.
    //   selection = { section, cell, anchor: {paragraph, offset},
    //                 focus: {paragraph, offset} }
    // anchor = where mousedown landed; focus = where the pointer is now. A
    // selection collapses to a plain caret when anchor and focus coincide.
    this.selection = null
    // Live drag-select gesture (only set while the mouse button is held).
    //   dragSelect = { pageIndex, section, cell, anchor: {paragraph, offset},
    //                  moved }   // moved=true once the pointer actually dragged
    this.dragSelect = null
    // Lamport-ish monotonic counter for op-log event ids (recovery stream).
    this.lamport = 0
    // Korean IME provisional composition region currently live in the document.
    //   composing = { start, length }  (in the caret's paragraph/cell)
    this.composing = null
    this.snapshotTimer = null
    this.snapshotSeq = 0
    this.caretBlinkOn = true

    this.imeProxy = this.el.querySelector("[data-role='local-hwp-ime-proxy']")
    this.pageStack = this.el.querySelector("[data-role='local-hwp-pages']")

    this.documentId = this.el.dataset.documentId || this.el.dataset.localDocumentId
    this.format = this.el.dataset.localDocumentFormat || "hwp"

    // Pre-warm the wasm module so the first `hwp_wasm_load` doesn't pay the
    // instantiation cost on the critical path.
    ensureWasm().catch(error => console.error("[wasm-hwp] init failed", error))

    // Server pushes this when an HWP/HWPX document opens (re-open / revision
    // change): fetch its raw bytes and hand them to the WASM engine.
    this.handleEvent("hwp_wasm_load", payload => this.loadDocument(payload))

    // Agent edit/read/find routed from the server because THIS document is
    // `:browser`-backed in the Doc Pool (the WASM model here is its authority).
    // Apply against the same WASM doc the user is viewing, re-render, and reply
    // with the result + new revision so the agent's doc.* tool returns it.
    this.handleEvent("doc.apply_edit", payload => this.handleAgentOp(payload))

    // On a fresh mount the server's `hwp_wasm_load` push may have raced ahead of
    // this hook registering its `handleEvent` above. The host element also
    // carries the bytes URL as a data attribute, so load from it directly — the
    // load is idempotent (a later `hwp_wasm_load` for the same URL just
    // re-renders the same bytes).
    const bytesUrl = this.el.dataset.bytesUrl
    if (bytesUrl) this.loadDocument({ url: bytesUrl })

    // Re-render visible pages on container resize (zoom/devicePixelRatio shifts).
    this.onResize = () => this.renderVisiblePages()
    window.addEventListener("resize", this.onResize)

    // IME proxy focus + mouse hit-testing (caret placement / drag-select).
    // mousedown anchors on the page canvas; mousemove/mouseup are bound on the
    // document so a drag that leaves the canvas (or the window) still tracks and
    // finalizes correctly.
    this.onMouseDown = event => this.onCanvasMouseDown(event)
    this.onMouseMove = event => this.onCanvasMouseMove(event)
    this.onMouseUp = event => this.onCanvasMouseUp(event)
    this.el.addEventListener("mousedown", this.onMouseDown)
    document.addEventListener("mousemove", this.onMouseMove)
    document.addEventListener("mouseup", this.onMouseUp)

    // Wire the edit loop to the IME proxy (the OS-focused editable element).
    this.bindEditing()

    // Blinking caret.
    this.blink = setInterval(() => {
      this.caretBlinkOn = !this.caretBlinkOn
      if (this.caret) this.drawCaret(this.caret)
    }, 530)

    // Lazy render: only render pages near the viewport (a 1000-page deck never
    // rasterizes all pages into canvases at once).
    this.io = new IntersectionObserver(
      entries => {
        for (const e of entries) {
          const idx = Number(e.target.dataset.pageIndex)
          if (e.isIntersecting) {
            this.visible.add(idx)
            this.renderPage(idx)
          } else {
            this.visible.delete(idx)
          }
        }
      },
      { root: this.el, rootMargin: "1200px 0px", threshold: 0 }
    )
  },

  destroyed() {
    if (this.io) this.io.disconnect()
    if (this.blink) clearInterval(this.blink)
    if (this.snapshotTimer) clearTimeout(this.snapshotTimer)
    window.removeEventListener("resize", this.onResize)
    this.el.removeEventListener("mousedown", this.onMouseDown)
    document.removeEventListener("mousemove", this.onMouseMove)
    document.removeEventListener("mouseup", this.onMouseUp)
    this.unbindEditing()
    if (this.doc) {
      try { this.doc.free() } catch (_) {}
      this.doc = null
    }
  },

  async loadDocument({ url }) {
    // Idempotent: a re-pushed `hwp_wasm_load` for the URL we already hold must
    // NOT rebuild the doc — the in-browser doc is the authoritative copy for the
    // viewed document, so reloading the original bytes would discard live edits.
    // (Spurious re-pushes come from tree-refresh / fs-watcher / reconcile cycles.)
    // Reload only on a genuine document switch (a different URL).
    if (this.doc && this.loadedUrl === url) return
    try {
      await ensureWasm()
      const response = await fetch(url, { credentials: "same-origin" })
      if (!response.ok) throw new Error(`document bytes HTTP ${response.status}`)
      const bytes = new Uint8Array(await response.arrayBuffer())

      if (this.doc) {
        try { this.doc.free() } catch (_) {}
        this.doc = null
      }

      this.doc = new HwpDocument(bytes)
      this.loadedUrl = url
      // Distribution/read-only docs must be converted before render/edit (the
      // reference editor does this on every open). Harmless on normal docs.
      try { this.doc.convertToEditable() } catch (_) {}
      try { this.format = this.doc.getSourceFormat() || this.format } catch (_) {}

      this.pageCount = this.doc.pageCount()
      this.caret = null
      this.composing = null
      window.__rhwpDoc = this.doc

      this.buildPageStack()
      this.renderVisiblePages()
    } catch (error) {
      console.error("[wasm-hwp] load failed", error)
    }
  },

  // Build one box-reserving <section> per page with a render <canvas> and a
  // caret-overlay <canvas>. `phx-update="ignore"` on the stack means the hook
  // owns this DOM (LiveView won't patch it), so we create the page nodes here.
  buildPageStack() {
    if (!this.pageStack) return
    this.rendered.clear()
    this.visible.clear()
    this.pageStack.replaceChildren()
    if (this.io) this.io.disconnect()

    for (let i = 0; i < this.pageCount; i++) {
      const { w, h } = this.pageInfo(i)

      const section = document.createElement("section")
      section.className = "ehwp-svg-page"
      section.dataset.role = "local-hwp-page"
      section.dataset.pageIndex = String(i)
      section.dataset.pageNumber = String(i + 1)
      section.style.cssText = `width:${w}px;max-width:100%;aspect-ratio:${w} / ${h};position:relative`

      const canvas = document.createElement("canvas")
      canvas.dataset.role = "ehwp-canvas"
      canvas.style.cssText = "display:block;width:100%;height:100%"

      const overlay = document.createElement("canvas")
      overlay.dataset.role = "ehwp-caret-overlay"
      overlay.style.cssText =
        "position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none"

      section.appendChild(canvas)
      section.appendChild(overlay)
      this.pageStack.appendChild(section)
      this.io.observe(section)
    }
  },

  pageInfo(index) {
    try {
      const info = JSON.parse(this.doc.getPageInfo(index))
      const w = Math.max(1, Math.round(info.width || 794))
      const h = Math.max(1, Math.round(info.height || 1123))
      return { w, h }
    } catch (_) {
      return { w: 794, h: 1123 }
    }
  },

  renderVisiblePages() {
    for (const idx of this.visible) this.renderPage(idx)
    if (this.visible.size === 0 && this.pageCount > 0) this.renderPage(0)
  },

  renderPage(index) {
    if (!this.doc) return
    const section = this.pageSection(index)
    if (!section) return
    const canvas = section.querySelector("[data-role='ehwp-canvas']")
    if (!canvas) return

    // Render scale = devicePixelRatio so the canvas backing store matches
    // physical pixels (crisp text, no interpolation). renderPageToCanvas sizes
    // the backing store to pageWidth*scale x pageHeight*scale; CSS keeps it at
    // 100% of the box (which already has the page's aspect-ratio).
    const dpr = window.devicePixelRatio || 1
    this.scale = dpr
    try {
      this.doc.renderPageToCanvas(index, canvas, dpr)
      // Keep the caret overlay's backing store in lockstep with the page canvas.
      const overlay = section.querySelector("[data-role='ehwp-caret-overlay']")
      if (overlay) {
        overlay.width = canvas.width
        overlay.height = canvas.height
      }
      this.rendered.set(index, true)
      // Redraw the caret if it lives on this page (a re-render clears it).
      if (this.caret && this.caret.cursorRect && this.caret.cursorRect.pageIndex === index) {
        this.drawCaret(this.caret)
      }
    } catch (error) {
      console.error(`[wasm-hwp] renderPage(${index}) failed`, error)
    }
  },

  pageSection(index) {
    return this.pageStack &&
      this.pageStack.querySelector(`[data-role='local-hwp-page'][data-page-index='${index}']`)
  },

  // Render whatever page the caret currently sits on. After an edit reflows the
  // document, the affected glyph lives on `cursorRect.pageIndex`; we re-render
  // exactly that page (plus any other visible page that changed by reflow).
  renderCaretPage() {
    const idx = this.caret && this.caret.cursorRect && this.caret.cursorRect.pageIndex
    if (typeof idx === "number") this.renderPage(idx)
    // A split/merge/large insert can push content onto neighbouring visible
    // pages; refresh the visible window so reflow is reflected immediately.
    for (const v of this.visible) if (v !== idx) this.renderPage(v)
  },

  // mousedown on a page canvas -> map canvas-rect coords to PAGE coords -> hitTest.
  //
  // Page coord = (clientX - rect.left) * (canvas.width / rect.width) / scale.
  // `canvas.width / rect.width` is the CSS-px -> backing-px ratio (includes the
  // devicePixelRatio supersampling); dividing by `scale` (== dpr) yields page
  // units, which is the coordinate space renderPageToCanvas/hitTest use.
  onCanvasMouseDown(event) {
    if (event.button !== 0 || !this.doc) return
    const hitInfo = this.hitTestEvent(event)
    if (!hitInfo) return
    const { hit, pageIndex } = hitInfo
    window.__rhwpLastHit = hit

    // Place the caret at the press point (this is also the selection anchor).
    this.setCaretFromHit(hit, pageIndex)

    // Arm a drag-select gesture. mousemove (while pressed) extends the focus;
    // mouseup finalizes. `moved` stays false until the pointer actually moves to
    // a different document offset, so a plain click leaves only a caret.
    const c = this.caret
    this.dragSelect = {
      pageIndex,
      section: c.section,
      cell: c.cell,
      anchor: { paragraph: c.paragraph, offset: c.offset },
      moved: false
    }
    // A fresh press clears any prior selection until the drag re-establishes one.
    this.clearSelection()

    // Keep the OS IME composition target focused + anchored at the caret so the
    // Korean candidate window pops next to the cursor.
    if (this.imeProxy) {
      event.preventDefault()
      this.imeProxy.focus({ preventScroll: true })
      this.anchorProxy()
    }
  },

  // mousemove while the button is held: hit-test the current point and extend
  // the selection from the drag anchor to the current (focus) offset.
  onCanvasMouseMove(event) {
    if (!this.dragSelect || !this.doc) return
    // Only react while the primary button is still pressed (defensive: a mouseup
    // outside the window can be missed).
    if ((event.buttons & 1) === 0) {
      this.onCanvasMouseUp(event)
      return
    }
    const hitInfo = this.hitTestEvent(event, this.dragSelect.pageIndex)
    if (!hitInfo) return
    const { hit } = hitInfo
    if (hit.sectionIndex !== undefined && hit.sectionIndex !== this.dragSelect.section) return

    const focus = {
      paragraph: hit.paragraphIndex !== undefined ? hit.paragraphIndex : 0,
      offset: hit.charOffset !== undefined ? hit.charOffset : 0
    }
    const ds = this.dragSelect
    const sameSpot = focus.paragraph === ds.anchor.paragraph && focus.offset === ds.anchor.offset
    if (!sameSpot) ds.moved = true

    // Update the live caret/focus position so the caret tracks the pointer and
    // the IME proxy follows.
    this.setCaretFromHit(hit, ds.pageIndex)

    if (ds.moved) {
      this.selection = {
        section: ds.section,
        cell: ds.cell,
        anchor: { ...ds.anchor },
        focus
      }
    } else {
      this.clearSelection()
    }
    this.renderSelection()
    // Re-draw the caret on top of the selection highlight.
    if (this.caret) this.drawCaret(this.caret)
    this.anchorProxy()
    if (event.cancelable) event.preventDefault()
  },

  // mouseup: finalize (or discard) the drag-select gesture.
  onCanvasMouseUp(_event) {
    if (!this.dragSelect) return
    const ds = this.dragSelect
    this.dragSelect = null
    if (!ds.moved) {
      // Plain click — no drag — so leave just the caret (no selection).
      this.clearSelection()
      this.renderSelection()
      if (this.caret) this.drawCaret(this.caret)
    }
    // A moved drag already established `this.selection` during mousemove; nothing
    // more to do — the highlight stays until the next press.
  },

  // Map a pointer event to { hit, pageIndex } via the engine's hitTest. When the
  // pointer is over a page canvas we use that page; otherwise (drag left the
  // canvas) we fall back to `preferPage` and clamp coords into its box so the
  // selection still extends to the nearest in-page offset.
  hitTestEvent(event, preferPage) {
    let section = event.target && event.target.closest
      ? event.target.closest("[data-role='local-hwp-page']")
      : null
    let pageIndex = section ? Number(section.dataset.pageIndex) : preferPage
    if (section == null && preferPage != null) section = this.pageSection(preferPage)
    if (!section && typeof pageIndex === "number") section = this.pageSection(pageIndex)
    if (!section) return null
    if (typeof pageIndex !== "number" || Number.isNaN(pageIndex)) {
      pageIndex = Number(section.dataset.pageIndex)
    }
    const canvas = section.querySelector("[data-role='ehwp-canvas']")
    if (!canvas) return null

    const rect = canvas.getBoundingClientRect()
    const backingRatio = canvas.width / rect.width
    // Clamp the pointer into the canvas box so a drag that runs past the page
    // edge still resolves to the nearest in-page glyph.
    const clientX = Math.min(Math.max(event.clientX, rect.left), rect.right)
    const clientY = Math.min(Math.max(event.clientY, rect.top), rect.bottom)
    const x = ((clientX - rect.left) * backingRatio) / this.scale
    const y = ((clientY - rect.top) * backingRatio) / this.scale

    try {
      const raw = this.doc.hitTest(pageIndex, x, y)
      if (!raw) return null
      return { hit: JSON.parse(raw), pageIndex }
    } catch (error) {
      console.error("[wasm-hwp] hitTest failed", error)
      return null
    }
  },

  // ─── Selection rendering ─────────────────────────────────────────────────

  // Drop the active selection (state only; caller re-renders).
  clearSelection() {
    this.selection = null
    window.__rhwpSelection = null
  },

  // Ask the engine for the line-by-line rects of the current selection and paint
  // a translucent highlight on each affected page's overlay canvas (the same
  // overlay the caret uses). getSelectionRects returns page-coordinate rects
  // `[{pageIndex, x, y, width, height}, ...]`; we scale them to the overlay
  // backing store exactly like drawCaret does.
  renderSelection() {
    // Clear selection paint from every overlay we might have drawn on. Because a
    // selection can span pages we clear the whole visible window, then the caret
    // is redrawn by the caller.
    this.clearSelectionOverlays()

    const sel = this.selection
    if (!sel) return
    // Collapsed selection => nothing to paint.
    if (sel.anchor.paragraph === sel.focus.paragraph && sel.anchor.offset === sel.focus.offset) {
      return
    }

    // Normalize so start <= end in document order.
    const [start, end] = this.orderedSelection(sel)
    window.__rhwpSelection = { section: sel.section, start, end, cell: sel.cell || null }

    let rects
    try {
      let raw
      if (sel.cell) {
        raw = this.doc.getSelectionRectsInCell(
          sel.section, sel.cell.parentParaIndex, sel.cell.controlIndex,
          sel.cell.cellIndex, start.paragraph, start.offset, end.paragraph, end.offset
        )
      } else {
        raw = this.doc.getSelectionRects(
          sel.section, start.paragraph, start.offset, end.paragraph, end.offset
        )
      }
      rects = raw ? JSON.parse(raw) : []
    } catch (error) {
      console.error("[wasm-hwp] getSelectionRects failed", error)
      return
    }
    window.__rhwpSelectionRects = rects
    if (!Array.isArray(rects) || rects.length === 0) return

    const s = this.scale
    for (const r of rects) {
      const overlay = this.pageOverlay(r.pageIndex)
      if (!overlay) continue
      const ctx = overlay.getContext("2d")
      if (!ctx) continue
      ctx.fillStyle = "rgba(29, 78, 216, 0.28)" // matches the caret blue
      ctx.fillRect(r.x * s, r.y * s, Math.max(1, r.width) * s, Math.max(1, r.height) * s)
    }
  },

  // Clear all overlay canvases (selection highlight + any stale caret) across the
  // page stack so a moving selection doesn't leave streaks behind.
  clearSelectionOverlays() {
    if (!this.pageStack) return
    const overlays = this.pageStack.querySelectorAll("[data-role='ehwp-caret-overlay']")
    for (const overlay of overlays) {
      const ctx = overlay.getContext("2d")
      if (ctx) ctx.clearRect(0, 0, overlay.width, overlay.height)
    }
  },

  pageOverlay(index) {
    const section = this.pageSection(index)
    return section ? section.querySelector("[data-role='ehwp-caret-overlay']") : null
  },

  // Order a selection's anchor/focus into [start, end] in document order.
  orderedSelection(sel) {
    const a = sel.anchor
    const f = sel.focus
    const before = a.paragraph < f.paragraph ||
      (a.paragraph === f.paragraph && a.offset <= f.offset)
    return before ? [a, f] : [f, a]
  },

  // True when a non-collapsed selection is active.
  hasSelection() {
    const sel = this.selection
    return !!sel &&
      !(sel.anchor.paragraph === sel.focus.paragraph && sel.anchor.offset === sel.focus.offset)
  },

  // Drop the selection highlight and repaint the overlays (keeps the caret).
  collapseSelection() {
    if (!this.selection) return
    this.clearSelection()
    this.clearSelectionOverlays()
    if (this.caret) this.drawCaret(this.caret)
  },

  // Delete the active selection from the document and collapse the caret to the
  // start of the deleted range. Used when typing / Backspace / Delete replaces a
  // selection. The engine returns the collapse point `{paraIdx, charOffset}`.
  deleteSelection() {
    if (!this.hasSelection()) return
    const sel = this.selection
    const [start, end] = this.orderedSelection(sel)
    const c = this.caret
    try {
      let raw
      if (sel.cell && c.cell) {
        raw = this.doc.deleteRangeInCell(
          sel.section, c.cell.parentParaIndex, c.cell.controlIndex,
          c.cell.cellIndex, start.paragraph, start.offset, end.paragraph, end.offset
        )
        const r = JSON.parse(raw)
        c.cell.cellParaIndex = r.paraIdx !== undefined ? r.paraIdx : start.paragraph
        c.offset = r.charOffset !== undefined ? r.charOffset : start.offset
      } else {
        raw = this.doc.deleteRange(
          sel.section, start.paragraph, start.offset, end.paragraph, end.offset
        )
        const r = JSON.parse(raw)
        c.paragraph = r.paraIdx !== undefined ? r.paraIdx : start.paragraph
        c.offset = r.charOffset !== undefined ? r.charOffset : start.offset
      }
      this.recordOp("RangeDeleted", {
        section: sel.section,
        startPara: start.paragraph, startOffset: start.offset,
        endPara: end.paragraph, endOffset: end.offset
      })
    } catch (error) {
      console.error("[wasm-hwp] deleteRange failed", error)
      return
    }
    c.preferredX = -1
    this.clearSelection()
    this.refreshCursorRect()
    this.renderCaretPage()
    this.clearSelectionOverlays()
    this.drawCaret(c)
    this.anchorProxy()
    this.scheduleSnapshot()
  },

  // Normalize a hitTest / moveVertical result into caret state.
  setCaretFromHit(hit, fallbackPage) {
    const cell =
      hit.parentParaIndex !== undefined
        ? {
            parentParaIndex: hit.parentParaIndex,
            controlIndex: hit.controlIndex,
            cellIndex: hit.cellIndex,
            cellParaIndex: hit.cellParaIndex,
            cellPath: hit.cellPath || null,
            isTextBox: !!hit.isTextBox
          }
        : null

    const cursorRect = hit.cursorRect ||
      (hit.x !== undefined
        ? { pageIndex: hit.pageIndex !== undefined ? hit.pageIndex : fallbackPage,
            x: hit.x, y: hit.y, height: hit.height }
        : null)

    this.caret = {
      section: hit.sectionIndex !== undefined ? hit.sectionIndex : (this.caret ? this.caret.section : 0),
      // For cell carets the editable paragraph index is cellParaIndex; for body
      // it's paragraphIndex.
      paragraph: hit.paragraphIndex !== undefined ? hit.paragraphIndex : 0,
      offset: hit.charOffset !== undefined ? hit.charOffset : 0,
      cell,
      cursorRect,
      preferredX: -1
    }
    this.caretBlinkOn = true
    this.drawCaret(this.caret)
    this.anchorProxy()
  },

  // Refresh `cursorRect` from the engine for the current caret position. Used
  // after edits whose result JSON gives us the new offset but not coordinates.
  refreshCursorRect() {
    if (!this.caret || !this.doc) return
    const c = this.caret
    try {
      let raw
      if (c.cell) {
        raw = this.doc.getCursorRectInCell(
          c.section, c.cell.parentParaIndex, c.cell.controlIndex,
          c.cell.cellIndex, c.cell.cellParaIndex, c.offset
        )
      } else {
        raw = this.doc.getCursorRect(c.section, c.paragraph, c.offset)
      }
      if (raw) c.cursorRect = JSON.parse(raw)
    } catch (error) {
      console.error("[wasm-hwp] getCursorRect failed", error)
    }
  },

  // Draw the blinking caret on the page's overlay canvas, in page coords scaled
  // to the overlay backing store (overlay.width == page canvas.width == w*scale).
  drawCaret(caret) {
    const rect = caret && caret.cursorRect
    if (!rect) return
    const section = this.pageSection(rect.pageIndex)
    if (!section) return
    const overlay = section.querySelector("[data-role='ehwp-caret-overlay']")
    if (!overlay) return
    const ctx = overlay.getContext("2d")
    if (!ctx) return

    ctx.clearRect(0, 0, overlay.width, overlay.height)
    // The caret and the selection highlight share this overlay; clearing it for
    // the caret blink would wipe the highlight, so repaint the selection first.
    if (this.selection) this.paintSelectionOnPage(rect.pageIndex)
    if (!this.caretBlinkOn) return
    const s = this.scale
    ctx.fillStyle = "#1d4ed8"
    ctx.fillRect(rect.x * s, rect.y * s, 1.5 * s, (rect.height || 16) * s)
  },

  // Paint just the selection rects that fall on `pageIndex` (used by drawCaret to
  // restore the highlight after it clears the shared overlay for a blink frame).
  paintSelectionOnPage(pageIndex) {
    const sel = this.selection
    if (!sel) return
    if (sel.anchor.paragraph === sel.focus.paragraph && sel.anchor.offset === sel.focus.offset) {
      return
    }
    const [start, end] = this.orderedSelection(sel)
    let rects
    try {
      let raw
      if (sel.cell) {
        raw = this.doc.getSelectionRectsInCell(
          sel.section, sel.cell.parentParaIndex, sel.cell.controlIndex,
          sel.cell.cellIndex, start.paragraph, start.offset, end.paragraph, end.offset
        )
      } else {
        raw = this.doc.getSelectionRects(
          sel.section, start.paragraph, start.offset, end.paragraph, end.offset
        )
      }
      rects = raw ? JSON.parse(raw) : []
    } catch (_) {
      return
    }
    if (!Array.isArray(rects)) return
    const overlay = this.pageOverlay(pageIndex)
    if (!overlay) return
    const ctx = overlay.getContext("2d")
    if (!ctx) return
    const s = this.scale
    ctx.fillStyle = "rgba(29, 78, 216, 0.28)"
    for (const r of rects) {
      if (r.pageIndex !== pageIndex) continue
      ctx.fillRect(r.x * s, r.y * s, Math.max(1, r.width) * s, Math.max(1, r.height) * s)
    }
  },

  // Position the hidden IME proxy textarea over the caret so the OS candidate
  // window anchors there (Korean) and so the caret-row stays focused.
  anchorProxy() {
    if (!this.imeProxy || !this.caret || !this.caret.cursorRect) return
    const rect = this.caret.cursorRect
    const section = this.pageSection(rect.pageIndex)
    if (!section) return
    const canvas = section.querySelector("[data-role='ehwp-canvas']")
    if (!canvas) return
    const cr = canvas.getBoundingClientRect()
    const hostRect = this.el.getBoundingClientRect()
    // page units -> CSS px within the page box.
    const cssPerPage = cr.width / (canvas.width / this.scale)
    const left = cr.left - hostRect.left + this.el.scrollLeft + rect.x * cssPerPage
    const top = cr.top - hostRect.top + this.el.scrollTop + rect.y * cssPerPage
    this.imeProxy.style.left = `${Math.round(left)}px`
    this.imeProxy.style.top = `${Math.round(top)}px`
    this.imeProxy.style.height = `${Math.max(12, Math.round((rect.height || 16) * cssPerPage))}px`
  },

  // ─── Edit loop wiring ────────────────────────────────────────────────────

  bindEditing() {
    if (!this.imeProxy) return
    this.onBeforeInput = e => this.handleBeforeInput(e)
    this.onInput = e => this.handleInput(e)
    this.onCompositionStart = e => this.handleCompositionStart(e)
    this.onCompositionUpdate = e => this.handleCompositionUpdate(e)
    this.onCompositionEnd = e => this.handleCompositionEnd(e)
    this.onKeyDown = e => this.handleKeyDown(e)

    this.imeProxy.addEventListener("beforeinput", this.onBeforeInput)
    this.imeProxy.addEventListener("input", this.onInput)
    this.imeProxy.addEventListener("compositionstart", this.onCompositionStart)
    this.imeProxy.addEventListener("compositionupdate", this.onCompositionUpdate)
    this.imeProxy.addEventListener("compositionend", this.onCompositionEnd)
    this.imeProxy.addEventListener("keydown", this.onKeyDown)
  },

  unbindEditing() {
    if (!this.imeProxy) return
    this.imeProxy.removeEventListener("beforeinput", this.onBeforeInput)
    this.imeProxy.removeEventListener("input", this.onInput)
    this.imeProxy.removeEventListener("compositionstart", this.onCompositionStart)
    this.imeProxy.removeEventListener("compositionupdate", this.onCompositionUpdate)
    this.imeProxy.removeEventListener("compositionend", this.onCompositionEnd)
    this.imeProxy.removeEventListener("keydown", this.onKeyDown)
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
    if (event.isComposing) return

    const type = event.inputType || ""
    if (type === "insertText" || type === "insertFromPaste" ||
        type === "insertCompositionText" || type === "insertReplacementText") {
      const data = event.data != null ? event.data : this.imeProxy.value
      // Typing over a selection replaces it: delete the range, then insert.
      if (data) {
        if (this.hasSelection()) this.deleteSelection()
        this.insertAtCaret(data)
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
    this.composing = { start: this.caret.offset, length: 0 }
  },

  // compositionupdate — replace the provisional composing string IN the document
  // (in-document composing, not a separate overlay). We delete the previous
  // provisional run and insert the new one, then re-render + reposition caret.
  handleCompositionUpdate(event) {
    if (!this.doc || !this.caret || !this.composing) return
    const str = event.data || ""
    this.replaceComposing(str)
  },

  // compositionend — commit. The final string is already in the document from
  // the last compositionupdate; we just finalize the region and clear the proxy
  // (the OS IME target).
  handleCompositionEnd(event) {
    if (!this.doc || !this.caret) return
    if (this.composing) {
      const str = event.data || ""
      // Ensure the committed string matches the final composition (some IMEs
      // send a final compositionend with the resolved text).
      this.replaceComposing(str)
      this.composing = null
    }
    this.imeProxy.value = ""
    this.scheduleSnapshot()
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
    this.composing.length = str.length
    // Caret sits at the end of the provisional run.
    c.offset = start + str.length
    this.refreshCursorRect()
    this.renderCaretPage()
    this.drawCaret(c)
    this.anchorProxy()
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
      if (c.cell) {
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
      if (c.cell) {
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
    if (!this.doc || !this.caret) return
    if (event.isComposing) return // IME owns the keystroke
    if (event.metaKey || event.ctrlKey || event.altKey) return // shortcuts pass through

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

  // Left/Right: move the caret offset by ±1. The engine's getCursorRect gives
  // us the new coordinates; paragraph/line boundary crossing is handled by
  // clamping at 0 / paragraph length and stepping to the adjacent paragraph.
  moveHorizontal(dir) {
    const c = this.caret
    const len = this.caretParagraphLength()
    let offset = c.offset + dir

    if (offset < 0) {
      // Step to end of previous paragraph (body only for now).
      if (!c.cell && c.paragraph > 0) {
        c.paragraph -= 1
        c.offset = this.paragraphLength(c.section, c.paragraph)
      } else {
        c.offset = 0
      }
    } else if (offset > len) {
      if (!c.cell && c.paragraph + 1 < this.paragraphCount(c.section)) {
        c.paragraph += 1
        c.offset = 0
      } else {
        c.offset = len
      }
    } else {
      c.offset = offset
    }
    c.preferredX = -1
    this.refreshCursorRect()
    this.drawCaret(c)
    this.anchorProxy()
  },

  // Up/Down: ask the engine to move vertically, keeping a sticky preferred x so
  // the caret tracks a column down a ragged-right paragraph. moveVertical
  // returns the new position + cursor coords + the preferredX to carry forward.
  moveVertical(dir) {
    const c = this.caret
    const cell = c.cell
    const SENTINEL = 0xffffffff
    try {
      const raw = this.doc.moveVertical(
        c.section, c.paragraph, c.offset, dir, c.preferredX,
        cell ? cell.parentParaIndex : SENTINEL,
        cell ? cell.controlIndex : 0,
        cell ? cell.cellIndex : 0,
        cell ? cell.cellParaIndex : 0
      )
      const r = JSON.parse(raw)
      const preferredX = r.preferredX
      this.setCaretFromHit(r, c.cursorRect ? c.cursorRect.pageIndex : 0)
      if (typeof preferredX === "number") this.caret.preferredX = preferredX
    } catch (error) {
      console.error("[wasm-hwp] moveVertical failed", error)
    }
  },

  caretParagraphLength() {
    const c = this.caret
    try {
      if (c.cell) {
        return this.doc.getCellParagraphLength(
          c.section, c.cell.parentParaIndex, c.cell.controlIndex,
          c.cell.cellIndex, c.cell.cellParaIndex
        )
      }
      return this.doc.getParagraphLength(c.section, c.paragraph)
    } catch (_) {
      return c.offset
    }
  },

  paragraphLength(section, paragraph) {
    try { return this.doc.getParagraphLength(section, paragraph) } catch (_) { return 0 }
  },

  paragraphCount(section) {
    try { return this.doc.getParagraphCount(section) } catch (_) { return 1 }
  },

  // ─── Agent ops (server -> browser, design §6.2) ──────────────────────────

  // Apply an agent-routed op to the authoritative WASM doc and reply with the
  // result. `verb` is read | find | edit. The reply is always sent (even on
  // error) so the blocked MCP caller never hangs to its timeout.
  handleAgentOp({ request_id, verb, payload }) {
    const reply = body => this.pushEvent("doc.browser_reply", { request_id, ...body })
    if (!this.doc) {
      reply({ error: "document_not_loaded" })
      return
    }
    try {
      switch (verb) {
        case "edit":
          // Batch form (doc_edit {ops:[...]}) vs. single op (doc_edit {op}).
          reply(
            Array.isArray(payload && payload.ops)
              ? this.applyAgentEditBatch(payload)
              : this.applyAgentEdit(payload)
          )
          break
        case "set":
          // Batch form (doc_set {sets:[{ref,props}]}) vs. single (doc_set {ref,props}).
          reply(
            Array.isArray(payload && payload.sets)
              ? this.applyAgentSetBatch(payload)
              : this.applyAgentSet(payload)
          )
          break
        case "find":
          reply({ result: this.applyAgentFind(payload) })
          break
        case "read":
          reply({ result: this.applyAgentRead(payload) })
          break
        case "save":
          // The viewer's WASM model is authority for an open doc — export its
          // CURRENT edited bytes so doc.save persists what the user sees.
          reply({ result: this.exportForSave() })
          break
        default:
          reply({ error: `unsupported_verb:${verb}` })
      }
    } catch (error) {
      console.error("[wasm-hwp] agent op failed", verb, error)
      reply({ error: String((error && error.message) || error) })
    }
  },

  // Structural edit verbs over the viewed WASM model: `replace_text`,
  // `insert_text`, `delete_range`. Each addresses text positionally via a `ref`
  // ({section, paragraph, offset} from doc.find) so the agent can target ONE
  // paragraph instead of the whole document. `replace_text` may also run without
  // a ref (global), but only replaces >1 match when `all:true` is set.
  //
  // Single-op entry point: apply the MUTATION (applyOneOp, no render) then run
  // the shared finish (re-render + revision bump) ONCE. The mutation and the
  // finish are deliberately split so the BATCH path (applyAgentEditBatch) can
  // mutate many ops and finish a single time.
  applyAgentEdit({ op, base_revision }) {
    const baseRev = typeof base_revision === "number" ? base_revision : 0
    const r = this.applyOneOp(op)
    if (r.error) return { error: r.error }
    return this.finishAgentEdit(baseRev, r.extra || {})
  },

  // Apply ONE structural edit op to the WASM model and return either
  // `{ ok: true, extra }` (the per-verb result fields the finish should echo) or
  // `{ error }`. This function NEVER renders or bumps the revision — that is the
  // caller's job via finishAgentEdit, so a batch can mutate N ops and finish once.
  applyOneOp(op) {
    const verb = op && op.op
    const ref = this.parseRef(op && op.ref)

    if (verb === "replace_text") {
      const query = op.query != null ? String(op.query) : ""
      if (!query) return { error: "replace_text requires a non-empty query" }
      // A MISSING replacement must never become a silent delete — that is how a
      // mis-fielded op (new text under `text`/`new`) wiped paragraphs. Require it
      // explicitly; to delete text the agent uses delete_range.
      if (op.replacement == null) {
        return { error: "replace_text requires a 'replacement' field (the field is 'replacement', not 'text'/'new'; to delete text use delete_range)" }
      }
      const replacement = String(op.replacement)
      if (replacement.includes("\n")) {
        return { error: "replace_text replacement must be a single paragraph (no newlines); use one op per paragraph or 'split'" }
      }

      // cell-scoped: the ref addresses text inside a TABLE CELL. Read/replace via
      // the cell primitives (getTextInCell/deleteTextInCell/insertTextInCell) — the
      // body getTextRange path can't see cell text, so without this the agent can
      // never fill a table (signature block, 계약금액 table, …).
      if (ref && ref.cell) {
        const cl = ref.cell
        let cellText = ""
        try {
          const len = this.doc.getCellParagraphLength(
            ref.section, cl.parentParaIndex, cl.controlIndex, cl.cellIndex, cl.cellParaIndex
          )
          cellText =
            this.doc.getTextInCell(
              ref.section, cl.parentParaIndex, cl.controlIndex, cl.cellIndex, cl.cellParaIndex, 0, len
            ) || ""
        } catch (error) {
          return { error: `cell read failed: ${String((error && error.message) || error)}` }
        }
        const idx = cellText.indexOf(query)
        if (idx < 0) {
          return { error: `replace_text: query not found in target cell (cell text: ${JSON.stringify(cellText.slice(0, 80))})` }
        }
        try {
          this.doc.deleteTextInCell(
            ref.section, cl.parentParaIndex, cl.controlIndex, cl.cellIndex, cl.cellParaIndex, idx, query.length
          )
          this.doc.insertTextInCell(
            ref.section, cl.parentParaIndex, cl.controlIndex, cl.cellIndex, cl.cellParaIndex, idx, replacement
          )
        } catch (error) {
          return { error: `cell replace failed: ${String((error && error.message) || error)}` }
        }
        this.recordOp("AgentReplaceText", { section: ref.section, cell: cl, offset: idx, query, replacement, replaced: 1 })
        return { ok: true, extra: { replaced: 1 } }
      }

      // ref-scoped: replace the query ONLY inside the referenced paragraph, so a
      // phrase that recurs across sample blocks is edited exactly where intended.
      if (ref) {
        let paraText = ""
        try {
          const len = this.paragraphLength(ref.section, ref.paragraph)
          paraText = this.doc.getTextRange(ref.section, ref.paragraph, 0, len) || ""
        } catch (_) {
          paraText = ""
        }
        const idx = paraText.indexOf(query)
        if (idx >= 0) {
          try {
            this.doc.deleteText(ref.section, ref.paragraph, idx, query.length)
            this.doc.insertText(ref.section, ref.paragraph, idx, replacement)
          } catch (error) {
            return { error: `scoped replace failed: ${String((error && error.message) || error)}` }
          }
          this.recordOp("AgentReplaceText", { section: ref.section, para: ref.paragraph, offset: idx, query, replacement, replaced: 1 })
          return { ok: true, extra: { replaced: 1 } }
        }
        // Body-paragraph miss — the text most likely lives inside a TABLE CELL,
        // which getTextRange(section,paragraph) does not read. Don't error: fall
        // through to the global count-guarded path below, which searches the whole
        // document (cells included) and replaces the match.
        console.warn(
          `[wasm-hwp] ref-scoped replace: query not in body paragraph ${ref.section}/${ref.paragraph} ` +
            "(likely in a table cell) — falling back to global match"
        )
      }

      // global (no ref): count matches first; replacing >1 needs explicit all:true
      // so a paragraph-length query can never rewrite unrelated sample blocks.
      const all = op.all === true
      let matchCount = null
      try {
        const raw = this.doc.searchAllText(query, true, true)
        const parsed = raw ? JSON.parse(raw) : []
        const list = Array.isArray(parsed) ? parsed : (parsed.matches || [])
        matchCount = list.length
      } catch (_) {
        matchCount = null
      }
      if (matchCount === 0) {
        return { error: `replace_text: no match for query (it must be the document's exact current text)` }
      }
      if (matchCount != null && matchCount > 1 && !all) {
        return { error: `replace_text: query matches ${matchCount} places; pass a ref to target one, use a longer/unique query, or pass all:true to replace every match` }
      }

      let replaced = 0
      try {
        const raw = this.doc.replaceAll(query, replacement, true)
        replaced = this.replacedCount(raw)
      } catch (error) {
        return { error: `replaceAll failed: ${String((error && error.message) || error)}` }
      }
      this.recordOp("AgentReplaceText", { query, replacement, replaced })
      return { ok: true, extra: { replaced } }
    }

    if (verb === "insert_text") {
      if (!ref) return { error: "insert_text requires a ref {section,paragraph,offset} (from doc.find)" }
      const text = op.text != null ? String(op.text) : ""
      if (!text) return { error: "insert_text requires non-empty 'text'" }
      if (text.includes("\n")) return { error: "insert_text 'text' must be a single paragraph (no newlines); use 'split' for new paragraphs" }
      const offset = Number.isInteger(ref.offset) ? ref.offset : 0
      if (ref.cell) {
        const cl = ref.cell
        try {
          this.doc.insertTextInCell(
            ref.section, cl.parentParaIndex, cl.controlIndex, cl.cellIndex, cl.cellParaIndex, offset, text
          )
        } catch (error) {
          return { error: `insertTextInCell failed: ${String((error && error.message) || error)}` }
        }
        this.recordOp("AgentInsertText", { section: ref.section, cell: cl, offset, text })
        return { ok: true, extra: { inserted: text.length } }
      }
      try {
        this.doc.insertText(ref.section, ref.paragraph, offset, text)
      } catch (error) {
        return { error: `insertText failed: ${String((error && error.message) || error)}` }
      }
      this.recordOp("AgentInsertText", { section: ref.section, para: ref.paragraph, offset, text })
      return { ok: true, extra: { inserted: text.length } }
    }

    if (verb === "delete_range") {
      if (!ref) return { error: "delete_range requires a ref {section,paragraph,offset} (from doc.find)" }
      const offset = Number.isInteger(ref.offset) ? ref.offset : 0
      const cl = ref.cell
      // count defaults to "rest of the paragraph from offset" when omitted.
      let count = Number.isInteger(op.count) ? op.count : null
      if (count == null) {
        let len = 0
        try {
          len = cl
            ? this.doc.getCellParagraphLength(ref.section, cl.parentParaIndex, cl.controlIndex, cl.cellIndex, cl.cellParaIndex)
            : this.paragraphLength(ref.section, ref.paragraph)
        } catch (_) {
          len = 0
        }
        count = Math.max(0, len - offset)
      }
      if (count <= 0) return { error: "delete_range: nothing to delete (count must be > 0)" }
      try {
        if (cl) {
          this.doc.deleteTextInCell(
            ref.section, cl.parentParaIndex, cl.controlIndex, cl.cellIndex, cl.cellParaIndex, offset, count
          )
        } else {
          this.doc.deleteText(ref.section, ref.paragraph, offset, count)
        }
      } catch (error) {
        return { error: `deleteText failed: ${String((error && error.message) || error)}` }
      }
      this.recordOp("AgentDeleteRange", { section: ref.section, cell: cl, para: ref.paragraph, offset, count })
      return { ok: true, extra: { deleted: count } }
    }

    return { error: `unsupported_op:${verb}` }
  },

  // Batch structural edit (doc_edit {ops:[...]}). Apply every op to the WASM
  // model with ONE re-render/revision bump at the end (finishAgentEdit). This is
  // best-effort: each op is applied independently, a bad ref does NOT abort the
  // rest, and the result carries a per-op `results` array.
  //
  // ORDERING — index-shifting body ops vs. order-independent cell ops:
  // a verb that inserts/removes BODY paragraphs (insert_text whose text has a
  // newline, insert_paragraph, delete_paragraph, split, merge, delete_range on a
  // body paragraph) shifts the paragraph indices AFTER it, invalidating other
  // body refs the agent computed against the pre-edit document. So body
  // index-shifting ops run in REVERSE document order (section desc, then
  // paragraph desc): editing the LAST paragraph first leaves every earlier ref
  // still valid. Cell-targeted ops (ref carries `.cell`) and pure in-place ops
  // address a fixed cell/offset and never move another op's target, so they are
  // order-independent and run first (in their given order).
  applyAgentEditBatch({ ops, base_revision }) {
    const baseRev = typeof base_revision === "number" ? base_revision : 0
    const list = Array.isArray(ops) ? ops : []
    if (list.length === 0) return { error: "edit batch requires a non-empty 'ops' array" }

    // Tag each op with its original index + whether it shifts body indices, then
    // order: order-independent ops first (original order), index-shifting body
    // ops last in REVERSE document order so earlier body refs stay valid.
    const tagged = list.map((op, idx) => ({ op, idx, shift: this.opShiftsBodyIndices(op) }))
    const stable = tagged.filter((t) => !t.shift)
    const shifting = tagged
      .filter((t) => t.shift)
      .sort((a, b) => {
        const ra = this.parseRef(a.op && a.op.ref) || { section: 0, paragraph: 0 }
        const rb = this.parseRef(b.op && b.op.ref) || { section: 0, paragraph: 0 }
        if ((rb.section || 0) !== (ra.section || 0)) return (rb.section || 0) - (ra.section || 0)
        return (rb.paragraph || 0) - (ra.paragraph || 0)
      })
    const ordered = stable.concat(shifting)

    const results = new Array(list.length)
    let applied = 0
    let failed = 0
    for (const { op, idx } of ordered) {
      const refStr = op && op.ref != null ? (typeof op.ref === "string" ? op.ref : JSON.stringify(op.ref)) : null
      let r
      try {
        r = this.applyOneOp(op)
      } catch (error) {
        r = { error: String((error && error.message) || error) }
      }
      if (r && r.ok) {
        applied++
        results[idx] = Object.assign({ ref: refStr, ok: true }, r.extra || {})
      } else {
        failed++
        results[idx] = { ref: refStr, error: (r && r.error) || "unknown_error" }
      }
    }

    const finished = this.finishAgentEdit(baseRev, {})
    return {
      ok: true,
      result: { ok: true, revision: finished.result.revision, applied, failed, results }
    }
  },

  // Does this op shift BODY paragraph indices after its target? insert_paragraph,
  // delete_paragraph, split and merge always restructure the body; insert_text
  // only when it authors >1 paragraph (its text contains a newline); delete_range
  // can collapse a paragraph. Cell-targeted ops (ref has `.cell`) never move
  // another op's body target, so they are order-independent. Used only to ORDER a
  // batch — never to reject an op.
  opShiftsBodyIndices(op) {
    if (!op || typeof op !== "object") return false
    const ref = this.parseRef(op.ref)
    if (ref && ref.cell) return false // cell-targeted: order-independent
    switch (op.op) {
      case "insert_paragraph":
      case "delete_paragraph":
      case "split":
      case "merge":
        return true
      case "insert_text":
        return typeof op.text === "string" && op.text.includes("\n")
      case "delete_range":
        return true
      default:
        return false
    }
  },

  // Universal property set (doc.set) over the viewed WASM model, so a property
  // change RENDERS in the viewer — the server NIF copy is NOT what the user sees,
  // which is why server-side doc.set was invisible for an open doc. `props` is the
  // agent's property map; a `kind` discriminator (if present) is stripped — the
  // engine reads the property KEYS (BackgroundColor/fillColor for a cell;
  // Bold/TextColor/FontSize for a char run). `ref` is doc.find's positional ref; a
  // cell ref carries {parentParaIndex,controlIndex,cellIndex,cellParaIndex}.
  applyAgentSet({ ref, props, base_revision }) {
    const baseRev = typeof base_revision === "number" ? base_revision : 0
    const r = this.applySetOne(ref, props)
    if (r.error) return { error: r.error }
    return this.finishAgentEdit(baseRev, {})
  },

  // Apply ONE property set to the WASM model and return `{ ok: true }` or
  // `{ error }`. Mutate-only — no render / revision bump (the caller finishes
  // once), so a batch of sets renders a single time.
  applySetOne(ref, props) {
    const parsed = this.parseRef(ref)
    if (!parsed) return { error: "set requires a ref {section,paragraph,offset[,cell]} (from doc.find)" }
    if (props == null || typeof props !== "object") return { error: "set requires a 'props' object" }

    const { kind: rawKind, ...rest } = props
    if (Object.keys(rest).length === 0) return { error: "set requires at least one property in 'props'" }
    const propJson = JSON.stringify(rest)
    // Default the kind from the ref (a cell ref -> cell properties, e.g. a yellow
    // BackgroundColor), mirroring the server resolver; pass kind:"char" to format a
    // run that lives inside a cell instead of filling the cell.
    const kind = rawKind || (parsed.cell ? "cell" : "char")

    if (kind === "cell") {
      const cl = parsed.cell
      if (!cl) return { error: "set kind:cell needs a cell ref (doc.find a cell, then set its BackgroundColor)" }
      try {
        this.doc.setCellProperties(parsed.section, cl.parentParaIndex, cl.controlIndex, cl.cellIndex, propJson)
      } catch (error) {
        return { error: `setCellProperties failed: ${String((error && error.message) || error)}` }
      }
      this.recordOp("AgentSetCell", { section: parsed.section, cell: cl, props: rest })
      return { ok: true }
    }

    if (kind === "char") {
      const start = Number.isInteger(parsed.offset) ? parsed.offset : 0
      const span = Number(parsed.length ?? parsed.len ?? 0)
      const end = start + (Number.isFinite(span) && span > 0 ? span : 0)
      const cl = parsed.cell
      try {
        if (cl) {
          this.doc.applyCharFormatInCell(
            parsed.section, cl.parentParaIndex, cl.controlIndex, cl.cellIndex, cl.cellParaIndex, start, end, propJson
          )
        } else {
          this.doc.applyCharFormat(parsed.section, parsed.paragraph, start, end, propJson)
        }
      } catch (error) {
        return { error: `applyCharFormat failed: ${String((error && error.message) || error)}` }
      }
      this.recordOp("AgentSetChar", { section: parsed.section, para: parsed.paragraph, cell: cl, start, end, props: rest })
      return { ok: true }
    }

    return { error: `set: unsupported kind '${kind}' in the browser editor (supported: cell, char)` }
  },

  // Batch property set (doc_set {sets:[{ref,props}, ...]}). Apply every set to
  // the WASM model with ONE re-render/revision bump at the end. Best-effort: a
  // bad ref does NOT abort the rest; the result carries a per-set `results`
  // array. Sets address fixed cells/runs and never move another set's target, so
  // order is irrelevant (applied in the given order).
  applyAgentSetBatch({ sets, base_revision }) {
    const baseRev = typeof base_revision === "number" ? base_revision : 0
    const list = Array.isArray(sets) ? sets : []
    if (list.length === 0) return { error: "set batch requires a non-empty 'sets' array" }

    const results = []
    let applied = 0
    let failed = 0
    for (const entry of list) {
      const ref = entry && entry.ref
      const refStr = ref != null ? (typeof ref === "string" ? ref : JSON.stringify(ref)) : null
      let r
      try {
        r = this.applySetOne(ref, entry && entry.props)
      } catch (error) {
        r = { error: String((error && error.message) || error) }
      }
      if (r && r.ok) {
        applied++
        results.push({ ref: refStr, ok: true })
      } else {
        failed++
        results.push({ ref: refStr, error: (r && r.error) || "unknown_error" })
      }
    }

    const finished = this.finishAgentEdit(baseRev, {})
    return {
      ok: true,
      result: { ok: true, revision: finished.result.revision, applied, failed, results }
    }
  },

  // A ref is the positional index doc.find returns (a JSON string
  // {section,paragraph,offset}); accept the parsed object too. null when absent.
  parseRef(ref) {
    if (ref == null) return null
    let r = ref
    if (typeof ref === "string") {
      try { r = JSON.parse(ref) } catch (_) { return null }
    }
    if (typeof r !== "object") return null
    const section = Number(r.section ?? r.sectionIndex ?? 0)
    const paragraph = Number(r.paragraph ?? r.paragraphIndex)
    if (!Number.isInteger(paragraph)) return null
    const offset = Number(r.offset ?? r.charOffset ?? 0)
    const out = { section: Number.isInteger(section) ? section : 0, paragraph, offset: Number.isInteger(offset) ? offset : 0 }
    // Table-cell address (from doc.find's cellContext). Accept both the bridge
    // shape ({parentParaIndex,controlIndex,cellIndex,cellParaIndex}) and the raw
    // rhwp shape ({parentPara,ctrlIdx,cellIdx,cellPara}).
    const cell = r.cell
    if (cell && typeof cell === "object") {
      const ppi = Number(cell.parentParaIndex ?? cell.parentPara)
      if (Number.isInteger(ppi)) {
        out.cell = {
          parentParaIndex: ppi,
          controlIndex: Number(cell.controlIndex ?? cell.ctrlIdx ?? 0),
          cellIndex: Number(cell.cellIndex ?? cell.cellIdx ?? 0),
          cellParaIndex: Number(cell.cellParaIndex ?? cell.cellPara ?? 0)
        }
      }
    }
    return out
  },

  // Shared post-edit step: re-render the visible window (an edit can reflow any
  // page), redraw the caret, and persist the edited bytes so it survives reload.
  finishAgentEdit(baseRev, extra) {
    this._elementsCache = null // the document changed; the cached element list is stale
    this.rendered.clear()
    this.renderVisiblePages()
    if (this.caret) this.drawCaret(this.caret)
    this.scheduleSnapshot()
    return { ok: true, result: { ok: true, revision: baseRev + 1, ...extra } }
  },

  // Best-effort match count from replaceAll's JSON return (shape varies across
  // rhwp builds: {replaced}/{count}/{matches}); default to 1 when it applied.
  replacedCount(raw) {
    if (raw == null) return 1
    try {
      const j = typeof raw === "string" ? JSON.parse(raw) : raw
      if (typeof j === "number") return j
      const n = j.replaced ?? j.count ?? j.matches ?? j.replacedCount
      return typeof n === "number" ? n : 1
    } catch (_) {
      const n = Number(raw)
      return Number.isFinite(n) ? n : 1
    }
  },

  // Literal search over the viewed model -> [{ref, text}] (ref carries the
  // section/paragraph/offset so the agent can target a replace).
  //
  // `all` (or `regex`) flips to discovery mode: enumerate EVERY addressable
  // element — body paragraphs AND table cells (empty ones included, which the
  // literal searchAllText can never surface) — and filter by `pattern` as a
  // regex. This is what lets the agent see the blank boxes in a form template.
  applyAgentFind({ pattern, case_sensitive, all, regex, type }) {
    if (all || regex || type) return this.applyAgentFindAll(pattern, !!case_sensitive, type)
    const matches = []
    try {
      const raw = this.doc.searchAllText(String(pattern || ""), !!case_sensitive, true)
      const parsed = raw ? JSON.parse(raw) : []
      const list = Array.isArray(parsed) ? parsed : parsed.matches || []
      for (const m of list) {
        // searchAllText (rhwp_core) returns {sec,para,charOffset,length,cellContext?}
        // — NOT {section,paragraph,offset}. Read the real field names, else every
        // ref collapses to {section:0,paragraph:0} and the agent can never target a
        // specific paragraph (and table cells become unreachable entirely).
        const refObj = {
          section: m.sec ?? m.section ?? m.sectionIndex ?? 0,
          paragraph: m.para ?? m.paragraph ?? m.paragraphIndex ?? 0,
          offset: m.charOffset ?? m.offset ?? 0
        }
        // A match inside a table cell carries cellContext {parentPara,ctrlIdx,
        // cellIdx,cellPara}. Surface it as `cell` so a follow-up replace/insert can
        // route to the cell primitives instead of the body paragraph.
        const cc = m.cellContext
        if (cc && cc.parentPara != null) {
          refObj.cell = {
            parentParaIndex: cc.parentPara,
            controlIndex: cc.ctrlIdx ?? 0,
            cellIndex: cc.cellIdx ?? 0,
            cellParaIndex: cc.cellPara ?? 0
          }
        }
        matches.push({ ref: JSON.stringify(refObj), text: m.text ?? pattern })
      }
    } catch (error) {
      console.error("[wasm-hwp] searchAllText failed", error)
    }
    return { pattern, matches }
  },

  // Discovery search: enumerate every element (collectElements) and keep those
  // whose text matches `pattern` as a regex. An empty/missing pattern becomes
  // [\s\S]* so {all:true} lists the WHOLE structure, including empty cells.
  applyAgentFindAll(pattern, caseSensitive, type) {
    const src = pattern == null || pattern === "" ? "[\\s\\S]*" : String(pattern)
    let re
    try {
      re = new RegExp(src, caseSensitive ? "" : "i")
    } catch (error) {
      return { pattern, error: String(error && error.message ? error.message : error), matches: [] }
    }
    // Optional element-TYPE filter so the agent can pull just the slice it needs
    // (e.g. {type:"empty_cell"} = the blank table cells to fill) instead of the
    // whole structure.
    const t = String(type || "").toLowerCase()
    const typeOk = (el) => {
      const isCell = !!(el.ref && el.ref.cell)
      const isEmpty = !el.text || el.text.trim() === ""
      // A REAL form field self-describes: it has a column header and/or a row
      // label (collectElements stashes that in `el.context`). A blank cell with
      // NO context is structural/merged noise (a spacer/merged span), not a field
      // to fill — exclude it from `empty_cell` so the agent only gets genuine
      // blanks. `cell`/`all` still include it.
      const isFormField = !!el.context
      // Engine enumeration tags every node with its IR kind; the positional-probe
      // fallback has none, so derive cell/paragraph from the ref.
      const kind = el.type || (isCell ? "cell" : "paragraph")
      switch (t) {
        case "cell": return isCell
        case "empty_cell": case "blank_cell": return isCell && isEmpty && isFormField
        case "filled_cell": return isCell && !isEmpty
        case "paragraph": return kind === "paragraph"
        case "empty": case "blank": return isEmpty
        // Any IR kind: field, form, picture, shape, table, equation, header, …
        default: return kind === t
      }
    }
    const MATCH_CAP = 2000
    const matches = []
    let truncated = false
    for (const el of this.collectElements()) {
      // Stateless test: no global flag, so lastIndex never advances between calls.
      if (typeOk(el) && re.test(el.text)) {
        if (matches.length >= MATCH_CAP) { truncated = true; break }
        const m = { ref: JSON.stringify(el.ref), text: el.text, table_cell: !!(el.ref && el.ref.cell) }
        if (el.type) m.type = el.type
        // For a cell, surface what it IS (column header / row label) so a blank is
        // self-describing and the agent fills it without reading the table.
        if (el.context) m.context = el.context
        if (el.row != null) m.row = el.row
        if (el.col != null) m.col = el.col
        matches.push(m)
      }
    }
    const out = { pattern, matches }
    if (truncated) out.truncated = true
    return out
  },

  // Enumerate EVERY addressable element of the viewed model -> [{ref, text}]:
  // every body paragraph plus every table cell (empty cells included). Empty
  // cells are invisible to searchAllText/collectParagraphs but are real edit
  // targets, so this is what powers {all:true} template discovery.
  //
  // Tables are anchored at a body paragraph (s,p); we probe controls c and cells
  // i positionally via getCellParagraphLength, which THROWS once we walk past the
  // last control/cell — that throw is the loop bound. If c===0&&i===0 throws there
  // is no table at (s,p), so we stop probing this paragraph entirely (cheap).
  collectElements() {
    if (this._elementsCache) return this._elementsCache
    let out = null
    try { out = this.collectElementsViaEngine() } catch (e) {
      console.warn("[wasm-hwp] enumerateElements failed; falling back to probe", e)
      out = null
    }
    if (!out || out.length === 0) out = this.collectElementsProbe()
    this._elementsCache = out
    return out
  },

  // Engine-native enumeration: the rhwp_core `enumerateElements()` WASM export
  // walks the FULL IR (every Control kind — table/picture/shape/equation/field/
  // form/header/footer/… plus paragraph/cell) and returns typed nodes. We attach
  // per-cell `context` ("<table title> › <column header> / <row label>") so a
  // blank cell self-describes, and skip pure-layout controls that aren't agent
  // targets. Returns null when the export is absent (older wasm) so collectElements
  // can fall back to the positional probe.
  collectElementsViaEngine() {
    if (!this.doc || typeof this.doc.enumerateElements !== "function") return null
    let raw
    try { raw = JSON.parse(this.doc.enumerateElements() || "[]") } catch (_) { return null }
    if (!Array.isArray(raw) || raw.length === 0) return null

    const SKIP = new Set([
      "section_def", "column_def", "page_number_pos",
      "auto_number", "new_number", "char_overlap", "page_hide"
    ])
    // Pass 1: per-table grid (row,col)->text + the nearest preceding heading.
    const grids = {}
    let lastHeading = ""
    for (const el of raw) {
      const isCell = !!(el.ref && el.ref.cell)
      if (el.type === "paragraph" && !isCell) {
        const t = (el.text || "").trim()
        if (t) lastHeading = t
      } else if (el.type === "cell" && isCell && el.row != null && el.col != null) {
        const key = el.ref.cell.parentParaIndex + ":" + el.ref.cell.controlIndex
        if (!grids[key]) grids[key] = { byRC: {}, caption: lastHeading }
        grids[key].byRC[el.row + "," + el.col] = el.text || ""
      }
    }
    // Pass 2: emit, attaching cell context.
    const out = []
    for (const el of raw) {
      if (SKIP.has(el.type)) continue
      const isCell = !!(el.ref && el.ref.cell)
      const o = { ref: el.ref, text: el.text || "", type: el.type }
      if (isCell && el.row != null && el.col != null) {
        o.row = el.row
        o.col = el.col
        const g = grids[el.ref.cell.parentParaIndex + ":" + el.ref.cell.controlIndex]
        if (g) {
          const header = el.row > 0 ? g.byRC["0," + el.col] || "" : ""
          const rowLabel = el.col > 0 ? g.byRC[el.row + ",0"] || "" : ""
          const hr = [header, rowLabel].map((x) => (x || "").trim()).filter(Boolean).join(" / ")
          const parts = []
          if (g.caption) parts.push(g.caption)
          if (hr) parts.push(hr)
          if (parts.length) o.context = parts.join(" › ")
        }
      }
      out.push(o)
    }
    return out
  },

  // Fallback positional probe (paragraphs + table cells only) for builds whose
  // wasm predates enumerateElements.
  collectElementsProbe() {
    const ELEM_CAP = 5000
    const out = []
    let sectionCount = 1
    try { sectionCount = this.doc.getSectionCount() } catch (_) {}
    for (let s = 0; s < sectionCount; s++) {
      let paraCount = 0
      try { paraCount = this.doc.getParagraphCount(s) } catch (_) { paraCount = 0 }
      for (let p = 0; p < paraCount; p++) {
        if (out.length >= ELEM_CAP) break
        let len = 0
        try { len = this.doc.getParagraphLength(s, p) } catch (_) { len = 0 }
        let text = ""
        try { text = this.doc.getTextRange(s, p, 0, len) || "" } catch (_) { text = "" }
        out.push({ ref: { section: s, paragraph: p, offset: 0 }, text })

        // Tables anchored at this paragraph. getTableDimensions bounds the cell
        // loop (cellCount) and returns null when there is no table at (s,p,c). For
        // each cell capture its (row,col) via getCellInfo, then attach the column
        // header (row 0, same col) and row label (col 0, same row) so a BLANK cell
        // self-describes ("지급금액 / 선급금") and the agent can fill it without
        // having to read the whole table for context.
        for (let c = 0; c < 8; c++) {
          let dims = null
          try { dims = JSON.parse(this.doc.getTableDimensions(s, p, c)) } catch (_) { dims = null }
          if (!dims || !(Number(dims.cellCount) > 0)) break
          const cellCount = Math.min(Number(dims.cellCount), 512)
          const cells = []
          const byRC = {}
          for (let i = 0; i < cellCount; i++) {
            let ctext = ""
            try {
              const clen = this.doc.getCellParagraphLength(s, p, c, i, 0)
              ctext = this.doc.getTextInCell(s, p, c, i, 0, 0, clen) || ""
            } catch (_) { ctext = "" }
            let row = null, col = null
            try { const ci = JSON.parse(this.doc.getCellInfo(s, p, c, i)); row = ci.row; col = ci.col } catch (_) {}
            cells.push({ i, text: ctext, row, col })
            if (row != null && col != null) byRC[row + "," + col] = ctext
          }
          for (const cell of cells) {
            if (out.length >= ELEM_CAP) break
            const el = {
              ref: {
                section: s,
                paragraph: p,
                offset: 0,
                cell: { parentParaIndex: p, controlIndex: c, cellIndex: cell.i, cellParaIndex: 0 }
              },
              text: cell.text
            }
            if (cell.row != null && cell.col != null) {
              el.row = cell.row
              el.col = cell.col
              const header = cell.row > 0 ? byRC["0," + cell.col] || "" : ""
              const rowLabel = cell.col > 0 ? byRC[cell.row + ",0"] || "" : ""
              const ctx = [header, rowLabel].map((x) => (x || "").trim()).filter(Boolean).join(" / ")
              if (ctx) el.context = ctx
            }
            out.push(el)
          }
        }
        if (out.length >= ELEM_CAP) break
      }
    }
    this._elementsCache = out
    return out
  },

  // Page through the document text from the viewed model. Mirrors the server
  // doc.read shape ({text, at, size, total, next_at}) so the agent pages the
  // same way regardless of backing.
  applyAgentRead({ opts }) {
    const o = opts || {}
    const at = Math.max(0, Number(o.at || 0))
    const size = Math.min(30, Math.max(1, Number(o.size || 30)))
    // Read the FULL element list (body paragraphs AND table cells, empty cells
    // included) — collectParagraphs() walks only body paragraphs, so TABLES were
    // invisible in doc.read and the agent skipped them entirely. Each element
    // carries its `ref` so the agent can fill a cell straight from the read,
    // and a `table_cell` flag + `[cell]` text prefix so blanks are obvious.
    const elements = this.collectElements()
    const total = elements.length
    const window = elements.slice(at, at + size)
    const nextAt = at + window.length < total ? at + window.length : null
    const paragraphs = window.map((el) => {
      const o = { text: el.text, ref: JSON.stringify(el.ref), table_cell: !!(el.ref && el.ref.cell) }
      if (el.type) o.type = el.type
      if (el.context) o.context = el.context
      return o
    })
    return {
      text: window.map((el) => (el.ref && el.ref.cell ? `[cell] ${el.text}` : el.text)).join("\n"),
      at,
      size: window.length,
      paragraphs,
      total,
      next_at: nextAt
    }
  },

  // Flatten body paragraph text across sections via the WASM accessors.
  collectParagraphs() {
    const out = []
    let sectionCount = 1
    try { sectionCount = this.doc.getSectionCount() } catch (_) {}
    for (let s = 0; s < sectionCount; s++) {
      let paraCount = 0
      try { paraCount = this.doc.getParagraphCount(s) } catch (_) { paraCount = 0 }
      for (let p = 0; p < paraCount; p++) {
        let len = 0
        try { len = this.doc.getParagraphLength(s, p) } catch (_) { len = 0 }
        let text = ""
        try { text = this.doc.getTextRange(s, p, 0, len) || "" } catch (_) { text = "" }
        out.push(text)
      }
    }
    return out
  },

  // ─── Op-log + snapshot persistence ───────────────────────────────────────

  // Push a single edit op to the server's op-log so edits are recoverable even
  // before the next byte snapshot lands. Body mirrors the rhwp DocumentEvent
  // shape the server's `rhwp.text.mutated` handler expects.
  recordOp(type, fields) {
    if (!this.documentId) return
    this.lamport += 1
    const eventId = `${this.documentId}:${Date.now()}:${this.lamport}`
    const body = { type, ...fields }
    if (this.caret && this.caret.cell) {
      body.parentParaIndex = this.caret.cell.parentParaIndex
      body.controlIndex = this.caret.cell.controlIndex
      body.cellPath = this.caret.cell.cellPath
    }
    this.pushEvent("rhwp.text.mutated", {
      documentId: this.documentId,
      document_id: this.documentId,
      siteId: window.__rhwpSiteId || "local",
      lamport: this.lamport,
      eventId,
      body
    })
  },

  // Debounced full-document snapshot: serialize the edited doc to its native
  // format and push the bytes so a browser close doesn't lose work. The engine
  // exposes exportHwp/exportHwpx, so this is a real save (not just an op-log).
  scheduleSnapshot() {
    if (this.snapshotTimer) clearTimeout(this.snapshotTimer)
    this.snapshotTimer = setTimeout(() => {
      this.snapshotTimer = null
      this.pushSnapshot()
    }, SNAPSHOT_IDLE_MS)
  },

  // Export the open doc's current edited bytes for doc.save (the server writes
  // them to disk). Same serializer as the snapshot, but returned synchronously
  // to the doc.save round-trip rather than pushed as a checkpoint.
  exportForSave() {
    const bytes = this.format === "hwpx" ? this.doc.exportHwpx() : this.doc.exportHwp()
    return { format: this.format, bytes_base64: this.bytesToBase64(bytes), bytes: bytes.length }
  },

  pushSnapshot() {
    if (!this.doc || !this.documentId) return
    let bytes
    try {
      bytes = this.format === "hwpx" ? this.doc.exportHwpx() : this.doc.exportHwp()
    } catch (error) {
      console.error("[wasm-hwp] export failed", error)
      return
    }
    const requestId = `${this.documentId}:snap:${++this.snapshotSeq}`
    this.pushEvent("rhwp.local.snapshot.checkpoint", {
      document_id: this.documentId,
      request_id: requestId,
      format: this.format,
      bytes_base64: this.bytesToBase64(bytes)
    })
  },

  bytesToBase64(bytes) {
    let binary = ""
    const chunk = 0x8000
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk))
    }
    return btoa(binary)
  },
}

export { WasmHwpEditor }
