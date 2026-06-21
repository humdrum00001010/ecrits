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
// `HwpDocument` class. The generated ES module is served directly from the
// dependency-owned `/assets/rhwp/rhwp.js` path so its `import.meta.url` fallback
// remains a real module URL instead of being rewritten by esbuild's IIFE bundle.
import { appendPickedElementToComposer, bindElementPickerTarget } from "./document_element_picker.js"
import { OPS } from "./wasm_ops.ts"
// Keyboard / IME / text-input hook methods, split into their own file. Spread
// into the hook below so `this` is the editor instance (same pattern as OPS).
import { keyboardSubsystem } from "./wasm_hwp_keys.ts"

const WASM_URL = "/assets/rhwp/rhwp_bg.wasm"
const RHWP_JS_URL = "/assets/rhwp/rhwp.js"
const LOCAL_EDITOR_COMMAND_EVENT = "ecrits:local-editor-command"

// How long the doc must stay idle (no edits) before we export+snapshot bytes
// to the server. Each edit is instant locally; persistence is debounced so we
// don't serialize the whole document on every keystroke.
const SNAPSHOT_IDLE_MS = 1500

// Module-level singleton: `init()` instantiates the wasm module ONCE per page
// load (every hook instance shares the same wasm memory + HwpDocument class).
let wasmReady = null
let HwpDocument = null
function ensureWasm() {
  if (!wasmReady) {
    wasmReady = import(RHWP_JS_URL).then((module) => {
      HwpDocument = module.HwpDocument
      return module.default(WASM_URL).then(() => {
        window.__rhwpWasmReady = true
        return true
      })
    })
  }
  return wasmReady
}

// ── Char-property translation (spec + cast) ────────────────────────────────
// The WASM engine reads camelCase/lowercase keys (bold, italic, underline,
// strikethrough, fontSize, textColor, fontFamily); agents send HWP PascalCase
// (Bold, FontSize…) or Office UNO names (CharWeight:150, CharHeight…). Each
// source key maps to `[engineKey, valueType]` — pure DATA. `castCharProp`
// applies the value transform by type; a key with no spec passes through
// (already an engine key, or unknown). Mirrors rhwp.ex @char_prop_spec +
// translate/cast so every arm shares one vocabulary. Adding an alias is one row.
const CHAR_PROP_SPEC = {
  // Office UNO → engine
  CharWeight:    ["bold", "weightThreshold"],
  FontWeight:    ["bold", "fontWeight"],
  CharPosture:   ["italic", "positive"],
  CharUnderline: ["underline", "positive"],
  CharColor:     ["textColor", "verbatim"],
  CharHeight:    ["fontSize", "fontSize"],
  // HWP PascalCase → engine
  Bold:          ["bold", "bool"],
  Italic:        ["italic", "bool"],
  Underline:     ["underline", "bool"],
  Strikethrough: ["strikethrough", "bool"],
  TextColor:     ["textColor", "verbatim"],
  FontSize:      ["fontSize", "fontSize"],
  fontSize:      ["fontSize", "fontSize"],
  FontFamily:    ["fontFamily", "verbatim"],
}

const castCharProp = (type, v) => {
  switch (type) {
    case "bool":            return !!v
    case "weightThreshold": return Number(v) >= 150
    case "fontWeight":      return v === "bold" || Number(v) >= 600
    case "positive":        return Number(v) > 0
    case "verbatim":        return v
    // fontSize is 1/100 pt (10pt = 1000); a point-scale value (<=200) means
    // POINTS → x100, else it's already 1/100pt. Mirrors rhwp.ex font_size_hu.
    case "fontSize": {
      const n = Number(v)
      return n <= 0 ? 1000 : n <= 200 ? Math.round(n * 100) : Math.round(n)
    }
    default: return v
  }
}

// The single eval: translate a prop bag through CHAR_PROP_SPEC.
const translateCharProps = (props) => {
  const out = {}
  for (const [k, v] of Object.entries(props)) {
    const spec = CHAR_PROP_SPEC[k]
    if (spec) out[spec[0]] = castCharProp(spec[1], v)
    else out[k] = v
  }
  return out
}

// ── Op handler registry ──────────────────────────────────────────────────────
// The doc-edit verbs live in a typed, CHAINED registry — `OPS` in
// assets/js/wasm_ops.ts (each verb a standalone `(ctx, op, ref, verb) => …`
// handler). `applyOneOp` dispatches through it. Register a new op — or override a
// built-in — with `WasmHwpEditor.define(verb, handler)`:
//
//     WasmHwpEditor.define("highlight", (editor, op, ref) => {
//       editor.doc.setCellProperties(...)        // editor = the ctx (hook instance)
//       return { ok: true, extra: {} }
//     })
//
// A handler is `(editor, op, ref, verb) => { ok, extra } | { error }`.

