// Browser-WASM office (docx/pptx) editor hook — the CLIENT INTERACTIVE ARM of
// the office dual-arch.
//
// This mirrors the HWP WASM editor (`wasm_office_editor.js`'s sibling
// `wasm_hwp_editor.js`): the browser loads a LibreOffice->WASM build and does
// open + render (and, as a stretch, hit-test + edit) locally on a per-page
// `<canvas>`. The server keeps the raw bytes as the source of truth.
//
// HOW IT DIFFERS FROM THE HWP HOOK
// --------------------------------
// rhwp_core is a clean `wasm-bindgen --target web` ES module: `import init,
// {HwpDocument}` Just Works under esbuild. The LibreOffice build is instead a
// classic *auto-running Emscripten PThreads* module (`var Module = ...`): it
// can't be `import`-ed cleanly (esbuild would mangle its `import.meta`/worker
// bootstrap), and it needs a *shared* WebAssembly.Memory, i.e. the page must be
// cross-origin isolated (SharedArrayBuffer). So we:
//   1. require `crossOriginIsolated` (COOP/COEP set by CrossOriginIsolationPlug),
//   2. configure a global `Module` (locateFile + mainScriptUrlOrBlob for pthread
//      workers + onRuntimeInitialized),
//   3. inject `/assets/office/soffice.js` as a <script> (NOT bundled by esbuild),
//   4. once the runtime is up, discover the document API on `Module` and render.
//
// THE CUSTOM EXPORTS
// ------------------
// The build exposes (per the build manifest): loadFromBytes, saveToBytes,
// paintTile, getDocumentSize, getParts, hitTest, setTextSelection, postKeyEvent,
// postWindowExtTextInputEvent. Emscripten can surface these either as Embind
// methods on `Module` / a returned document handle, or as C exports reachable
// via `Module.ccall`/`cwrap` / `Module._loadFromBytes`. We probe for both shapes
// at runtime (`resolveApi`) rather than hard-coding one calling convention, and
// log the resolved surface so a missing/renamed export is a clear console error
// (not a silent blank canvas).

const OFFICE_BASE = "/assets/office/"
const GLUE_URL = OFFICE_BASE + "soffice.js"

// Module-level singleton: the Emscripten runtime is heavy (127MB wasm + 82MB
// data) and pthread-based; we instantiate it ONCE per page load and share it
// across hook instances.
let runtimePromise = null

function ensureRuntime() {
  if (runtimePromise) return runtimePromise

  runtimePromise = new Promise((resolve, reject) => {
    if (typeof SharedArrayBuffer === "undefined" || !self.crossOriginIsolated) {
      reject(
        new Error(
          "office WASM needs cross-origin isolation (SharedArrayBuffer). " +
            "crossOriginIsolated=" + String(self.crossOriginIsolated)
        )
      )
      return
    }

    // Emscripten reads this PRE-EXISTING global for config. The auto-running glue
    // (`var Module = typeof Module != "undefined" ? Module : {}`) picks it up.
    const Module = {
      locateFile: (path) => OFFICE_BASE + path,
      // pthread workers re-load the SAME script; point them at the static glue.
      mainScriptUrlOrBlob: GLUE_URL,
      // Don't run LibreOffice's `main()` (it would try to bring up the full Qt/VCL
      // desktop UI). We only want the runtime + the document API exports.
      noInitialRun: true,
      print: (text) => console.log("[office-wasm:stdout]", text),
      printErr: (text) => console.warn("[office-wasm:stderr]", text),
      onAbort: (what) => {
        console.error("[office-wasm] aborted", what)
        reject(new Error("office WASM aborted: " + what))
      },
      onRuntimeInitialized: () => {
        console.log("[office-wasm] runtime initialized")
        window.__officeWasmModule = Module
        resolve(Module)
      }
    }
    window.Module = Module

    const script = document.createElement("script")
    script.src = GLUE_URL
    script.async = true
    script.onerror = () => reject(new Error("failed to load " + GLUE_URL))
    document.head.appendChild(script)
  })

  return runtimePromise
}

