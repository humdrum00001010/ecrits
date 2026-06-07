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
      closeDocument: direct("closeDocument"),
      // O5b agent-edit verbs (LokEditBindings embind free-functions): the IR
      // read, the structured edit, and the property set the office `doc.*`
      // browser arm drives. The build registers `getElements` (NOT `elements`);
      // probe `elements` too so a future rename still resolves.
      getElements: direct("getElements") || direct("elements"),
      unoApply: direct("uno_apply"),
      unoSet: direct("uno_set")
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
    // Per-page document-twip rectangles {x,y,w,h} from getPartPageRectangles(),
    // index 0 == page 1. Used to map page-local px <-> absolute document twips so
    // setTextSelection (which takes document twips) can be driven from a mouse
    // drag whose coords are page-local px.
    this.pageRects = []
    this.rendered = new Map() // pageIndex -> true
    this.visible = new Set()
    this.scale = window.devicePixelRatio || 1

    // ─── Interactive-edit state (mirrors wasm_hwp_editor.js) ────────────────
    // LOK owns the real text cursor + selection internally; we only TRACK the
    // caret rect for rendering. caret = { page (1-based), x, y, height } in
    // page-local px (the shape getCursor()/hitTest() return), or null.
    this.caret = null
    this.caretBlinkOn = true
    // Live drag-select gesture (set only while the primary button is held).
    //   dragSelect = { page, startX, startY, moved }  (px, page-local)
    this.dragSelect = null
    // True while an active LOK selection exists (so typing/keys know to let LOK
    // replace it and we know to repaint).
    this.hasActiveSelection = false
    // True while the OS IME is composing (Korean). While composing, keydown and
    // the plain input path must NOT also post keys — the composition* path owns
    // the keystrokes (else Hangul double-inserts).
    this.composing = false

    this.pageStack = this.el.querySelector("[data-role='office-wasm-pages']")
    this.statusEl = this.el.querySelector("[data-role='office-wasm-status']")
    this.imeProxy = this.el.querySelector("[data-role='office-wasm-ime-proxy']")

    this.documentId = this.el.dataset.documentId
    this.format = this.el.dataset.localDocumentFormat || "docx"

    this.setStatus("Loading office engine… (large WASM, first load is slow)")

    // Pre-warm + load on mount. The host element carries the bytes URL; the
    // server also pushes `office_wasm_load` (re-open / revision change).
    this.handleEvent("office_wasm_load", (payload) => this.loadDocument(payload))

    // Agent edit/read/find/set/save routed from the server because THIS office
    // document is `:browser`-backed (a human viewer is registered, so its WASM
    // model is the authority — design §6.2 / O5b). Apply against the same WASM
    // doc the user is viewing, re-render, and reply with the result so the
    // agent's `doc.*` MCP tool returns it. Mirrors the HWP hook's
    // `doc.apply_edit` -> handleAgentOp -> `doc.browser_reply` round-trip exactly;
    // the server side (Ecrits.Doc.Tools.browser_call + WorkspaceLive relay) is
    // engine-agnostic, so the only office-specific part is THIS handler mapping
    // verbs onto getElements/uno_apply/uno_set/saveToBytes.
    this.handleEvent("doc.apply_edit", (payload) => this.handleAgentOp(payload))

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

    // ─── Interactive editing: mouse (caret + drag-select) ───────────────────
    // mousedown anchors on a page canvas; mousemove/mouseup are bound on the
    // document so a drag that leaves the canvas (or the window) still tracks and
    // finalizes (matching the HWP arm).
    this.onMouseDown = event => this.onCanvasMouseDown(event)
    this.onMouseMove = event => this.onCanvasMouseMove(event)
    this.onMouseUp = event => this.onCanvasMouseUp(event)
    this.el.addEventListener("mousedown", this.onMouseDown)
    document.addEventListener("mousemove", this.onMouseMove)
    document.addEventListener("mouseup", this.onMouseUp)

    // Keyboard + Korean IME — bound to the hidden IME proxy (the OS-focused
    // editable element). Plain keys -> postKeyEvent; composition -> ExtTextInput.
    this.bindEditing()

    // Blinking caret (overlay redraw only — never re-rasterizes the page tile).
    this.blink = setInterval(() => {
      this.caretBlinkOn = !this.caretBlinkOn
      if (this.caret) this.drawCaret()
    }, 530)

    window.__officeWasmEditor = this
  },

  destroyed() {
    if (this.io) this.io.disconnect()
    if (this.blink) clearInterval(this.blink)
    window.removeEventListener("resize", this.onResize)
    this.el.removeEventListener("mousedown", this.onMouseDown)
    document.removeEventListener("mousemove", this.onMouseMove)
    document.removeEventListener("mouseup", this.onMouseUp)
    this.unbindEditing()
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
      this.pageRects = this.queryPageRects()
      this.caret = null
      this.hasActiveSelection = false
      this.composing = false
      console.log("[office-wasm] parts/geometry:", this.parts, "pageRects:", this.pageRects)
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

      // Caret/selection overlay (same backing-store size as the render canvas).
      // The blinking caret is drawn here so a caret blink never re-rasterizes the
      // page tile. The LOK selection highlight is painted by paintTile itself
      // (into the page canvas), so the overlay only carries the caret.
      const overlay = document.createElement("canvas")
      overlay.dataset.role = "office-wasm-caret-overlay"
      overlay.width = canvas.width
      overlay.height = canvas.height
      overlay.style.cssText =
        "position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none"

      section.appendChild(canvas)
      section.appendChild(overlay)
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
      // Keep the caret overlay's backing store in lockstep with the page canvas
      // (resize/dpr changes), and redraw the caret if it lives on this page (the
      // re-paint of the page canvas does not touch the overlay, but a buildPage/
      // resize can have reset it).
      const overlay = section.querySelector("[data-role='office-wasm-caret-overlay']")
      if (overlay && (overlay.width !== pxW || overlay.height !== pxH)) {
        overlay.width = pxW
        overlay.height = pxH
      }
      this.rendered.set(index, true)
      if (this.caret && this.caret.page - 1 === index) this.drawCaret()
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
  },

  // ══════════════════════════════════════════════════════════════════════════
  // INTERACTIVE EDITING (caret + selection + keyboard/Korean-IME typing)
  //
  // This is the LOK twin of wasm_hwp_editor.js's edit loop. Unlike the HWP arm —
  // which owns a structural document model (HwpDocument) and computes caret/
  // selection rects itself — LibreOfficeKit (LOK) owns the real text cursor and
  // selection INTERNALLY. We therefore drive it with the LOK input primitives
  // and read back the cursor rect, rather than maintaining a paragraph/offset
  // model:
  //
  //   click            -> hitTest(page1based, xPx, yPx)        (place caret)
  //   drag             -> setTextSelection(START|END, xTwip,yTwip) + repaint
  //   typing (ASCII)   -> postKeyEvent(KEYINPUT, charCode, 0) + KEYUP
  //   Backspace/Enter/… -> postKeyEvent with the awt keyCode
  //   Korean IME       -> postWindowExtTextInputEvent(0, TEXTINPUT, preedit)
  //                       then …(0, TEXTINPUT_END, "") on commit
  //
  // After every input we re-paint ONLY the caret's page tile (and any other
  // visible page, for reflow) and refresh the caret rect from getCursor(), so
  // the typed text + caret show at the cursor immediately.
  // ══════════════════════════════════════════════════════════════════════════

  // LOK enum values (LibreOfficeKitEnums.h), inlined so we don't depend on a
  // wasm-side export. Verified against the deployed binary.
  // LibreOfficeKitKeyEventType
  LOK_KEYEVENT_KEYINPUT: 0,
  LOK_KEYEVENT_KEYUP: 1,
  // LibreOfficeKitExtTextInputType
  LOK_EXT_TEXTINPUT: 0,
  LOK_EXT_TEXTINPUT_END: 2,
  // LibreOfficeKitSetTextSelectionType
  LOK_SETTEXTSELECTION_START: 0,
  LOK_SETTEXTSELECTION_END: 1,
  LOK_SETTEXTSELECTION_RESET: 2,

  // awt::Key codes (offapi/com/sun/star/awt/Key.idl == vcl KEY_*). postKeyEvent's
  // `keyCode` arg is exactly these; `charCode` is the Unicode code point (and the
  // ASCII control char for Backspace/Delete/Enter, matching init.cxx usage).
  AWT_KEY: {
    DOWN: 1024, UP: 1025, LEFT: 1026, RIGHT: 1027,
    HOME: 1028, END: 1029, PAGEUP: 1030, PAGEDOWN: 1031,
    RETURN: 1280, ESCAPE: 1281, TAB: 1282, BACKSPACE: 1283,
    SPACE: 1284, INSERT: 1285, DELETE: 1286
  },

  // ─── LOK API call wrappers (shape-agnostic, like callPaintTile) ────────────
  callApi(name, ...args) {
    if (this.api.shape === "embind-class" && this.handle && typeof this.handle[name] === "function") {
      return this.handle[name](...args)
    }
    if (this.api[name]) return this.api[name](...args)
    return undefined
  },

  // ─── Per-page document-twip rects (for px <-> twip conversion) ─────────────
  // getPartPageRectangles() -> "x, y, w, h; x, y, w, h; ..." in document twips.
  queryPageRects() {
    try {
      const raw = this.callApi("getPartPageRectangles")
      if (!raw || typeof raw !== "string") return []
      return raw
        .split(";")
        .map(s => s.trim())
        .filter(Boolean)
        .map(s => {
          const m = s.match(/(-?\d+)\D+(-?\d+)\D+(-?\d+)\D+(-?\d+)/)
          if (!m) return null
          return { x: +m[1], y: +m[2], w: +m[3], h: +m[4] }
        })
        .filter(Boolean)
    } catch (error) {
      console.warn("[office-wasm] getPartPageRectangles failed", error)
      return []
    }
  },

  // Map a page-local px point on page `pageIndex0` (0-based) to ABSOLUTE document
  // twips, the coordinate space setTextSelection expects. 1 px @96dpi == 15 twip
  // (TWIPS_PER_PX in LokEditBindings.cxx); the page's twip origin comes from its
  // page rect.
  pageLocalPxToDocTwip(pageIndex0, xPx, yPx) {
    const r = this.pageRects[pageIndex0]
    const ox = r ? r.x : 0
    const oy = r ? r.y : 0
    return { x: Math.round(ox + xPx * 15), y: Math.round(oy + yPx * 15) }
  },

  // ─── Mouse: click -> caret, drag -> selection ──────────────────────────────

  onCanvasMouseDown(event) {
    if (event.button !== 0 || !this.api || !this.parts.length) return
    const loc = this.eventToPageLocal(event)
    if (!loc) return

    // Place the LOK caret at the press point and capture its rect.
    this.placeCaret(loc.pageIndex, loc.x, loc.y)

    // Start a LOK text selection at the press point (document twips). The drag
    // extends the END; a plain click with no movement resets it on mouseup.
    const t = this.pageLocalPxToDocTwip(loc.pageIndex, loc.x, loc.y)
    try {
      this.callApi("setTextSelection", this.LOK_SETTEXTSELECTION_START, t.x, t.y)
    } catch (error) {
      console.error("[office-wasm] setTextSelection(START) failed", error)
    }
    this.dragSelect = { page: loc.pageIndex, startX: loc.x, startY: loc.y, moved: false }
    this.clearSelectionState()

    // Keep the OS IME composition target focused + anchored at the caret so the
    // Korean candidate window pops next to the cursor.
    if (this.imeProxy) {
      event.preventDefault()
      this.imeProxy.focus({ preventScroll: true })
      this.anchorProxy()
    }
  },

  onCanvasMouseMove(event) {
    if (!this.dragSelect || !this.api) return
    if ((event.buttons & 1) === 0) {
      this.onCanvasMouseUp(event)
      return
    }
    // Resolve the current point, preferring the page the drag started on so a
    // drag that runs past the page edge still extends the selection.
    const loc = this.eventToPageLocal(event, this.dragSelect.page)
    if (!loc) return
    const ds = this.dragSelect
    if (Math.abs(loc.x - ds.startX) > 1 || Math.abs(loc.y - ds.startY) > 1 || loc.pageIndex !== ds.page) {
      ds.moved = true
    }
    const t = this.pageLocalPxToDocTwip(loc.pageIndex, loc.x, loc.y)
    try {
      this.callApi("setTextSelection", this.LOK_SETTEXTSELECTION_END, t.x, t.y)
    } catch (error) {
      console.error("[office-wasm] setTextSelection(END) failed", error)
    }
    this.hasActiveSelection = ds.moved
    // LOK paints the selection highlight INTO the tile, so re-paint the affected
    // page(s) to reveal it, then refresh + redraw the caret on top.
    if (ds.moved) {
      this.renderCaretWindow()
      this.refreshCaret()
    }
    this.anchorProxy()
    if (event.cancelable) event.preventDefault()
  },

  onCanvasMouseUp(_event) {
    if (!this.dragSelect) return
    const ds = this.dragSelect
    this.dragSelect = null
    if (!ds.moved) {
      // Plain click — collapse any LOK selection back to a caret.
      try {
        this.callApi("setTextSelection", this.LOK_SETTEXTSELECTION_RESET, 0, 0)
      } catch (_) {}
      this.hasActiveSelection = false
    }
  },

  // Map a pointer event to { pageIndex (0-based), x, y } in page-local px (the
  // space hitTest/getCursor use). Clamps into the page box so a drag past the
  // edge still resolves; `preferPage` (0-based) is used when the pointer left the
  // canvas during a drag.
  eventToPageLocal(event, preferPage) {
    let section = event.target && event.target.closest
      ? event.target.closest("[data-role='office-wasm-page']")
      : null
    let pageIndex = section ? Number(section.dataset.pageIndex) : preferPage
    if (!section && typeof preferPage === "number") section = this.pageSection(preferPage)
    if (!section) return null
    if (typeof pageIndex !== "number" || Number.isNaN(pageIndex)) {
      pageIndex = Number(section.dataset.pageIndex)
    }
    const canvas = section.querySelector("[data-role='office-wasm-canvas']")
    if (!canvas) return null

    const rect = canvas.getBoundingClientRect()
    if (!rect.width || !rect.height) return null
    // CSS px -> backing px ratio, then / scale to get page-local px (matches the
    // HWP arm's coordinate derivation).
    const backingRatio = canvas.width / rect.width
    const clientX = Math.min(Math.max(event.clientX, rect.left), rect.right)
    const clientY = Math.min(Math.max(event.clientY, rect.top), rect.bottom)
    const x = ((clientX - rect.left) * backingRatio) / this.scale
    const y = ((clientY - rect.top) * backingRatio) / this.scale
    return { pageIndex, x, y }
  },

  // Place the LOK caret via hitTest (page is 1-based) and adopt the returned
  // page-local rect. hitTest returns {ok,page,x,y,height}.
  placeCaret(pageIndex0, xPx, yPx) {
    try {
      const res = this.callApi("hitTest", pageIndex0 + 1, xPx, yPx)
      if (res && res.ok) {
        this.caret = { page: res.page, x: res.x, y: res.y, height: res.height }
      } else {
        // hitTest didn't resolve a caret (e.g. empty area) — keep the click point
        // as a best-effort caret so the overlay still shows where the user clicked.
        this.caret = { page: pageIndex0 + 1, x: xPx, y: yPx, height: 16 }
      }
    } catch (error) {
      console.error("[office-wasm] hitTest failed", error)
      this.caret = { page: pageIndex0 + 1, x: xPx, y: yPx, height: 16 }
    }
    this.caretBlinkOn = true
    this.drawCaret()
    window.__officeWasmCaret = this.caret
  },

  // Refresh the caret rect from getCursor() (after a key/IME edit moved it).
  refreshCaret() {
    try {
      const res = this.callApi("getCursor")
      if (res && res.ok) {
        this.caret = { page: res.page, x: res.x, y: res.y, height: res.height }
        window.__officeWasmCaret = this.caret
      }
    } catch (error) {
      console.error("[office-wasm] getCursor failed", error)
    }
    this.caretBlinkOn = true
    this.drawCaret()
    this.anchorProxy()
  },

  // ─── Caret overlay rendering ───────────────────────────────────────────────

  caretOverlay(pageIndex0) {
    const section = this.pageSection(pageIndex0)
    return section ? section.querySelector("[data-role='office-wasm-caret-overlay']") : null
  },

  clearAllCaretOverlays() {
    if (!this.pageStack) return
    const overlays = this.pageStack.querySelectorAll("[data-role='office-wasm-caret-overlay']")
    for (const o of overlays) {
      const ctx = o.getContext("2d")
      if (ctx) ctx.clearRect(0, 0, o.width, o.height)
    }
  },

  // Draw the blinking caret on its page's overlay (page-local px scaled to the
  // overlay backing store == page canvas size). Clears every overlay first so a
  // caret that moved to a new page never leaves a stale one behind.
  drawCaret() {
    const c = this.caret
    if (!c) return
    this.clearAllCaretOverlays()
    if (!this.caretBlinkOn) return
    const overlay = this.caretOverlay(c.page - 1)
    if (!overlay) return
    const ctx = overlay.getContext("2d")
    if (!ctx) return
    const s = this.scale
    ctx.fillStyle = "#1d4ed8"
    ctx.fillRect(c.x * s, c.y * s, 1.5 * s, Math.max(8, c.height || 16) * s)
  },

  // Position the hidden IME proxy textarea over the caret so the OS candidate
  // window (Korean) anchors there and keystrokes target it.
  anchorProxy() {
    if (!this.imeProxy || !this.caret) return
    const c = this.caret
    const section = this.pageSection(c.page - 1)
    if (!section) return
    const canvas = section.querySelector("[data-role='office-wasm-canvas']")
    if (!canvas) return
    const cr = canvas.getBoundingClientRect()
    const hostRect = this.el.getBoundingClientRect()
    const cssPerPage = cr.width / (canvas.width / this.scale)
    const left = cr.left - hostRect.left + this.el.scrollLeft + c.x * cssPerPage
    const top = cr.top - hostRect.top + this.el.scrollTop + c.y * cssPerPage
    this.imeProxy.style.left = `${Math.round(left)}px`
    this.imeProxy.style.top = `${Math.round(top)}px`
    this.imeProxy.style.height = `${Math.max(12, Math.round((c.height || 16) * cssPerPage))}px`
  },

  clearSelectionState() {
    this.hasActiveSelection = false
  },

  // Re-paint the caret's page tile (+ any other visible page, for reflow) so a
  // just-applied edit / selection shows immediately.
  renderCaretWindow() {
    const idx = this.caret ? this.caret.page - 1 : null
    if (typeof idx === "number") this.renderPage(idx)
    for (const v of this.visible) if (v !== idx) this.renderPage(v)
  },

  // ─── Keyboard + IME wiring (the IME proxy is the OS-focused element) ────────

  bindEditing() {
    if (!this.imeProxy) return
    this.onInput = e => this.handleInput(e)
    this.onCompositionStart = e => this.handleCompositionStart(e)
    this.onCompositionUpdate = e => this.handleCompositionUpdate(e)
    this.onCompositionEnd = e => this.handleCompositionEnd(e)
    this.onKeyDown = e => this.handleKeyDown(e)

    this.imeProxy.addEventListener("input", this.onInput)
    this.imeProxy.addEventListener("compositionstart", this.onCompositionStart)
    this.imeProxy.addEventListener("compositionupdate", this.onCompositionUpdate)
    this.imeProxy.addEventListener("compositionend", this.onCompositionEnd)
    this.imeProxy.addEventListener("keydown", this.onKeyDown)
  },

  unbindEditing() {
    if (!this.imeProxy) return
    this.imeProxy.removeEventListener("input", this.onInput)
    this.imeProxy.removeEventListener("compositionstart", this.onCompositionStart)
    this.imeProxy.removeEventListener("compositionupdate", this.onCompositionUpdate)
    this.imeProxy.removeEventListener("compositionend", this.onCompositionEnd)
    this.imeProxy.removeEventListener("keydown", this.onKeyDown)
  },

  // keydown — non-composing keys only. Printable chars and special keys both go
  // through postKeyEvent; composition keystrokes are owned by the composition*
  // path (we must skip them here, else Hangul double-inserts). Editing shortcuts
  // (Cmd/Ctrl) pass through to the browser/UNO.
  handleKeyDown(event) {
    if (!this.api || !this.parts.length) return
    if (event.isComposing || this.composing) return // IME owns the keystroke
    if (event.metaKey || event.ctrlKey || event.altKey) return // shortcuts pass through

    const k = event.key
    const special = this.specialKeyCode(k)
    if (special != null) {
      event.preventDefault()
      this.postKey(special.charCode, special.keyCode)
      // Caret-moving keys (arrows/home/end) don't change content -> just refresh
      // the caret; content keys repaint the page first.
      if (special.repaint) this.renderCaretWindow()
      this.refreshCaret()
      return
    }

    // Printable single character (length-1 key, no modifier). Multi-char keys
    // ("Shift", "Tab"→handled above, "Dead", etc.) are not text.
    if (k && k.length === 1) {
      event.preventDefault()
      const cp = k.codePointAt(0)
      this.postKey(cp, 0)
      this.renderCaretWindow()
      this.refreshCaret()
    }
  },

  // Map a KeyboardEvent.key to {charCode,keyCode,repaint} for the special keys we
  // handle; null for everything else (printable / unhandled). charCode mirrors
  // init.cxx (Backspace=8, Delete=46, Enter=13, Tab=9); arrows have charCode 0.
  specialKeyCode(key) {
    const K = this.AWT_KEY
    switch (key) {
      case "Backspace": return { charCode: 8, keyCode: K.BACKSPACE, repaint: true }
      case "Delete": return { charCode: 46, keyCode: K.DELETE, repaint: true }
      case "Enter": return { charCode: 13, keyCode: K.RETURN, repaint: true }
      case "Tab": return { charCode: 9, keyCode: K.TAB, repaint: true }
      case "ArrowLeft": return { charCode: 0, keyCode: K.LEFT, repaint: false }
      case "ArrowRight": return { charCode: 0, keyCode: K.RIGHT, repaint: false }
      case "ArrowUp": return { charCode: 0, keyCode: K.UP, repaint: false }
      case "ArrowDown": return { charCode: 0, keyCode: K.DOWN, repaint: false }
      case "Home": return { charCode: 0, keyCode: K.HOME, repaint: false }
      case "End": return { charCode: 0, keyCode: K.END, repaint: false }
      case "PageUp": return { charCode: 0, keyCode: K.PAGEUP, repaint: false }
      case "PageDown": return { charCode: 0, keyCode: K.PAGEDOWN, repaint: false }
      default: return null
    }
  },

  // Post a full key press (KEYINPUT then KEYUP), as the LOK/online clients do.
  postKey(charCode, keyCode) {
    try {
      this.callApi("postKeyEvent", this.LOK_KEYEVENT_KEYINPUT, charCode, keyCode)
      this.callApi("postKeyEvent", this.LOK_KEYEVENT_KEYUP, charCode, keyCode)
      this.hasActiveSelection = false
    } catch (error) {
      console.error("[office-wasm] postKeyEvent failed", error)
    }
    // Always drain the proxy so it never accumulates state.
    if (this.imeProxy) this.imeProxy.value = ""
  },

  // Plain (non-composing) text input — fires for some IMEs / paste / dictation
  // where keydown doesn't carry the char. Korean composition is handled by the
  // composition* path and skipped here.
  handleInput(event) {
    if (!this.api) return
    if (event.isComposing || this.composing) return
    const type = event.inputType || ""
    if (type.startsWith("insert")) {
      const data = event.data != null ? event.data : this.imeProxy.value
      if (data) {
        for (const ch of data) this.postKey(ch.codePointAt(0), 0)
        this.renderCaretWindow()
        this.refreshCaret()
      }
    }
    if (this.imeProxy) this.imeProxy.value = ""
  },

  // Korean IME — compositionstart marks composing; the in-document preedit is
  // driven by postWindowExtTextInputEvent on each update so Hangul composes and
  // shows live at the caret (not a separate overlay).
  handleCompositionStart(_event) {
    if (!this.api) return
    this.composing = true
  },

  // compositionupdate — push the current preedit string to LOK as a single
  // ExtTextInput; LOK replaces the live preedit run each time. Re-paint + refresh
  // so the composing Hangul shows at the caret immediately.
  handleCompositionUpdate(event) {
    if (!this.api) return
    const str = event.data || ""
    try {
      this.callApi("postWindowExtTextInputEvent", 0, this.LOK_EXT_TEXTINPUT, str)
    } catch (error) {
      console.error("[office-wasm] postWindowExtTextInputEvent(update) failed", error)
    }
    this.renderCaretWindow()
    this.refreshCaret()
  },

  // compositionend — commit. Push the final string once more (some IMEs only send
  // the resolved text here) then END the composition so LOK turns the preedit
  // into committed text.
  handleCompositionEnd(event) {
    if (!this.api) { this.composing = false; return }
    const str = event.data || ""
    try {
      if (str) this.callApi("postWindowExtTextInputEvent", 0, this.LOK_EXT_TEXTINPUT, str)
      this.callApi("postWindowExtTextInputEvent", 0, this.LOK_EXT_TEXTINPUT_END, "")
    } catch (error) {
      console.error("[office-wasm] postWindowExtTextInputEvent(end) failed", error)
    }
    this.composing = false
    this.hasActiveSelection = false
    if (this.imeProxy) this.imeProxy.value = ""
    this.renderCaretWindow()
    this.refreshCaret()
  },

  // ══════════════════════════════════════════════════════════════════════════
  // AGENT-EDIT BRIDGE (O5b) — the office twin of wasm_hwp_editor.js's
  // handleAgentOp. The server routes a viewed office doc's `doc.*` calls HERE
  // (because a viewer is registered, so the browser WASM model is authority);
  // we apply them to the SAME LibreOffice->WASM doc the user sees and reply.
  //
  // HOW OFFICE DIFFERS FROM HWP. The HWP arm owns a structural rhwp model and
  // addresses text positionally ({section,paragraph,offset} refs) via per-verb
  // WASM accessors. The office arm instead drives the build's IR + UNO verbs:
  //
  //   doc.find / doc.read / doc.get  -> getElements()  (IR JSON; filter/window)
  //   doc.edit (insert/replace/delete, single + ops:[…]) -> uno_apply(opJson)
  //   doc.set  (ref+props, single + sets:[…])            -> uno_set(ref, propsJson)
  //   doc.save                                           -> saveToBytes(format)
  //
  // Office refs are STRINGS the IR emits: "p<idx>" (paragraph), "tbl[<Name>]",
  // "tbl[<Name>]/cell[<B2>]", "page[<Slide>]/shape[<N>]". So office does NOT use
  // the HWP parseRef ({section,paragraph,offset}); the verbs take the ref string
  // (and JSON args) straight through.
  // ══════════════════════════════════════════════════════════════════════════

  // Entry point for a server-routed agent op. `verb` is read|find|get|edit|set|
  // save. ALWAYS reply (even on error) so the blocked MCP caller never hangs to
  // its timeout. Serialize ops through a promise chain so a save can never race a
  // still-pending edit (uno_apply dispatches onto the LOK worker — saveToBytes
  // immediately after an edit can otherwise read an inconsistent buffer).
  handleAgentOp({ request_id, verb, payload }) {
    const reply = (body) => this.pushEvent("doc.browser_reply", { request_id, ...body })
    if (!this.api || !this.handle) {
      reply({ error: "document_not_loaded" })
      return
    }
    // Chain on the previous agent op (and any in-flight load) so edits + the
    // save settle in submission order.
    const prior = this._agentInFlight || Promise.resolve()
    this._agentInFlight = prior
      .catch(() => {})
      .then(async () => {
        if (this._loadInFlight) { try { await this._loadInFlight } catch (_) {} }
        try {
          switch (verb) {
            case "edit": {
              const body = Array.isArray(payload && payload.ops)
                ? await this.officeApplyEditBatch(payload)
                : await this.officeApplyEdit(payload)
              reply(body)
              break
            }
            case "set": {
              const body = Array.isArray(payload && payload.sets)
                ? await this.officeApplySetBatch(payload)
                : await this.officeApplySet(payload)
              reply(body)
              break
            }
            case "find":
              reply({ result: this.officeFind(payload) })
              break
            case "read":
              reply({ result: this.officeRead(payload) })
              break
            case "get":
              reply({ result: this.officeGet(payload) })
              break
            case "save":
              // The viewer's WASM model is authority for an open doc — settle
              // pending edits FIRST (await the chain we're already in + a
              // microtask flush), then export its CURRENT edited bytes.
              reply({ result: await this.officeSave() })
              break
            default:
              reply({ error: `unsupported_verb:${verb}` })
          }
        } catch (error) {
          console.error("[office-wasm] agent op failed", verb, error)
          reply({ error: String((error && error.message) || error) })
        }
      })
  },

  // ─── IR read (getElements) ─────────────────────────────────────────────────

  // Parse the build's IR JSON once and cache it; invalidated after any edit/set.
  // Each element is normalized to { ref, text, type, context?, row?, col? } so the
  // find/read/get projections below are engine-shape agnostic (the build may key
  // the IR as {ref,text,type} or nest text under {content}).
  officeElements() {
    if (this._elementsCache) return this._elementsCache
    const fn = this.api && this.api.getElements
    if (typeof fn !== "function") {
      throw new Error("getElements export not found in this office WASM build")
    }
    let raw
    try {
      raw = fn()
    } catch (error) {
      throw new Error("getElements failed: " + String((error && error.message) || error))
    }
    let parsed
    try {
      parsed = typeof raw === "string" ? JSON.parse(raw || "[]") : raw
    } catch (_) {
      throw new Error("getElements returned non-JSON: " + String(raw).slice(0, 120))
    }
    const list = Array.isArray(parsed) ? parsed : (parsed && Array.isArray(parsed.elements) ? parsed.elements : [])
    const norm = list.map((el) => this.normElement(el)).filter(Boolean)
    this._elementsCache = norm
    return norm
  },

  // Normalize one IR element to the find/read match shape. Tolerant of field
  // aliases so a small IR schema drift in the parallel wasm build doesn't break
  // the bridge.
  normElement(el) {
    if (!el || typeof el !== "object") return null
    const ref = el.ref != null ? String(el.ref) : null
    if (!ref) return null
    const text = el.text != null ? String(el.text)
      : el.content != null ? String(el.content) : ""
    const type = el.type != null ? String(el.type)
      : el.kind != null ? String(el.kind) : this.refType(ref)
    const out = { ref, text, type }
    if (el.context != null) out.context = String(el.context)
    if (el.row != null) out.row = el.row
    if (el.col != null) out.col = el.col
    return out
  },

  // Infer an element TYPE from its ref string when the IR omits one:
  //   p<idx>                       -> paragraph
  //   tbl[Name]                    -> table
  //   tbl[Name]/cell[B2]           -> cell
  //   page[N]/shape[M]             -> shape
  refType(ref) {
    if (/\/cell\[/.test(ref)) return "cell"
    if (/^tbl\[/.test(ref)) return "table"
    if (/\/shape\[/.test(ref)) return "shape"
    if (/^page\[/.test(ref)) return "page"
    if (/^p\d+$/.test(ref)) return "paragraph"
    return "unknown"
  },

  blankText(el) {
    return String(el.text || "").trim() === ""
  },

  // ─── doc.find -> getElements + filter ──────────────────────────────────────
  // Mirrors the HWP arm: literal substring search by default; `all`/`regex`/`type`
  // flips to discovery mode (enumerate every element, filter by `type`, and treat
  // `pattern` as a regex). Returns { matches: [{ref,text,type,…}] }.
  officeFind({ pattern, case_sensitive, all, regex, type }) {
    const elements = this.officeElements()
    const cs = !!case_sensitive

    let matches = elements
    if (type) matches = this.filterByType(matches, String(type))

    const pat = pattern != null ? String(pattern) : ""
    if (all || regex || type) {
      // discovery mode: pattern optional, regex when present.
      if (pat) {
        let re
        try { re = new RegExp(pat, cs ? "" : "i") } catch (_) { re = null }
        matches = re ? matches.filter((el) => re.test(el.text)) : matches
      }
    } else {
      // literal substring search (pattern required by the server schema).
      const needle = cs ? pat : pat.toLowerCase()
      matches = matches.filter((el) => {
        const hay = cs ? el.text : el.text.toLowerCase()
        return hay.includes(needle)
      })
    }
    return { pattern: pat, type: type || null, matches: matches.map((el) => ({ ...el })) }
  },

  // The server's element-type taxonomy, mapped onto office IR types. Cell-state
  // filters (empty_cell/filled_cell/empty) key off the cell text being blank.
  filterByType(elements, type) {
    if (!type) return elements
    switch (type) {
      case "empty": return elements.filter((el) => this.blankText(el))
      case "cell": return elements.filter((el) => el.type === "cell")
      case "empty_cell": return elements.filter((el) => el.type === "cell" && this.blankText(el))
      case "filled_cell": return elements.filter((el) => el.type === "cell" && !this.blankText(el))
      case "paragraph": return elements.filter((el) => el.type === "paragraph")
      default: return elements.filter((el) => el.type === type)
    }
  },

  // ─── doc.read -> windowed getElements ──────────────────────────────────────
  // Incremental: ≤30 elements/call + a next_at cursor (mirrors the HWP arm and
  // the server's read cap). Each entry carries its `ref` so the agent can edit it.
  officeRead({ opts }) {
    const o = opts || {}
    const at = Math.max(0, Number(o.at || 0))
    const size = Math.min(30, Math.max(1, Number(o.size || 30)))
    const elements = this.officeElements()
    const total = elements.length
    const win = elements.slice(at, at + size)
    const nextAt = at + win.length < total ? at + win.length : null
    const paragraphs = win.map((el) => {
      const p = { text: el.text, ref: el.ref, table_cell: el.type === "cell" }
      if (el.type) p.type = el.type
      if (el.context) p.context = el.context
      return p
    })
    return {
      text: win.map((el) => (el.type === "cell" ? `[cell] ${el.text}` : el.text)).join("\n"),
      at,
      size: win.length,
      paragraphs,
      total,
      next_at: nextAt
    }
  },

  // ─── doc.get -> inspect one (or many) IR elements ──────────────────────────
  // Best-effort reflective read off the IR: the element's type + current text.
  // (The office IR doesn't expose a settable-property vocabulary the way the HWP
  // engine does, so `settable` is omitted; the agent sets via doc.set's known
  // UNO property names.)
  officeGet({ ref, refs }) {
    const byRef = new Map(this.officeElements().map((el) => [el.ref, el]))
    const one = (r) => {
      const el = byRef.get(String(r))
      if (!el) return { ref: String(r), error: "unresolved ref" }
      return { ref: el.ref, type: el.type, values: { text: el.text }, properties: { text: el.text }, children: [] }
    }
    if (Array.isArray(refs)) return { results: refs.map(one) }
    return one(ref)
  },

  // ─── doc.edit -> uno_apply(opJson) ─────────────────────────────────────────
  // Single op. uno_apply takes the op as a JSON string (the SAME op the server
  // normalised: {op, ref, text|query|replacement|count, …}). Settle the edit,
  // invalidate the IR cache, re-render, and report a bumped revision.
  async officeApplyEdit({ op, base_revision }) {
    const baseRev = typeof base_revision === "number" ? base_revision : 0
    const r = await this.officeApplyOneOp(op)
    if (r.error) return { error: r.error }
    return this.finishAgentEdit(baseRev, r.extra || {})
  },

  // Apply ONE edit op via uno_apply. NEVER renders / bumps the revision — the
  // caller does that once (so a batch applies N ops and finishes once). uno_apply
  // may return a JSON status string ({ok}/{error}) or throw; treat a thrown error
  // OR an {error:…} payload as a per-op failure.
  async officeApplyOneOp(op) {
    const fn = this.api && this.api.unoApply
    if (typeof fn !== "function") return { error: "uno_apply export not found in this office WASM build" }
    const verb = op && op.op
    if (!verb) return { error: "edit op requires an 'op' verb" }
    let res
    try {
      res = fn(JSON.stringify(op))
      // uno_apply dispatches onto the LOK worker; await a possible thenable.
      if (res && typeof res.then === "function") res = await res
    } catch (error) {
      return { error: `${verb} failed: ${String((error && error.message) || error)}` }
    }
    const status = this.parseStatus(res)
    if (status && status.error) return { error: `${verb} failed: ${status.error}` }
    return { ok: true, extra: status && typeof status === "object" ? this.editExtra(status) : {} }
  },

  // Project the verb-specific count fields uno_apply may echo back into the
  // result the agent sees (replaced/inserted/deleted), best-effort.
  editExtra(status) {
    const extra = {}
    for (const k of ["replaced", "inserted", "deleted"]) {
      if (typeof status[k] === "number") extra[k] = status[k]
    }
    return extra
  },

  // Batch doc.edit (ops:[…]). Apply every op via uno_apply with ONE re-render +
  // revision bump at the end. Best-effort: a bad op does NOT abort the rest; the
  // result carries a per-op `results` array, mirroring the HWP batch shape.
  async officeApplyEditBatch({ ops, base_revision }) {
    const baseRev = typeof base_revision === "number" ? base_revision : 0
    const list = Array.isArray(ops) ? ops : []
    if (list.length === 0) return { error: "edit batch requires a non-empty 'ops' array" }
    const results = []
    let applied = 0
    let failed = 0
    for (const op of list) {
      const refStr = op && op.ref != null ? String(op.ref) : null
      let r
      try {
        r = await this.officeApplyOneOp(op)
      } catch (error) {
        r = { error: String((error && error.message) || error) }
      }
      if (r && r.ok) {
        applied++
        results.push(Object.assign({ ref: refStr, ok: true }, r.extra || {}))
      } else {
        failed++
        results.push({ ref: refStr, error: (r && r.error) || "unknown_error" })
      }
    }
    const finished = this.finishAgentEdit(baseRev, {})
    return { ok: true, result: { ok: true, revision: finished.result.revision, applied, failed, results } }
  },

  // ─── doc.set -> uno_set(ref, propsJson) ────────────────────────────────────
  // Single set. CHAR properties must address the PARAGRAPH ref `p<idx>` (verified:
  // a run ref like "p0/r0" returns {"error":"unresolved ref"}), so we coerce a
  // run ref down to its paragraph for the uno_set call.
  async officeApplySet({ ref, props, base_revision }) {
    const baseRev = typeof base_revision === "number" ? base_revision : 0
    const r = await this.officeApplySetOne(ref, props)
    if (r.error) return { error: r.error }
    return this.finishAgentEdit(baseRev, {})
  },

  async officeApplySetOne(ref, props) {
    const fn = this.api && this.api.unoSet
    if (typeof fn !== "function") return { error: "uno_set export not found in this office WASM build" }
    if (ref == null || String(ref) === "") return { error: "set requires a 'ref' (from doc.find/doc.read)" }
    if (props == null || typeof props !== "object") return { error: "set requires a 'props' object" }
    // Strip the server's `kind` discriminator (office reads the property KEYS).
    const { kind: _kind, ...rest } = props
    if (Object.keys(rest).length === 0) return { error: "set requires at least one property in 'props'" }
    // Translate the engine-agnostic property vocabulary the doc.set schema + HWP
    // arm use (Bold/Italic/TextColor/FontSize/Alignment) into the UNO-native names
    // office uno_set expects (VERIFIED in-browser: it accepts CharWeight/CharPosture/
    // CharColor/CharHeight/ParaAdjust and REJECTS Bold/TextColor with "names not
    // settable on this ref"). Names already in UNO form pass through unchanged.
    const unoProps = this.toUnoProps(rest)
    // Char-property sets resolve only against the PARAGRAPH ref, never a run ref.
    const target = this.paragraphRefFor(String(ref))
    let res
    try {
      res = fn(target, JSON.stringify(unoProps))
      if (res && typeof res.then === "function") res = await res
    } catch (error) {
      return { error: `uno_set failed: ${String((error && error.message) || error)}` }
    }
    const status = this.parseStatus(res)
    if (status && status.error) return { error: `uno_set failed: ${status.error}` }
    return { ok: true }
  },

  // Map the cross-engine doc.set property vocabulary onto UNO property names +
  // values for office uno_set. Booleans/strings the HWP arm accepts become the UNO
  // numeric enums (FontWeight.BOLD=150, FontSlant.ITALIC=2, ParagraphAdjust),
  // colors become a packed 0xRRGGBB long, font size stays points. Names already in
  // UNO form (CharWeight, CharColor, ParaAdjust, …) pass through.
  toUnoProps(props) {
    const out = {}
    for (const [k, v] of Object.entries(props)) {
      switch (k) {
        case "Bold":
          out.CharWeight = v ? 150 : 100 // com.sun.star.awt.FontWeight NORMAL=100 BOLD=150
          break
        case "Italic":
          out.CharPosture = v ? 2 : 0 // com.sun.star.awt.FontSlant NONE=0 ITALIC=2
          break
        case "Underline":
          out.CharUnderline = v ? 1 : 0 // com.sun.star.awt.FontUnderline SINGLE=1 NONE=0
          break
        case "TextColor":
        case "FontColor":
          out.CharColor = this.colorToLong(v)
          break
        case "FontSize":
          out.CharHeight = Number(v)
          break
        case "FontName":
          out.CharFontName = String(v)
          break
        case "Alignment":
          out.ParaAdjust = this.alignToParaAdjust(v)
          break
        default:
          out[k] = v // raw UNO name (CharWeight/CharColor/ParaAdjust/…) passes through
      }
    }
    return out
  },

  // "#RRGGBB" / "#RGB" / a number -> a packed 0xRRGGBB long the UNO CharColor
  // property takes. A non-parseable value is returned as-is (best-effort).
  colorToLong(v) {
    if (typeof v === "number") return v
    if (typeof v === "string") {
      let h = v.trim().replace(/^#/, "")
      if (h.length === 3) h = h.split("").map((c) => c + c).join("")
      const n = parseInt(h, 16)
      if (Number.isFinite(n)) return n
    }
    return v
  },

  // doc.set alignment vocabulary -> com.sun.star.style.ParagraphAdjust enum
  // (LEFT=0, RIGHT=1, BLOCK/justify=2, CENTER=3, STRETCH=4).
  alignToParaAdjust(v) {
    if (typeof v === "number") return v
    switch (String(v).toLowerCase()) {
      case "left": return 0
      case "right": return 1
      case "justify": case "both": case "block": return 2
      case "center": case "centre": return 3
      default: return 0
    }
  },

  // A run ref ("p0/r3") collapses to its paragraph ("p0") because uno_set only
  // resolves char props against the paragraph ref. A cell/table/shape ref passes
  // through unchanged.
  paragraphRefFor(ref) {
    const m = /^(p\d+)\/r\d+$/.exec(ref)
    return m ? m[1] : ref
  },

  // Batch doc.set (sets:[{ref,props}, …]). Apply every set with ONE finish.
  async officeApplySetBatch({ sets, base_revision }) {
    const baseRev = typeof base_revision === "number" ? base_revision : 0
    const list = Array.isArray(sets) ? sets : []
    if (list.length === 0) return { error: "set batch requires a non-empty 'sets' array" }
    const results = []
    let applied = 0
    let failed = 0
    for (const entry of list) {
      const refStr = entry && entry.ref != null ? String(entry.ref) : null
      let r
      try {
        r = await this.officeApplySetOne(entry && entry.ref, entry && entry.props)
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
    return { ok: true, result: { ok: true, revision: finished.result.revision, applied, failed, results } }
  },

  // ─── doc.save -> saveToBytes(format) ───────────────────────────────────────
  // Export the open doc's CURRENT edited bytes for the server to write to disk.
  // Pending edits are already settled (handleAgentOp serialises the op chain and
  // we await it here too); flush a microtask so the LOK worker's last uno_apply
  // commit is visible before we read the buffer.
  async officeSave() {
    const fn = this.api && this.api.saveToBytes
    if (typeof fn !== "function") throw new Error("saveToBytes export not found in this office WASM build")
    // Microtask flush: let any just-resolved edit's worker commit land before
    // reading the export buffer (the saveToBytes-vs-pending-edit race).
    await Promise.resolve()
    let bytes = fn(this.format || "docx")
    if (bytes && typeof bytes.then === "function") bytes = await bytes
    if (!bytes || !bytes.length) throw new Error("saveToBytes returned no bytes")
    const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes)
    return { format: this.format || "docx", bytes_base64: this.bytesToBase64(u8), bytes: u8.length }
  },

  // ─── shared edit-finish + helpers ──────────────────────────────────────────

  // Post-edit step (mirrors the HWP finishAgentEdit): the IR changed so the
  // cached element list is stale; re-render the visible pages so the edit shows
  // in the viewer, and report a monotonically bumped revision.
  finishAgentEdit(baseRev, extra) {
    this._elementsCache = null
    this.rendered.clear()
    this.renderVisiblePages()
    if (this.caret) this.refreshCaret()
    return { ok: true, result: { ok: true, revision: baseRev + 1, ...extra } }
  },

  // uno_apply/uno_set may return a JSON status string, a plain object, or
  // undefined (= applied with no payload). Normalise to an object or null.
  parseStatus(res) {
    if (res == null) return null
    if (typeof res === "object") return res
    if (typeof res === "string") {
      const s = res.trim()
      if (!s) return null
      try { return JSON.parse(s) } catch (_) { return { raw: s } }
    }
    return null
  },

  bytesToBase64(bytes) {
    let binary = ""
    const chunk = 0x8000
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk))
    }
    return btoa(binary)
  }
}

export { WasmOfficeEditor }
