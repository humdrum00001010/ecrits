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
