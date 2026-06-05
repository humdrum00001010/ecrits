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

// Ring buffer of the last stderr/stdout lines. A WebAssembly `unreachable`
// trap (e.g. `O3TL_UNREACHABLE`/`std::unreachable` in the headless VCL event
// loop) reports only the generic "unreachable" — the REAL cause is whatever
// LibreOffice logged to stderr (SAL_WARN / "Bootstrapping exception ..." /
// documentLoad errors) immediately before. Keep them so we can surface them
// alongside the trap.
const stderrRing = []
const RING_MAX = 80
function pushLog(stream, text) {
  const line = "[" + stream + "] " + text
  stderrRing.push(line)
  if (stderrRing.length > RING_MAX) stderrRing.shift()
}
function dumpLog() {
  return stderrRing.slice(-40).join("\n")
}

function ensureRuntime() {
  if (runtimePromise) return runtimePromise

  runtimePromise = new Promise((resolve, reject) => {
    // NOTE: we do NOT pre-empt with a hardcoded "needs cross-origin isolation"
    // message. The Emscripten PThreads glue will surface the REAL failure itself
    // (e.g. a SharedArrayBuffer/`shared:true` memory error, a glue 404 via
    // script.onerror, or onAbort) — report that actual error, not an assumption.
    // A diagnostic only, non-fatal:
    if (typeof SharedArrayBuffer === "undefined" || !self.crossOriginIsolated) {
      console.warn(
        "[office-wasm] crossOriginIsolated=" + String(self.crossOriginIsolated) +
          ", SharedArrayBuffer=" + typeof SharedArrayBuffer +
          " — attempting load anyway; the glue will surface the real error if it can't run."
      )
    }

    // Emscripten reads this PRE-EXISTING global for config. The auto-running glue
    // (`var Module = typeof Module != "undefined" ? Module : {}`) picks it up.
    const Module = {
      locateFile: (path) => OFFICE_BASE + path,
      // pthread workers re-load the SAME script; point them at the static glue.
      mainScriptUrlOrBlob: GLUE_URL,
      // CRITICAL: this headless LibreOffice->WASM build MUST run its `main()`
      // (-> soffice_main -> Desktop::Main). Suppressing it (noInitialRun:true)
      // is what traps `unreachable`:
      //   * The LOK editing API (loadFromBytes -> lok_cpp_init ->
      //     libreofficekit_hook_2 -> lo_initialize, see LokEditBindings.cxx +
      //     desktop/source/lib/init.cxx) only works once the UNO component
      //     context + SfxApplication/Desktop are up — which the desktop
      //     bootstrap brings up.
      //   * That bootstrap drives the headless VCL event loop via
      //     SvpSalInstance::DoExecute (vcl/headless/svpinst.cxx), which calls
      //     emscripten_set_main_loop_arg(..., simulateInfiniteLoop=1) and then
      //     `O3TL_UNREACHABLE` (== std::unreachable == the wasm `unreachable`
      //     instruction). set_main_loop is meant to unwind the stack by throwing
      //     and KEEP the runtime alive via the JS event loop; that only works
      //     when reached from the runtime's own `main()`. With noInitialRun the
      //     loop machinery never gets a `main()` to unwind back to, so the
      //     `unreachable` after it is what actually executes -> the trap.
      //   * UNO bootstrap (initJsUnoScripting, desktop/source/app/
      //     initjsunoscripting.cxx) runs on the soffice pthread and uses
      //     emscripten_{sync,async}_run_in_main_runtime_thread — it REQUIRES the
      //     JS main thread to be free + pumping its proxy queue (i.e. inside the
      //     set_main_loop loop), not blocked inside a synchronous embind call.
      // So we let main() run and instead gate the API on `Module.uno_init`
      // (resolved by initJsUnoScripting once the bootstrap is ready) below.
      noInitialRun: false,
      // Standard soffice-WASM config: main() does not "exit" (it parks in the
      // emscripten main loop); don't let Emscripten tear down the runtime.
      ignoreApplicationExit: true,
      // Force headless and skip the IPC/socket pipe the desktop would normally
      // open (no UI / single instance handling in the browser).
      arguments: ["--headless", "--invisible", "--nologo", "--norestore", "--nolockcheck"],
      print: (text) => {
        pushLog("stdout", text)
        console.log("[office-wasm:stdout]", text)
      },
      printErr: (text) => {
        pushLog("stderr", text)
        console.warn("[office-wasm:stderr]", text)
      },
      onAbort: (what) => {
        const dump = dumpLog()
        console.error("[office-wasm] ABORT:", what)
        if (dump) console.error("[office-wasm] last engine output before abort:\n" + dump)
        try {
          console.error("[office-wasm] Module state:", {
            calledRun: Module.calledRun,
            runtimeInitialized: Module.runtimeInitialized,
            hasLoadFromBytes: typeof Module.loadFromBytes,
            hasUnoInit: typeof Module.uno_init,
            crossOriginIsolated: self.crossOriginIsolated
          })
        } catch (_) {}
        reject(
          new Error(
            "office WASM aborted: " + what + (dump ? " | last engine output: " + dump : "")
          )
        )
      },
      onRuntimeInitialized: () => {
        console.log("[office-wasm] runtime initialized (wasm instantiated); awaiting desktop bootstrap")
      }
    }
    window.Module = Module

    // The runtime is usable for the LOK editing API only AFTER the desktop/UNO
    // bootstrap finishes. The standard soffice-WASM glue exposes that as the
    // `Module.uno_init` promise (static/emscripten/uno.js, resolved from
    // initjsunoscripting.cxx). Prefer it; fall back to onRuntimeInitialized +
    // a loadFromBytes-presence poll if this build doesn't expose uno_init.
    let settled = false
    const finish = () => {
      if (settled) return
      settled = true
      window.__officeWasmModule = Module
      console.log("[office-wasm] bootstrap ready; document API available")
      resolve(Module)
    }

    Module.onRuntimeInitialized = () => {
      console.log("[office-wasm] runtime initialized (wasm instantiated); awaiting desktop bootstrap")
      if (Module.uno_init && typeof Module.uno_init.then === "function") {
        Module.uno_init.then(finish, (err) => {
          console.error("[office-wasm] uno_init rejected", err, "\n" + dumpLog())
          reject(new Error("office WASM bootstrap (uno_init) failed: " + (err && err.message || err)))
        })
      } else {
        // No uno_init in this build: wait until the embind export materializes
        // (it registers during bootstrap), then proceed. Bounded poll so a
        // never-arriving export becomes a clear error rather than a hang.
        let tries = 0
        const poll = () => {
          if (typeof Module.loadFromBytes === "function" || typeof Module._loadFromBytes === "function") {
            finish()
          } else if (++tries > 600) {
            reject(new Error(
              "office WASM: desktop bootstrap did not expose loadFromBytes within 30s. Last engine output:\n" + dumpLog()
            ))
          } else {
            setTimeout(poll, 50)
          }
        }
        poll()
      }
    }

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
      getDocumentType: direct("getDocumentType"),
      getParts: direct("getParts"),
      getPart: direct("getPart"),
      setPart: direct("setPart"),
      getPartPageRectangles: direct("getPartPageRectangles"),
      hitTest: direct("hitTest"),
      setTextSelection: direct("setTextSelection"),
      getTextSelection: direct("getTextSelection"),
      postKeyEvent: direct("postKeyEvent"),
      postUnoCommand: direct("postUnoCommand"),
      postWindowExtTextInputEvent: direct("postWindowExtTextInputEvent"),
      getCursor: direct("getCursor"),
      closeDocument: direct("closeDocument")
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
    // embind-class shape: the handle is a real C++ object -> delete().
    if (this.handle && typeof this.handle.delete === "function") {
      try {
        this.handle.delete()
      } catch (_) {}
    } else if (this.handle && this.api && this.api.closeDocument) {
      // module-functions shape: the single process-global doc is closed via the
      // closeDocument() export (LokEditBindings.cxx) before loading the next.
      try {
        this.api.closeDocument()
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
      const dump = dumpLog()
      console.error("[office-wasm] load failed", error)
      if (dump) console.error("[office-wasm] last engine output:\n" + dump)
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

    // module-functions shape: the embind `loadFromBytes(Uint8Array, fileName)`
    // returns a bool (LokEditBindings.cxx) — true on success, false when
    // documentLoad failed (the reason is on stderr, captured in the ring). Try
    // the typed array first; on TypeError fall back to a (ptr,len) heap copy for
    // a raw-C calling convention.
    let ok
    try {
      ok = this.api.loadFromBytes(bytes, this.format)
    } catch (e) {
      if (!(e instanceof TypeError)) throw e
      const ptr = Module._malloc(bytes.length)
      Module.HEAPU8.set(bytes, ptr)
      try {
        ok = this.api.loadFromBytes(ptr, bytes.length, this.format)
      } finally {
        Module._free(ptr)
      }
    }
    if (ok === false) {
      throw new Error("loadFromBytes returned false (open failed). Engine output:\n" + dumpLog())
    }
    this.handle = ok || true
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
      // Embind getDocumentSize() takes NO args and returns the ACTIVE part's
      // size; getParts() is the slide/sheet count (Impress/Calc) or 1 (Writer,
      // where pages come from getPartPageRectangles()). Walk parts via setPart.
      const count = callDoc("getParts")
      const n = typeof count === "number" ? count : Number(count) || 1
      const baseSize = this.parseSize(callDoc("getDocumentSize")) || { width: 794, height: 1123 }
      if (n > 1) {
        for (let i = 0; i < n; i++) {
          callDoc("setPart", i)
          parts.push(this.parseSize(callDoc("getDocumentSize")) || baseSize)
        }
        callDoc("setPart", 0)
      } else {
        parts.push(baseSize)
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
  // The embind binding (LokEditBindings.cxx) is:
  //   paintTile(part, tileX, tileY, tileW, tileH, canvasW, canvasH) -> Uint8Array
  // It RETURNS a canvasW*canvasH*4 RGBA buffer (already R/B-swapped from the
  // platform BGRA tile mode), painting the document twip rectangle
  // (tileX,tileY,tileW,tileH) into canvasW x canvasH device px. We blit the
  // returned bytes straight into the page <canvas> via ImageData.
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
      // Whole-page tile: origin (0,0), extent = page size in twips.
      const tileW = Math.round((part.width || 794) * 1440 / 96) // px -> twips
      const tileH = Math.round((part.height || 1123) * 1440 / 96)

      const rgba = this.callPaintTile(index, 0, 0, tileW, tileH, pxW, pxH)
      if (!rgba || !rgba.length) {
        throw new Error("paintTile returned no pixels (document not loaded?). Engine output:\n" + dumpLog())
      }
      // `rgba` is a Uint8Array view onto the wasm heap (typed_memory_view);
      // copy into a Uint8ClampedArray that backs ImageData.
      const buf = new Uint8ClampedArray(pxW * pxH * 4)
      buf.set(rgba.subarray(0, buf.length))
      const imageData = new ImageData(buf, pxW, pxH)
      const ctx = canvas.getContext("2d")
      if (ctx) ctx.putImageData(imageData, 0, 0)
      this.rendered.set(index, true)
    } catch (error) {
      console.error(`[office-wasm] renderPage(${index}) failed`, error)
      this.setStatus("Render failed on page " + (index + 1) + ": " + (error && error.message))
    }
  },

  // Call paintTile with the embind signature
  // (part, tileX, tileY, tileW, tileH, canvasW, canvasH) -> Uint8Array RGBA.
  callPaintTile(part, tileX, tileY, tileW, tileH, canvasW, canvasH) {
    const args = [part, tileX, tileY, tileW, tileH, canvasW, canvasH]
    if (this.api.shape === "embind-class" && this.handle && typeof this.handle.paintTile === "function") {
      return this.handle.paintTile(...args)
    }
    if (this.api.paintTile) return this.api.paintTile(...args)
    throw new Error("paintTile export not found")
  }
}

export { WasmOfficeEditor }
