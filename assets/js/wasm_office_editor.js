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
// Monotonic engine-output activity: bumped on every stdout/stderr line so the
// document-load watchdog can tell a still-working import (engine chattering)
// from a DEADLOCKED one (engine went silent while loadStatus stays "loading").
// The LibreOffice-WASM worker can wedge mid table-import (the writerfilter
// `createTextCursorByRange() failed` / "End of content node doesn't have the
// proper start node" path on VML-heavy / malformed-nesting docx): it emits its
// whole warning flood within the first seconds, then the worker neither finishes
// nor reports failure — loadStatus() is pinned at 1 forever. Native LibreOffice
// recovers from the same exception in <300ms, so this is a WASM-only import hang
// we cannot fix in the prebuilt binary; the watchdog turns the silent 120s hang
// into a fast, specific error.
let engineActivityAt = 0
const stallSeen = { cursorFail: false, badStartNode: false }
function noteEngineActivity(text) {
  engineActivityAt = performance.now()
  // Latch the table-import wedge signature so the watchdog error can be specific.
  if (/createTextCursorByRange\(\) failed/.test(text)) stallSeen.cursorFail = true
  if (/proper start node/.test(text)) stallSeen.badStartNode = true
}
function pushLog(stream, text) {
  const line = "[" + stream + "] " + text
  stderrRing.push(line)
  if (stderrRing.length > RING_MAX) stderrRing.shift()
  noteEngineActivity(text)
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

    // THE root office-load failure (captured live, top-level COI tab): the UNO
    // JS scripting bootstrap `runUnoScriptUrls` (run synchronously inside the
    // first `loadFromBytes`) calls `importScripts(...)` to load the UNO binding
    // scripts. `importScripts` is a Web Worker global; under -sPROXY_TO_PTHREAD
    // that code path runs on the JS MAIN thread (window), where importScripts is
    // undefined → `ReferenceError: importScripts is not defined` → init fails and
    // LOK caches it as "lok office init previously failed". Provide a main-thread
    // polyfill: load each URL synchronously and eval it in GLOBAL scope (matching
    // importScripts semantics). The scripts are same-origin (served under
    // /assets/office/ via locateFile), so a synchronous XHR is fine. The guard
    // leaves the real importScripts untouched inside actual pthread Workers.
    if (typeof self.importScripts !== "function") {
      self.importScripts = function (...urls) {
        for (const u of urls) {
          const url = /^(https?:|blob:|\/)/.test(u) ? u : OFFICE_BASE + u
          tlog("importScripts(polyfill) GET", url)
          const xhr = new XMLHttpRequest()
          xhr.open("GET", url, false)
          xhr.send()
          if (xhr.status && (xhr.status < 200 || xhr.status >= 300)) {
            throw new Error("importScripts polyfill: GET " + url + " -> " + xhr.status)
          }
          // indirect eval -> global scope, like importScripts
          ;(0, eval)(xhr.responseText)
        }
      }
    }

    // Emscripten reads this PRE-EXISTING global for config. The auto-running glue
    // (`var Module = typeof Module != "undefined" ? Module : {}`) picks it up.
    const Module = {
      locateFile: (path) => OFFICE_BASE + path,
      // pthread workers re-load the SAME script; point them at the static glue.
      mainScriptUrlOrBlob: GLUE_URL,
      // CRITICAL — RUN the auto `main()` (noInitialRun:false).
      //
      // This is the headless LibreOffice-Technology->WASM *LOK editing* build
      // (static/source/unoembindhelpers/LokEditBindings.cxx), compiled with
      // -sPROXY_TO_PTHREAD (HAVE_EMSCRIPTEN_PROXY_TO_PTHREAD=1) and JSPI OFF.
      //
      // Under -sPROXY_TO_PTHREAD the emscripten runtime ONLY spins up its
      // "main" runtime thread (the proxy-main pthread) when callMain() runs,
      // i.e. when noInitialRun is FALSE — callMain's entry is
      // __emscripten_proxy_main, which spawns that pthread and runs the C
      // main(). With noInitialRun:true that pthread is NEVER created, so there
      // is no LO main/event-loop thread at all; the lazy embind loadFromBytes
      // then runs lo_initialize ON THE BROWSER JS MAIN THREAD, which spawns the
      // lo_startmain pthread and immediately blocks in RequestHandler::
      // WaitForReady(). But a worker pthread can only finish starting while the
      // JS main thread is free to service the Worker handshake — and it is
      // blocked — so lo_startmain never runs, readiness is never signalled, and
      // init fails; LokEditBindings caches that as "lok office init previously
      // failed" (the symptom). (desktop/source/lib/init.cxx ~8595; emscripten
      // libeventloop/libpthread; see static/README.wasm.md "Threads and the
      // event loop".)
      //
      // THE FIX (build-level): the WASM main() (desktop/source/app/main.c, our
      // __EMSCRIPTEN__ branch) calls libreofficekit_hook_2("/instdir", NULL) so
      // the ONE UNO/VCL bootstrap + the parked svp event loop come up on the
      // proxy-main pthread, with the browser JS main thread free to service the
      // lo_startmain Worker spawn and the emscripten main-runtime-thread
      // proxied calls (getUnoScriptUrls reading location.href in
      // initjsunoscripting.cxx). libreofficekit_hook_2 -> lo_initialize is
      // idempotent (static alreadyCalled / bInitialized guards, init.cxx:8343,
      // 8646), so the first embind loadFromBytes -> ensure_office ->
      // lok_cpp_init -> libreofficekit_hook_2 REUSES the same gImpl (no second
      // component-context bootstrap, no second soffice_main).
      //
      // We must therefore wait for the bootstrap to COMPLETE before the first
      // loadFromBytes (see the uno_init gate below) so ensure_office never wins
      // the race and re-enters lo_initialize on the JS main thread.
      noInitialRun: false,
      // Standard soffice-WASM config: the soffice runtime thread does not
      // "exit" (it parks in the emscripten main loop); don't let Emscripten
      // tear down the runtime.
      ignoreApplicationExit: true,
      // LOK-FULLY-READY gate (THE first-load fix). Our WASM main()
      // (desktop/source/app/main.c) runs libreofficekit_hook_2 -> lo_initialize,
      // which BLOCKS in RequestHandler::WaitForReady() until lo_startmain's
      // Desktop::Main() has completed InitVCL() (ImplSVData / solar mutex up) and
      // reached SetReady(true). Only THEN does main() set the shared
      // lok_is_ready() flag and park the runtime. We MUST gate the first
      // loadFromBytes on lok_is_ready() (polled below) — NOT on Module.uno_main,
      // which initJsUnoScripting() resolves from inside initialize_uno() at the
      // very START of lo_initialize (before InitVCL), so a load gated on uno_main
      // races VCL startup and the first lo_documentLoadWithOptions()'s
      // SolarMutexGuard dereferences a not-yet-initialized ImplSVData -> "memory
      // access out of bounds" (which then poisons LokState::init_done as "lok
      // office init previously failed"). A JS Module promise can't carry this
      // signal: main() runs in the soffice-main pthread Worker whose Module is a
      // different object from this (window) Module, so it can't resolve a promise
      // we hold here — but the wasm memory is a SharedArrayBuffer, so the embind
      // lok_is_ready() reads the flag main()'s worker stored.
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

    // READINESS GATE (LOK build, noInitialRun:false): TWO things must be true
    // before the first loadFromBytes:
    //   1. the embind export `loadFromBytes` is callable (force-registered via
    //      EMSCRIPTEN_BINDINGS at wasm runtime init), AND
    //   2. main()->libreofficekit_hook_2->lo_initialize has FULLY completed,
    //      including RequestHandler::WaitForReady() (i.e. lo_startmain's
    //      Desktop::Main has run InitVCL and the solar mutex / ImplSVData are
    //      live). main() signals that by setting the shared flag the embind
    //      Module.lok_is_ready() reads (polled below). Gating on lok_is_ready()
    //      — NOT uno_main, which fires mid-init before InitVCL — guarantees the
    //      first lo_documentLoadWithOptions() finds a fully-initialized VCL and
    //      does not trap in SolarMutexGuard.
    let settled = false
    let unoReady = false
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

    const exportReady = () =>
      typeof Module.loadFromBytes === "function" || typeof Module._loadFromBytes === "function"
    // The embind `lok_is_ready()` reads the shared flag main() sets once
    // lo_initialize has fully completed (past WaitForReady/InitVCL). Ready to
    // load a document only when the export exists AND LOK is fully ready.
    const lokReady = () => {
      try {
        return typeof Module.lok_is_ready === "function" && Module.lok_is_ready() === true
      } catch (_) {
        return false
      }
    }
    const apiReady = () => exportReady() && (unoReady || lokReady())

    // Bootstrap-complete signal: main() sets lok_is_ready() ONLY after
    // libreofficekit_hook_2 -> lo_initialize fully returns (past WaitForReady /
    // InitVCL). uno_main fires too early (mid initialize_uno, before InitVCL) and
    // gating on it caused the first-load SolarMutexGuard OOB, so we poll
    // lok_is_ready() instead. A grace fallback bounds the wait so a missing
    // lok_is_ready export can never reproduce a 120s hang (the export being
    // attached means the bindings are live; a real load failure self-reports).
    const GRACE_MS = 30000
    const probeUnoInit = () => {
      tlog("gating on lok_is_ready() (full-VCL-ready); export=", exportReady())
      setTimeout(() => {
        if (settled || unoReady) return
        if (exportReady()) {
          tlog("lok_is_ready() not true within " + GRACE_MS + "ms but export is live — proceeding")
          unoReady = true
          finish()
        }
      }, GRACE_MS)
    }

    const POLL_INTERVAL_MS = 50
    const POLL_MAX_MS = 120000 // 2 min: first instantiate of a 127MB wasm is slow
    Module.onRuntimeInitialized = () => {
      tlog("runtime initialized (wasm instantiated)")
      probeUnoInit()
      tlog("ready at runtimeInitialized? export=", exportReady(), "uno=", unoReady)
      if (apiReady()) {
        finish()
        return
      }
      // Not both gates yet: poll until the embind export is attached AND the UNO
      // bootstrap (uno_init) has resolved. Bounded so a missing export or a
      // never-completing bootstrap becomes a clear console error, not a hang.
      // (uno_init resolving also calls finish() directly from its .then above.)
      const deadline = performance.now() + POLL_MAX_MS
      let attempt = 0
      const poll = () => {
        if (settled) return
        attempt++
        const ok = apiReady()
        // Log first few attempts + then every ~2s so the timeline isn't noisy
        // but a stall is still visible (and never silent).
        if (attempt <= 3 || attempt % 40 === 0) {
          tlog("poll: export=", exportReady(), "lokReady=", lokReady(), "(attempt " + attempt + ")")
        }
        if (ok) {
          finish()
        } else if (performance.now() >= deadline) {
          tlog("poll TIMEOUT after " + (POLL_MAX_MS / 1000) + "s — export=" +
            exportReady() + " uno=" + unoReady)
          fail(new Error(
            "office WASM: not ready within " + (POLL_MAX_MS / 1000) +
              "s of runtime init (loadFromBytes export present=" + exportReady() +
              ", UNO bootstrap uno_init resolved=" + unoReady + "). Module keys: " +
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
      loadStatus: direct("loadStatus"),
      getPartSizesJson: direct("getPartSizesJson"),
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
    // Serialize loads: the hook fires loadDocument both on mount AND on the
    // server's `office_wasm_load` push, which can race two concurrent
    // (async, worker-dispatched) loadFromBytes for the same URL — overwriting
    // the in-progress import and crashing. Chain on the previous load and skip
    // a duplicate URL that is already loading.
    if (this._loadInFlight) {
      if (this._loadingUrl === url) return this._loadInFlight
      try { await this._loadInFlight } catch (_) {}
      if (this.loadedUrl === url && this.parts.length) return
    }
    this._loadingUrl = url
    this._loadInFlight = (async () => {
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
      await this.openWithBytes(Module, bytes)
      this.loadedUrl = url

      this.parts = this.queryParts()
      console.log("[office-wasm] parts/geometry:", this.parts)
      this.setStatus("")
      // A clean load clears any prior one-shot reload guard for this document.
      try { sessionStorage.removeItem("office-wasm-retry:" + url) } catch (_) {}
      this.buildPageStack()
      this.renderVisiblePages()
    } catch (error) {
      const dump = dumpLog()
      console.error("[office-wasm] load failed", error)
      if (dump) console.error("[office-wasm] last engine output:\n" + dump)

      // A LOK init failure POISONS the heavy WASM runtime singleton for the WHOLE
      // page session: once `ensure_office` fails, every later loadFromBytes short-
      // circuits to "lok office init previously failed", masking the real first
      // error. The runtime can't be re-instantiated in place — re-injecting the
      // 144MB pthreads glue beside the dead instance risks a SharedArrayBuffer/OOM
      // clash — so the only reliable recovery is a fresh page. Self-heal with ONE
      // guarded full reload per document (sessionStorage guard => can never loop);
      // if the load still fails after a clean reload, surface the error so the user
      // isn't stuck in a reload cycle.
      const msg = (error && error.message) || String(error)
      const poisoned = /previously failed|importScripts|postMessage|abort\(|unreachable/i.test(msg + "\n" + dump)
      const retryKey = "office-wasm-retry:" + url
      let alreadyRetried = false
      try { alreadyRetried = !!sessionStorage.getItem(retryKey) } catch (_) {}

      if (poisoned && !alreadyRetried) {
        try { sessionStorage.setItem(retryKey, "1") } catch (_) {}
        this.setStatus("Office engine hit a failed state — reloading to recover…")
        setTimeout(() => location.reload(), 1200)
        return
      }

      this.setStatus(
        "Office WASM failed to load: " + msg + " — reload the page (Cmd/Ctrl+Shift+R) to retry."
      )
    }
    })()
    try {
      await this._loadInFlight
    } finally {
      this._loadInFlight = null
      this._loadingUrl = null
    }
  },

  // Hand the document bytes to the engine. loadFromBytes is ASYNCHRONOUS
  // (LokEditBindings.cxx): it kicks the real documentLoad() onto a dedicated LOK
  // worker pthread (so a heavy Impress/PowerPoint import that blocks internally
  // never freezes the browser main thread) and returns immediately. We then poll
  // the embind loadStatus() (0 idle, 1 loading, 2 done, 3 failed) until the load
  // settles. The 2-arg signature (bytes, fileName) selects LibreOffice's import
  // filter from the extension.
  async openWithBytes(Module, bytes) {
    const arg = this.toEmbindBytes(Module, bytes)
    const fileName = "document." + (this.format || "docx")

    if (this.api.shape === "embind-class") {
      const ctor = this.api.ctor
      if (typeof ctor.loadFromBytes === "function") {
        this.handle = ctor.loadFromBytes(arg, fileName)
      } else {
        this.handle = new ctor()
        this.handle.loadFromBytes(arg, fileName)
      }
      return
    }

    // module-functions shape: async loadFromBytes(bytes, fileName) -> void;
    // poll loadStatus() for completion.
    // Reset the per-load stall signal so a PRIOR document's wedge signature /
    // engine chatter never bleeds into this load's watchdog decision.
    stallSeen.cursorFail = false
    stallSeen.badStartNode = false
    engineActivityAt = 0
    this.api.loadFromBytes(arg, fileName)
    if (typeof this.api.loadStatus === "function") {
      const start = performance.now()
      const deadline = start + 120000 // 2 min hard ceiling: large Impress imports
      // Idle-stall watchdog. The import runs on a LOK worker pthread; a wedged
      // table-import deadlocks the worker (loadStatus pinned at 1) while it stops
      // emitting ANY output. We detect that by watching engine-output activity:
      // once the engine has spoken (warning flood) AND then gone quiet for
      // STALL_IDLE_MS with no forward status change, the load is dead — bail fast
      // with a specific error instead of blocking the user for the full 120s.
      const STALL_IDLE_MS = 25000
      // Don't arm the watchdog until the engine has produced SOME output for this
      // load (so a clean, fast, silent load is never misjudged as stalled) and a
      // floor of wall time has passed (the worker needs a beat to spin up).
      const STALL_ARM_MS = 8000
      // eslint-disable-next-line no-constant-condition
      while (true) {
        const st = this.api.loadStatus()
        if (st === 2) break
        if (st === 3) {
          throw new Error("loadFromBytes failed (documentLoad). Engine output:\n" + dumpLog())
        }
        const now = performance.now()
        if (now >= deadline) {
          throw new Error("loadFromBytes timed out after 120s. Engine output:\n" + dumpLog())
        }
        // Stall detection: still "loading" (st === 1), the engine emitted output
        // earlier in THIS load, and it has been silent past the idle window.
        if (
          st === 1 &&
          now - start >= STALL_ARM_MS &&
          engineActivityAt > 0 &&
          now - engineActivityAt >= STALL_IDLE_MS
        ) {
          const tableWedge = stallSeen.cursorFail || stallSeen.badStartNode
          const detail = tableWedge
            ? "the document's table layout wedged LibreOffice's importer " +
              "(createTextCursorByRange/\"proper start node\") — this docx can't be " +
              "opened in the in-browser office viewer"
            : "the office engine stopped responding mid-import"
          throw new Error(
            "loadFromBytes stalled after " +
              Math.round((now - start) / 1000) +
              "s (engine silent " +
              Math.round((now - engineActivityAt) / 1000) +
              "s): " +
              detail +
              ".\nEngine output:\n" +
              dumpLog()
          )
        }
        await new Promise((r) => setTimeout(r, 50))
      }
    }
    this.handle = true
  },

  toEmbindBytes(Module, bytes) {
    // Embind `std::vector<uint8_t>` / typed_memory_view both accept a JS
    // Uint8Array argument directly in modern emscripten; pass it through.
    return bytes
  },

  // Resolve page/slide geometry to [{ width, height }] in page-local px.
  // PREFERRED: getPartSizesJson() returns the WHOLE document's geometry cached
  // (in twips) on the LOK worker during load — a single cheap read with NO
  // proxy, so the browser main thread never blocks (a per-part getParts/setPart/
  // getDocumentSize storm would block it and can crash on Impress layout).
  queryParts() {
    if (this.api.shape === "module-functions" && typeof this.api.getPartSizesJson === "function") {
      try {
        const info = JSON.parse(this.api.getPartSizesJson())
        const parts = (info.parts || [])
          .map((p) => this.parseSize(p))
          .filter(Boolean)
        if (parts.length) return parts
      } catch (error) {
        console.warn("[office-wasm] getPartSizesJson failed, falling back", error)
      }
    }

    // Fallback (embind-class shape or missing getter): walk parts directly.
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