// Probe `Module` for the document API. Returns an object whose methods are
// normalized so the rest of the hook doesn't care which binding shape the build
// used. Throws (with a descriptive message) when the core entrypoint
// (`loadFromBytes`) can't be found at all.
function resolveApi(Module) {
  // 1) Embind free functions / C exports directly on Module.
  const direct = (name) =>
    typeof Module[name] === "function"
      ? Module[name].bind(Module)
      : typeof Module["_" + name] === "function"
        ? Module["_" + name].bind(Module)
        : null

  const loadFromBytes = direct("loadFromBytes")
  if (loadFromBytes) {
    return {
      shape: "module-functions",
      loadFromBytes,
      saveToBytes: direct("saveToBytes"),
      paintTile: direct("paintTile"),
      getDocumentSize: direct("getDocumentSize"),
      getParts: direct("getParts"),
      hitTest: direct("hitTest"),
      setTextSelection: direct("setTextSelection"),
      postKeyEvent: direct("postKeyEvent"),
      postWindowExtTextInputEvent: direct("postWindowExtTextInputEvent")
    }
  }

  // 2) Embind class: a constructor/factory on Module returns a doc handle whose
  //    prototype carries the methods. Look for a likely class name.
  const classNames = ["Document", "LOKDocument", "OfficeDocument", "Office", "Doc"]
  for (const cn of classNames) {
    const ctor = Module[cn]
    if (typeof ctor === "function") {
      const proto = ctor.prototype || {}
      if (typeof proto.loadFromBytes === "function" || typeof ctor.loadFromBytes === "function") {
        return { shape: "embind-class", ctor, className: cn }
      }
    }
  }

  // Nothing matched: dump what IS on Module so the failure is diagnosable.
  const keys = Object.keys(Module)
    .filter((k) => typeof Module[k] === "function" || /^(load|save|paint|get|hit|set|post)/i.test(k))
    .sort()
  throw new Error(
    "office WASM: could not find loadFromBytes on Module. Candidate keys: " +
      keys.join(", ")
  )
}