const WasmHwpEditor = {
  // Keyboard / IME / text-input methods (bindEditing, handleKeyDown, composition
  // input, delete/merge/split at caret, Ctrl+S) live in wasm_hwp_keys.ts and are
  // mixed in here — they run as hook methods with `this` = this editor instance.
  ...keyboardSubsystem,

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
    // Live image gesture (press on a picture): click = select, drag = move.
    this.imageDrag = null
    // Live drag-select gesture (only set while the mouse button is held).
    //   dragSelect = { pageIndex, section, cell, anchor: {paragraph, offset},
    //                  moved }   // moved=true once the pointer actually dragged
    this.dragSelect = null
    // Lamport-ish monotonic counter for op-log event ids (recovery stream).
    this.lamport = 0
    // Korean IME provisional composition region currently live in the document.
    //   composing = { start, length }  (in the caret's paragraph/cell)
    this.composing = null
    this.skipNextCompositionInput = null
    this.snapshotTimer = null
    this.snapshotSeq = 0
    this.undoStack = []
    this.redoStack = []
    this.caretBlinkOn = true
    this.elementPickerEnabled = false
    this.pickerHover = null
    this.pickerHoverEvent = null
    this.pickerHoverRaf = null
    this.agentOpQueue = []
    this.agentOpProcessing = false

    this.imeProxy = this.el.querySelector("[data-role='local-hwp-ime-proxy']")
    this.pageStack = this.el.querySelector("[data-role='local-hwp-pages']")

    this.documentId = this.el.dataset.documentId || this.el.dataset.localDocumentId
    this.format = this.el.dataset.localDocumentFormat || "hwp"

    // Pre-warm the wasm module so the first `hwp_wasm_load` doesn't pay the
    // instantiation cost on the critical path.
    ensureWasm().catch(error => console.error("[wasm-hwp] init failed", error))

    // Server pushes this when an HWP/HWPX document opens: fetch its raw bytes
    // and hand them to the WASM engine.
    this.handleEvent("hwp_wasm_load", payload => this.loadDocument(payload))

    // Agent edit/read/find routed from the server because THIS document is
    // `:browser`-backed in the Doc Pool (the WASM model here is its authority).
    // Apply against the same WASM doc the user is viewing, re-render, and reply
    // with the result so the agent's doc.* tool returns it.
    this.handleEvent("doc.apply_edit", payload => this.handleAgentOp(payload))
    this.handleEvent("local_document.save.request", payload => this.saveLocalDocument(payload))

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
    this.onDoubleClick = event => this.onCanvasDoubleClick(event)
    this.onToolbarCommand = event => this.handleToolbarCommand(event.detail || {})
    this.el.addEventListener("mousedown", this.onMouseDown)
    this.el.addEventListener("dblclick", this.onDoubleClick)
    document.addEventListener("mousemove", this.onMouseMove)
    document.addEventListener("mouseup", this.onMouseUp)
    document.addEventListener(LOCAL_EDITOR_COMMAND_EVENT, this.onToolbarCommand)

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
    this.unbindElementPicker = bindElementPickerTarget(this)
  },

  destroyed() {
    if (this.io) this.io.disconnect()
    if (this.blink) clearInterval(this.blink)
    // Flush-before-detach: a doc switch destroys this hook (the editor element
    // id is per-document), and authority falls back to the server NIF twin.
    // A pending debounced snapshot here means the twin (and the snapshot
    // store) would MISS the latest edits — exports done after this point can
    // silently clobber them (observed: agent footnote edits lost to a tab
    // switch). Export+push the final checkpoint NOW, while the wasm doc is
    // still alive; the server accepts checkpoints for non-active documents.
    if (this.snapshotTimer) {
      clearTimeout(this.snapshotTimer)
      this.snapshotTimer = null
      try { this.pushSnapshot() } catch (_) { /* socket gone — nothing to flush to */ }
    }
    if (this.pickerHoverRaf) cancelAnimationFrame(this.pickerHoverRaf)
    window.removeEventListener("resize", this.onResize)
    this.el.removeEventListener("mousedown", this.onMouseDown)
    this.el.removeEventListener("dblclick", this.onDoubleClick)
    document.removeEventListener("mousemove", this.onMouseMove)
    document.removeEventListener("mouseup", this.onMouseUp)
    document.removeEventListener(LOCAL_EDITOR_COMMAND_EVENT, this.onToolbarCommand)
    if (this.unbindElementPicker) this.unbindElementPicker()
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
        // In-place document switch: flush the OLD doc's pending snapshot
        // before discarding its model (same flush-before-detach as destroyed()).
        if (this.snapshotTimer) {
          clearTimeout(this.snapshotTimer)
          this.snapshotTimer = null
          try { this.pushSnapshot() } catch (_) {}
        }
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
      this.selection = null
      this.composing = null
      this.undoStack = []
      this.redoStack = []
      window.__rhwpDoc = this.doc

      this.buildPageStack()
      this.renderVisiblePages()
      // The browser becomes this doc's authority only now that the model is
      // actually loaded — the LiveView attaches the Session viewer on this
      // event (a tab whose editor failed to load must NOT capture doc.* routing).
      this.notifyViewerState(true)
    } catch (error) {
      console.error("[wasm-hwp] load failed", error)
      this.notifyViewerState(false)
    }
  },

  notifyViewerState(ready) {
    const id = this.documentId
    if (!id) return
    try {
      this.pushEvent(
        ready ? "local_document.viewer_ready" : "local_document.viewer_failed",
        { document_id: id }
      )
    } catch (_) { /* disconnected socket — nothing to claim */ }
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

    if (this.elementPickerEnabled) {
      event.preventDefault()
      event.stopPropagation()
      const pick = this.hwpPickFromHit(hit, pageIndex)
      // Toggle into the multi-select set; bindElementPickerTarget's picks
      // listener repaints every highlight (incl. removal).
      appendPickedElementToComposer(pick)
      return
    }

    // A press on the corner HANDLE of a selected picture resizes (scales) it.
    const handle = this.pictureResizeHandleAtHit(hit)
    if (handle) {
      event.preventDefault()
      this.beginImageResize(handle, hit, pageIndex)
      return
    }

    // A press on a picture arms an image gesture: release WITHOUT moving →
    // SELECT it (pick), release AFTER dragging → MOVE it. (See begin/end
    // ImageDrag.) The engine resolves what's under the point — no TS hit-test.
    const pressPick = this.hwpPick(hit, pageIndex)
    if (pressPick && /image|picture/i.test(pressPick.type || "")) {
      event.preventDefault()
      this.beginImageDrag(
        {
          section: pressPick.ref.section,
          paragraph: pressPick.ref.paragraph,
          controlIndex: pressPick.controlIndex,
          type: pressPick.type,
          bbox: (pressPick.rects || [])[0]
        },
        hit,
        pageIndex
      )
      return
    }

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
  // the selection from the drag anchor to the current (focus) offset. In picker
  // mode (no drag) it instead tracks a DOM-inspector-style hover preview of the
  // element under the cursor.
  onCanvasMouseMove(event) {
    if (!this.doc) return
    if (this.imageDrag) {
      if ((event.buttons & 1) === 0) { this.onCanvasMouseUp(event); return }
      this.updateImageDrag(event)
      return
    }
    if (!this.dragSelect) {
      if (this.elementPickerEnabled) this.queuePickerHover(event)
      return
    }
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
    if (this.imageDrag) {
      this.endImageDrag()
      return
    }
    if (!this.dragSelect) return
    const ds = this.dragSelect
    this.dragSelect = null
    if (!ds.moved) {
      // Plain click — no drag — so leave just the caret (no selection).
      this.clearSelection()
      this.renderSelection()
      if (this.caret) this.drawCaret(this.caret)
    }
    // A moved drag already established `this.selection` during mousemove; the
    // text highlight stays until the next press. Picks persist after picker
    // mode ends, and the drag's overlay clears wiped them on OTHER pages
    // (drawCaret only restores the caret's page) — repaint the full set.
    if (this.currentDocumentPicks().length > 0) this.paintPickedHighlights()
  },

  onCanvasDoubleClick(event) {
    if (!this.doc) return
    const hitInfo = this.hitTestEvent(event)
    if (!hitInfo) return
    const { hit, pageIndex } = hitInfo
    event.preventDefault()
    event.stopPropagation()

    this.dragSelect = null
    this.clearSelection()
    this.renderSelection()
    this.setCaretFromHit(hit, pageIndex)

    if (this.imeProxy) {
      this.imeProxy.focus({ preventScroll: true })
      this.anchorProxy()
    }
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
      // Carry the doc-space click point on the hit so inline-control picking can
      // do an exact page-bbox containment test — the engine hit itself only
      // reports a char offset, not where in the page the pointer landed.
      const hit = JSON.parse(raw)
      hit.x = x
      hit.y = y
      return { hit, pageIndex }
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

  selectedText() {
    if (!this.hasSelection() || !this.doc) return ""
    const sel = this.selection
    const [start, end] = this.orderedSelection(sel)
    const chunks = []
    for (let paragraph = start.paragraph; paragraph <= end.paragraph; paragraph++) {
      const startOffset = paragraph === start.paragraph ? start.offset : 0
      const endOffset = paragraph === end.paragraph
        ? end.offset
        : this.hwpToolbarParagraphLength(sel.section, paragraph, sel.cell)
      if (endOffset < startOffset) continue
      try {
        if (sel.cell) {
          const ref = this.hwpToolbarRef(sel.section, paragraph, 0, sel.cell)
          chunks.push(this.getTextInCellRef(ref, ref.cell, paragraph, startOffset, endOffset - startOffset) || "")
        } else {
          chunks.push(this.doc.getTextRange(sel.section, paragraph, startOffset, endOffset - startOffset) || "")
        }
      } catch (_) {
        chunks.push("")
      }
    }
    return chunks.join("\n")
  },

  cloneEditorPoint(point) {
    return point ? JSON.parse(JSON.stringify(point)) : null
  },

  captureHistorySnapshot() {
    if (!this.doc) return null
    try {
      const bytes = this.format === "hwpx" ? this.doc.exportHwpx() : this.doc.exportHwp()
      return {
        format: this.format,
        bytes: new Uint8Array(bytes),
        caret: this.cloneEditorPoint(this.caret),
        selection: this.cloneEditorPoint(this.selection),
        pageCount: this.pageCount
      }
    } catch (error) {
      console.error("[wasm-hwp] history snapshot failed", error)
      return null
    }
  },

  historyBytesEqual(a, b) {
    if (!a || !b || a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    return true
  },

  pushUndoCheckpoint() {
    const snapshot = this.captureHistorySnapshot()
    if (!snapshot) return false
    const last = this.undoStack && this.undoStack[this.undoStack.length - 1]
    if (last && this.historyBytesEqual(last.bytes, snapshot.bytes)) return false
    this.undoStack.push(snapshot)
    if (this.undoStack.length > 30) this.undoStack.shift()
    this.redoStack = []
    return true
  },

  restoreHistorySnapshot(snapshot) {
    if (!snapshot || !snapshot.bytes) return false
    try {
      const previous = this.doc
      this.doc = new HwpDocument(snapshot.bytes)
      try { this.doc.convertToEditable() } catch (_) {}
      if (previous) {
        try { previous.free() } catch (_) {}
      }
      this.format = snapshot.format || this.format
      this.pageCount = this.doc.pageCount()
      this.caret = this.cloneEditorPoint(snapshot.caret)
      this.selection = this.cloneEditorPoint(snapshot.selection)
      this.composing = null
      window.__rhwpDoc = this.doc
      this.buildPageStack()
      this.renderVisiblePages()
      this.clearSelectionOverlays()
      if (this.selection) this.renderSelection()
      if (this.caret) {
        this.refreshCursorRect()
        this.renderCaretPage()
        this.drawCaret(this.caret)
        this.anchorProxy()
      }
      this.scheduleSnapshot()
      return true
    } catch (error) {
      console.error("[wasm-hwp] history restore failed", error)
      return false
    }
  },

  undoHistory() {
    if (!this.undoStack || !this.undoStack.length) return false
    const redo = this.captureHistorySnapshot()
    const snapshot = this.undoStack.pop()
    if (!this.restoreHistorySnapshot(snapshot)) return false
    if (redo) this.redoStack.push(redo)
    return true
  },

  redoHistory() {
    if (!this.redoStack || !this.redoStack.length) return false
    const undo = this.captureHistorySnapshot()
    const snapshot = this.redoStack.pop()
    if (!this.restoreHistorySnapshot(snapshot)) return false
    if (undo) this.undoStack.push(undo)
    return true
  },

  handleToolbarCommand(detail) {
    if (!this.activeToolbarTarget() || !this.doc || !this.toolbarCommandMatchesDocument(detail)) return

    switch (detail.command) {
      case "bold":
        this.hwpToolbarToggleCharProp("Bold", "bold")
        break
      case "italic":
        this.hwpToolbarToggleCharProp("Italic", "italic")
        break
      case "image":
        this.hwpToolbarImage(detail)
        break
      default:
        break
    }
  },

  activeToolbarTarget() {
    return !!(this.el && this.el.isConnected && /^(hwp|hwpx)$/i.test(this.format || ""))
  },

  toolbarCommandMatchesDocument(detail) {
    const commandDocumentId = detail && (detail.document_id || detail.documentId)
    if (!commandDocumentId) return true
    return !!(this.documentId && String(commandDocumentId) === String(this.documentId))
  },

  hwpToolbarApplyProps(props) {
    const refs = this.hwpToolbarCharRefs()
    return this.hwpToolbarApplyPropsToRefs(refs, props)
  },

  hwpToolbarToggleCharProp(prop, engineKey) {
    const refs = this.hwpToolbarCharRefs()
    if (!refs.length) return

    const enabled = refs.every((ref) => this.hwpToolbarCharPropEnabled(ref, engineKey))
    this.hwpToolbarApplyPropsToRefs(refs, { [prop]: !enabled })
  },

  hwpToolbarApplyPropsToRefs(refs, props) {
    if (!refs.length) return

    let applied = 0
    for (const ref of refs) {
      const result = this.applySetOne(ref, { kind: "char", ...props })
      if (result && result.error) {
        console.warn("[wasm-hwp] toolbar format failed", result.error)
      } else {
        applied++
      }
    }
    if (applied > 0) this.finishAgentEdit({})
  },

  hwpToolbarCharPropEnabled(ref, engineKey) {
    const parsed = this.parseRef(ref)
    if (!parsed) return false

    const offset = this.hwpToolbarCharPropProbeOffset(parsed)
    try {
      let raw
      const cl = parsed.cell
      if (cl) {
        raw = this.doc.getCellCharPropertiesAt(
          parsed.section,
          cl.parentParaIndex,
          cl.controlIndex,
          cl.cellIndex,
          cl.cellParaIndex,
          offset
        )
      } else {
        raw = this.doc.getCharPropertiesAt(parsed.section, parsed.paragraph, offset)
      }
      const props = typeof raw === "string" ? JSON.parse(raw || "{}") : (raw || {})
      return props && props[engineKey] === true
    } catch (_) {
      return false
    }
  },

  hwpToolbarCharPropProbeOffset(parsed) {
    let offset = Number.isInteger(parsed.offset) ? parsed.offset : 0
    const span = Number(parsed.length ?? parsed.len ?? 0)
    if (!(Number.isFinite(span) && span > 0) && offset > 0) offset -= 1
    return Math.max(0, offset)
  },

  hwpToolbarImage(detail) {
    if (!detail || !detail.image_base64) return
    const ref = this.hwpToolbarCaretRef() || this.resolveEndRef("end")
    if (!ref) return

    const size = this.hwpToolbarImageSize(detail, 8504)
    const result = this.applyOneOp({
      op: "insert_picture",
      ref,
      image_base64: detail.image_base64,
      extension: detail.extension || "png",
      natural_width_px: detail.natural_width_px || 0,
      natural_height_px: detail.natural_height_px || 0,
      width: size.width,
      height: size.height,
      description: detail.file_name || "image"
    })

    if (result && result.error) {
      console.warn("[wasm-hwp] toolbar image failed", result.error)
      return
    }
    this.finishAgentEdit(result && result.extra ? result.extra : {})
  },

  hwpToolbarCharRefs() {
    if (this.hasSelection()) {
      const sel = this.selection
      const [start, end] = this.orderedSelection(sel)
      const refs = []

      for (let paragraph = start.paragraph; paragraph <= end.paragraph; paragraph++) {
        const startOffset = paragraph === start.paragraph ? start.offset : 0
        const endOffset = paragraph === end.paragraph
          ? end.offset
          : this.hwpToolbarParagraphLength(sel.section, paragraph, sel.cell)
        if (endOffset <= startOffset) continue

        const ref = this.hwpToolbarRef(sel.section, paragraph, startOffset, sel.cell)
        ref.length = endOffset - startOffset
        refs.push(ref)
      }

      if (refs.length) return refs
    }

    const caretRef = this.hwpToolbarCaretRef()
    return caretRef ? [caretRef] : this.hwpToolbarDefaultRefs()
  },

  hwpToolbarDefaultRefs() {
    if (!this.doc) return []

    let sections = 1
    try {
      if (typeof this.doc.sectionCount === "function") {
        sections = Math.max(1, Number(this.doc.sectionCount()) || 1)
      }
    } catch (_) {}

    for (let section = 0; section < sections; section++) {
      let paragraphs = 0
      try { paragraphs = this.doc.getParagraphCount(section) } catch (_) {}
      if (Number.isFinite(paragraphs) && paragraphs > 0) {
        return [this.hwpToolbarRef(section, 0, 0, null)]
      }
    }

    return []
  },

  hwpToolbarCaretRef() {
    const c = this.caret
    if (!c) return null
    return this.hwpToolbarRef(c.section, c.paragraph, c.offset, c.cell)
  },

  hwpToolbarRef(section, paragraph, offset, cell) {
    const ref = { section, paragraph, offset } as any
    if (cell) {
      ref.cell = {
        parentParaIndex: cell.parentParaIndex,
        controlIndex: cell.controlIndex,
        cellIndex: cell.cellIndex,
        cellParaIndex: paragraph
      }
      if (cell.cellPath) ref.cellPath = cell.cellPath
    }
    return ref
  },

  hwpToolbarParagraphLength(section, paragraph, cell) {
    if (cell) {
      const ref = this.hwpToolbarRef(section, paragraph, 0, cell)
      return this.cellParagraphLength(ref, ref.cell, paragraph)
    }
    return this.paragraphLength(section, paragraph)
  },

  hwpToolbarImageSize(detail, maxUnit) {
    const widthPx = Math.max(1, Number(detail.natural_width_px || 1))
    const heightPx = Math.max(1, Number(detail.natural_height_px || 1))
    const aspect = widthPx / heightPx

    if (aspect >= 1) {
      return {
        width: maxUnit,
        height: Math.max(1, Math.round(maxUnit / aspect))
      }
    }

    return {
      width: Math.max(1, Math.round(maxUnit * aspect)),
      height: maxUnit
    }
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
      // The native caret hit carries `note` when the click landed on a footnote
      // marker (engine resolved the caret INTO the note). The editor stores it
      // so the caret stays in the footnote on refresh + routes typing there —
      // it just consumes the engine's note caret, no front-end footnote logic.
      note: cell ? null : (hit.note || null),
      cursorRect,
      preferredX: -1
    }
    this.caretBlinkOn = true
    this.drawCaret(this.caret)
    this.anchorProxy()
  },

  // One engine call resolves the WHOLE hit: footnote-marker → containing control
  // → cell/paragraph, with engine-computed highlight rects (cell bbox, column-
  // banded line union). The editor does NOT hit-test — that lives in rhwp_core
  // (`pickAtPoint`). Returns the engine pick {type, ref, rects, footnoteNumber?,
  // controlIndex?}; the cell ref is reshaped to the nested {…,cell:{…}} grammar
  // the doc.* tools + text/element helpers consume. Null only if unresolvable.
  hwpPick(hit, pageIndex) {
    if (!this.doc || hit.x === undefined || hit.y === undefined) return null
    let pick
    try {
      pick = JSON.parse(this.doc.pickAtPoint(pageIndex, hit.x, hit.y))
    } catch (_) {
      return null
    }
    if (!pick) return null
    if (pick.type === "cell") {
      const r = pick.ref
      pick.ref = {
        section: r.section,
        paragraph: r.parentParaIndex,
        offset: 0,
        cell: {
          parentParaIndex: r.parentParaIndex,
          controlIndex: r.controlIndex,
          cellIndex: r.cellIndex,
          cellParaIndex: r.cellParaIndex,
          cellPath: r.cellPath || null
        }
      }
    }
    return pick
  },

  // The composer pick envelope. Hit resolution + rects are the engine's
  // (`hwpPick`); here we only attach document identity and the element TEXT (a
  // ref→text lookup, not hit-testing).
  hwpPickFromHit(hit, pageIndex) {
    const pick = this.hwpPick(hit, pageIndex)
    if (!pick) return null
    return {
      document: this.el.dataset.documentPath || "",
      backend: "hwp",
      format: this.format || "hwp",
      type: pick.type,
      ref: JSON.stringify(pick.ref),
      text: this.hwpTextForPick(pick),
      rects: pick.rects || [],
      ir: {
        page: pageIndex + 1,
        ref: pick.ref,
        hit,
        footnoteNumber: pick.footnoteNumber,
        controlIndex: pick.controlIndex
      }
    }
  },

  // ref→text for a resolved pick (NOT hit-testing): the note's first paragraph
  // for a footnote; the element text for a paragraph/cell; controls carry none.
  hwpTextForPick(pick) {
    if (pick.type === "footnote") {
      try {
        const info = JSON.parse(
          this.doc.getFootnoteInfo(pick.ref.section, pick.ref.paragraph, pick.ref.control) || "{}")
        if (Array.isArray(info.texts) && info.texts.length) return String(info.texts[0] || "").trim()
      } catch (_) {
        /* fall through */
      }
      return ""
    }
    if (pick.type === "paragraph" || pick.type === "cell") {
      const element = this.findHwpElement(pick.ref)
      return element ? element.text || "" : this.hwpTextForRef(pick.ref)
    }
    return ""
  },

  // ─── Image gesture: click = select, drag = move ──────────────────────────
  // Pressing a picture arms a gesture. If released without dragging it's a CLICK
  // → select (pick) the image. If dragged it's a MOVE → one Paper-anchored float
  // committed on release (a ghost box previews; per-mousemove engine calls would
  // corrupt the bin). SAFEGUARD: an image the engine can't render floats as an
  // opaque white box over the text (large bins, #51) — if the committed move
  // renders blank-white, revert to inline rather than hide the document.
  beginImageDrag(control, hit, pageIndex) {
    // `control` came from hwpControlAtHit → getPageControlLayout, and was picked
    // by containment on its bbox — so control.bbox.{x,y,width,height} is always
    // present. No `?? 0` geometry fallback: trust the engine's layout.
    const { bbox } = control
    const props = JSON.parse(
      this.doc.getPictureProperties(control.section, control.paragraph, control.controlIndex)
    )
    this.imageDrag = {
      mode: "move",
      control,
      hit,
      section: control.section,
      paraIdx: control.paragraph,
      controlIdx: control.controlIndex,
      pageIndex,
      startX: bbox.x,
      startY: bbox.y,
      curX: bbox.x,
      curY: bbox.y,
      w: bbox.width,
      h: bbox.height,
      // px↔HWPUNIT is the engine's job: the move commits through
      // `this.doc.pxToHwpUnit` (authoritative, DPI-based). No hand-rolled scale.
      startMouseX: hit.x,
      startMouseY: hit.y,
      props,
      moved: false
    }
    this.dragSelect = null
  },

  // Resize the SELECTED picture by dragging its corner handle: scales uniformly
  // (keeps aspect) via the engine's setPictureProperties{width,height}. The
  // top-left (inline anchor) stays fixed; the engine reflows around the new size.
  beginImageResize(handle, hit, pageIndex) {
    const props = JSON.parse(
      this.doc.getPictureProperties(handle.section, handle.paraIdx, handle.controlIdx)
    )
    // handle.bbox is the engine's live control bbox — width/height are real
    // pixels of a rendered picture, never 0. No `|| 1` divide-guard fallback.
    const w = handle.bbox.width
    const h = handle.bbox.height
    this.imageDrag = {
      mode: "resize",
      section: handle.section,
      paraIdx: handle.paraIdx,
      controlIdx: handle.controlIdx,
      pageIndex,
      x: handle.bbox.x,
      y: handle.bbox.y,
      curW: w,
      curH: h,
      aspect: w / h,
      // Size commits through `this.doc.pxToHwpUnit` — the engine owns px↔HWPUNIT.
      props,
      moved: false
    }
    this.dragSelect = null
  },

  updateImageDrag(event) {
    const drag = this.imageDrag
    if (!drag) return
    const hitInfo = this.hitTestEvent(event, drag.pageIndex)
    if (!hitInfo || hitInfo.hit.x === undefined) return
    if (drag.mode === "resize") {
      const newW = Math.max(20, hitInfo.hit.x - drag.x)
      const newH = newW / drag.aspect // uniform scale (keep aspect)
      if (Math.abs(newW - drag.curW) > 1) drag.moved = true
      drag.curW = newW
      drag.curH = newH
      this.clearSelection()
      this.drawImageDragGhost({ pageIndex: drag.pageIndex, curX: drag.x, curY: drag.y, w: newW, h: newH })
      if (event.cancelable) event.preventDefault()
      return
    }
    const nx = Math.max(0, drag.startX + (hitInfo.hit.x - drag.startMouseX))
    const ny = Math.max(0, drag.startY + (hitInfo.hit.y - drag.startMouseY))
    // Threshold so a click with tiny jitter still counts as a select, not a move.
    if (!drag.moved && Math.hypot(nx - drag.startX, ny - drag.startY) < 4) return
    drag.moved = true
    drag.curX = nx
    drag.curY = ny
    this.clearSelection()
    this.drawImageDragGhost(drag) // preview only; the move commits in endImageDrag
    if (event.cancelable) event.preventDefault()
  },

  endImageDrag() {
    const drag = this.imageDrag
    this.imageDrag = null
    if (!drag) return
    this.clearImageDragGhost(drag.pageIndex)

    if (drag.mode === "resize") {
      if (!drag.moved) { this.paintPickedHighlights(); return }
      const next = Object.assign({}, drag.props, {
        width: this.doc.pxToHwpUnit(drag.curW),
        height: this.doc.pxToHwpUnit(drag.curH)
      })
      try {
        this.doc.setPictureProperties(drag.section, drag.paraIdx, drag.controlIdx, JSON.stringify(next))
      } catch (_) {
        return
      }
      this.renderPage(drag.pageIndex)
      this.scheduleSnapshot()
      // Repaint the selection live (the box + handle follow the new size).
      this.paintPickedHighlights()
      return
    }

    if (!drag.moved) {
      // A plain click → SELECT (pick) the image.
      appendPickedElementToComposer(this.hwpPickFromHit(drag.hit, drag.pageIndex))
      return
    }

    // A drag → commit the move (single Paper-anchored float). Page-px → HWPUNIT
    // is the engine's `pxToHwpUnit` (authoritative, DPI-based) — no constant.
    const floatProps = Object.assign({}, drag.props, {
      treatAsChar: false,
      horzRelTo: "Paper",
      vertRelTo: "Paper",
      horzAlign: "Left",
      vertAlign: "Top",
      horzOffset: this.doc.pxToHwpUnit(drag.curX),
      vertOffset: this.doc.pxToHwpUnit(drag.curY)
    })
    try {
      this.doc.setPictureProperties(drag.section, drag.paraIdx, drag.controlIdx, JSON.stringify(floatProps))
    } catch (_) {
      return
    }
    this.renderPage(drag.pageIndex)
    this.scheduleSnapshot()
    // Repaint the selection live so the box + handle follow the moved picture
    // (its bbox comes straight from rhwp's getPageControlLayout — never stale).
    this.paintPickedHighlights()
  },

  // Dashed ghost box (page overlay) showing where a dragged picture will land.
  drawImageDragGhost(drag) {
    const overlay = this.pageOverlay(drag.pageIndex)
    const ctx = overlay && overlay.getContext("2d")
    if (!ctx) return
    const s = this.scale
    ctx.clearRect(0, 0, overlay.width, overlay.height)
    ctx.save()
    ctx.fillStyle = "rgba(29, 78, 216, 0.10)"
    ctx.strokeStyle = "#1d4ed8"
    ctx.lineWidth = Math.max(1, 1.5 * s)
    ctx.setLineDash([6 * s, 4 * s])
    ctx.fillRect(drag.curX * s, drag.curY * s, drag.w * s, drag.h * s)
    ctx.strokeRect(drag.curX * s, drag.curY * s, drag.w * s, drag.h * s)
    ctx.restore()
  },

  clearImageDragGhost(pageIndex) {
    const overlay = this.pageOverlay(pageIndex)
    const ctx = overlay && overlay.getContext("2d")
    if (ctx) ctx.clearRect(0, 0, overlay.width, overlay.height)
  },

  // Half-size (doc px) of the square resize handle drawn at a selected picture's
  // bottom-right corner.
  IMAGE_HANDLE_HALF: 7,

  // The picture pick's LIVE bbox on `pageIndex`, read from rhwp's control layout
  // (passed in to avoid re-querying). The single source of truth for a picture's
  // selection box + handle — so it always tracks the engine's current geometry.
  pictureLiveRect(pick, pageIndex, layout) {
    if (!/picture|image/i.test(pick.type || "")) return null
    let ref = {}
    try {
      ref = JSON.parse(pick.ref)
    } catch (_) {
      return null
    }
    if (ref.control === undefined) return null
    const c = (layout || []).find(
      (cc) =>
        Number(cc.secIdx ?? 0) === Number(ref.section ?? 0) &&
        Number(cc.paraIdx) === Number(ref.paragraph) &&
        Number(cc.controlIdx) === Number(ref.control)
    )
    return c ? { pageIndex, x: c.x, y: c.y, width: c.w, height: c.h } : null
  },

  // If the press is on the bottom-right resize handle of a SELECTED picture,
  // return that picture's ref + LIVE bbox (from rhwp's layout); else null.
  pictureResizeHandleAtHit(hit) {
    if (!hit || hit.x === undefined || hit.y === undefined) return null
    const H = this.IMAGE_HANDLE_HALF + 2
    for (const pick of this.currentDocumentPicks()) {
      if (!/picture|image/i.test(pick.type || "")) continue
      const pageIndex = ((pick.rects || [])[0] || {}).pageIndex ?? 0
      let layout = []
      try {
        layout = (JSON.parse(this.doc.getPageControlLayout(pageIndex)) || {}).controls || []
      } catch (_) {
        continue
      }
      const r = this.pictureLiveRect(pick, pageIndex, layout)
      if (!r) continue
      const hx = r.x + r.width
      const hy = r.y + r.height
      if (Math.abs(hit.x - hx) <= H && Math.abs(hit.y - hy) <= H) {
        const ref = JSON.parse(pick.ref)
        return {
          section: Number(ref.section ?? 0),
          paraIdx: Number(ref.paragraph),
          controlIdx: Number(ref.control),
          bbox: r
        }
      }
    }
    return null
  },

  findHwpControlElement(section, paragraph, controlIndex) {
    try {
      return this.collectElements().find(el => {
        const r = el.ref || {}
        return Number(r.section ?? 0) === Number(section) &&
          Number(r.paragraph ?? 0) === Number(paragraph) &&
          Number(r.control ?? -1) === Number(controlIndex)
      }) || null
    } catch (_) {
      return null
    }
  },

  findHwpElement(ref) {
    try {
      return this.collectElements().find(el => this.sameHwpElementRef(el.ref, ref)) || null
    } catch (_) {
      return null
    }
  },

  sameHwpElementRef(a, b) {
    if (!a || !b) return false
    if (Number(a.section ?? 0) !== Number(b.section ?? 0)) return false
    if (Number(a.paragraph ?? 0) !== Number(b.paragraph ?? 0)) return false
    if (!!a.cell !== !!b.cell) return false
    if (!a.cell) return true

    return Number(a.cell.parentParaIndex ?? a.paragraph) === Number(b.cell.parentParaIndex ?? b.paragraph) &&
      Number(a.cell.controlIndex ?? 0) === Number(b.cell.controlIndex ?? 0) &&
      Number(a.cell.cellIndex ?? 0) === Number(b.cell.cellIndex ?? 0)
  },

  hwpTextForRef(ref) {
    try {
      if (ref.cell) {
        const c = ref.cell
        const para = c.cellParaIndex ?? 0
        const len = this.doc.getCellParagraphLength(ref.section, c.parentParaIndex, c.controlIndex, c.cellIndex, para)
        return this.doc.getTextInCell(ref.section, c.parentParaIndex, c.controlIndex, c.cellIndex, para, 0, len) || ""
      }

      const len = this.paragraphLength(ref.section, ref.paragraph)
      return this.doc.getTextRange(ref.section, ref.paragraph, 0, len) || ""
    } catch (_) {
      return ""
    }
  },

  // Repaint EVERY current pick's highlight (multi-select) plus the live hover
  // preview. Clears + repaints the overlays through the normal selection pass
  // so picks, hover, text selection and caret coexist.
  paintPickedHighlights() {
    this.renderSelection()
    // drawCaret also repaints the adornments on the caret's page (it owns that
    // overlay's clear/blink cycle) — don't paint that page twice below.
    const caretPage =
      this.caret && this.caret.cursorRect ? this.caret.cursorRect.pageIndex : null
    if (this.caret) this.drawCaret(this.caret)

    const pages = new Set()
    for (const pick of this.currentDocumentPicks()) {
      for (const rect of pick.rects || []) pages.add(rect.pageIndex ?? 0)
    }
    if (this.elementPickerEnabled && this.pickerHover) {
      for (const rect of this.pickerHover.rects || []) pages.add(rect.pageIndex ?? 0)
    }
    if (caretPage != null) pages.delete(caretPage)
    for (const page of pages) this.paintAdornmentsOnPage(page)
  },

  currentDocumentPicks() {
    const picker = window.EcritsDocumentElementPicker
    const picks = (picker && picker.picks) || []
    const docPath = this.el.dataset.documentPath || ""
    return picks.filter(p => p.document === docPath)
  },

  // Paint the pick highlights + hover preview that fall on ONE page's overlay,
  // without clearing it (the caller owns the clear). Solid indigo for picks,
  // dashed for the hover preview.
  paintAdornmentsOnPage(pageIndex) {
    const overlay = this.pageOverlay(pageIndex)
    if (!overlay) return
    const ctx = overlay.getContext("2d")
    if (!ctx) return
    const s = this.scale

    let layout // lazily-fetched live control layout for this page (rhwp geometry)
    for (const pick of this.currentDocumentPicks()) {
      const isPicture = /picture|image/i.test(pick.type || "")
      // A picture's selection box is derived LIVE from rhwp's getPageControlLayout
      // each paint, so it always tracks the engine's current geometry (move/
      // resize) — never a stale cached rect. Other element types use their rects.
      let rects = pick.rects || []
      if (isPicture) {
        if (layout === undefined) {
          try {
            layout = (JSON.parse(this.doc.getPageControlLayout(pageIndex)) || {}).controls || []
          } catch (_) {
            layout = []
          }
        }
        const r = this.pictureLiveRect(pick, pageIndex, layout)
        rects = r ? [r] : []
      }
      for (const rect of rects) {
        if ((rect.pageIndex ?? 0) !== pageIndex) continue
        ctx.save()
        ctx.fillStyle = "rgba(99, 102, 241, 0.16)"
        ctx.strokeStyle = "rgba(79, 70, 229, 0.95)"
        ctx.lineWidth = Math.max(2, 1.5 * s)
        ctx.fillRect(rect.x * s, rect.y * s, rect.width * s, rect.height * s)
        ctx.strokeRect(rect.x * s, rect.y * s, rect.width * s, rect.height * s)
        // A selected picture gets a bottom-right resize handle (drag to scale).
        if (isPicture) {
          const hh = this.IMAGE_HANDLE_HALF * s
          const hx = (rect.x + (rect.width || 0)) * s
          const hy = (rect.y + (rect.height || 0)) * s
          ctx.fillStyle = "#4f46e5"
          ctx.strokeStyle = "#ffffff"
          ctx.lineWidth = Math.max(1, s)
          ctx.fillRect(hx - hh, hy - hh, hh * 2, hh * 2)
          ctx.strokeRect(hx - hh, hy - hh, hh * 2, hh * 2)
        }
        ctx.restore()
      }
    }

    const hover = this.elementPickerEnabled ? this.pickerHover : null
    if (hover) {
      for (const rect of hover.rects || []) {
        if ((rect.pageIndex ?? 0) !== pageIndex) continue
        ctx.save()
        ctx.fillStyle = "rgba(99, 102, 241, 0.08)"
        ctx.strokeStyle = "rgba(79, 70, 229, 0.9)"
        ctx.lineWidth = Math.max(1.5, s)
        ctx.setLineDash([6 * s, 4 * s])
        ctx.fillRect(rect.x * s, rect.y * s, rect.width * s, rect.height * s)
        ctx.strokeRect(rect.x * s, rect.y * s, rect.width * s, rect.height * s)
        ctx.restore()
      }
    }
  },

  // ─── Picker hover preview (DOM-inspector style) ─────────────────────────

  // rAF-throttle the document-level mousemove: hit-testing every move would
  // hammer the WASM engine while the pointer sweeps across a page.
  queuePickerHover(event) {
    this.pickerHoverEvent = event
    if (this.pickerHoverRaf) return
    this.pickerHoverRaf = requestAnimationFrame(() => {
      this.pickerHoverRaf = null
      this.updatePickerHover(this.pickerHoverEvent)
    })
  },

  updatePickerHover(event) {
    if (!this.elementPickerEnabled || !this.doc || !event) {
      this.setPickerHover(null)
      return
    }
    const overPage = event.target && event.target.closest
      ? event.target.closest("[data-role='local-hwp-page']")
      : null
    if (!overPage) {
      this.setPickerHover(null)
      return
    }
    const hitInfo = this.hitTestEvent(event)
    if (!hitInfo) {
      this.setPickerHover(null)
      return
    }
    const { hit, pageIndex } = hitInfo
    // The engine resolves the element under the cursor + its highlight rects —
    // the picker just paints them (no TS hit-test).
    const pick = this.hwpPick(hit, pageIndex)
    if (!pick) {
      this.setPickerHover(null)
      return
    }
    const key = JSON.stringify({ type: pick.type, ref: pick.ref, control: pick.controlIndex })
    if (this.pickerHover && this.pickerHover.key === key) return
    this.setPickerHover({
      key,
      rects: (pick.rects || []).map(r => ({ ...r, pageIndex: r.pageIndex ?? pageIndex }))
    })
  },

  setPickerHover(hover) {
    if (!hover && !this.pickerHover) return
    this.pickerHover = hover
    this.paintPickedHighlights()
  },

  // bindElementPickerTarget calls this on picker mode changes: every transition
  // starts with a blank hover preview. Picks persist independently.
  onElementPickerState(enabled) {
    if (this.pickerHoverRaf) {
      cancelAnimationFrame(this.pickerHoverRaf)
      this.pickerHoverRaf = null
    }
    this.pickerHoverEvent = null
    this.setPickerHover(null)
  },

  // Refresh `cursorRect` from the engine for the current caret position. Used
  // after edits whose result JSON gives us the new offset but not coordinates.
  refreshCursorRect() {
    if (!this.caret || !this.doc) return
    const c = this.caret
    try {
      let raw
      if (c.note) {
        // Caret inside a footnote — keep its rect from the engine's note query
        // so a re-render doesn't snap it back to the body paragraph.
        raw = this.doc.getCursorRectInFootnote(
          c.cursorRect ? c.cursorRect.pageIndex : 0,
          c.note.footnoteIndex, c.note.innerParaIndex, c.offset
        )
      } else if (c.cell) {
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
    // The caret, the selection highlight AND the picker adornments share this
    // overlay; clearing it for the caret blink would wipe them, so repaint
    // both before the caret.
    if (this.selection) this.paintSelectionOnPage(rect.pageIndex)
    this.paintAdornmentsOnPage(rect.pageIndex)
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

  // Read a note (footnote/endnote) body sub-paragraph's text via getFootnoteInfo,
  // which returns {ok, paraCount, totalTextLen, number, texts:[...]} for BOTH
  // footnotes and endnotes (the native impl is control-type agnostic). `note`
  // carries {controlIndex, subParaIndex}; returns the sub-paragraph text or ""
  // (so an empty note reads as "" rather than throwing).
  noteParagraphText(section, paragraph, note) {
    try {
      const info = JSON.parse(this.doc.getFootnoteInfo(section, paragraph, note.controlIndex) || "{}")
      const texts = Array.isArray(info.texts) ? info.texts : []
      const t = texts[note.subParaIndex]
      return typeof t === "string" ? t : ""
    } catch (_) {
      return ""
    }
  },

  paragraphCount(section) {
    try { return this.doc.getParagraphCount(section) } catch (_) { return 1 }
  },

  // ─── Agent ops (server -> browser, design §6.2) ──────────────────────────

  // Apply an agent-routed op to the authoritative WASM doc and reply with the
  // result. `verb` is read | find | edit. The reply is always sent (even on
  // error) so the blocked MCP caller never hangs to its timeout.
  handleAgentOp(request) {
    this.agentOpQueue.push(request)
    this.processAgentOpQueue()
  },

  processAgentOpQueue() {
    if (this.agentOpProcessing) return

    const request = this.agentOpQueue.shift()
    if (!request) return

    this.agentOpProcessing = true
    const { request_id, verb, payload } = request
    const replyNow = body => this.pushEvent("doc.browser_reply", { request_id, ...body })
    const reply = (body, waitForPaint = false) => {
      const send = () => {
        replyNow(body)
        this.agentOpProcessing = false
        this.processAgentOpQueue()
      }

      if (waitForPaint) {
        this.afterNextPaint(send)
      } else {
        setTimeout(send, 0)
      }
    }

    if (!this.doc) {
      reply({ error: "document_not_loaded" })
      return
    }
    try {
      switch (verb) {
        case "edit":
          // Batch form (doc.edit {ops:[...]}) vs. single op (doc.edit {op}).
          reply(
            Array.isArray(payload && payload.ops)
              ? this.applyAgentEditBatch(payload)
              : this.applyAgentEdit(payload),
            true
          )
          break
        case "set":
          // Batch form (doc.set {sets:[{ref,props}]}) vs. single (doc.set {ref,props}).
          reply(
            Array.isArray(payload && payload.sets)
              ? this.applyAgentSetBatch(payload)
              : this.applyAgentSet(payload),
            true
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

  afterNextPaint(callback) {
    if (typeof window.requestAnimationFrame !== "function" || document.visibilityState === "hidden") {
      setTimeout(callback, 0)
      return
    }

    window.requestAnimationFrame(() => setTimeout(callback, 0))
  },

  // Structural edit verbs over the viewed WASM model: `replace_text`,
  // `insert_text`, `delete_range`. Each addresses text positionally via a `ref`
  // ({section, paragraph, offset} from doc.find) so the agent can target ONE
  // paragraph instead of the whole document. `replace_text` may also run without
  // a ref (global), but only replaces >1 match when `all:true` is set.
  //
  // Single-op entry point: apply the MUTATION (applyOneOp, no render) then run
  // the shared finish (re-render/snapshot) ONCE. The mutation and the
  // finish are deliberately split so the BATCH path (applyAgentEditBatch) can
  // mutate many ops and finish a single time.
  applyAgentEdit({ op }) {
    // try/catch parity with applyAgentEditBatch: an op-level throw (e.g. a WASM
    // primitive error) must surface as a structured {error}, never a raw
    // uncaught exception to the agent.
    let r
    try {
      r = this.applyOneOp(op)
    } catch (error) {
      return { error: String((error && error.message) || error) }
    }
    if (r.error) return { error: r.error }
    return this.finishAgentEdit(r.extra || {})
  },

  // Apply ONE structural edit op to the WASM model and return either
  // `{ ok: true, extra }` (the per-verb result fields the finish should echo) or
  // `{ error }`. This function NEVER renders — that is the
  // caller's job via finishAgentEdit, so a batch can mutate N ops and finish once.
  colorValueToBgr(value) {
    if (Number.isInteger(value)) return value
    if (typeof value !== "string") return null
    const match = value.trim().match(/^#?([0-9a-fA-F]{6})$/)
    if (!match) return null
    const hex = match[1]
    const r = parseInt(hex.slice(0, 2), 16)
    const g = parseInt(hex.slice(2, 4), 16)
    const b = parseInt(hex.slice(4, 6), 16)
    return (b << 16) | (g << 8) | r
  },

  colorPropFromOp(op, keys) {
    for (const key of keys) {
      if (op && Object.prototype.hasOwnProperty.call(op, key)) {
        const color = this.colorValueToBgr(op[key])
        if (color != null) return color
      }
    }
    return null
  },

  intPropFromOp(op, keys) {
    for (const key of keys) {
      if (op && Number.isInteger(op[key])) return op[key]
    }
    return null
  },

  shapeStylePropsFromOp(op) {
    const props = {}
    const fillColor = this.colorPropFromOp(op, [
      "fillBgColor",
      "fillColor",
      "BackgroundColor",
      "backgroundColor",
      "fill_color",
      "background_color"
    ])
    const fillType = op && (op.fillType != null ? op.fillType : op.fill_type)

    if (fillColor != null) {
      props.fillType = fillType != null ? String(fillType) : "solid"
      props.fillBgColor = fillColor
      props.fillPatType = -1
    } else if (fillType != null) {
      props.fillType = String(fillType)
    }

    for (const [target, keys] of [
      ["fillPatColor", ["fillPatColor", "fill_pat_color"]],
      ["fillPatType", ["fillPatType", "fill_pat_type"]],
      ["fillAlpha", ["fillAlpha", "fill_alpha"]],
      ["borderWidth", ["borderWidth", "border_width"]],
      ["lineType", ["lineType", "line_type"]],
      ["roundRate", ["roundRate", "round_rate"]],
      ["rotationAngle", ["rotationAngle", "rotation_angle"]]
    ]) {
      const value = this.intPropFromOp(op, keys)
      if (value != null) props[target] = value
    }

    const borderColor = this.colorPropFromOp(op, ["borderColor", "border_color", "lineColor", "line_color"])
    if (borderColor != null) props.borderColor = borderColor
    return props
  },

  // ── Doc-edit dispatch ───────────────────────────────────────────
  // Parse the verb + ref ONCE, then dispatch through the chained, typed op
  // registry (assets/js/wasm_ops.ts). Each verb is a standalone handler taking
  // the editor instance as `ctx`; add/override one via WasmHwpEditor.define.
  applyOneOp(op) {
    const verb = op && op.op
    const ref = this.parseRef(op && op.ref)
    const handler = OPS.registry[verb]
    if (!handler) return { error: `unsupported_op:${verb}` }
    return handler(this, op, ref, verb)
  },


  // "end" -> an appendable position at the document tail: the LAST section's
  // last paragraph (offset = its length) plus appendIndex (= paragraph count)
  // for insert_paragraph's append-after semantics. This is the ref shape the
  // docx authoring guide teaches; agents reuse it on hwp, and rejecting it
  // turned "append 3 sonnets" into a failed batch (live 2026-06-13).
  resolveEndRef(rawRef) {
    if (rawRef !== "end") return null
    let section = 0
    try {
      for (const el of this.collectElements()) {
        const s = el.ref && el.ref.section
        if (Number.isInteger(s) && s > section) section = s
      }
    } catch (_) {}
    let count = 0
    try { count = this.doc.getParagraphCount(section) } catch (_) {}
    const paragraph = Math.max(0, count - 1)
    let offset = 0
    try { offset = this.paragraphLength(section, paragraph) } catch (_) {}
    return { section, paragraph, offset, appendIndex: count }
  },

  // Resolve a table edit target from a ref. Table row/col/merge/split ops need the
  // paragraph that HOLDS the table control + the control index; a cell ref carries
  // both (parentParaIndex + controlIndex). Returns null if the ref is not a cell.
  resolveTableTarget(ref) {
    if (
      ref &&
      ref.cell &&
      Number.isInteger(ref.cell.parentParaIndex) &&
      Number.isInteger(ref.cell.controlIndex)
    ) {
      return {
        section: ref.section,
        paragraph: ref.cell.parentParaIndex,
        control: ref.cell.controlIndex,
        cellIndex: ref.cell.cellIndex
      }
    }
    return null
  },

  // (row, col) of the picked cell, read from the engine (getCellInfo returns
  // {row,col,rowSpan,colSpan}). Lets "insert a row below THIS cell" work without
  // the agent separately computing the row index.
  cellRowCol(target) {
    try {
      const info = JSON.parse(
        this.doc.getCellInfo(target.section, target.paragraph, target.control, target.cellIndex) || "{}"
      )
      return {
        row: Number.isInteger(info.row) ? info.row : null,
        col: Number.isInteger(info.col) ? info.col : null
      }
    } catch (_) {
      return { row: null, col: null }
    }
  },

  // Extract a bare control index from a raw ref (object or {control}/{controlIndex}).
  // parseRef only keeps a control when it pairs with a note sub-paragraph; a
  // picture/shape control ref carries `control` alone, which delete_node needs.
  rawControlIndex(rawRef) {
    let r = rawRef
    if (typeof r === "string") {
      try {
        r = JSON.parse(r)
      } catch (_) {
        return null
      }
    }
    if (r && typeof r === "object") {
      const c = Number(r.control ?? r.controlIndex)
      if (Number.isInteger(c)) return c
    }
    return null
  },

  // base64 → Uint8Array (the inverse of bytesToBase64), for inline image bytes.
  base64ToBytes(b64) {
    const binary = atob(String(b64 || ""))
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
    return bytes
  },

  singleParagraphText(value) {
    return String(value == null ? "" : value).replace(/\r\n|\r|\n/g, " ").replace(/[ \t]{2,}/g, " ").trim()
  },

  splitTextLines(value) {
    return String(value == null ? "" : value).split(/\r\n|\r|\n/)
  },

  normalizeCellPath(raw) {
    const list = Array.isArray(raw) ? raw : null
    if (!list || list.length === 0) return null

    const path = []
    for (const step of list) {
      if (!step || typeof step !== "object") return null
      const controlIndex = Number(step.controlIndex ?? step.control ?? step.ctrlIdx)
      const cellIndex = Number(step.cellIndex ?? step.cell ?? step.cellIdx)
      const cellParaIndex = Number(step.cellParaIndex ?? step.cellPara ?? step.cell_para)
      if (!Number.isInteger(controlIndex) || !Number.isInteger(cellIndex) || !Number.isInteger(cellParaIndex)) {
        return null
      }
      path.push({ controlIndex, cellIndex, cellParaIndex })
    }
    return path
  },

  cellPathForPara(ref, cellParaIndex) {
    if (!ref || !Array.isArray(ref.cellPath) || ref.cellPath.length === 0) return null
    const path = ref.cellPath.map((step) => ({
      controlIndex: step.controlIndex,
      cellIndex: step.cellIndex,
      cellParaIndex: step.cellParaIndex
    }))
    if (Number.isInteger(cellParaIndex)) {
      path[path.length - 1].cellParaIndex = cellParaIndex
    }
    return path
  },

  cellPathJson(ref, cellParaIndex) {
    const path = this.cellPathForPara(ref, cellParaIndex)
    return path ? JSON.stringify(path) : null
  },

  cellParagraphCount(ref, cell) {
    const pathJson = this.cellPathJson(ref, 0)
    if (pathJson && typeof this.doc.getCellParagraphCountByPath === "function") {
      return this.doc.getCellParagraphCountByPath(ref.section, cell.parentParaIndex, pathJson)
    }
    return this.doc.getCellParagraphCount(ref.section, cell.parentParaIndex, cell.controlIndex, cell.cellIndex)
  },

  cellParagraphLength(ref, cell, cellParaIndex) {
    const pathJson = this.cellPathJson(ref, cellParaIndex)
    if (pathJson && typeof this.doc.getCellParagraphLengthByPath === "function") {
      return this.doc.getCellParagraphLengthByPath(ref.section, cell.parentParaIndex, pathJson)
    }
    return this.doc.getCellParagraphLength(
      ref.section, cell.parentParaIndex, cell.controlIndex, cell.cellIndex, cellParaIndex
    )
  },

  getTextInCellRef(ref, cell, cellParaIndex, offset, count) {
    const pathJson = this.cellPathJson(ref, cellParaIndex)
    if (pathJson && typeof this.doc.getTextInCellByPath === "function") {
      return this.doc.getTextInCellByPath(ref.section, cell.parentParaIndex, pathJson, offset, count)
    }
    return this.doc.getTextInCell(
      ref.section, cell.parentParaIndex, cell.controlIndex, cell.cellIndex, cellParaIndex, offset, count
    )
  },

  insertTextInCellRef(ref, cell, cellParaIndex, offset, text) {
    const pathJson = this.cellPathJson(ref, cellParaIndex)
    if (pathJson && typeof this.doc.insertTextInCellByPath === "function") {
      return this.doc.insertTextInCellByPath(ref.section, cell.parentParaIndex, pathJson, offset, text)
    }
    return this.doc.insertTextInCell(
      ref.section, cell.parentParaIndex, cell.controlIndex, cell.cellIndex, cellParaIndex, offset, text
    )
  },

  deleteTextInCellRef(ref, cell, cellParaIndex, offset, count) {
    const pathJson = this.cellPathJson(ref, cellParaIndex)
    if (pathJson && typeof this.doc.deleteTextInCellByPath === "function") {
      return this.doc.deleteTextInCellByPath(ref.section, cell.parentParaIndex, pathJson, offset, count)
    }
    return this.doc.deleteTextInCell(
      ref.section, cell.parentParaIndex, cell.controlIndex, cell.cellIndex, cellParaIndex, offset, count
    )
  },

  splitParagraphInCellRef(ref, cell, cellParaIndex, offset) {
    const pathJson = this.cellPathJson(ref, cellParaIndex)
    if (pathJson && typeof this.doc.splitParagraphInCellByPath === "function") {
      return this.doc.splitParagraphInCellByPath(ref.section, cell.parentParaIndex, pathJson, offset)
    }
    return this.doc.splitParagraphInCell(
      ref.section, cell.parentParaIndex, cell.controlIndex, cell.cellIndex, cellParaIndex, offset
    )
  },

  mergeParagraphInCellRef(ref, cell, cellParaIndex) {
    const pathJson = this.cellPathJson(ref, cellParaIndex)
    if (pathJson && typeof this.doc.mergeParagraphInCellByPath === "function") {
      return this.doc.mergeParagraphInCellByPath(ref.section, cell.parentParaIndex, pathJson)
    }
    return this.doc.mergeParagraphInCell(
      ref.section, cell.parentParaIndex, cell.controlIndex, cell.cellIndex, cellParaIndex
    )
  },

  insertTextLines(ref, offset, text) {
    const lines = this.splitTextLines(text)
    this.doc.insertText(ref.section, ref.paragraph, offset, lines[0] || "")
    let para = ref.paragraph
    let splitOffset = offset + (lines[0] || "").length
    for (let i = 1; i < lines.length; i++) {
      this.doc.splitParagraph(ref.section, para, splitOffset)
      para += 1
      const line = lines[i] || ""
      this.doc.insertText(ref.section, para, 0, line)
      splitOffset = line.length
    }
  },

  insertTextLinesInCell(ref, cell, offset, text) {
    const lines = this.splitTextLines(text)
    let cellPara = cell.cellParaIndex
    this.insertTextInCellRef(ref, cell, cellPara, offset, lines[0] || "")
    let splitOffset = offset + (lines[0] || "").length
    for (let i = 1; i < lines.length; i++) {
      this.splitParagraphInCellRef(ref, cell, cellPara, splitOffset)
      cellPara += 1
      const line = lines[i] || ""
      this.insertTextInCellRef(ref, cell, cellPara, 0, line)
      splitOffset = line.length
    }
  },

  insertTextLinesInFootnote(ref, note, offset, text) {
    const lines = this.splitTextLines(text)
    let subPara = note.subParaIndex
    this.doc.insertTextInFootnote(ref.section, ref.paragraph, note.controlIndex, subPara, offset, lines[0] || "")
    let splitOffset = offset + (lines[0] || "").length
    for (let i = 1; i < lines.length; i++) {
      this.doc.splitParagraphInFootnote(ref.section, ref.paragraph, note.controlIndex, subPara, splitOffset)
      subPara += 1
      const line = lines[i] || ""
      this.doc.insertTextInFootnote(ref.section, ref.paragraph, note.controlIndex, subPara, 0, line)
      splitOffset = line.length
    }
  },


  // Batch structural edit (doc.edit {ops:[...]}). Apply every op to the WASM
  // model with ONE re-render/snapshot at the end (finishAgentEdit). This is
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
  applyAgentEditBatch({ ops }) {
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

    this.finishAgentEdit({})
    return {
      ok: true,
      result: { ok: true, applied, failed, results }
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
    if (ref && ref.note) return false // note (footnote/endnote) body: never shifts BODY indices
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
  applyAgentSet({ ref, props }) {
    const r = this.applySetOne(ref, props)
    if (r.error) return { error: r.error }
    return this.finishAgentEdit({})
  },

  // Apply ONE property set to the WASM model and return `{ ok: true }` or
  // `{ error }`. Mutate-only — no render (the caller finishes
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
      // Translate the agent's vocabulary (HWP PascalCase / Office UNO) to the
      // engine's keys via CHAR_PROP_SPEC + castCharProp (defined once, module-
      // level — see top of file).
      const charJson = JSON.stringify(translateCharProps(rest))
      const start = Number.isInteger(parsed.offset) ? parsed.offset : 0
      const span = Number(parsed.length ?? parsed.len ?? 0)
      // No explicit span -> format the WHOLE paragraph (a bare paragraph ref
      // used to yield a ZERO-length range: applied nothing, replied ok).
      let end = start + (Number.isFinite(span) && span > 0 ? span : 0)
      const cl = parsed.cell
      if (end <= start) {
        try {
          end = cl
            ? this.cellParagraphLength(parsed, cl, cl.cellParaIndex)
            : this.paragraphLength(parsed.section, parsed.paragraph)
        } catch (_) { end = start }
      }
      try {
        if (cl) {
          this.doc.applyCharFormatInCell(
            parsed.section, cl.parentParaIndex, cl.controlIndex, cl.cellIndex, cl.cellParaIndex, start, end, charJson
          )
        } else {
          this.doc.applyCharFormat(parsed.section, parsed.paragraph, start, end, charJson)
        }
      } catch (error) {
        return { error: `applyCharFormat failed: ${String((error && error.message) || error)}` }
      }
      this.recordOp("AgentSetChar", { section: parsed.section, para: parsed.paragraph, cell: cl, start, end, props: rest })
      return { ok: true }
    }

    return { error: `set: unsupported kind '${kind}' in the browser editor (supported: cell, char)` }
  },

  // Batch property set (doc.set {sets:[{ref,props}, ...]}). Apply every set to
  // the WASM model with ONE re-render/snapshot at the end. Best-effort: a
  // bad ref does NOT abort the rest; the result carries a per-set `results`
  // array. Sets address fixed cells/runs and never move another set's target, so
  // order is irrelevant (applied in the given order).
  applyAgentSetBatch({ sets }) {
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

    this.finishAgentEdit({})
    return {
      ok: true,
      result: { ok: true, applied, failed, results }
    }
  },

  // A ref is the positional index doc.find returns (a JSON string
  // {section,paragraph,offset}); accept the parsed object too. null when absent.
  parseRef(ref) {
    if (ref == null) return null
    let r = ref
    if (typeof ref === "string") {
      try { r = JSON.parse(ref) } catch (_) {
        const text = ref.trim()
        let match = /^hwp:s(\d+)\/p(\d+)(?:@(\d+))?$/.exec(text)
        if (match) {
          return {
            section: Number(match[1]),
            paragraph: Number(match[2]),
            offset: Number(match[3] || 0)
          }
        }
        match = /^hwp:s(\d+)\/p(\d+)\/c(\d+)\+\d+$/.exec(text)
        if (match) {
          return {
            section: Number(match[1]),
            paragraph: Number(match[2]),
            offset: Number(match[3])
          }
        }
        return null
      }
    }
    if (typeof r !== "object") return null
    const section = Number(r.section ?? r.sectionIndex ?? 0)
    const paragraph = Number(r.paragraph ?? r.paragraphIndex)
    if (!Number.isInteger(paragraph)) return null
    const offset = Number(r.offset ?? r.charOffset ?? 0)
    const out = { section: Number.isInteger(section) ? section : 0, paragraph, offset: Number.isInteger(offset) ? offset : 0 } as any
    const length = Number(r.length ?? r.len)
    if (Number.isFinite(length) && length > 0) out.length = length
    const cellPath = this.normalizeCellPath(r.cellPath ?? r.cell_path)
    if (cellPath) {
      const last = cellPath[cellPath.length - 1]
      // `cellPath` is the authoritative address for nested tables. Keep a
      // cell-shaped summary so existing cell branches route here, then the
      // low-level helpers switch to rhwp's `*ByPath` calls.
      out.cellPath = cellPath
      out.cell = {
        parentParaIndex: paragraph,
        controlIndex: cellPath[0].controlIndex,
        cellIndex: last.cellIndex,
        cellParaIndex: last.cellParaIndex,
        cellPath
      }
      return out
    }
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
    // Note (footnote/endnote) BODY sub-paragraph address. enumerateElements emits
    // a note's inner paragraph as {section,paragraph,control,subParagraph} (the
    // body paragraph at `paragraph` HOLDS the note anchor at control `control`;
    // `subParagraph` indexes the note's own paragraph). Without this the address
    // collapses to a plain {section,paragraph} body insert and the note body is
    // never writable. Both control and subParagraph must be integers to qualify.
    const control = Number(r.control ?? r.controlIndex)
    const subPara = Number(r.subParagraph ?? r.subParagraphIndex ?? r.sub_paragraph)
    if (Number.isInteger(control) && Number.isInteger(subPara)) {
      out.note = { controlIndex: control, subParaIndex: subPara }
    }
    return out
  },

  // Shared post-edit step: re-render the visible window (an edit can reflow any
  // page), redraw the caret, and persist the edited bytes so it survives reload.
  finishAgentEdit(extra) {
    this._elementsCache = null // the document changed; the cached element list is stale
    this.rendered.clear()
    this.renderVisiblePages()
    if (this.caret) this.drawCaret(this.caret)
    this.scheduleSnapshot()
    return { ok: true, result: { ok: true, ...extra } }
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
  applyAgentFind({ pattern, patterns, case_sensitive, all, regex, type, limit }) {
    if (Array.isArray(patterns)) {
      return {
        results: patterns.map((p) =>
          this.applyAgentFind({ pattern: p, case_sensitive, all, regex, type, limit })
        )
      }
    }
    if (all || regex || type) return this.applyAgentFindAll(pattern, !!case_sensitive, type, limit)
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
    return { pattern, matches: this.limitAgentMatches(matches, limit) }
  },

  // Discovery search: enumerate every element (collectElements) and keep those
  // whose text matches `pattern` as a regex. An empty/missing pattern becomes
  // [\s\S]* so {all:true} lists the WHOLE structure, including empty cells.
  applyAgentFindAll(pattern, caseSensitive, type, limit) {
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
      if (!t) return true
      const isCell = !!(el.ref && el.ref.cell)
      const isEmpty = !el.text || el.text.trim() === ""
      // A REAL form field self-describes: it has a column header and/or a row
      // label (collectElements stashes that in `el.context`). A blank cell with
      // NO context is structural/merged noise (a spacer/merged span), not a field
      // to fill — exclude it from `empty_cell` so the agent only gets genuine
      // blanks. `cell`/`all` still include it.
      const isFormField = !!(el.context && String(el.context).trim())
      // Engine enumeration tags every node with its IR kind; the positional-probe
      // fallback has none, so derive cell/paragraph from the ref.
      const kind = el.type || (isCell ? "cell" : "paragraph")
      switch (t) {
        case "fillable": return !!this.fillableKind(el)
        case "cell": return isCell
        case "empty_cell": case "blank_cell": return isCell && isEmpty && isFormField
        case "filled_cell": return isCell && !isEmpty
        case "paragraph": return kind === "paragraph"
        case "empty": case "blank": return isEmpty
        // Any IR kind: field, form, picture, shape, table, equation, header, …
        default: return kind === t
      }
    }
    const MATCH_CAP = Math.min(2000, Math.max(1, Number(limit || 2000)))
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
        const fillableKind = this.fillableKind(el)
        if (fillableKind) m.fillable_kind = fillableKind
        matches.push(m)
      }
    }
    const out = { pattern, matches }
    if (truncated) out.truncated = true
    return out
  },

  isPlaceholderText(text) {
    return !!this.placeholderKind(text)
  },

  placeholderKind(text) {
    const s = String(text || "").trim()
    if (!s || s.startsWith("※")) return null
    if (s.includes("____")) return "underscore"
    if (s.includes("[]") || /^[□☐]\s*/u.test(s)) return "checkbox"
    if (/[-‐‑‒–—―－─]{4,}.*\(이하/u.test(s)) return "signature_line"
    if (/\(\s{2,}\)/u.test(s)) return "paren_blank"
    if (/[:：]\s{2,}[회년월일원%]/u.test(s)) return "inline_gap"
    if (/[년월일]\s{2,}/u.test(s)) return "date_gap"
    if (s.endsWith(":") && s.length <= 80) return "trailing_label"
    return null
  },

  fillableKind(el) {
    const isCell = !!(el && el.ref && el.ref.cell)
    const text = String((el && el.text) || "").trim()
    const kind = (el && el.type) || (isCell ? "cell" : "paragraph")
    const hasContext = !!(el && el.context && String(el.context).trim())
    if (kind === "cell" && text === "" && hasContext) return "empty_cell"
    if (kind === "field" || kind === "form") return kind
    if (kind === "paragraph" || kind === "cell") return this.placeholderKind(text)
    return null
  },

  limitAgentMatches(matches, limit) {
    const n = Number(limit || 0)
    return n > 0 ? matches.slice(0, Math.min(2000, n)) : matches
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

  // Clarify a single anchor ref from doc.find. No paging/full-document read.
  applyAgentRead({ opts }) {
    const o = opts || {}
    if (!o.ref) return { error: "doc.read requires ref from doc.find" }
    return this.applyAgentReadNearby(o)
  },

  applyAgentReadNearby(o) {
    const ref = String(o.ref || "")
    const nearby = this.normalizeAgentNearby(o.nearby)
    const elements = this.collectElements()
    const matches = elements.map((el) => this.agentElementMatch(el))
    const candidates = this.agentReadRefCandidates(ref)
    const hit = this.findAgentReadMatch(matches, candidates)
    if (!hit) {
      const table = this.compactAgentTableRead(candidates, nearby)
      return table && !table.error ? { ref, ...table } : { ref, error: "ref not found" }
    }

    const idx = hit.idx
    const resolvedRef = hit.ref
    const start = Math.max(0, idx - nearby.before)
    const window = matches.slice(start, idx + nearby.after + 1)
    const target = matches[idx]
    const out = {
      ref,
      target,
      elements: window,
      text: window.map((m) => m.text || "").join("\n")
    }
    if (resolvedRef !== ref) out.resolved_ref = resolvedRef

    if (target.type === "cell" || this.tableKeyFromRefString(resolvedRef)) {
      Object.assign(out, this.tableNearby(matches, target, nearby))
    }
    return out
  },

  findAgentReadMatch(matches, refs) {
    for (const ref of refs) {
      const idx = matches.findIndex((m) => m.ref === ref)
      if (idx >= 0) return { ref, idx }
    }
    return null
  },

  agentReadRefCandidates(ref) {
    const refs = [String(ref || "")]
    let obj = null
    try { obj = JSON.parse(String(ref || "")) } catch (_) { obj = null }

    if (obj && typeof obj === "object") {
      if (obj.cell && typeof obj.cell === "object") {
        const sec = Number(obj.section ?? obj.sectionIndex ?? 0)
        const parentPara = Number(obj.cell.parentParaIndex ?? obj.cell.parentPara ?? obj.paragraph)
        const control = Number(obj.cell.controlIndex ?? obj.cell.ctrlIdx)
        const cell = Number(obj.cell.cellIndex ?? obj.cell.cellIdx)
        const cellPara = Number(obj.cell.cellParaIndex ?? obj.cell.cellPara ?? 0)
        if ([sec, parentPara, control, cell, cellPara].every(Number.isInteger)) {
          refs.push(JSON.stringify({
            section: sec,
            paragraph: parentPara,
            offset: 0,
            cell: { parentParaIndex: parentPara, controlIndex: control, cellIndex: cell, cellParaIndex: cellPara }
          }))
          refs.push(JSON.stringify({ section: sec, paragraph: parentPara, control }))
        }
      } else if (obj.paragraph != null || obj.paragraphIndex != null) {
        const sec = Number(obj.section ?? obj.sectionIndex ?? 0)
        const para = Number(obj.paragraph ?? obj.paragraphIndex)
        if (Number.isInteger(sec) && Number.isInteger(para)) {
          refs.push(JSON.stringify({ section: sec, paragraph: para, offset: 0 }))
          refs.push(`hwp:s${sec}/p${para}`)
        }
      }
    }

    const s = String(ref || "")
    let m = /^hwp:s(\d+)\/p(\d+)\/tbl(\d+)\/cell(\d+)\/cp(\d+)\/c\d+\+\d+$/.exec(s)
    if (m) {
      const sec = Number(m[1])
      const para = Number(m[2])
      const control = Number(m[3])
      const cell = Number(m[4])
      const cellPara = Number(m[5])
      refs.push(JSON.stringify({
        section: sec,
        paragraph: para,
        offset: 0,
        cell: { parentParaIndex: para, controlIndex: control, cellIndex: cell, cellParaIndex: cellPara }
      }))
    }

    m = /^hwp:s(\d+)\/p(\d+)\/c\d+\+\d+$/.exec(s)
    if (m) {
      const sec = Number(m[1])
      const para = Number(m[2])
      refs.push(JSON.stringify({ section: sec, paragraph: para, offset: 0 }))
      refs.push(`hwp:s${sec}/p${para}`)
    }

    return Array.from(new Set(refs.filter(Boolean)))
  },

  normalizeAgentNearby(input) {
    const n = input && typeof input === "object" ? input : {}
    const clamp = (value, fallback) => {
      const x = Number(value)
      return Number.isFinite(x) ? Math.max(0, Math.min(10, Math.floor(x))) : fallback
    }
    return {
      before: clamp(n.before, 2),
      after: clamp(n.after, 2),
      row: n.row !== false,
      column: n.column === true,
      headers: n.headers !== false
    }
  },

  agentElementMatch(el) {
    const m = {
      ref: JSON.stringify(el.ref),
      text: el.text || "",
      type: el.type || ((el.ref && el.ref.cell) ? "cell" : "paragraph")
    }
    if (el.context) m.context = el.context
    if (el.row != null) m.row = el.row
    if (el.col != null) m.col = el.col
    return m
  },

  compactAgentTableRead(ref, nearby) {
    const refs = Array.isArray(ref) ? ref.map((r) => String(r || "")) : [String(ref || "")]
    const refString = refs[0] || ""
    const matches = this.collectElements().map((el) => this.agentElementMatch(el))
    const key = refs.map((r) => this.tableKeyFromRefString(r)).find(Boolean) || (() => {
      const hit = matches.find((m) => refs.includes(m.ref))
      return hit ? this.tableKeyFromRefString(hit.ref) : null
    })()
    if (!key) return { ref: refString, error: "ref is not a table/cell ref" }
    const cells = matches.filter((m) => m.type === "cell" && this.tableKeyFromRefString(m.ref) === key)
    if (!cells.length) return { ref: refString, error: "no cells for table ref" }
    return this.compactTablePayload(refString, key, cells, null, nearby)
  },

  tableNearby(matches, target, nearby) {
    const key = this.tableKeyFromRefString(target.ref)
    const cells = matches.filter((m) => m.type === "cell" && this.tableKeyFromRefString(m.ref) === key)
    return cells.length ? this.compactTablePayload(target.ref, key, cells, target, nearby) : {}
  },

  compactTablePayload(ref, key, cells, target, nearby) {
    const sorted = cells.slice().sort((a, b) => ((a.row || 0) - (b.row || 0)) || ((a.col || 0) - (b.col || 0)))
    const targetRow = target && Number.isInteger(target.row) ? target.row : null
    const targetCol = target && Number.isInteger(target.col) ? target.col : null
    const out = {
      table: {
        key,
        anchor: this.tableAnchor(key),
        row_count: new Set(sorted.map((c) => c.row).filter((v) => Number.isInteger(v))).size,
        col_count: new Set(sorted.map((c) => c.col).filter((v) => Number.isInteger(v))).size
      }
    }
    if (nearby.headers) {
      out.table_headers = sorted
        .filter((c) => c.row === 0)
        .map((c) => ({ col: c.col, text: c.text || "" }))
      out.row_labels = sorted
        .filter((c) => (c.col || 0) === 0 && (c.row || 0) > 0)
        .filter((c) => String(c.text || "").trim() || c.row === targetRow)
        .map((c) => ({ row: c.row, text: c.text || "" }))
    }
    if (nearby.row && targetRow !== null) {
      out.row = sorted.filter((c) => c.row === targetRow).map((c) => this.compactTableCell(c, ref))
    }
    if (nearby.column && targetCol !== null) {
      out.column = sorted.filter((c) => c.col === targetCol).map((c) => this.compactTableCell(c, ref))
    }
    return out
  },

  compactTableCell(cell, targetRef) {
    const out = {
      row: cell.row,
      col: cell.col,
      text: cell.text || "",
      type: cell.type || "cell"
    }
    if (cell.context) out.context = cell.context
    const writable = this.writableCell(cell)
    if (writable) out.writable = true
    if (writable || cell.ref === targetRef) out.ref = cell.ref
    return out
  },

  tableAnchor(key) {
    const m = /^hwp:s(\d+):p(\d+):c(\d+)$/.exec(String(key || ""))
    return m ? { section: Number(m[1]), paragraph: Number(m[2]), control: Number(m[3]) } : { key }
  },

  writableCell(cell) {
    return cell.type === "cell" && String(cell.text || "").trim() === "" &&
      (!!(cell.context && String(cell.context).trim()) ||
        (Number.isInteger(cell.row) && Number.isInteger(cell.col) && cell.row > 0 && cell.col > 0))
  },

  tableKeyFromRefString(ref) {
    let obj = null
    try { obj = JSON.parse(String(ref || "")) } catch (_) { obj = null }
    if (obj && typeof obj === "object") {
      if (obj.cell && typeof obj.cell === "object") {
        const sec = Number(obj.section ?? obj.sectionIndex ?? 0)
        const para = Number(obj.cell.parentParaIndex ?? obj.cell.parentPara ?? obj.paragraph)
        const control = Number(obj.cell.controlIndex ?? obj.cell.ctrlIdx ?? 0)
        if (Number.isInteger(para) && Number.isInteger(control)) return `hwp:s${Number.isInteger(sec) ? sec : 0}:p${para}:c${control}`
      }
      const control = Number(obj.control ?? obj.controlIndex)
      const para = Number(obj.paragraph ?? obj.paragraphIndex)
      const sec = Number(obj.section ?? obj.sectionIndex ?? 0)
      if (Number.isInteger(control) && Number.isInteger(para)) return `hwp:s${Number.isInteger(sec) ? sec : 0}:p${para}:c${control}`
    }
    const m = /^hwp:s(\d+)\/p(\d+)\/tbl(\d+)/.exec(String(ref || ""))
    return m ? `hwp:s${m[1]}:p${m[2]}:c${m[3]}` : null
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

  saveLocalDocument(payload = {}) {
    const requestId = payload.request_id || `local-save:${++this.snapshotSeq}`
    const documentId = payload.document_id || this.documentId
    if (!this.doc || !documentId) {
      this.pushEvent("local_document.viewer_save", {
        request_id: requestId,
        document_id: documentId,
        error: "document_not_loaded"
      })
      return
    }
    try {
      this.pushEvent("local_document.viewer_save", {
        request_id: requestId,
        document_id: documentId,
        ...this.exportForSave()
      })
    } catch (error) {
      console.error("[wasm-hwp] save failed", error)
      this.pushEvent("local_document.viewer_save", {
        request_id: requestId,
        document_id: documentId,
        error: String((error && error.message) || error)
      })
    }
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

// Public registration door: new ops register through the SAME chained registry
// (assets/js/wasm_ops.ts). `define` returns the builder for further chaining.
WasmHwpEditor.define = (verb, handler) => OPS.define(verb, handler)

export { WasmHwpEditor }
