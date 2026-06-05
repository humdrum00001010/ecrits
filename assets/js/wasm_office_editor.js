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

// Wall-clock origin for the staged bootstrap logs. Set when ensureRuntime first
// runs so every `[office-wasm] t+Nms: ...` line is relative to the load start;
// the top-level console timeline then pinpoints exactly where the bootstrap
// parks (runtime init vs. waiting for the API to materialize vs. timeout).
let bootT0 = 0
function tlog(...args) {
  const dt = bootT0 ? (performance.now() - bootT0) | 0 : 0
  console.log("[office-wasm] t+" + dt + "ms:", ...args)
}

function ensureRuntime() {
  if (runtimePromise) return runtimePromise

  bootT0 = performance.now()
  tlog("ensureRuntime() called; injecting glue", GLUE_URL)

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
      // So we let main() run and gate the API on the embind export becoming
      // callable (see the readiness poll below).
      //
      // WHY NOT `Module.uno_init`? (this was the prior gate, and it DEADLOCKED)
      // `Module.uno_init` (static/emscripten/uno.js) is the *interactive desktop
      // UNO-scripting* ready signal. It is resolved by initJsUnoScripting()
      // (appinit.cxx InitApplicationServiceManager / init.cxx lo_initialize) via
      // a `LOWA-channel` MessageChannel handshake — but ONLY once the desktop
      // bootstrap (soffice_main -> Desktop::Main) runs. In THIS headless build
      // (CONFIRMED from ~/Desktop/core) that bootstrap is kicked off lazily by
      // the FIRST `loadFromBytes` call: loadFromBytes -> ensure_office ->
      // lok::lok_cpp_init -> libreofficekit_hook_2 -> lo_initialize, which
      // osl_createThread(lo_startmain)->soffice_main->Desktop::Main
      // (desktop/source/lib/init.cxx:~8595). So `uno_init` never resolves until
      // loadFromBytes is called — yet our hook only calls loadFromBytes AFTER
      // ensureRuntime() (the uno_init gate) resolves. uno_init waits on
      // loadFromBytes; loadFromBytes waits on uno_init -> permanent hang on
      // "Loading office engine…". The correct LOK-build ready signal is simply
      // that the embind export (loadFromBytes) is registered & callable, which
      // happens during wasm runtime init (EMSCRIPTEN_BINDINGS(LokEditBindings),
      // static-linked --whole-archive) — i.e. by onRuntimeInitialized. The heavy
      // office init then happens lazily, synchronously, inside the first
      // loadFromBytes (ensure_office), which is fine.
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
        tlog("ABORT:", what)
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
        // `fail` (guarded by `settled`) is defined below in this executor scope.
        fail(
          new Error(
            "office WASM aborted: " + what + (dump ? " | last engine output: " + dump : "")
          )
        )
      }
    }
    window.Module = Module

    // READINESS GATE (LOK build): the editing API is the embind export
    // `loadFromBytes` (LokEditBindings.cxx), force-registered via
    // EMSCRIPTEN_BINDINGS during wasm runtime init. We do NOT wait on
    // `Module.uno_init` — that is the desktop UNO-scripting signal and only
    // resolves *inside* the first loadFromBytes call, which deadlocks against
    // this gate (see the long note in the Module config above). Instead we wait
    // for `loadFromBytes` to become callable (it should be present at/just after
    // onRuntimeInitialized) with a bounded poll, so a never-arriving export
    // surfaces a real error instead of an indefinite "Loading…".
    let settled = false
    const finish = () => {
      if (settled) return
      settled = true
      window.__officeWasmModule = Module
      tlog("bootstrap ready; document API available (loadFromBytes callable)")
      resolve(Module)
    }
    const fail = (err) => {
      if (settled) return
      settled = true
      reject(err)
    }

    const apiReady = () =>
      typeof Module.loadFromBytes === "function" || typeof Module._loadFromBytes === "function"

    // Diagnostic: surface what uno_init is doing in THIS build without gating on
    // it. If it ever resolves/rejects, the timeline shows it (expected: never,
    // until a doc is loaded) — proves whether uno_init was the wrong signal.
    const probeUnoInit = () => {
      const present = !!(Module.uno_init && typeof Module.uno_init.then === "function")
      tlog("uno_init present?", present, "(NOT gating on it; LOK build uses loadFromBytes)")
      if (present) {
        Module.uno_init.then(
          () => tlog("uno_init resolved (desktop UNO bootstrap complete — happens during/after first loadFromBytes)"),
          (err) => tlog("uno_init rejected", err && err.message || err)
        )
      }
    }

    const POLL_INTERVAL_MS = 50
    const POLL_MAX_MS = 120000 // 2 min: first instantiate of a 127MB wasm is slow
    Module.onRuntimeInitialized = () => {
      tlog("runtime initialized (wasm instantiated)")
      probeUnoInit()
      tlog("loadFromBytes present at runtimeInitialized?", apiReady())
      if (apiReady()) {
        finish()
        return
      }
      // Embind export not attached yet: poll until it is. Bounded so a missing
      // export (renamed/not linked) becomes a clear console error, not a hang.
      const deadline = performance.now() + POLL_MAX_MS
      let attempt = 0
      const poll = () => {
        if (settled) return
        attempt++
        const ok = apiReady()
        // Log first few attempts + then every ~2s so the timeline isn't noisy
        // but a stall is still visible (and never silent).
        if (attempt <= 3 || attempt % 40 === 0) {
          tlog("poll: loadFromBytes present?", ok, "(attempt " + attempt + ")")
        }
        if (ok) {
          finish()
        } else if (performance.now() >= deadline) {
          tlog("poll TIMEOUT after " + (POLL_MAX_MS / 1000) + "s — loadFromBytes never appeared")
          fail(new Error(
            "office WASM: embind export loadFromBytes did not become callable within " +
              (POLL_MAX_MS / 1000) + "s of runtime init. Module keys: " +
              Object.keys(Module).filter((k) => typeof Module[k] === "function").sort().join(", ") +
              "\nLast engine output:\n" + dumpLog()
          ))
        } else {
          setTimeout(poll, POLL_INTERVAL_MS)
        }
      }
      poll()
    }

    // Hard safety net: if onRuntimeInitialized itself never fires (wasm never
    // instantiates — e.g. SharedArrayBuffer/COOP-COEP missing in this tab, or a
    // glue/data 404 that doesn't trigger onAbort), don't sit on "Loading…"
    // forever. Surface a real error with the captured engine output.
    setTimeout(() => {
      if (settled || Module.calledRun) return
      tlog("WATCHDOG: runtime never initialized (calledRun=" + Module.calledRun +
        ", crossOriginIsolated=" + self.crossOriginIsolated +
        ", SharedArrayBuffer=" + (typeof SharedArrayBuffer) + ")")
      fail(new Error(
        "office WASM: runtime never initialized within 120s (wasm did not instantiate). " +
          "crossOriginIsolated=" + self.crossOriginIsolated +
          ", SharedArrayBuffer=" + (typeof SharedArrayBuffer) +
          ". This tab likely is not cross-origin isolated (needs COOP/COEP). Last engine output:\n" +
          dumpLog()
      ))
    }, 120000)

    const script = document.createElement("script")
    script.src = GLUE_URL
    script.async = true
    script.onload = () => tlog("glue script loaded (soffice.js)")
    script.onerror = () => {
      tlog("glue script FAILED to load", GLUE_URL)
      fail(new Error("failed to load " + GLUE_URL))
    }
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
    // The embind `loadFromBytes` takes a SINGLE argument (the byte buffer); the
    // format is auto-detected by LibreOffice's import-filter detection from the
    // content — passing a 2nd `format` arg throws
    // "called with 2 arguments, expected 1".
    const arg = this.toEmbindBytes(Module, bytes)

    if (this.api.shape === "embind-class") {
      const ctor = this.api.ctor
      if (typeof ctor.loadFromBytes === "function") {
        this.handle = ctor.loadFromBytes(arg)
      } else {
        this.handle = new ctor()
        this.handle.loadFromBytes(arg)
      }
      return
    }

    // module-functions shape: embind `loadFromBytes(bytes) -> bool`
    // (LokEditBindings.cxx) — true on success, false when documentLoad failed
    // (reason on stderr, captured in the ring).
    const ok = this.api.loadFromBytes(arg)
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