const WasmOfficeEditor = {
  mounted() {
    this.api = null
    this.handle = null // document handle (embind-class shape) or null
    this.parts = [] // [{ width, height }] page/slide geometry, page-local px
    this.rendered = new Map() // pageIndex -> true
    this.visible = new Set()
    this.scale = window.devicePixelRatio || 1

    this.pageStack = this.el.querySelector("[data-role='office-wasm-pages']")
    this.statusEl = this.el.querySelector("[data-role='office-wasm-status']")

    this.documentId = this.el.dataset.documentId
    this.format = this.el.dataset.localDocumentFormat || "docx"

    this.setStatus("Loading office engine… (large WASM, first load is slow)")

    // Pre-warm + load on mount. The host element carries the bytes URL; the
    // server also pushes `office_wasm_load` (re-open / revision change).
    this.handleEvent("office_wasm_load", (payload) => this.loadDocument(payload))
    const bytesUrl = this.el.dataset.bytesUrl
    if (bytesUrl) this.loadDocument({ url: bytesUrl })

    this.onResize = () => this.renderVisiblePages()
    window.addEventListener("resize", this.onResize)

    // Lazy render: only rasterize pages near the viewport.
    this.io = new IntersectionObserver(
      (entries) => {
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

    window.__officeWasmEditor = this
  },

  destroyed() {
    if (this.io) this.io.disconnect()
    window.removeEventListener("resize", this.onResize)
    this.freeHandle()
    if (window.__officeWasmEditor === this) window.__officeWasmEditor = null
  },

  setStatus(text) {
    if (this.statusEl) this.statusEl.textContent = text || ""
  },

  freeHandle() {
    if (this.handle && typeof this.handle.delete === "function") {
      try {
        this.handle.delete()
      } catch (_) {}
    }
    this.handle = null
  },

  async loadDocument({ url }) {
    if (this.loadedUrl === url && this.parts.length) return
    try {
      const Module = await ensureRuntime()
      if (!this.api) {
        this.api = resolveApi(Module)
        console.log("[office-wasm] API shape:", this.api.shape, this.api)
      }
      this.setStatus("Fetching document…")
      const response = await fetch(url, { credentials: "same-origin" })
      if (!response.ok) throw new Error(`document bytes HTTP ${response.status}`)
      const bytes = new Uint8Array(await response.arrayBuffer())

      this.setStatus("Opening document…")
      this.freeHandle()
      this.openWithBytes(Module, bytes)
      this.loadedUrl = url

      this.parts = this.queryParts()
      console.log("[office-wasm] parts/geometry:", this.parts)
      this.setStatus("")
      this.buildPageStack()
      this.renderVisiblePages()
    } catch (error) {
      console.error("[office-wasm] load failed", error)
      this.setStatus("Office WASM failed to load: " + (error && error.message))
    }
  },

  // Hand the document bytes to the engine, copying into the wasm heap when the
  // export expects a (ptr,len) pair rather than a JS typed array.
  openWithBytes(Module, bytes) {
    if (this.api.shape === "embind-class") {
      const ctor = this.api.ctor
      // Try static factory first, then `new`.
      if (typeof ctor.loadFromBytes === "function") {
        this.handle = ctor.loadFromBytes(this.toEmbindBytes(Module, bytes), this.format)
      } else {
        this.handle = new ctor()
        this.handle.loadFromBytes(this.toEmbindBytes(Module, bytes), this.format)
      }
      return
    }

    // module-functions shape: the export may accept (Uint8Array) [Embind] or
    // (ptr, len) [raw C]. Try the typed array first; on TypeError fall back to a
    // heap copy.
    try {
      this.handle = this.api.loadFromBytes(bytes, this.format) || true
    } catch (_) {
      const ptr = Module._malloc(bytes.length)
      Module.HEAPU8.set(bytes, ptr)
      try {
        this.handle = this.api.loadFromBytes(ptr, bytes.length, this.format) || true
      } finally {
        Module._free(ptr)
      }
    }
  },

  toEmbindBytes(Module, bytes) {
    // Embind `std::vector<uint8_t>` / typed_memory_view both accept a JS
    // Uint8Array argument directly in modern emscripten; pass it through.
    return bytes
  },

  // Resolve page/slide geometry to [{ width, height }] in page-local px.
  queryParts() {
    const callDoc = (name, ...args) => {
      if (this.api.shape === "embind-class" && this.handle && typeof this.handle[name] === "function") {
        return this.handle[name](...args)
      }
      if (this.api[name]) return this.api[name](...args)
      return undefined
    }

    let parts = []
    try {
      const count = callDoc("getParts")
      const n = typeof count === "number" ? count : Number(count) || 1
      const sizeRaw = callDoc("getDocumentSize", 0)
      const size = this.parseSize(sizeRaw)
      for (let i = 0; i < Math.max(1, n); i++) {
        const ps = this.parseSize(callDoc("getDocumentSize", i)) || size
        parts.push(ps || { width: 794, height: 1123 })
      }
    } catch (error) {
      console.warn("[office-wasm] queryParts failed, defaulting to A4", error)
      parts = [{ width: 794, height: 1123 }]
    }
    if (!parts.length) parts = [{ width: 794, height: 1123 }]
    return parts
  },

  // getDocumentSize may return a JSON string, an object {width,height}, or a
  // twips/100thmm pair. Normalize to CSS px @96dpi (best-effort).
  parseSize(raw) {
    if (!raw) return null
    let v = raw
    if (typeof raw === "string") {
      try {
        v = JSON.parse(raw)
      } catch (_) {
        const m = raw.match(/(\d+)\D+(\d+)/)
        if (m) v = { width: Number(m[1]), height: Number(m[2]) }
      }
    }
    if (v && typeof v === "object") {
      let w = Number(v.width ?? v.w ?? v[0])
      let h = Number(v.height ?? v.h ?? v[1])
      if (!(w > 0) || !(h > 0)) return null
      // Heuristic: LOK reports twips (1/1440") for text; convert to 96dpi px.
      // A4 in twips is ~11906x16838 -> px ~794x1123. If the value is far larger
      // than a screen page, assume twips and scale.
      if (w > 5000 || h > 5000) {
        w = Math.round((w / 1440) * 96)
        h = Math.round((h / 1440) * 96)
      }
      return { width: Math.max(1, w), height: Math.max(1, h) }
    }
    return null
  },

  buildPageStack() {
    if (!this.pageStack) return
    this.rendered.clear()
    this.visible.clear()
    this.pageStack.replaceChildren()
    if (this.io) this.io.disconnect()

    this.parts.forEach((part, i) => {
      const w = Math.max(1, Math.round(part.width || 794))
      const h = Math.max(1, Math.round(part.height || 1123))

      const section = document.createElement("section")
      section.dataset.role = "office-wasm-page"
      section.dataset.pageIndex = String(i)
      section.dataset.pageNumber = String(i + 1)
      section.className = "relative bg-white shadow-sm border border-base-300"
      section.style.cssText = `width:${w}px;max-width:100%;aspect-ratio:${w} / ${h};position:relative`

      const canvas = document.createElement("canvas")
      canvas.dataset.role = "office-wasm-canvas"
      canvas.width = Math.round(w * this.scale)
      canvas.height = Math.round(h * this.scale)
      canvas.style.cssText = "display:block;width:100%;height:100%"
      const ctx = canvas.getContext("2d")
      if (ctx) {
        ctx.fillStyle = "#ffffff"
        ctx.fillRect(0, 0, canvas.width, canvas.height)
      }

      section.appendChild(canvas)
      this.pageStack.appendChild(section)
      this.io.observe(section)
    })
  },

  pageSection(index) {
    return (
      this.pageStack &&
      this.pageStack.querySelector(`[data-role='office-wasm-page'][data-page-index='${index}']`)
    )
  },

  renderVisiblePages() {
    for (const idx of this.visible) this.renderPage(idx)
    if (this.visible.size === 0 && this.parts.length > 0) this.renderPage(0)
  },

  // Paint a page/slide via the engine's paintTile into the page <canvas>.
  // paintTile is the LOK convention:
  //   paintTile(part, buffer, canvasW, canvasH, tilePosX, tilePosY, tileW, tileH)
  // where canvas px are device px and tilePos/tileW are in twips. The engine
  // writes BGRA/RGBA into a heap buffer that we blit via ImageData. Because the
  // exact binding shape is build-specific, we attempt the heap-buffer convention
  // and surface any failure clearly.
  renderPage(index) {
    if (!this.api) return
    const section = this.pageSection(index)
    if (!section) return
    const canvas = section.querySelector("[data-role='office-wasm-canvas']")
    if (!canvas) return

    const part = this.parts[index] || this.parts[0]
    const pxW = canvas.width
    const pxH = canvas.height

    try {
      const Module = window.__officeWasmModule

      // Heap RGBA buffer the engine paints into.
      const bytes = pxW * pxH * 4
      const ptr = Module._malloc(bytes)
      try {
        const tileW = Math.round((part.width || 794) * 1440 / 96) // px -> twips
        const tileH = Math.round((part.height || 1123) * 1440 / 96)

        this.callPaintTile(Module, index, ptr, pxW, pxH, 0, 0, tileW, tileH)

        const buf = new Uint8ClampedArray(Module.HEAPU8.buffer, ptr, bytes).slice()
        const imageData = new ImageData(buf, pxW, pxH)
        const ctx = canvas.getContext("2d")
        if (ctx) ctx.putImageData(imageData, 0, 0)
        this.rendered.set(index, true)
      } finally {
        Module._free(ptr)
      }
    } catch (error) {
      console.error(`[office-wasm] renderPage(${index}) failed`, error)
      this.setStatus("Render failed on page " + (index + 1) + ": " + (error && error.message))
    }
  },

  callPaintTile(Module, part, ptr, canvasW, canvasH, tilePosX, tilePosY, tileW, tileH) {
    const args = [part, ptr, canvasW, canvasH, tilePosX, tilePosY, tileW, tileH]
    if (this.api.shape === "embind-class" && this.handle && typeof this.handle.paintTile === "function") {
      return this.handle.paintTile(...args)
    }
    if (this.api.paintTile) return this.api.paintTile(...args)
    throw new Error("paintTile export not found")
  }
}

export { WasmOfficeEditor }
