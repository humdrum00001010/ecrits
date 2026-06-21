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
import { appendPickedElementToComposer, bindElementPickerTarget } from "./document_element_picker.js"
import { rewriteOfficeOp } from "./wasm_office_ops.ts"
import {
  normalizeOfficeNearby as normalizeOfficeNearbyValue,
  officeReadRefCandidates as officeReadRefCandidatesValue,
  readOfficeElements,
} from "./wasm_office_read.ts"

const OFFICE_BASE = "/assets/office/"
const LOCAL_EDITOR_COMMAND_EVENT = "ecrits:local-editor-command"
const OFFICE_ELEMENT_METADATA_FIELDS = [
  "sheet",
  "address",
  "display",
  "value",
  "value_type",
  "valueType",
  "formula",
  "cached_value",
  "cachedValue",
  "formula_error",
  "formulaError",
  "number_format",
  "numberFormat"
]
const OFFICE_FIND_TEXT_LIMIT = 48

function withAssetVersion(url, version) {
  if (!version) return url
  return url + (url.includes("?") ? "&" : "?") + "v=" + encodeURIComponent(version)
}

function officeAssetUrl(path, version) {
  return withAssetVersion(OFFICE_BASE + path, version)
}

// Module-level singleton: the Emscripten runtime is heavy (153MB wasm + 112MB
// data) and pthread-based; we instantiate it ONCE per page load and share it
// across hook instances.
let runtimePromise = null
let runtimeAssetVersion = null
let runtimeModule = null
let activeOfficeDocument = null
let activeOfficeShortcutEditor = null
// Global engine-load serializer + supersede tracking. The LOK runtime and the
// `activeOfficeDocument` cache are a SINGLE module-global instance, but LiveView
// remounts the hook on EVERY tab switch — so without a global lock two hook
// instances fire concurrent loadFromBytes on the one engine (which corrupts it
// and poisons every later load) and rapid switching piles up a backlog of
// redundant re-imports of heavy decks (the "stuck on Loading…/Opening…" wedge).
// Serialize all imports through one chain and drop superseded ones so a burst of
// tab switches imports only the final document.
let engineLoadChain = Promise.resolve()
let latestRequestedUrl = null
const RUNTIME_INIT_MAX_MS = 300000

function runtimeReadyFor(assetVersion = "") {
  return !!runtimePromise && !!runtimeModule && runtimeAssetVersion === assetVersion
}

function cachedDocumentMatches(url, assetVersion = "", format = "") {
  return !!activeOfficeDocument &&
    activeOfficeDocument.url === url &&
    activeOfficeDocument.assetVersion === assetVersion &&
    activeOfficeDocument.format === format &&
    Array.isArray(activeOfficeDocument.parts) &&
    activeOfficeDocument.parts.length > 0
}

function closeCachedOfficeDocument() {
  if (!activeOfficeDocument) return
  const cached = activeOfficeDocument
  activeOfficeDocument = null
  if (cached.handle && typeof cached.handle.delete === "function") {
    try { cached.handle.delete() } catch (_) {}
  } else if (cached.api && typeof cached.api.closeDocument === "function") {
    try { cached.api.closeDocument() } catch (_) {}
  }
}

// Serialize an engine import behind any in-flight one. `run` performs the actual
// fetch + loadFromBytes and must populate `activeOfficeDocument` (the module
// cache). The import is SKIPPED when the doc is already cached ("cached"), or
// when a newer load has superseded this url ("superseded", rapid tab switching)
// — collapsing a switch burst to a single import and guaranteeing the one LOK
// engine never runs two loadFromBytes at once. Returns "loaded"/"cached"/
// "superseded".
function serializeEngineLoad(url, assetVersion, format, run) {
  const link = engineLoadChain.then(async () => {
    if (cachedDocumentMatches(url, assetVersion, format)) return "cached"
    if (latestRequestedUrl !== url) return "superseded"
    await run()
    return "loaded"
  })
  // Keep the chain alive even if this link rejects, so one failed import can't
  // wedge every later load.
  engineLoadChain = link.then(() => {}, () => {})
  return link
}

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

function ensureRuntime(assetVersion = "") {
  if (runtimePromise) {
    if (runtimeAssetVersion !== assetVersion) {
      return Promise.reject(new Error("office WASM asset version changed during page session; reload required"))
    }
    return runtimePromise
  }

  runtimeAssetVersion = assetVersion
  bootT0 = performance.now()
  const glueUrl = officeAssetUrl("soffice.js", assetVersion)
  tlog("ensureRuntime() called; injecting glue", glueUrl)

  runtimePromise = new Promise((resolve, reject) => {
    if (typeof SharedArrayBuffer === "undefined" || !self.crossOriginIsolated) {
      reject(
        new Error(
          "office WASM requires a cross-origin isolated workspace tab " +
            "(crossOriginIsolated=" + String(self.crossOriginIsolated) +
            ", SharedArrayBuffer=" + typeof SharedArrayBuffer + ")."
        )
      )
      return
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
          const url = /^(https?:|blob:)/.test(u)
            ? u
            : withAssetVersion(u.startsWith("/") ? u : OFFICE_BASE + u, assetVersion)
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
      locateFile: (path) => officeAssetUrl(path, assetVersion),
      // pthread workers re-load the SAME script; point them at the static glue.
      mainScriptUrlOrBlob: glueUrl,
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
      preRun: [
        () => {
          if (typeof Module.FS_createDataFile !== "function") return
          const ensureParentDirs = (path) => {
            if (typeof Module.FS_createPath !== "function") return
            const parts = String(path).split("/").filter(Boolean)
            let parent = "/"
            for (const part of parts.slice(0, -1)) {
              try { Module.FS_createPath(parent, part, true, true) } catch (_) {}
              parent = parent === "/" ? "/" + part : parent + "/" + part
            }
          }
          const createDataFile = Module.FS_createDataFile
          Module.FS_createDataFile = function (parent, name, data, canRead, canWrite, canOwn) {
            try {
              return createDataFile.apply(this, arguments)
            } catch (error) {
              const path = name == null ? parent : String(parent).replace(/\/$/, "") + "/" + name
              ensureParentDirs(path)
              try {
                return createDataFile.apply(this, arguments)
              } catch (retryError) {
                console.error("[office-wasm] FS_createDataFile failed", path, retryError)
                throw retryError
              }
            }
          }
        }
      ],
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
      runtimeModule = Module
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
    // lok_is_ready() instead. A grace fallback is allowed only for older builds
    // that do not expose lok_is_ready at all. If the export exists and reports
    // false, keep waiting for the real ready signal instead of racing loadFromBytes.
    const GRACE_MS = 30000
    const probeUnoInit = () => {
      tlog("gating on lok_is_ready() (full-VCL-ready); export=", exportReady())
      setTimeout(() => {
        if (settled || unoReady) return
        if (exportReady() && typeof Module.lok_is_ready !== "function") {
          tlog("lok_is_ready export missing after " + GRACE_MS + "ms; proceeding with legacy readiness gate")
          unoReady = true
          finish()
        }
      }, GRACE_MS)
    }

    const POLL_INTERVAL_MS = 50
    const POLL_MAX_MS = 180000
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
        "office WASM: runtime never initialized within " + (RUNTIME_INIT_MAX_MS / 1000) +
          "s (wasm did not instantiate). " +
          "crossOriginIsolated=" + self.crossOriginIsolated +
          ", SharedArrayBuffer=" + (typeof SharedArrayBuffer) +
          ". Last engine output:\n" +
          dumpLog()
      ))
    }, RUNTIME_INIT_MAX_MS)

    const script = document.createElement("script")
    script.src = glueUrl
    script.async = true
    script.onload = () => tlog("glue script loaded (soffice.js)")
    script.onerror = () => {
      tlog("glue script FAILED to load", glueUrl)
      fail(new Error("failed to load " + glueUrl))
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
      // Click -> MODEL REF resolution (element picker). Present from the
      // 2026-06 wasm build on; officePickAtPoint degrades gracefully without it.
      hitRef: direct("hitRef"),
      // hitRef + accurate per-line bounds + commit flag (commit=false restores
      // the user's caret/selection — the hover probe). Newer builds only;
      // officeResolveAt falls back to hitRef without it.
      resolveRef: direct("resolveRef"),
      postMouseEvent: direct("postMouseEvent"),
      doubleClick: direct("doubleClick"),
      setTextSelection: direct("setTextSelection"),
      getTextSelection: direct("getTextSelection"),
      postKeyEvent: direct("postKeyEvent"),
      postUnoCommand: direct("postUnoCommand"),
      postWindowExtTextInputEvent: direct("postWindowExtTextInputEvent"),
      getCursor: direct("getCursor"),
      isTextEditActive: direct("isTextEditActive"),
      getInteractionState: direct("getInteractionState"),
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
    this.loaded = false
    this.parts = [] // [{ width, height }] page/slide geometry, page-local px
    // Per-page document-twip rectangles {x,y,w,h} from getPartPageRectangles(),
    // index 0 == page 1. Writer uses these for per-page geometry and painting.
    this.pageRects = []
    // LOK document type (0=Writer/TEXT, 1=Calc, 2=Impress, 3=Draw), read from
    // getPartSizesJson during load. Drives the per-type page geometry + tile
    // origin in queryParts/renderPage (see those for why Writer differs).
    this.docType = -1
    this.rendered = new Map() // pageIndex -> true
    this.visible = new Set()
    this.renderQueue = new Map()
    this.renderQueueTimer = null
    this.dragRenderPages = new Set()
    this.dragRenderFrame = null
    this.scale = window.devicePixelRatio || 1
    // Deferred caret-settle bookkeeping (fixes the one-click-stale embind
    // hitTest — see placeCaret/settleCaretAfterHit).
    this._caretSettle = null
    this._caretSettleSeq = 0
    this._lastDoubleActivation = null

    // ─── Interactive-edit state (mirrors wasm_hwp_editor.js) ────────────────
    // LOK owns the real text cursor + selection internally; we only TRACK the
    // caret rect for rendering. caret = { page (1-based), x, y, height } in
    // page-local px (the shape getCursor()/hitTest() return), or null.
    this.caret = null
    this.caretBlinkOn = true
    // Live drag-select gesture (set only while the primary button is held).
    //   dragSelect = { page, startX, startY, moved, selectionStarted }  (px, page-local)
    this.dragSelect = null
    // True while an active LOK selection exists (so typing/keys know to let LOK
    // replace it and we know to repaint).
    this.hasActiveSelection = false
    this.selectionVisual = null
    this.nativeTextEditReady = false
    this.nativeInteractionState = null
    this.elementPickerEnabled = false
    this.pickerHoverTimer = null
    this.pickerHoverLoc = null
    this.pickerHoverCache = new Map()
    // True while the OS IME is composing (Korean). While composing, keydown and
    // the plain input path must NOT also post keys — the composition* path owns
    // the keystrokes (else Hangul double-inserts).
    this.composing = false
    this.skipNextCompositionInput = null
    this._compositionCommittedText = ""
    this.spreadsheetEditBuffer = ""
    this.spreadsheetEditTimer = null
    this.spreadsheetKeyPostTimer = null

    this.pageStack = this.el.querySelector("[data-role='office-wasm-pages']")
    this.statusEl = this.el.querySelector("[data-role='office-wasm-status']")
    this.imeProxy = this.el.querySelector("[data-role='office-wasm-ime-proxy']")

    this.documentId = this.el.dataset.documentId
    this.format = this.el.dataset.localDocumentFormat || "docx"
    this.officeAssetVersion = this.el.dataset.officeAssetVersion || ""

    const bytesUrl = this.el.dataset.bytesUrl
    this.setInitialStatus(bytesUrl)

    // Pre-warm + load on mount. The host element carries the bytes URL; the
    // server also pushes `office_wasm_load` on re-open.
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
    this.handleEvent("local_document.save.request", (payload) => this.saveLocalDocument(payload))

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
            this.requestRenderPage(idx)
          } else {
            this.visible.delete(idx)
            this.releasePageCanvas(idx)
          }
        }
      },
      // Render-ahead band: rasterize pages well BEFORE they scroll into view so
      // they're ready (not blank/late) on arrival, and keep them rendered for a
      // wider band so a short scroll-back doesn't re-blank+repaint. Bounds the
      // retained-canvas set too (pages beyond this margin are released). (#57 B)
      { root: this.el, rootMargin: "2000px 0px", threshold: 0 }
    )

    // ─── Interactive editing: mouse (caret + drag-select) ───────────────────
    // mousedown anchors on a page canvas; mousemove/mouseup are bound on the
    // document so a drag that leaves the canvas (or the window) still tracks and
    // finalizes (matching the HWP arm).
    this.onMouseDown = event => this.onCanvasMouseDown(event)
    this.onMouseMove = event => this.onCanvasMouseMove(event)
    this.onMouseUp = event => this.onCanvasMouseUp(event)
    this.onDoubleClick = event => this.onCanvasDoubleClick(event)
    this.onToolbarCommand = event => this.handleToolbarCommand(event.detail || {})
    this.onDocumentKeyDown = event => this.handleDocumentKeyDown(event)
    this.onDocumentPointerDown = event => this.handleDocumentPointerDown(event)
    this.el.addEventListener("mousedown", this.onMouseDown)
    this.el.addEventListener("dblclick", this.onDoubleClick)
    document.addEventListener("mousemove", this.onMouseMove)
    document.addEventListener("mouseup", this.onMouseUp)
    document.addEventListener("keydown", this.onDocumentKeyDown, true)
    document.addEventListener("mousedown", this.onDocumentPointerDown, true)
    document.addEventListener(LOCAL_EDITOR_COMMAND_EVENT, this.onToolbarCommand)

    // Keyboard + Korean IME — bound to the hidden IME proxy (the OS-focused
    // editable element). Plain keys and composition both use the real LOK key
    // path; composition replaces provisional text on each update.
    this.bindEditing()

    // Blinking caret (overlay redraw only — never re-rasterizes the page tile).
    this.blink = setInterval(() => {
      this.caretBlinkOn = !this.caretBlinkOn
      if (this.caret) this.drawCaret()
    }, 530)

    this.unbindElementPicker = bindElementPickerTarget(this)
  },

  destroyed() {
    if (this.io) this.io.disconnect()
    if (this.blink) clearInterval(this.blink)
    if (this._caretSettle) { clearTimeout(this._caretSettle); this._caretSettle = null }
    if (this.renderQueueTimer) { clearTimeout(this.renderQueueTimer); this.renderQueueTimer = null }
    if (this.spreadsheetEditTimer) { clearTimeout(this.spreadsheetEditTimer); this.spreadsheetEditTimer = null }
    if (this.spreadsheetKeyPostTimer) { clearTimeout(this.spreadsheetKeyPostTimer); this.spreadsheetKeyPostTimer = null }
    if (this.dragRenderFrame) {
      const caf = window.cancelAnimationFrame || clearTimeout
      caf(this.dragRenderFrame)
      this.dragRenderFrame = null
    }
    if (this.dragRenderPages) this.dragRenderPages.clear()
    if (this.pickerHoverTimer) { clearTimeout(this.pickerHoverTimer); this.pickerHoverTimer = null }
    if (this.renderQueue) this.renderQueue.clear()
    window.removeEventListener("resize", this.onResize)
    this.el.removeEventListener("mousedown", this.onMouseDown)
    this.el.removeEventListener("dblclick", this.onDoubleClick)
    document.removeEventListener("mousemove", this.onMouseMove)
    document.removeEventListener("mouseup", this.onMouseUp)
    document.removeEventListener("keydown", this.onDocumentKeyDown, true)
    document.removeEventListener("mousedown", this.onDocumentPointerDown, true)
    document.removeEventListener(LOCAL_EDITOR_COMMAND_EVENT, this.onToolbarCommand)
    if (this.unbindElementPicker) this.unbindElementPicker()
    this.unbindEditing()
    if (activeOfficeShortcutEditor === this) activeOfficeShortcutEditor = null
    // Keep the loaded Office document attached to the module-level runtime cache.
    // LiveView remounts this hook while switching/reopening tabs; closing here
    // would force the next mount to fetch and import the same document again.
  },

  setInitialStatus(bytesUrl) {
    if (!bytesUrl) {
      this.setStatus("")
    } else if (cachedDocumentMatches(bytesUrl, this.officeAssetVersion, this.format)) {
      this.setStatus("")
    } else if (runtimeReadyFor(this.officeAssetVersion)) {
      this.setStatus("Opening document…")
    } else {
      this.setStatus("Loading office engine… (large WASM, first load is slow)")
    }
  },

  setStatus(text) {
    if (this.statusEl) this.statusEl.textContent = text || ""
  },

  async loadDocument({ url, asset_version }) {
    this.officeAssetVersion = asset_version || this.el.dataset.officeAssetVersion || this.officeAssetVersion || ""
    if (this.loadedUrl === url && this.parts.length) return
    // Record the most-recent load intent SYNCHRONOUSLY: the global serializer
    // uses it to drop superseded imports when the user switches tabs faster than
    // a heavy deck imports (see serializeEngineLoad).
    latestRequestedUrl = url
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
    this.loaded = false
    this._loadInFlight = (async () => {
    try {
      const Module = await ensureRuntime(this.officeAssetVersion)
      if (!this.api) {
        this.api = resolveApi(Module)
        console.log("[office-wasm] API shape:", this.api.shape, this.api)
      }
      // Fast path: the module cache already holds this exact doc (e.g. re-select
      // the current tab) — attach its view without touching the engine.
      if (this.attachCachedDocument(url)) return

      this.setStatus(
        runtimeReadyFor(this.officeAssetVersion)
          ? "Opening document…"
          : "Loading office engine… (large WASM, first load is slow)"
      )

      // The engine + activeOfficeDocument cache are a SINGLE shared instance, so
      // run the actual import through the GLOBAL serializer: only one
      // loadFromBytes runs at a time across all hook instances, and a superseded
      // url is dropped so rapid tab switching can't pile up redundant re-imports.
      const result = await serializeEngineLoad(url, this.officeAssetVersion, this.format, async () => {
        this.setStatus("Fetching document…")
        const response = await fetch(url, { credentials: "same-origin" })
        if (!response.ok) throw new Error(`document bytes HTTP ${response.status}`)
        const bytes = new Uint8Array(await response.arrayBuffer())

        this.setStatus("Opening document…")
        closeCachedOfficeDocument()
        this.handle = null
        await this.openWithBytes(Module, bytes)
        this.loadedUrl = url

        // Page rects (per-page document-twip rectangles) FIRST: queryParts needs
        // them to build the page geometry for a Writer doc (whose getDocumentSize
        // reports the WHOLE multi-page document, not one page — see queryParts).
        this.pageRects = this.queryPageRects()
        this.parts = this.queryParts()
        console.log("[office-wasm] parts/geometry:", this.parts, "pageRects:", this.pageRects)
        this.rememberActiveDocument(url)
      })

      // After the (possibly long) serialized import the module cache holds `url`
      // iff this load — or a concurrent one for the same doc — actually loaded
      // it. attachCachedDocument then builds THIS hook's view from the cache
      // (parts/geometry, caret reset, viewer-ready claim, page stack, render).
      // If a newer navigation superseded us the cache holds a different doc:
      // this hook is stale (the user moved on), so stop quietly WITHOUT claiming
      // the doc.* viewer authority — the current doc's hook builds its own view.
      if (!this.attachCachedDocument(url)) {
        this.loaded = false
        if (result === "superseded") this.setStatus("")
        return
      }
    } catch (error) {
      const dump = dumpLog()
      console.error("[office-wasm] load failed", error)
      if (dump) console.error("[office-wasm] last engine output:\n" + dump)

      // A LOK init failure can poison the heavy WASM runtime singleton for the
      // current page session. Do not auto-reload from the hook: in embedded,
      // longpoll, or error-recovery contexts that can become a LiveView remount
      // loop. Leave the page stable and report the failure instead.
      const msg = (error && error.message) || String(error)
      this.loaded = false
      this.notifyViewerState(false)
      if (/requires a cross-origin isolated workspace tab/.test(msg)) {
        this.setStatus(
          "Office WASM cannot load in this browser context: " + msg +
            " Open the workspace in a top-level tab and reload."
        )
        return
      }
      const poisoned = /previously failed|importScripts|postMessage|abort\(|unreachable/i.test(msg + "\n" + dump)
      this.setStatus(
        "Office WASM failed to load: " + msg +
          (poisoned ? " — reload the page (Cmd/Ctrl+Shift+R) to retry." : "")
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

  attachCachedDocument(url) {
    if (!cachedDocumentMatches(url, this.officeAssetVersion, this.format)) return false
    this.api = activeOfficeDocument.api || this.api
    this.handle = activeOfficeDocument.handle || null
    this.loadedUrl = activeOfficeDocument.url
    this.docType = activeOfficeDocument.docType
    this.pageRects = activeOfficeDocument.pageRects.map((rect) => ({ ...rect }))
    this.parts = activeOfficeDocument.parts.map((part) => ({ ...part }))
    this.caret = null
    this.hasActiveSelection = false
    this.selectionVisual = null
    window.__officeWasmSelectionVisual = null
    this.nativeTextEditReady = false
    this.nativeInteractionState = null
    this.composing = false
    this.spreadsheetEditBuffer = ""
    if (this.spreadsheetEditTimer) { clearTimeout(this.spreadsheetEditTimer); this.spreadsheetEditTimer = null }
    if (this.spreadsheetKeyPostTimer) { clearTimeout(this.spreadsheetKeyPostTimer); this.spreadsheetKeyPostTimer = null }
    this.loaded = true
    this.notifyViewerState(true)
    this.setStatus("")
    this.buildPageStack()
    this.renderVisiblePages()
    return true
  },

  // Tell the LiveView whether this editor actually holds the document model.
  // ready=true -> it attaches the Session viewer (browser becomes the doc.*
  // authority); ready=false -> it detaches, so the agent's tools fall back to
  // the server arm instead of a viewer that has nothing loaded.
  notifyViewerState(ready) {
    if (!this.documentId) return
    try {
      this.pushEvent(
        ready ? "local_document.viewer_ready" : "local_document.viewer_failed",
        { document_id: this.documentId }
      )
    } catch (_) { /* disconnected socket — nothing to claim */ }
  },

  rememberActiveDocument(url) {
    activeOfficeDocument = {
      url,
      assetVersion: this.officeAssetVersion,
      format: this.format,
      api: this.api,
      handle: this.handle,
      docType: this.docType,
      pageRects: this.pageRects.map((rect) => ({ ...rect })),
      parts: this.parts.map((part) => ({ ...part }))
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
  //
  // CRITICAL per-doc-type distinction (the #154 "page squished / wrong hit-test
  // geometry" root cause). LOK "parts" mean DIFFERENT things per document type:
  //   • Impress/Draw (type 2/3): each part IS a slide/page, and getDocumentSize
  //     per part is that slide's real size — the parts model is correct.
  //   • Writer (type 0): the WHOLE multi-page flow is ONE logical canvas;
  //     getParts() reports a part count but getDocumentSize returns the ENTIRE
  //     stacked-pages height (e.g. 51650 twips ≈ 3 A4 pages), NOT one page. The
  //     real page boxes come from getPartPageRectangles() instead. Using the
  //     part sizes there builds N canvases each as tall as the whole document
  //     (3× too tall, content duplicated) and throws every page-local px↔twip
  //     mapping off — so clicks/caret land in the wrong place.
  // So for Writer we derive the page list from the page rectangles (already
  // queried into this.pageRects), each page = its own twip rect → px.
  queryParts() {
    if (this.api.shape === "module-functions" && typeof this.api.getPartSizesJson === "function") {
      try {
        const info = JSON.parse(this.api.getPartSizesJson())
        this.docType = typeof info.type === "number" ? info.type : -1
        // Writer (TEXT=0): the part sizes are the whole-document height. Use the
        // per-page rectangles as the real page geometry instead.
        if (this.docType === 0 && Array.isArray(this.pageRects) && this.pageRects.length) {
          const pages = this.pageRects
            .map((r) => this.parseSize({ width: r.w, height: r.h }))
            .filter(Boolean)
          if (pages.length) return pages
        }
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
      canvas.width = 1
      canvas.height = 1
      canvas.style.cssText = "display:block;width:100%;height:100%;background:#fff"
      const ctx = canvas.getContext("2d")
      if (ctx) {
        ctx.fillStyle = "#ffffff"
        ctx.fillRect(0, 0, 1, 1)
      }

      // Caret/selection overlay (same backing-store size as the render canvas).
      // The blinking caret is drawn here so a caret blink never re-rasterizes the
      // page tile. The LOK selection highlight is painted by paintTile itself
      // (into the page canvas), so the overlay only carries the caret.
      const overlay = document.createElement("canvas")
      overlay.dataset.role = "office-wasm-caret-overlay"
      overlay.width = 1
      overlay.height = 1
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

  renderVisiblePages({ force = false } = {}) {
    for (const idx of this.visible) this.requestRenderPage(idx, { force })
    if (this.visible.size === 0 && this.parts.length > 0) this.requestRenderPage(0, { force })
  },

  requestRenderPage(index, { force = false } = {}) {
    if (!this.api) return
    if (!force && this.rendered.has(index)) return
    const queuedForce = this.renderQueue.get(index) || false
    this.renderQueue.set(index, queuedForce || force)
    if (this.renderQueueTimer) return
    this.renderQueueTimer = setTimeout(() => this.drainRenderQueue(), 0)
  },

  drainRenderQueue() {
    this.renderQueueTimer = null
    if (!this.api || !this.renderQueue.size) return

    // Prefer a forced or currently-VISIBLE page over FIFO order, so the page the
    // user is actually looking at paints first instead of an off-screen page that
    // happened to be queued earlier (the "slide 5 painted while slide 4 still
    // blank" scroll artifact). (#57 B)
    let pick = null
    for (const entry of this.renderQueue) {
      const [index, force] = entry
      if (force || this.visible.has(index)) { pick = entry; break }
    }
    if (!pick) pick = this.renderQueue.entries().next().value
    if (!pick) return
    const [index, force] = pick
    this.renderQueue.delete(index)
    if (force || this.visible.has(index) || (this.visible.size === 0 && index === 0)) {
      this.renderPage(index, { force })
    }

    if (this.renderQueue.size) {
      this.renderQueueTimer = setTimeout(() => this.drainRenderQueue(), 0)
    }
  },

  releasePageCanvas(index) {
    const section = this.pageSection(index)
    if (!section) return
    const canvas = section.querySelector("[data-role='office-wasm-canvas']")
    const overlay = section.querySelector("[data-role='office-wasm-caret-overlay']")
    if (canvas && (canvas.width !== 1 || canvas.height !== 1)) {
      canvas.width = 1
      canvas.height = 1
      const ctx = canvas.getContext("2d")
      if (ctx) {
        ctx.fillStyle = "#ffffff"
        ctx.fillRect(0, 0, 1, 1)
      }
    }
    if (overlay && (overlay.width !== 1 || overlay.height !== 1)) {
      overlay.width = 1
      overlay.height = 1
    }
    this.rendered.delete(index)
  },

  // Paint a page/slide via the engine's paintTile into the page <canvas>.
  // The embind binding (LokEditBindings.cxx) is:
  //   paintTile(part, tileX, tileY, tileW, tileH, canvasW, canvasH) -> Uint8Array
  // It RETURNS a canvasW*canvasH*4 RGBA buffer (already R/B-swapped from the
  // platform BGRA tile mode), painting the document twip rectangle
  // (tileX,tileY,tileW,tileH) into canvasW x canvasH device px. We blit the
  // returned bytes straight into the page <canvas> via ImageData.
  renderPage(index, { force = false } = {}) {
    if (!this.api) return
    if (!force && this.rendered.has(index)) return
    const section = this.pageSection(index)
    if (!section) return
    const canvas = section.querySelector("[data-role='office-wasm-canvas']")
    if (!canvas) return

    const part = this.parts[index] || this.parts[0]
    const logical = this.pageLogicalSize(index, canvas)
    const pxW = Math.max(1, Math.round(logical.width * this.scale))
    const pxH = Math.max(1, Math.round(logical.height * this.scale))
    if (canvas.width !== pxW || canvas.height !== pxH) {
      canvas.width = pxW
      canvas.height = pxH
    }

    try {
      // The tile rectangle is in ABSOLUTE document twips. Two cases (see
      // queryParts): a Writer doc is ONE part whose pages are sub-rectangles of
      // the single flow, so page `index` must paint ITS OWN page rectangle
      // (origin pageRects[index].{x,y}, extent .{w,h}) — painting (0,0,page-size)
      // would paint page 1 onto every canvas. An Impress slide is its own part,
      // so we select the part and paint its whole (0,0,size) box.
      const rect = this.docType === 0 ? this.pageRects[index] : null
      const partArg = this.docType === 0 ? 0 : index
      const tileX = rect ? rect.x : 0
      const tileY = rect ? rect.y : 0
      const tileW = rect ? rect.w : Math.round((part.width || 794) * 1440 / 96) // px -> twips
      const tileH = rect ? rect.h : Math.round((part.height || 1123) * 1440 / 96)

      const rgba = this.callPaintTile(partArg, tileX, tileY, tileW, tileH, pxW, pxH)
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
      if (this.selectionVisual && this.selectionVisual.pages && this.selectionVisual.pages.has(index)) {
        this.paintPickedHighlights()
      }
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
  //   click/drag       -> postMouseEvent(down/move/up, page1based, xPx, yPx)
  //   typing (ASCII)   -> postKeyEvent(KEYINPUT, charCode, 0) + KEYUP
  //   Backspace/Enter/… -> postKeyEvent with the awt keyCode
  //   Korean IME       -> compositionupdate replaces provisional text with
  //                       postKeyEvent/backspace so the real tile changes live
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
  // LibreOfficeKitMouseEventType
  LOK_MOUSEEVENT_MOUSEBUTTONDOWN: 0,
  LOK_MOUSEEVENT_MOUSEBUTTONUP: 1,
  LOK_MOUSEEVENT_MOUSEMOVE: 2,
  // LibreOfficeKitSetTextSelectionType
  LOK_SETTEXTSELECTION_START: 0,
  LOK_SETTEXTSELECTION_END: 1,
  LOK_SETTEXTSELECTION_RESET: 2,
  // vcl mouse/key modifier bits.
  LOK_MOUSE_LEFT: 1,
  LOK_KEY_SHIFT: 0x1000,
  LOK_KEY_MOD1: 0x2000,
  LOK_KEY_MOD2: 0x4000,

  // awt::Key codes (offapi/com/sun/star/awt/Key.idl == vcl KEY_*). postKeyEvent's
  // `keyCode` arg is exactly these; `charCode` is the Unicode code point (and the
  // ASCII control char for Backspace/Delete/Enter, matching init.cxx usage).
  AWT_KEY: {
    Y: 536, Z: 537,
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

  presentationLikeDoc() {
    return this.docType === 2 || this.docType === 3
  },

  spreadsheetLikeDoc() {
    return this.docType === 1
  },

  nativeDoubleClickAvailable() {
    return (this.api.shape === "embind-class" && this.handle && typeof this.handle.doubleClick === "function") ||
      typeof this.api.doubleClick === "function"
  },

  lokModifierMask(event) {
    let mask = 0
    if (event && event.shiftKey) mask |= this.LOK_KEY_SHIFT
    if (event && (event.ctrlKey || event.metaKey)) mask |= this.LOK_KEY_MOD1
    if (event && event.altKey) mask |= this.LOK_KEY_MOD2
    return mask
  },

  nativeMousePage(loc) {
    return this.spreadsheetLikeDoc() ? loc.pageIndex : loc.pageIndex + 1
  },

  postNativeMouseEvent(type, loc, count = 1, buttons = this.LOK_MOUSE_LEFT, modifier = 0) {
    this.callApi("postMouseEvent", type, this.nativeMousePage(loc), loc.x, loc.y, count, buttons, modifier)
  },

  documentTwipPoint(loc) {
    const rect = !this.presentationLikeDoc() && this.pageRects && this.pageRects[loc.pageIndex]
    return {
      x: Math.round((rect && Number(rect.x) || 0) + Number(loc.x || 0) * 1440 / 96),
      y: Math.round((rect && Number(rect.y) || 0) + Number(loc.y || 0) * 1440 / 96)
    }
  },

  postTextSelection(type, loc) {
    const point = this.documentTwipPoint(loc)
    const nativeType =
      this.presentationLikeDoc() && type === this.LOK_SETTEXTSELECTION_RESET
        ? this.LOK_SETTEXTSELECTION_START
        : type
    this.callApi("setTextSelection", nativeType, point.x, point.y)
  },

  presentationTextSelectionDragReady() {
    if (!this.presentationLikeDoc() || !this.hasApiMethod("setTextSelection")) return false
    try {
      if (this.hasApiMethod("isTextEditActive") && this.callApi("isTextEditActive") === true) {
        this.nativeTextEditReady = true
        return true
      }
    } catch (error) {
      console.error("[office-wasm] isTextEditActive failed", error)
    }
    return this.nativeTextEditReady === true && this.nativeCursorTargetReady()
  },

  textSelectionDragReady() {
    if (!this.hasApiMethod("setTextSelection")) return false
    if (this.spreadsheetLikeDoc()) return false
    return this.presentationLikeDoc() ? this.presentationTextSelectionDragReady() : false
  },

  preparePresentationTextDrag(ds) {
    if (!this.presentationLikeDoc() || !this.hasApiMethod("setTextSelection")) return false
    if (this.presentationTextSelectionDragReady()) return true
    if (!this.api || typeof this.api.resolveRef !== "function" || !ds || !ds.startLoc) return false
    let pick = null
    ds.textTarget = false
    try {
      pick = this.officeResolveAt(ds.startLoc, true)
      ds.visualProbe = pick
    } catch (error) {
      console.error("[office-wasm] resolveRef(commit) before text drag failed", error)
      return false
    }
    if (this.presentationTextSelectionDragReady()) return true

    const activationLoc = this.presentationTextActivationLoc(pick)
    if (activationLoc) ds.textTarget = true
    if (!activationLoc || !this.hasApiMethod("doubleClick")) return false

    try {
      this.callApi("doubleClick", activationLoc.pageIndex + 1, activationLoc.x, activationLoc.y)
    } catch (error) {
      console.error("[office-wasm] doubleClick before text drag failed", error)
      return false
    }

    ds.textActivationStarted = true
    return this.presentationTextSelectionDragReady()
  },

  presentationTextActivationLoc(pick) {
    if (!pick || !String(pick.text || "").trim()) return null
    const rect = Array.isArray(pick.rects) ? pick.rects[0] : null
    if (!rect) return null
    const x = Number(rect.x) + Number(rect.width) / 2
    const y = Number(rect.y) + Number(rect.height) / 2
    if (!Number.isFinite(x) || !Number.isFinite(y)) return null
    const pageIndex = Number.isFinite(Number(rect.pageIndex)) ? Number(rect.pageIndex) : 0
    return { pageIndex, x, y }
  },

  nativeCursorTargetReady() {
    if (this.caret) return true
    try {
      const res = this.callApi("getCursor")
      if (res && res.ok) {
        this.caret = { page: res.page, x: res.x, y: res.y, height: res.height }
        window.__officeWasmCaret = this.caret
        return true
      }
    } catch (_) {}
    return false
  },

  queuePresentationTextSelection(ds, loc) {
    if (!ds) return
    if (loc) ds.pendingTextSelectionLoc = loc
    if (ds.textSelectionFrame) return
    const raf = window.requestAnimationFrame || ((fn) => setTimeout(fn, 16))
    ds.textSelectionFrame = raf(() => this.drainPresentationTextSelection(ds))
  },

  drainPresentationTextSelection(ds) {
    ds.textSelectionFrame = null
    if (!ds || !this.api || !ds.startLoc) return
    if (!this.presentationTextSelectionDragReady()) {
      ds.textSelectionAttempts = (ds.textSelectionAttempts || 0) + 1
      if (ds.textSelectionAttempts < 12) {
        this.queuePresentationTextSelection(ds, ds.pendingTextSelectionLoc || ds.lastLoc)
      }
      return
    }

    const loc = ds.pendingTextSelectionLoc || ds.lastLoc
    if (!loc) return

    try {
      ds.mode = "text"
      this.postTextSelection(this.LOK_SETTEXTSELECTION_RESET, ds.startLoc)
      this.postTextSelection(this.LOK_SETTEXTSELECTION_END, loc)
      ds.selectionStarted = true
      this.hasActiveSelection = true
      this.requestDragRenderPage(ds.page)
      if (loc.pageIndex !== ds.page) this.requestDragRenderPage(loc.pageIndex)
      if (ds.released) this.settleAfterMouseSelection(ds.page)
    } catch (error) {
      console.error("[office-wasm] deferred setTextSelection failed", error)
    }
  },

  readNativeInteractionState() {
    if (!this.api || !this.api.getInteractionState) return null
    try {
      const raw = this.callApi("getInteractionState")
      const state = typeof raw === "string" ? JSON.parse(raw) : raw
      this.nativeInteractionState = state || null
      return this.nativeInteractionState
    } catch (error) {
      console.error("[office-wasm] getInteractionState failed", error)
      return this.nativeInteractionState
    }
  },

  updateNativeTextEditReady() {
    if (!this.presentationLikeDoc()) {
      this.nativeTextEditReady = true
      return true
    }
    const state = this.readNativeInteractionState()
    const nativeTextEdit =
      state &&
      (state.textEditActive === true ||
        state.textEditActive === 1 ||
        state.textEditActive === "1")
    const edit = state && state.editingInSelection
    const enabled =
      nativeTextEdit ||
      (!!edit &&
        (edit.enabled === true || edit.enabled === 1 || edit.enabled === "1"))
    this.nativeTextEditReady = enabled
    return enabled
  },

  presentationTextTargetReady() {
    if (!this.presentationLikeDoc()) return true
    const state = this.readNativeInteractionState()
    const nativeTextEdit =
      state &&
      (state.textEditActive === true ||
        state.textEditActive === 1 ||
        state.textEditActive === "1")
    const edit = state && state.editingInSelection
    const table = state && state.tableSelection
    const hasTableTarget =
      !!state &&
      (!!state.focusedCell ||
        !!(table && table.rectangle) ||
        !!(edit &&
          (edit.enabled === true || edit.enabled === 1 || edit.enabled === "1")))
    this.nativeTextEditReady = !!(hasTableTarget || (nativeTextEdit && this.nativeCursorTargetReady()))
    return this.nativeTextEditReady
  },

  sameCaret(a, b) {
    return !!a && !!b &&
      a.page === b.page &&
      Math.round(a.x) === Math.round(b.x) &&
      Math.round(a.y) === Math.round(b.y) &&
      Math.round(a.height || 0) === Math.round(b.height || 0)
  },

  // ─── Mouse: click -> caret, drag -> selection ──────────────────────────────

  onCanvasMouseDown(event) {
    if (event.button !== 0 || !this.api || !this.parts.length) return
    if (this.spreadsheetLikeDoc()) this.flushSpreadsheetTextInput()
    const loc = this.eventToPageLocal(event)
    if (!loc) return
    this.activateKeyboardShortcuts()

    if (this.elementPickerEnabled) {
      event.preventDefault()
      event.stopPropagation()
      const pick = this.officePickAtPoint(loc)
      // bindElementPickerTarget's picks listener repaints the highlights
      // (including removal when the same element is toggled off).
      if (pick) appendPickedElementToComposer(pick)
      return
    }

    // Let the dedicated dblclick handler send LibreOffice the count=2 event.
    // Treating the second press as another plain caret placement collapses the
    // Impress table-cell selection that desktop LibreOffice creates on double
    // click.
    if (event.detail > 1) {
      if (this.suppressPresentationTableDoubleClick(event, loc)) return
      this.activateDoubleClick(loc)
      if (event.cancelable) event.preventDefault()
      if (this.imeProxy) this.imeProxy.focus({ preventScroll: true })
      return
    }

    const modifier = this.lokModifierMask(event)
    const dragMode = this.textSelectionDragReady()
      ? "text"
      : this.presentationLikeDoc()
        ? "pending"
        : "native"
    const visualProbe = null
    try {
      if (dragMode === "text") {
        this.postTextSelection(this.LOK_SETTEXTSELECTION_RESET, loc)
      } else if (dragMode === "native") {
        this.postNativeMouseEvent(
          this.LOK_MOUSEEVENT_MOUSEBUTTONDOWN,
          loc,
          1,
          this.LOK_MOUSE_LEFT,
          modifier
        )
      }
    } catch (error) {
      console.error(
        dragMode === "text"
          ? "[office-wasm] setTextSelection(RESET) failed"
          : "[office-wasm] postMouseEvent(DOWN) failed",
        error
      )
      return
    }

    this.dragSelect = {
      mode: dragMode,
      page: loc.pageIndex,
      startX: loc.x,
      startY: loc.y,
      startLoc: loc,
      lastLoc: loc,
      visualProbe,
      moved: false,
      selectionStarted: false,
      modifier
    }
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
    // Picker mode (no drag in flight): track the DOM-inspector hover preview
    // instead of the drag-select path, matching the HWP arm.
    if (this.elementPickerEnabled && !this.dragSelect) {
      this.queuePickerHover(event)
      return
    }
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
    ds.lastLoc = loc
    if (!ds.moved) return
    try {
      if (ds.mode === "pending") {
        if (this.preparePresentationTextDrag(ds)) {
          ds.mode = "text"
          this.postTextSelection(this.LOK_SETTEXTSELECTION_RESET, ds.startLoc)
          this.postTextSelection(this.LOK_SETTEXTSELECTION_END, loc)
        } else if (ds.textActivationStarted) {
          ds.mode = "text-activating"
          this.queuePresentationTextSelection(ds, loc)
        } else if (ds.textTarget) {
          ds.mode = "text-blocked"
        } else {
          ds.mode = "native"
          this.postNativeMouseEvent(
            this.LOK_MOUSEEVENT_MOUSEBUTTONDOWN,
            ds.startLoc,
            1,
            this.LOK_MOUSE_LEFT,
            ds.modifier
          )
          this.postNativeMouseEvent(
            this.LOK_MOUSEEVENT_MOUSEMOVE,
            loc,
            1,
            this.LOK_MOUSE_LEFT,
            ds.modifier
          )
      }
      } else if (ds.mode === "text") {
        this.postTextSelection(this.LOK_SETTEXTSELECTION_END, loc)
      } else if (ds.mode === "text-activating") {
        this.queuePresentationTextSelection(ds, loc)
      } else if (ds.mode === "text-blocked") {
        // Strict text-target drag: no object-drag substitution.
      } else {
        this.postNativeMouseEvent(
          this.LOK_MOUSEEVENT_MOUSEMOVE,
          loc,
          1,
          this.LOK_MOUSE_LEFT,
          ds.modifier
        )
      }
      ds.selectionStarted = true
      this.updateSelectionVisual(ds, loc, true)
    } catch (error) {
      console.error(
        ds.mode === "text"
          ? "[office-wasm] setTextSelection(END) failed"
          : "[office-wasm] postMouseEvent(MOVE) failed",
        error
      )
    }
    this.hasActiveSelection = true
    this.requestDragRenderPage(ds.page)
    if (loc.pageIndex !== ds.page) this.requestDragRenderPage(loc.pageIndex)
    if (event.cancelable) event.preventDefault()
  },

  onCanvasMouseUp(event) {
    if (!this.dragSelect) return
    const ds = this.dragSelect
    this.dragSelect = null
    const loc = this.eventToPageLocal(event, ds.page) || ds.lastLoc
    if (loc) {
      try {
        if (ds.mode === "pending") {
          if (ds.moved && this.preparePresentationTextDrag(ds)) {
            ds.mode = "text"
            this.postTextSelection(this.LOK_SETTEXTSELECTION_RESET, ds.startLoc)
            this.postTextSelection(this.LOK_SETTEXTSELECTION_END, loc)
          } else if (ds.textActivationStarted) {
            ds.mode = "text-activating"
            ds.released = true
            this.queuePresentationTextSelection(ds, loc)
          } else if (ds.textTarget) {
            ds.mode = "text-blocked"
          } else {
            ds.mode = "native"
            this.postNativeMouseEvent(
              this.LOK_MOUSEEVENT_MOUSEBUTTONDOWN,
              ds.startLoc,
              1,
              this.LOK_MOUSE_LEFT,
              ds.modifier
            )
            this.postNativeMouseEvent(
              this.LOK_MOUSEEVENT_MOUSEBUTTONUP,
              loc,
              1,
              this.LOK_MOUSE_LEFT,
              ds.modifier
            )
          }
        } else if (ds.mode === "text" && ds.moved) {
          this.postTextSelection(this.LOK_SETTEXTSELECTION_END, loc)
        } else if (ds.mode === "text-activating") {
          ds.released = true
          this.queuePresentationTextSelection(ds, loc)
        } else if (ds.mode === "text-blocked") {
          // Strict text-target drag: no object-drag substitution.
        } else if (ds.mode !== "text") {
          this.postNativeMouseEvent(
            this.LOK_MOUSEEVENT_MOUSEBUTTONUP,
            loc,
            1,
            this.LOK_MOUSE_LEFT,
            ds.modifier
          )
        }
      } catch (error) {
        console.error(
          ds.mode === "text"
            ? "[office-wasm] setTextSelection(END on mouseup) failed"
            : "[office-wasm] postMouseEvent(UP) failed",
          error
        )
      }
    }
    if (!ds.moved) {
      this.hasActiveSelection = false
      this.renderPage(ds.page, { force: true })
      this.settleCaretAfterHit(null)
    } else {
      this.hasActiveSelection = true
      this.renderPage(ds.page, { force: true })
      if (loc && loc.pageIndex !== ds.page) this.renderPage(loc.pageIndex, { force: true })
      this.updateSelectionVisual(ds, loc, false)
      this.settleAfterMouseSelection(ds.page)
    }
    if (this.imeProxy) {
      this.imeProxy.focus({ preventScroll: true })
      this.anchorProxy()
    }
    if (event.cancelable) event.preventDefault()
  },

  requestDragRenderPage(index) {
    if (!this.api || typeof index !== "number") return
    if (!this.dragRenderPages) this.dragRenderPages = new Set()
    this.dragRenderPages.add(index)
    if (this.dragRenderFrame) return
    const raf = window.requestAnimationFrame || ((fn) => setTimeout(fn, 16))
    this.dragRenderFrame = raf(() => this.drainDragRenderPages())
  },

  drainDragRenderPages() {
    this.dragRenderFrame = null
    if (!this.dragRenderPages || !this.dragRenderPages.size) return
    const pages = Array.from(this.dragRenderPages)
    this.dragRenderPages.clear()
    for (const page of pages) this.renderPage(page, { force: true })
  },

  onCanvasDoubleClick(event) {
    if (!this.api || !this.parts.length) return
    const loc = this.eventToPageLocal(event)
    if (!loc) return
    this.activateKeyboardShortcuts()

    if (this.suppressPresentationTableDoubleClick(event, loc)) return

    if (this.recentDoubleActivation(loc)) {
      if (event.cancelable) event.preventDefault()
      return
    }

    this.activateDoubleClick(loc)
    if (event.cancelable) event.preventDefault()
  },

  suppressPresentationTableDoubleClick(event, loc) {
    if (!this.presentationLikeDoc() || !this.presentationTableAtPoint(loc)) return false
    if (event.cancelable) event.preventDefault()
    event.stopPropagation()
    if (this.imeProxy) this.imeProxy.focus({ preventScroll: true })
    return true
  },

  presentationTableAtPoint(loc) {
    let pick = null
    try {
      pick = this.officeResolveAt(loc, false)
    } catch (_) {
      return false
    }
    const ref = String(pick && pick.ref || "")
    const type = String(pick && pick.type || "")
    return /table/i.test(type) || /shape\[table/i.test(ref)
  },

  recentDoubleActivation(loc) {
    const last = this._lastDoubleActivation
    return !!last &&
      performance.now() - last.t < 350 &&
      last.pageIndex === loc.pageIndex &&
      Math.abs(last.x - loc.x) < 2 &&
      Math.abs(last.y - loc.y) < 2
  },

  activateDoubleClick(loc) {
    this._lastDoubleActivation = {
      t: performance.now(),
      pageIndex: loc.pageIndex,
      x: loc.x,
      y: loc.y
    }

    this.dragSelect = null
    if (this._caretSettle) { clearTimeout(this._caretSettle); this._caretSettle = null }

    // Impress/Draw needs native edit mode before keyboard input works. Send the
    // real native double-click, then wait until Libre reports a table/caret target.
    if (this.presentationLikeDoc()) {
      this.nativeTextEditReady = false
      this.nativeInteractionState = null
      this.caret = null
      this.clearAllCaretOverlays()

      try {
        if (this.nativeDoubleClickAvailable()) this.callApi("doubleClick", loc.pageIndex + 1, loc.x, loc.y)
        else this.placeCaret(loc.pageIndex, loc.x, loc.y)
        this.hasActiveSelection = true
        this.renderPage(loc.pageIndex, { force: true })
        this.settleCaretAfterHit(null)
      } catch (error) {
        console.error("[office-wasm] doubleClick failed", error)
      }

      if (this.imeProxy) {
        this.imeProxy.focus({ preventScroll: true })
        this.anchorProxy()
      }
      return
    }

    ++this._caretSettleSeq

    try {
      if (this.nativeDoubleClickAvailable()) this.callApi("doubleClick", loc.pageIndex + 1, loc.x, loc.y)
      else this.placeCaret(loc.pageIndex, loc.x, loc.y)
      this.hasActiveSelection = true
      this.renderPage(loc.pageIndex, { force: true })
      this.refreshCaret()
      this.settleAfterMouseSelection(loc.pageIndex)
    } catch (error) {
      console.error("[office-wasm] doubleClick failed", error)
    }

    if (this.imeProxy) {
      this.imeProxy.focus({ preventScroll: true })
      this.anchorProxy()
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
    const logical = this.pageLogicalSize(pageIndex, canvas)
    const clientX = Math.min(Math.max(event.clientX, rect.left), rect.right)
    const clientY = Math.min(Math.max(event.clientY, rect.top), rect.bottom)
    const x = ((clientX - rect.left) / rect.width) * logical.width
    const y = ((clientY - rect.top) / rect.height) * logical.height
    return { pageIndex, x, y }
  },

  pageLogicalSize(pageIndex0, canvas = null) {
    const part = this.parts[pageIndex0] || this.parts[0] || {}
    let width = Number(part.width)
    let height = Number(part.height)

    if (!(width > 0) && canvas) width = canvas.width / (this.scale || 1)
    if (!(height > 0) && canvas) height = canvas.height / (this.scale || 1)

    return {
      width: Math.max(1, width || 794),
      height: Math.max(1, height || 1123)
    }
  },

  // Place the LOK caret via hitTest (page is 1-based). hitTest posts the native
  // mouse events; for presentation/table editing the browser waits for LOK's
  // native edit-state callbacks before drawing a caret or accepting typing.
  placeCaret(pageIndex0, xPx, yPx) {
    let immediate = null
    if (this.presentationLikeDoc()) {
      this.nativeTextEditReady = false
      this.nativeInteractionState = null
      this.caret = null
      this.clearAllCaretOverlays()
    }

    try {
      const res = this.callApi("hitTest", pageIndex0 + 1, xPx, yPx)
      if (res && res.ok) {
        immediate = { page: res.page, x: res.x, y: res.y, height: res.height }
        if (!this.presentationLikeDoc()) this.caret = immediate
      }
    } catch (error) {
      console.error("[office-wasm] hitTest failed", error)
    }
    if (!this.presentationLikeDoc() && this.caret) {
      this.caretBlinkOn = true
      this.drawCaret()
      window.__officeWasmCaret = this.caret
    }
    this.settleCaretAfterHit(immediate)
  },

  // After a hit, the real caret can arrive over a few cursor callbacks. Poll
  // getCursor() until the rect is stable instead of adopting the first changed
  // rect, which can still be one character behind the final caret.
  settleCaretAfterHit(immediate) {
    if (this._caretSettle) { clearTimeout(this._caretSettle); this._caretSettle = null }
    const startedFor = ++this._caretSettleSeq
    const requireNativeEditState = this.presentationLikeDoc()
    let tries = 0
    let stable = 0
    let sawFresh = false
    let last = null
    const adopt = (fresh) => {
      this.caret = fresh
      window.__officeWasmCaret = this.caret
      this.caretBlinkOn = true
      if (requireNativeEditState) this.renderPage(fresh.page - 1, { force: true })
      this.drawCaret()
      this.anchorProxy()
    }
    const tick = () => {
      this._caretSettle = null
      // A newer click superseded this settle — stop.
      if (startedFor !== this._caretSettleSeq) return
      // A live drag owns the caret/selection; don't fight it. A held plain click
      // can still settle, otherwise long-press clicks stay on the stale rect.
      if (this.dragSelect && this.dragSelect.moved) return
      const nativeReady = !requireNativeEditState || this.updateNativeTextEditReady()
      let res = null
      try { res = this.callApi("getCursor") } catch (_) {}
      if (res && res.ok && nativeReady) {
        const fresh = { page: res.page, x: res.x, y: res.y, height: res.height }
        const movedFromStart = !this.sameCaret(fresh, immediate)
        if (requireNativeEditState || movedFromStart || sawFresh || tries >= 5) {
          adopt(fresh)
          sawFresh = true
        }
        stable = this.sameCaret(fresh, last) && sawFresh ? stable + 1 : 0
        last = fresh
        if ((sawFresh && stable >= 2) || tries >= 12) {
          if (!sawFresh && !requireNativeEditState) adopt(fresh)
          return
        }
      } else if (requireNativeEditState && tries >= 13) {
        this.nativeTextEditReady = false
        this.caret = null
        this.clearAllCaretOverlays()
        window.__officeWasmCaret = null
        return
      }
      if (++tries < 14) this._caretSettle = setTimeout(tick, 40)
    }
    this._caretSettle = setTimeout(tick, 40)
  },

  // Key/IME edits also move the LOK cursor asynchronously. Multi-char input can
  // report several cursor positions (after char 1, then char N), so keep polling
  // until the cursor is stable instead of stopping at the first changed rect.
  settleCaretAfterInput(previous, repaintContent = false) {
    if (this._caretSettle) { clearTimeout(this._caretSettle); this._caretSettle = null }
    const startedFor = ++this._caretSettleSeq
    const requireNativeEditState = this.presentationLikeDoc()
    const repaintOnAdopt = repaintContent || requireNativeEditState
    let tries = 0
    let stable = 0
    let sawMove = false
    let last = null
    const adopt = (fresh) => {
      this.caret = fresh
      window.__officeWasmCaret = this.caret
      this.caretBlinkOn = true
      if (repaintOnAdopt) {
        this.renderPage(fresh.page - 1, { force: true })
      }
      this.drawCaret()
      this.anchorProxy()
    }
    const tick = () => {
      this._caretSettle = null
      if (startedFor !== this._caretSettleSeq) return
      if (this.dragSelect && this.dragSelect.moved) return
      const nativeReady = !requireNativeEditState || this.updateNativeTextEditReady()
      let res = null
      try { res = this.callApi("getCursor") } catch (_) {}
      if (res && res.ok && nativeReady) {
        const fresh = { page: res.page, x: res.x, y: res.y, height: res.height }
        const movedFromStart = !this.sameCaret(fresh, previous)
        if (requireNativeEditState || movedFromStart || sawMove || tries >= 5) {
          adopt(fresh)
          sawMove = true
        }
        stable = this.sameCaret(fresh, last) && sawMove ? stable + 1 : 0
        last = fresh
        if ((sawMove && stable >= 2) || tries >= 18) {
          if (!sawMove && !requireNativeEditState) adopt(fresh)
          return
        }
      } else if (requireNativeEditState && tries >= 19) {
        this.nativeTextEditReady = false
        return
      }
      if (++tries < 20) this._caretSettle = setTimeout(tick, 40)
    }
    this._caretSettle = setTimeout(tick, 40)
  },

  settleAfterMouseSelection(pageIndex0) {
    if (this._caretSettle) { clearTimeout(this._caretSettle); this._caretSettle = null }
    const startedFor = ++this._caretSettleSeq
    let tries = 0
    const tick = () => {
      this._caretSettle = null
      if (startedFor !== this._caretSettleSeq) return
      this.renderPage(pageIndex0, { force: true })
      this.refreshCaret()
      try {
        const selected = this.callApi("getTextSelection", "text/plain;charset=utf-8")
        const hasSelection = !!String(selected || "").replace(/\0/g, "")
        this.hasActiveSelection = this.hasActiveSelection || hasSelection
        if (hasSelection) {
          this.confirmSelectionVisual()
        } else if (tries > 1) {
          this.clearSelectionVisual()
        }
      } catch (_) {}
      if (++tries < 6) this._caretSettle = setTimeout(tick, 40)
    }
    this._caretSettle = setTimeout(tick, 40)
  },

  // Refresh the caret rect from getCursor() (after a key/IME edit moved it).
  refreshCaret() {
    try {
      if (this.presentationLikeDoc() && !this.updateNativeTextEditReady()) {
        this.caret = null
        this.clearAllCaretOverlays()
        window.__officeWasmCaret = null
        return
      }
      const res = this.callApi("getCursor")
      if (res && res.ok) {
        this.caret = { page: res.page, x: res.x, y: res.y, height: res.height }
        window.__officeWasmCaret = this.caret
      } else if (this.presentationLikeDoc()) {
        this.caret = null
        this.clearAllCaretOverlays()
        window.__officeWasmCaret = null
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

  paintCaretOnPage(pageIndex) {
    const c = this.caret
    if (!c || c.page - 1 !== pageIndex || !this.caretBlinkOn) return
    const overlay = this.caretOverlay(pageIndex)
    if (!overlay) return
    const ctx = overlay.getContext("2d")
    if (!ctx) return
    const logical = this.pageLogicalSize(pageIndex)
    const sx = overlay.width / logical.width
    const sy = overlay.height / logical.height
    ctx.fillStyle = "#1d4ed8"
    ctx.fillRect(c.x * sx, c.y * sy, 1.5 * sx, Math.max(8, c.height || 16) * sy)
  },

  // Draw the blinking caret on its page's overlay (page-local px scaled to the
  // overlay backing store == page canvas size). Clears every overlay first so a
  // caret that moved to a new page never leaves a stale one behind.
  drawCaret() {
    const c = this.caret
    if (!c) return
    this.clearAllCaretOverlays()
    // The caret blink clears EVERY overlay — restore the element-picker
    // highlights before the caret so picks survive the blink cycle.
    this.paintAllAdornments()
    this.paintCaretOnPage(c.page - 1)
  },

  selectionVisualProbe(loc) {
    if (!loc || !this.api || typeof this.api.resolveRef !== "function") return null
    try {
      const pick = this.officeResolveAt(loc, false)
      if (!pick || !Array.isArray(pick.rects) || !pick.rects.length) return null
      return pick
    } catch (_) {
      return null
    }
  },

  selectionLineRectForLoc(loc, probe) {
    if (!loc || !probe || !Array.isArray(probe.rects) || !probe.rects.length) return null
    let best = null
    let bestDistance = Infinity
    for (const rect of probe.rects) {
      if ((rect.pageIndex ?? 0) !== loc.pageIndex) continue
      const top = Number(rect.y)
      const height = Number(rect.height)
      const bottom = top + height
      const distance = loc.y >= top && loc.y <= bottom
        ? 0
        : Math.min(Math.abs(loc.y - top), Math.abs(loc.y - bottom))
      if (distance < bestDistance) {
        best = rect
        bestDistance = distance
      }
    }
    return best
  },

  selectionVisualRects(ds, loc) {
    if (!ds || !ds.startLoc || !loc) return []
    if (ds.startLoc.pageIndex !== loc.pageIndex) return []

    const startProbe = ds.visualProbe || null
    const endProbe = startProbe
    const startLine = this.selectionLineRectForLoc(ds.startLoc, startProbe)
    const endLine = this.selectionLineRectForLoc(loc, endProbe)

    const pageIndex = loc.pageIndex
    if (startLine && endLine) {
      const sameLine = Math.abs(Number(startLine.y) - Number(endLine.y)) <=
        Math.max(Number(startLine.height) || 16, Number(endLine.height) || 16)
      if (sameLine) {
        const left = Math.max(Number(startLine.x), Math.min(ds.startLoc.x, loc.x))
        const right = Math.min(
          Number(startLine.x) + Number(startLine.width),
          Math.max(ds.startLoc.x, loc.x)
        )
        if (right > left) {
          return [{
            pageIndex,
            x: left,
            y: Number(startLine.y),
            width: right - left,
            height: Number(startLine.height) || 16
          }]
        }
      }

      const first = Number(startLine.y) <= Number(endLine.y) ? startLine : endLine
      const last = first === startLine ? endLine : startLine
      const startLoc = first === startLine ? ds.startLoc : loc
      const endLoc = first === startLine ? loc : ds.startLoc
      const rects = []
      const firstRight = Number(first.x) + Number(first.width)
      const firstLeft = Math.max(Number(first.x), Math.min(firstRight, startLoc.x))
      if (firstRight > firstLeft) {
        rects.push({
          pageIndex,
          x: firstLeft,
          y: Number(first.y),
          width: firstRight - firstLeft,
          height: Number(first.height) || 16
        })
      }
      const lastLeft = Number(last.x)
      const lastRight = Math.min(Number(last.x) + Number(last.width), Math.max(lastLeft, endLoc.x))
      if (lastRight > lastLeft) {
        rects.push({
          pageIndex,
          x: lastLeft,
          y: Number(last.y),
          width: lastRight - lastLeft,
          height: Number(last.height) || 16
        })
      }
      return rects
    }

    const height = Math.max(12, Math.abs(loc.y - ds.startLoc.y) || 16)
    return [{
      pageIndex,
      x: Math.min(ds.startLoc.x, loc.x),
      y: Math.min(ds.startLoc.y, loc.y) - height / 2,
      width: Math.abs(loc.x - ds.startLoc.x),
      height
    }].filter(rect => rect.width > 0)
  },

  setSelectionVisual(rects, confirmed = false) {
    if (!rects || !rects.length) {
      this.clearSelectionVisual()
      return
    }
    const pages = new Set(rects.map(rect => rect.pageIndex ?? 0))
    this.selectionVisual = { rects, pages, confirmed }
    window.__officeWasmSelectionVisual = {
      rects,
      pages: Array.from(pages),
      confirmed
    }
    this.paintPickedHighlights()
  },

  updateSelectionVisual(ds, loc, provisional) {
    const rects = this.selectionVisualRects(ds, loc)
    if (!rects.length) return
    this.setSelectionVisual(rects, !provisional)
  },

  confirmSelectionVisual() {
    if (!this.selectionVisual) return
    this.selectionVisual.confirmed = true
    window.__officeWasmSelectionVisual = {
      rects: this.selectionVisual.rects,
      pages: Array.from(this.selectionVisual.pages || []),
      confirmed: true
    }
    this.paintPickedHighlights()
  },

  clearSelectionVisual() {
    if (!this.selectionVisual) {
      window.__officeWasmSelectionVisual = null
      return
    }
    this.selectionVisual = null
    window.__officeWasmSelectionVisual = null
    this.paintPickedHighlights()
  },

  // ─── Element picker (docx/pptx in the browser) ────────────────────────────

  // Resolve the clicked element through the same read-only probe used by hover.
  // The picker must not post a native LOK click: Impress table clicks enter table
  // edit state asynchronously after the resolver returns, which can wedge the
  // browser tab while the picker keeps probing. getElements() carries no layout
  // geometry, so resolveRef/hitRef is still the pixel->ref mapping; on an older
  // wasm build (no export) picking is disabled instead of guessing a wrong element.
  officePickAtPoint(loc) {
    return this.officeResolveAt(loc, false)
  },

  // commit=true: native-click compatibility for direct callers (caret lands at
  // the click, like a user click). The picker intentionally uses commit=false.
  // commit=false: a hover probe — resolveRef restores the previous
  // caret/selection so sweeping the pointer never steals the editing state.
  officeResolveAt(loc, commit) {
    const resolve = this.api && this.api.resolveRef
    const legacy = this.api && this.api.hitRef
    const fn = typeof resolve === "function" ? resolve : legacy
    if (typeof fn !== "function") {
      console.warn(
        "[office-wasm] element picking needs the hitRef export — rebuild soffice.wasm"
      )
      return null
    }

    let hit
    try {
      hit = typeof resolve === "function"
        ? resolve(loc.pageIndex + 1, loc.x, loc.y, !!commit)
        : fn(loc.pageIndex + 1, loc.x, loc.y)
    } catch (error) {
      console.error("[office-wasm] hitRef failed", error)
      return null
    }
    if (!hit || !hit.ok || !hit.ref) return null

    // Highlight rects (page-local px), best first: per-line element rects from
    // resolveRef (Writer cells/paragraphs — accurate), then shape bounds, then
    // a caret-line marker as the last resort.
    const rects = []
    const lineRects = hit.rects
    if (lineRects && typeof lineRects.length === "number" && lineRects.length > 0) {
      for (let i = 0; i < lineRects.length; i++) {
        const r = lineRects[i]
        if (!r || !Number.isFinite(Number(r.width))) continue
        rects.push({
          pageIndex: (Number(r.page) || 1) - 1,
          x: Number(r.x),
          y: Number(r.y),
          width: Number(r.width),
          height: Number(r.height)
        })
      }
    }
    if (!rects.length && hit.bounds && Number.isFinite(Number(hit.bounds.width))) {
      rects.push({
        pageIndex: loc.pageIndex,
        x: Number(hit.bounds.x),
        y: Number(hit.bounds.y),
        width: Number(hit.bounds.width),
        height: Number(hit.bounds.height)
      })
    } else if (hit.caret && hit.caret.ok !== false && Number.isFinite(Number(hit.caret.x))) {
      const h = Number(hit.caret.height) || 14
      const page = Number.isFinite(Number(hit.caret.page))
        ? Number(hit.caret.page) - 1
        : loc.pageIndex
      rects.push({
        pageIndex: page,
        x: Number(hit.caret.x) - 2,
        y: Number(hit.caret.y),
        width: Math.max(90, h * 6),
        height: h
      })
    }

    return {
      document: this.el.dataset.documentPath || "",
      backend: "libre",
      format: this.format || "",
      type: hit.type || "unknown",
      ref: hit.ref,
      text: hit.text || "",
      rects,
      ir: {
        page: loc.pageIndex + 1,
        point: { x: loc.x, y: loc.y },
        hit: { ref: hit.ref, type: hit.type }
      }
    }
  },

  // ─── Picker hover preview (DOM-inspector style) ───────────────────────────
  // Hover is intentionally dwell-based. resolveRef is synchronous on the
  // LibreOffice main thread, and running it while the pointer is moving makes
  // the picker feel stuck on larger decks. Click-pick remains immediate and
  // precise; hover is a preview only.
  queuePickerHover(event) {
    const loc = this.eventToPageLocal(event)
    this.pickerHoverLoc = loc

    // Off every page canvas: clear immediately rather than after the delay.
    if (!loc) {
      if (this.pickerHoverTimer) clearTimeout(this.pickerHoverTimer)
      this.pickerHoverTimer = null
      this.setPickerHover(null)
      return
    }

    const cached = this.cachedPickerHover(loc)
    if (cached !== undefined) {
      if (this.pickerHoverTimer) clearTimeout(this.pickerHoverTimer)
      this.pickerHoverTimer = null
      this.applyPickerHoverProbe(cached)
      return
    }

    if (this.pickerHoverTimer) clearTimeout(this.pickerHoverTimer)
    this.pickerHoverTimer = setTimeout(() => {
      this.pickerHoverTimer = null
      this.updatePickerHoverAt(this.pickerHoverLoc)
    }, this.pickerHoverDelay())
  },

  updatePickerHover(event) {
    if (!this.elementPickerEnabled || !this.api || !event) {
      this.setPickerHover(null)
      return
    }
    const loc = this.eventToPageLocal(event)
    if (!loc) {
      this.setPickerHover(null)
      return
    }
    this.updatePickerHoverAt(loc)
  },

  updatePickerHoverAt(loc) {
    if (!this.elementPickerEnabled || !this.api || !loc) {
      this.setPickerHover(null)
      return
    }
    const probe = this.officeResolveAt(loc, false)
    this.rememberPickerHover(loc, probe)
    this.applyPickerHoverProbe(probe)
  },

  applyPickerHoverProbe(probe) {
    if (!probe || !(probe.rects || []).length) {
      this.setPickerHover(null)
      return
    }
    if (this.pickerHover && this.pickerHover.key === probe.ref) return
    this.setPickerHover({ key: probe.ref, rects: probe.rects })
  },

  pickerHoverDelay() {
    return this.api && typeof this.api.resolveRef === "function" ? 180 : 240
  },

  pickerHoverKey(loc) {
    return `${loc.pageIndex}:${Math.floor(loc.x / 8)}:${Math.floor(loc.y / 8)}`
  },

  cachedPickerHover(loc) {
    if (!this.pickerHoverCache) return undefined
    const key = this.pickerHoverKey(loc)
    return this.pickerHoverCache.has(key) ? this.pickerHoverCache.get(key) : undefined
  },

  rememberPickerHover(loc, probe) {
    if (!this.pickerHoverCache) this.pickerHoverCache = new Map()
    const key = this.pickerHoverKey(loc)
    this.pickerHoverCache.set(key, probe || null)
    if (this.pickerHoverCache.size > 300) {
      const first = this.pickerHoverCache.keys().next().value
      if (first !== undefined) this.pickerHoverCache.delete(first)
    }
  },

  setPickerHover(hover) {
    if (!hover && !this.pickerHover) return
    this.pickerHover = hover
    this.paintPickedHighlights()
  },

  // bindElementPickerTarget calls this on mode flips: every transition starts
  // with a blank hover preview and no pending dwell probe.
  onElementPickerState(enabled) {
    if (this.pickerHoverTimer) {
      clearTimeout(this.pickerHoverTimer)
      this.pickerHoverTimer = null
    }
    this.pickerHoverLoc = null
    if (enabled) this.pickerHoverCache = new Map()
    this.setPickerHover(null)
  },

  currentDocumentPicks() {
    const picker = window.EcritsDocumentElementPicker
    const picks = (picker && picker.picks) || []
    const docPath = this.el && this.el.dataset ? this.el.dataset.documentPath || "" : ""
    return picks.filter(p => p.document === docPath)
  },

  // bindElementPickerTarget calls this on every pick change: repaint the
  // overlays so highlights appear/disappear with the picks.
  paintPickedHighlights() {
    if (this.caret) {
      this.drawCaret() // clears all overlays, repaints adornments + caret
      return
    }
    this.clearAllCaretOverlays()
    this.paintAllAdornments()
  },

  paintAllAdornments() {
    const pages = new Set()
    if (this.selectionVisual) {
      for (const rect of this.selectionVisual.rects || []) pages.add(rect.pageIndex ?? 0)
    }
    for (const pick of this.currentDocumentPicks()) {
      for (const rect of pick.rects || []) pages.add(rect.pageIndex ?? 0)
    }
    const hover = this.elementPickerEnabled ? this.pickerHover : null
    if (hover) {
      for (const rect of hover.rects || []) pages.add(rect.pageIndex ?? 0)
    }
    for (const page of pages) this.paintAdornmentsOnPage(page)
  },

  paintAdornmentsOnPage(pageIndex) {
    const overlay = this.caretOverlay(pageIndex)
    if (!overlay) return
    const ctx = overlay.getContext("2d")
    if (!ctx) return
    const logical = this.pageLogicalSize(pageIndex)
    if (!logical || !logical.width || !logical.height) return
    const sx = overlay.width / logical.width
    const sy = overlay.height / logical.height

    if (this.selectionVisual) {
      for (const rect of this.selectionVisual.rects || []) {
        if ((rect.pageIndex ?? 0) !== pageIndex) continue
        ctx.save()
        ctx.fillStyle = this.selectionVisual.confirmed
          ? "rgba(37, 99, 235, 0.30)"
          : "rgba(37, 99, 235, 0.22)"
        ctx.fillRect(rect.x * sx, rect.y * sy, rect.width * sx, rect.height * sy)
        ctx.restore()
      }
    }

    for (const pick of this.currentDocumentPicks()) {
      for (const rect of pick.rects || []) {
        if ((rect.pageIndex ?? 0) !== pageIndex) continue
        ctx.save()
        ctx.fillStyle = "rgba(99, 102, 241, 0.16)"
        ctx.strokeStyle = "rgba(79, 70, 229, 0.95)"
        ctx.lineWidth = Math.max(2, 1.5 * (this.scale || 1))
        ctx.fillRect(rect.x * sx, rect.y * sy, rect.width * sx, rect.height * sy)
        ctx.strokeRect(rect.x * sx, rect.y * sy, rect.width * sx, rect.height * sy)
        ctx.restore()
      }
    }

    // Hover preview: filled box + dashed outline, matching the HWP picker.
    const hover = this.elementPickerEnabled ? this.pickerHover : null
    if (hover) {
      for (const rect of hover.rects || []) {
        if ((rect.pageIndex ?? 0) !== pageIndex) continue
        ctx.save()
        ctx.fillStyle = "rgba(99, 102, 241, 0.13)"
        ctx.strokeStyle = "rgba(79, 70, 229, 0.9)"
        ctx.lineWidth = Math.max(2, 1.5 * (this.scale || 1))
        ctx.setLineDash([5, 3])
        ctx.fillRect(rect.x * sx, rect.y * sy, rect.width * sx, rect.height * sy)
        ctx.strokeRect(rect.x * sx, rect.y * sy, rect.width * sx, rect.height * sy)
        ctx.restore()
      }
    }
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
    const logical = this.pageLogicalSize(c.page - 1, canvas)
    const cssX = cr.width / logical.width
    const cssY = cr.height / logical.height
    const left = cr.left - hostRect.left + this.el.scrollLeft + c.x * cssX
    const top = cr.top - hostRect.top + this.el.scrollTop + c.y * cssY
    this.imeProxy.style.left = `${Math.round(left)}px`
    this.imeProxy.style.top = `${Math.round(top)}px`
    this.imeProxy.style.height = `${Math.max(12, Math.round((c.height || 16) * cssY))}px`
  },

  clearSelectionState() {
    this.hasActiveSelection = false
    this.clearSelectionVisual()
  },

  // Re-paint the caret's page tile (+ any other visible page, for reflow) so a
  // just-applied edit / selection shows immediately.
  renderCaretWindow() {
    const idx = this.caret ? this.caret.page - 1 : null
    if (typeof idx === "number") this.renderPage(idx, { force: true })
    for (const v of this.visible) if (v !== idx) this.renderPage(v, { force: true })
  },

  renderAfterInput() {
    if (this.presentationLikeDoc() && this.presentationTextTargetReady()) {
      const idx = this.caret ? this.caret.page - 1 : null
      if (typeof idx === "number") this.renderPage(idx, { force: true })
      return
    }
    this.renderCaretWindow()
  },

  // ─── Keyboard + IME wiring (the IME proxy is the OS-focused element) ────────

  bindEditing() {
    if (!this.imeProxy) return
    this.onInput = e => this.handleInput(e)
    this.onCompositionStart = e => this.handleCompositionStart(e)
    this.onCompositionUpdate = e => this.handleCompositionUpdate(e)
    this.onCompositionEnd = e => this.handleCompositionEnd(e)
    this.onKeyDown = e => this.handleKeyDown(e)
    this.onCopy = e => this.handleCopy(e)
    this.onPaste = e => this.handlePaste(e)
    this.onProxyFocus = () => this.activateKeyboardShortcuts()

    this.imeProxy.addEventListener("input", this.onInput)
    this.imeProxy.addEventListener("compositionstart", this.onCompositionStart)
    this.imeProxy.addEventListener("compositionupdate", this.onCompositionUpdate)
    this.imeProxy.addEventListener("compositionend", this.onCompositionEnd)
    this.imeProxy.addEventListener("keydown", this.onKeyDown)
    this.imeProxy.addEventListener("copy", this.onCopy)
    this.imeProxy.addEventListener("paste", this.onPaste)
    this.imeProxy.addEventListener("focus", this.onProxyFocus)
  },

  unbindEditing() {
    if (!this.imeProxy) return
    this.imeProxy.removeEventListener("input", this.onInput)
    this.imeProxy.removeEventListener("compositionstart", this.onCompositionStart)
    this.imeProxy.removeEventListener("compositionupdate", this.onCompositionUpdate)
    this.imeProxy.removeEventListener("compositionend", this.onCompositionEnd)
    this.imeProxy.removeEventListener("keydown", this.onKeyDown)
    this.imeProxy.removeEventListener("copy", this.onCopy)
    this.imeProxy.removeEventListener("paste", this.onPaste)
    this.imeProxy.removeEventListener("focus", this.onProxyFocus)
  },

  activateKeyboardShortcuts() {
    activeOfficeShortcutEditor = this
  },

  handleDocumentPointerDown(event) {
    if (activeOfficeShortcutEditor !== this) return
    const target = event.target
    if (target && this.el && this.el.contains && this.el.contains(target)) return
    if (target === this.imeProxy) return
    activeOfficeShortcutEditor = null
  },

  handleDocumentKeyDown(event) {
    if (event.defaultPrevented || !this.documentShortcutTarget(event)) return
    this.handleEditShortcut(event)
  },

  documentShortcutTarget(event) {
    if (activeOfficeShortcutEditor !== this) return false
    if (!this.api || !this.parts.length) return false
    const target = event.target
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

  // keydown — non-composing keys only. Printable chars and special keys both go
  // through postKeyEvent; composition keystrokes are owned by the composition*
  // path (we must skip them here, else Hangul double-inserts). Editing shortcuts
  // (Cmd/Ctrl) pass through to the browser/UNO.
  handleKeyDown(event) {
    if (this.saveShortcut(event)) {
      event.preventDefault()
      event.stopPropagation()
      if (this.spreadsheetLikeDoc()) this.flushSpreadsheetTextInput()
      this.saveLocalDocument({})
      return
    }
    if (!this.api || !this.parts.length) return
    if (event.isComposing || this.composing) return // IME owns the keystroke
    if (this.koreanImeKey(event)) return
    if (this.handleEditShortcut(event)) return
    if (event.metaKey || event.ctrlKey || event.altKey) return // unhandled shortcuts pass through

    const k = event.key
    if (k === "Tab") {
      if (this.spreadsheetLikeDoc()) this.flushSpreadsheetTextInput()
      event.preventDefault()
      event.stopPropagation()
      if (this.imeProxy) this.imeProxy.focus({ preventScroll: true })
      this.anchorProxy()
      return
    }

    if (this.spreadsheetLikeDoc()) {
      if (k === "Enter" && this.spreadsheetEditBuffer) {
        event.preventDefault()
        event.stopPropagation()
        this.flushSpreadsheetTextInput({ commit: true })
        return
      }

      if (k === "Escape" && this.spreadsheetEditBuffer) {
        event.preventDefault()
        event.stopPropagation()
        this.clearSpreadsheetTextInput()
        return
      }

      if (k === "Backspace" && this.spreadsheetEditBuffer) {
        event.preventDefault()
        event.stopPropagation()
        this.spreadsheetEditBuffer = Array.from(this.spreadsheetEditBuffer).slice(0, -1).join("")
        this.scheduleSpreadsheetTextInputFlush()
        return
      }

      if (k && k.length === 1) {
        event.preventDefault()
        event.stopPropagation()
        this.queueSpreadsheetTextInput(k)
        return
      }
    }

    const special = this.specialKeyCode(k)
    if (special != null) {
      event.preventDefault()
      const previous = this.caret
      const posted = this.postKey(special.charCode, special.keyCode)
      // Caret-moving keys (arrows/home/end) don't change content -> just refresh
      // the caret; content keys repaint the page first.
      if (special.repaint) this.renderAfterInput()
      this.refreshCaret()
      this.settleCaretAfterInput(previous, special.repaint)
      if (special.repaint && posted) this.markViewerMutated()
      return
    }

    // Printable single character (length-1 key, no modifier). Multi-char keys
    // ("Shift", "Tab"→handled above, "Dead", etc.) are not text.
    if (k && k.length === 1) {
      event.preventDefault()
      const previous = this.caret
      const cp = k.codePointAt(0)
      const posted = this.postKey(cp, 0)
      this.renderAfterInput()
      this.refreshCaret()
      this.settleCaretAfterInput(previous, true)
      if (posted) this.markViewerMutated()
    }
  },

  queueSpreadsheetTextInput(text) {
    const value = String(text || "")
    if (!value) return
    this.spreadsheetEditBuffer = (this.spreadsheetEditBuffer || "") + value
    this.scheduleSpreadsheetTextInputFlush()
    if (this.imeProxy) this.imeProxy.value = ""
  },

  scheduleSpreadsheetTextInputFlush() {
    if (this.spreadsheetEditTimer) clearTimeout(this.spreadsheetEditTimer)
    this.spreadsheetEditTimer = setTimeout(() => {
      this.spreadsheetEditTimer = null
      this.flushSpreadsheetTextInput()
    }, 1200)
  },

  clearSpreadsheetTextInput() {
    if (this.spreadsheetEditTimer) {
      clearTimeout(this.spreadsheetEditTimer)
      this.spreadsheetEditTimer = null
    }
    if (this.spreadsheetKeyPostTimer) {
      clearTimeout(this.spreadsheetKeyPostTimer)
      this.spreadsheetKeyPostTimer = null
    }
    this.spreadsheetEditBuffer = ""
    if (this.imeProxy) this.imeProxy.value = ""
  },

  flushSpreadsheetTextInput({ commit = false } = {}) {
    if (this.spreadsheetEditTimer) {
      clearTimeout(this.spreadsheetEditTimer)
      this.spreadsheetEditTimer = null
    }
    if (this.spreadsheetKeyPostTimer) {
      clearTimeout(this.spreadsheetKeyPostTimer)
      this.spreadsheetKeyPostTimer = null
    }

    const text = this.spreadsheetEditBuffer || ""
    this.spreadsheetEditBuffer = ""
    const keys = Array.from(text).map(ch => [ch.codePointAt(0), 0])
    if (commit) keys.push([13, this.AWT_KEY.RETURN])
    if (!keys.length) return false
    const previous = this.caret
    let posted = false

    const finish = () => {
      this.spreadsheetKeyPostTimer = null
      if (this.imeProxy) this.imeProxy.value = ""
      if (!posted) return
      this.renderAfterInput()
      this.refreshCaret()
      this.settleCaretAfterInput(previous, true)
      this.markViewerMutated()
    }

    const send = (index) => {
      const [charCode, keyCode] = keys[index]
      posted = this.postKey(charCode, keyCode, false) || posted
      if (index >= keys.length - 1) {
        finish()
        return
      }
      this.spreadsheetKeyPostTimer = setTimeout(() => send(index + 1), 32)
    }

    send(0)
    return true
  },

  handleEditShortcut(event) {
    if (event.altKey || !(event.metaKey || event.ctrlKey)) return false
    const key = String(event.key || "").toLowerCase()
    const undo = key === "z" && !event.shiftKey
    const redo = (key === "z" && event.shiftKey) || (key === "y" && event.ctrlKey && !event.metaKey)
    if (!undo && !redo) return false

    event.preventDefault()
    event.stopPropagation()
    const keyCode = undo
      ? this.AWT_KEY.Z | this.LOK_KEY_MOD1
      : key === "z"
        ? this.AWT_KEY.Z | this.LOK_KEY_MOD1 | this.LOK_KEY_SHIFT
        : this.AWT_KEY.Y | this.LOK_KEY_MOD1
    this.runOfficeUndoCommand(keyCode)
    return true
  },

  runOfficeUndoCommand(keyCode) {
    if (!this.hasApiMethod("postKeyEvent")) return false
    const previous = this.caret
    try {
      this.callApi("postKeyEvent", this.LOK_KEYEVENT_KEYINPUT, 0, keyCode)
      this.callApi("postKeyEvent", this.LOK_KEYEVENT_KEYUP, 0, keyCode)
      this.clearSelectionState()
      this.renderAfterInput()
      this.refreshCaret()
      this.settleCaretAfterInput(previous, true)
      this.markViewerMutated()
      return true
    } catch (error) {
      console.error("[office-wasm] undo shortcut postKeyEvent failed", keyCode, error)
      return false
    } finally {
      if (this.imeProxy) this.imeProxy.value = ""
    }
  },

  handleCopy(event) {
    const selected = this.currentTextSelection()
    if (!selected || !event.clipboardData) return
    event.preventDefault()
    event.clipboardData.setData("text/plain", selected)
    if (this.imeProxy) this.imeProxy.value = ""
  },

  handlePaste(event) {
    const text = event.clipboardData && event.clipboardData.getData("text/plain")
    if (!text) return
    event.preventDefault()
    this.insertPlainTextAtCaret(text)
  },

  currentTextSelection() {
    if (!this.hasApiMethod("getTextSelection")) return ""
    try {
      const selected = this.callApi("getTextSelection", "text/plain;charset=utf-8")
      return typeof selected === "string" ? selected.replace(/\0/g, "") : ""
    } catch (error) {
      console.error("[office-wasm] getTextSelection failed", error)
      return ""
    }
  },

  insertPlainTextAtCaret(text) {
    const value = String(text || "").replace(/\r\n?/g, "\n")
    if (!value || !this.api) return false
    const previous = this.caret
    let posted = false
    for (const ch of value) {
      if (ch === "\n") {
        posted = this.postKey(13, this.AWT_KEY.RETURN, false) || posted
      } else {
        posted = this.postKey(ch.codePointAt(0), 0, false) || posted
      }
    }
    if (this.imeProxy) this.imeProxy.value = ""
    if (!posted) return false
    this.renderAfterInput()
    this.refreshCaret()
    this.settleCaretAfterInput(previous, true)
    this.markViewerMutated()
    return true
  },

  hasApiMethod(name) {
    if (!this.api) return false
    if (this.api.shape === "embind-class" && this.handle && typeof this.handle[name] === "function") return true
    return typeof this.api[name] === "function"
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

  koreanImeKey(event) {
    const key = event.key || ""
    return event.keyCode === 229 ||
      key === "Process" ||
      key === "Unidentified" ||
      /^[\u3130-\u318F\uAC00-\uD7AF]$/u.test(key)
  },

  // Post a full key press (KEYINPUT then KEYUP), as the LOK/online clients do.
  postKey(charCode, keyCode, clearProxy = true) {
    if (this.presentationLikeDoc() && !this.presentationTextTargetReady()) {
      if (this.imeProxy) this.imeProxy.value = ""
      return false
    }
    try {
      this.callApi("postKeyEvent", this.LOK_KEYEVENT_KEYINPUT, charCode, keyCode)
      this.callApi("postKeyEvent", this.LOK_KEYEVENT_KEYUP, charCode, keyCode)
      this.clearSelectionState()
      return true
    } catch (error) {
      console.error("[office-wasm] postKeyEvent failed", error)
      return false
    } finally {
      // Always drain the proxy so it never accumulates state.
      if (clearProxy && this.imeProxy) this.imeProxy.value = ""
    }
  },

  markViewerMutated() {
    this._elementsCache = null
    if (!this.documentId) return
    this.pushEvent("local_document.viewer_mutated", { document_id: this.documentId })
  },

  // Plain (non-composing) text input — fires for some IMEs / paste / dictation
  // where keydown doesn't carry the char. Korean composition is handled by the
  // composition* path and skipped here.
  handleInput(event) {
    if (!this.api) return
    if (this.handleTrailingCompositionInput(event)) {
      if (this.imeProxy) this.imeProxy.value = ""
      return
    }
    if (event.isComposing || this.composing) return
    const type = event.inputType || ""
    if (type.startsWith("insert")) {
      const data = event.data != null ? event.data : this.imeProxy.value
      if (data) {
        const previous = this.caret
        let posted = false
        for (const ch of data) posted = this.postKey(ch.codePointAt(0), 0) || posted
        this.renderAfterInput()
        this.refreshCaret()
        this.settleCaretAfterInput(previous, true)
        if (posted) this.markViewerMutated()
      }
    }
    if (this.imeProxy) this.imeProxy.value = ""
  },

  // Korean IME — compositionstart marks composing. The composition text is
  // written into the actual LibreOffice document on each update, replacing the
  // prior provisional text, so the page tile itself changes immediately.
  handleCompositionStart(_event) {
    if (!this.api) return
    this.composing = true
    this.skipNextCompositionInput = null
    this._compositionCommittedText = ""
  },

  // compositionupdate — update the real document model immediately. We avoid a
  // browser-side fake overlay: visible glyphs must come from paintTile().
  handleCompositionUpdate(event) {
    if (!this.api) return
    if (this.presentationLikeDoc()) {
      if (!this.presentationTextTargetReady()) {
        this.anchorProxy()
        return
      }
      this.replaceCommittedComposition(event.data || (this.imeProxy && this.imeProxy.value) || "")
      return
    }
    this.replaceCommittedComposition(event.data || (this.imeProxy && this.imeProxy.value) || "")
  },

  replaceCommittedComposition(text) {
    const next = String(text || "")
    const prev = this._compositionCommittedText || ""
    if (next === prev) return false
    const previousCaret = this.caret
    let posted = false

    for (const _ch of [...prev]) {
      posted = this.postKey(8, this.AWT_KEY.BACKSPACE, false) || posted
    }
    for (const ch of [...next]) {
      posted = this.postKey(ch.codePointAt(0), 0, false) || posted
    }

    this._compositionCommittedText = next
    this.renderAfterInput()
    this.refreshCaret()
    this.settleCaretAfterInput(previousCaret, true)
    return posted
  },

  // compositionend — make one last replacement with the resolved string. If the
  // update event already wrote the same string this is a no-op, preventing a
  // trailing duplicate Hangul syllable.
  handleCompositionEnd(event) {
    if (!this.api) {
      this.composing = false
      return
    }
    if (this.presentationLikeDoc()) {
      const eventText = event.data || (this.imeProxy && this.imeProxy.value) || ""
      const str = eventText
      const ready = this.presentationTextTargetReady()
      this.composing = false
      this.clearSelectionState()
      this.armTrailingCompositionInputGuard(str, { provisional: !eventText && !!this._compositionCommittedText })
      if (this.imeProxy) this.imeProxy.value = ""
      if (!ready) return

      const posted = this.replaceCommittedComposition(str)
      if (posted) {
        this.markViewerMutated()
      }
      this._compositionCommittedText = ""
      return
    }
    const eventText = event.data || (this.imeProxy && this.imeProxy.value) || ""
    const str = eventText || this._compositionCommittedText || ""
    const posted = this.replaceCommittedComposition(str)
    this.composing = false
    this.clearSelectionState()
    this.armTrailingCompositionInputGuard(str, { provisional: !eventText && !!this._compositionCommittedText })
    if (this.imeProxy) this.imeProxy.value = ""
    if (posted || str) this.markViewerMutated()
    this._compositionCommittedText = ""
  },

  armTrailingCompositionInputGuard(text, options = {}) {
    const value = String(text || "")
    this.skipNextCompositionInput = value
      ? { value, at: performance.now(), provisional: !!options.provisional }
      : null
  },

  handleTrailingCompositionInput(event) {
    const pending = this.skipNextCompositionInput
    if (!pending) return false

    const type = event.inputType || ""
    const data = String(event.data != null ? event.data : (this.imeProxy && this.imeProxy.value) || "")
    const age = performance.now() - pending.at
    const immediate = age >= 0 && age < 500
    const delayedProvisional = pending.provisional && age >= 0 && age < 2500
    const compositionInput = type === "insertCompositionText" || type === "insertReplacementText"
    const hangulReplacementInput =
      (immediate || delayedProvisional) &&
      type.startsWith("insert") &&
      data &&
      data !== pending.value &&
      this.hangulCompositionText(data) &&
      this.hangulCompositionText(pending.value)
    const sameImmediateText = data === pending.value && immediate

    if (compositionInput && data && data !== pending.value && (immediate || delayedProvisional)) {
      this.replaceTrailingCompositionInput(pending.value, data)
      this.skipNextCompositionInput = null
      return true
    }

    if (hangulReplacementInput) {
      this.replaceTrailingCompositionInput(pending.value, data)
      this.skipNextCompositionInput = null
      return true
    }

    if (compositionInput || sameImmediateText) {
      this.skipNextCompositionInput = null
      return true
    }

    this.skipNextCompositionInput = null
    return false
  },

  replaceTrailingCompositionInput(previousText, nextText) {
    if (!nextText || nextText === previousText) return false
    const saved = this._compositionCommittedText
    this._compositionCommittedText = String(previousText || "")
    const posted = this.replaceCommittedComposition(nextText)
    this._compositionCommittedText = ""
    if (posted) this.markViewerMutated()
    if (saved && saved !== previousText && !posted) this._compositionCommittedText = saved
    return posted
  },

  hangulCompositionText(text) {
    return /[\u3130-\u318F\uAC00-\uD7AF]/u.test(String(text || ""))
  },

  handleToolbarCommand(detail) {
    if (!this.activeToolbarTarget() || !this.toolbarCommandMatchesDocument(detail)) return

    switch (detail.command) {
      case "bold":
        this.officeToolbarToggleProp("Bold", "CharWeight").catch(error => {
          console.warn("[office-wasm] toolbar bold failed", error)
        })
        break
      case "italic":
        this.officeToolbarToggleProp("Italic", "CharPosture").catch(error => {
          console.warn("[office-wasm] toolbar italic failed", error)
        })
        break
      case "image":
        this.officeToolbarImage(detail).catch(error => {
          console.warn("[office-wasm] toolbar image failed", error)
        })
        break
      default:
        break
    }
  },

  activeToolbarTarget() {
    return !!(
      this.el &&
      this.el.isConnected &&
      this.api &&
      this.handle &&
      !/^(hwp|hwpx|md|markdown)$/i.test(this.format || "")
    )
  },

  toolbarCommandMatchesDocument(detail) {
    const commandDocumentId = detail && (detail.document_id || detail.documentId)
    if (!commandDocumentId) return true
    return !!(this.documentId && String(commandDocumentId) === String(this.documentId))
  },

  async officeToolbarApplyProps(props) {
    const ref = this.officeToolbarTextRef()
    if (!ref) return

    const result = await this.officeApplySetOne(ref, props)
    if (result && result.error) {
      console.warn("[office-wasm] toolbar format failed", result.error)
      return
    }
    this.finishAgentEdit({})
  },

  async officeToolbarToggleProp(prop, unoKey) {
    const ref = this.officeToolbarTextRef()
    if (!ref) return

    const enabled = this.officeToolbarCharPropEnabled(ref, unoKey)
    const result = await this.officeApplySetOne(ref, { [prop]: !enabled })
    if (result && result.error) {
      console.warn("[office-wasm] toolbar format failed", result.error)
      return
    }
    this.finishAgentEdit({})
  },

  officeToolbarCharPropEnabled(ref, unoKey) {
    const value = this.officeToolbarCharPropValue(ref, unoKey)
    switch (unoKey) {
      case "CharWeight":
        return value === true || value === "bold" || Number(value) >= 150
      case "CharPosture":
        return value === true || value === "italic" || Number(value) > 0
      default:
        return !!value
    }
  },

  officeToolbarCharPropValue(ref, unoKey) {
    const elements = this.officeElements()
    const targetRef = String(ref)
    const candidates = [
      ...elements.filter((el) => el.ref === targetRef),
      ...elements.filter((el) => String(el.ref || "").startsWith(`${targetRef}/`)),
    ]

    for (const el of candidates) {
      const raw = (el && el.raw) || el || {}
      const props = raw.props && typeof raw.props === "object" ? raw.props
        : raw.properties && typeof raw.properties === "object" ? raw.properties
          : {}
      if (props[unoKey] != null) return props[unoKey]
    }

    return null
  },

  async officeToolbarImage(detail) {
    if (!detail || !detail.bytes) return
    const src = this.officeToolbarWriteImage(detail)
    const name = this.officeToolbarImageName(detail)
    const size = this.officeToolbarImageSize(detail, 5000)
    let op

    if (this.presentationLikeDoc()) {
      const loc = this.officeToolbarLoc()
      const pick = loc ? this.officeResolveAt(loc, false) : null
      const page = this.officeToolbarPageName(loc, pick)
      const position = this.officeToolbarSlidePosition(loc, size)
      op = { op: "insert_picture", page, name, src, ...position, ...size }
    } else {
      op = {
        op: "insert_picture",
        ref: this.officeToolbarTextRef() || "end",
        name,
        src,
        w: size.w,
        h: size.h
      }
    }

    const result = await this.officeApplyOneOp(op)
    if (result && result.error) {
      console.warn("[office-wasm] toolbar image failed", result.error)
      return
    }
    this.finishAgentEdit(result && result.extra ? result.extra : {})
  },

  officeToolbarTextRef() {
    const pick = this.officeToolbarPick()
    if (pick && pick.ref && !/^page\[[^\]]+\]$/.test(String(pick.ref))) {
      return String(pick.ref)
    }

    try {
      const el = this.officeElements().find((item) =>
        ["paragraph", "cell", "shape", "text_frame", "run"].includes(String(item.type || ""))
      )
      if (el && el.ref) return String(el.ref)
    } catch (_) {}

    return null
  },

  officeToolbarPick() {
    const loc = this.officeToolbarLoc()
    return loc ? this.officeResolveAt(loc, false) : null
  },

  officeToolbarLoc() {
    if (this.caret && Number.isFinite(Number(this.caret.page))) {
      return {
        pageIndex: Math.max(0, Number(this.caret.page) - 1),
        x: Math.max(1, Number(this.caret.x) || 1),
        y: Math.max(1, Number(this.caret.y) || 1)
      }
    }

    const visible = Array.from(this.visible || [])
    const pageIndex = visible.length ? visible[0] : 0
    const logical = this.pageLogicalSize(pageIndex)
    return {
      pageIndex,
      x: Math.max(1, Math.round((logical.width || 794) * 0.12)),
      y: Math.max(1, Math.round((logical.height || 1123) * 0.12))
    }
  },

  officeToolbarWriteImage(detail) {
    const Module = window.__officeWasmModule
    if (!Module) throw new Error("office WASM module is not ready")

    const bytes = detail.bytes instanceof Uint8Array
      ? detail.bytes
      : this.base64ToBytes(detail.image_base64)
    const dir = "/tmp/ecrits-toolbar"
    const file = `${Date.now()}-${this.officeToolbarSafeFileName(detail.file_name || "image")}`
    const path = `${dir}/${file}`

    if (typeof Module.FS_createPath === "function") {
      try { Module.FS_createPath("/", "tmp", true, true) } catch (_) {}
      try { Module.FS_createPath("/tmp", "ecrits-toolbar", true, true) } catch (_) {}
    }

    if (typeof Module.FS_writeFile === "function") {
      Module.FS_writeFile(path, bytes)
      return path
    }

    if (typeof Module.FS_createDataFile === "function") {
      try {
        if (typeof Module.FS_unlink === "function") Module.FS_unlink(path)
      } catch (_) {}
      Module.FS_createDataFile(dir, file, bytes, true, true, true)
      return path
    }

    throw new Error("office WASM filesystem writer is unavailable")
  },

  base64ToBytes(b64) {
    const binary = atob(String(b64 || ""))
    const bytes = new Uint8Array(binary.length)
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
    return bytes
  },

  officeToolbarSafeFileName(name) {
    const cleaned = String(name || "image")
      .replace(/[^a-zA-Z0-9._-]+/g, "-")
      .replace(/^-+|-+$/g, "")
    return cleaned || "image"
  },

  officeToolbarImageName(detail) {
    return `toolbar-${Date.now()}-${this.officeToolbarSafeFileName(detail.file_name || "image").replace(/\.[^.]+$/, "")}`
  },

  officeToolbarImageSize(detail, max) {
    const widthPx = Math.max(1, Number(detail.natural_width_px || 1))
    const heightPx = Math.max(1, Number(detail.natural_height_px || 1))
    const aspect = widthPx / heightPx

    if (aspect >= 1) {
      return { w: max, h: Math.max(1, Math.round(max / aspect)) }
    }

    return { w: Math.max(1, Math.round(max * aspect)), h: max }
  },

  officeToolbarSlidePosition(loc, size) {
    const pageIndex = loc ? loc.pageIndex : 0
    const logical = this.pageLogicalSize(pageIndex)
    const unit = 25.4 * 100 / 96
    const pageW = Math.max(1, Math.round((logical.width || 794) * unit))
    const pageH = Math.max(1, Math.round((logical.height || 1123) * unit))
    const margin = 800
    const rawX = Math.round(((loc && loc.x) || (logical.width || 794) * 0.12) * unit)
    const rawY = Math.round(((loc && loc.y) || (logical.height || 1123) * 0.12) * unit)
    const x = Math.min(Math.max(margin, rawX), Math.max(margin, pageW - size.w - margin))
    const y = Math.min(Math.max(margin, rawY), Math.max(margin, pageH - size.h - margin))

    return { x, y }
  },

  officeToolbarPageName(loc, pick) {
    const picked = String((pick && pick.ref) || "")
    const match = picked.match(/^page\[([^\]]+)\]/)
    if (match) return match[1]

    try {
      const pages = this.officeElements().filter((el) => /^page\[[^\]]+\]$/.test(String(el.ref || "")))
      const page = pages[(loc && loc.pageIndex) || 0] || pages[0]
      const pageMatch = page && String(page.ref || "").match(/^page\[([^\]]+)\]$/)
      if (pageMatch) return pageMatch[1]
    } catch (_) {}

    return String(((loc && loc.pageIndex) || 0) + 1)
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
  //   doc.find / doc.read / doc.get  -> getElements()  (IR JSON; filter/anchor)
  //   doc.edit (insert/replace/delete, single + ops:[…]) -> uno_apply(opJson)
  //   doc.set  (ref+props, single + sets:[…])            -> uno_set(ref, propsJson)
  //   doc.save                                           -> saveToBytes(format)
  //
  // Office refs are STRINGS the IR emits: "p<idx>" (paragraph), "tbl[<Name>]",
  // "tbl[<Name>]/cell[<B2>]", "page[<Slide>]/shape[<N>]",
  // "page[<Slide>]/shape[<N>]/cell[<B2>]". So office does NOT use
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
    Object.defineProperty(out, "raw", { value: el, enumerable: false })
    if (el.context != null) out.context = String(el.context)
    if (el.row != null) out.row = el.row
    if (el.col != null) out.col = el.col
    if (el.page != null) out.page = el.page
    if (el.pageIndex != null) out.pageIndex = el.pageIndex
    if (el.slide != null) out.slide = el.slide
    if (el.part != null) out.part = el.part
    for (const key of OFFICE_ELEMENT_METADATA_FIELDS) {
      if (el[key] != null) out[key] = el[key]
    }
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
  // `pattern` as a regex). Returns compact discovery matches
  // ({ref,type,text-snippet,...}); use doc.read/doc.get for full text/IR.
  officeFind({ pattern, patterns, case_sensitive, all, regex, type, limit }) {
    const elements = this.officeFindElements(type)
    const opts = { case_sensitive, all, regex, type, limit }

    if (Array.isArray(patterns)) {
      return { results: this.officeFindPatterns(elements, patterns, opts) }
    }

    return this.officeFindPatterns(elements, [pattern], opts)[0]
  },

  officeFindElements(type) {
    const elements = this.officeElements()
    return type ? this.filterByType(elements, String(type)) : elements
  },

  officeFindPatterns(elements, patterns, opts) {
    const specs = patterns.map((pattern) => this.officeFindSpec(pattern, opts))
    const limit = this.officeFindLimit(opts.limit)
    const unlimited = limit === Infinity
    const done = () => specs.every((spec) => !unlimited && spec.matches.length >= limit)

    for (const el of elements) {
      const text = this.officeFindText(el)
      const lowerText = opts.case_sensitive ? text : text.toLowerCase()

      for (const spec of specs) {
        if (!unlimited && spec.matches.length >= limit) continue
        if (spec.matchesElement(el, text, lowerText)) {
          spec.matches.push(this.officeFindMatch(el, spec, opts, text))
        }
      }

      if (done()) break
    }

    return specs.map((spec) => ({
      pattern: spec.pattern,
      type: opts.type || null,
      matches: spec.matches
    }))
  },

  officeFindSpec(pattern, opts) {
    const pat = pattern != null ? String(pattern) : ""
    const cs = !!opts.case_sensitive
    const discovery = !!(opts.all || opts.regex || opts.type)

    if (discovery) {
      if (!pat) return { pattern: pat, matches: [], matchesElement: () => true }

      let re
      try { re = new RegExp(pat, cs ? "" : "i") } catch (_) { re = null }

      return {
        pattern: pat,
        matches: [],
        matchesElement: re ? ((_el, text) => re.test(text)) : (() => true)
      }
    }

    const needle = cs ? pat : pat.toLowerCase()

    return {
      pattern: pat,
      matches: [],
      matchesElement: (_el, text, lowerText) => (cs ? text : lowerText).includes(needle)
    }
  },

  officeFindMatch(el, spec, opts, text) {
    const fullText = text != null ? String(text) : this.officeFindText(el)
    const snippet = this.officeFindSnippet(fullText, spec && spec.pattern, opts)
    const match = { ref: el.ref, text: snippet, type: el.type }
    const compactLength = this.officeFindCompactText(fullText).length

    if (compactLength > snippet.length) {
      match.text_truncated = true
    }

    for (const key of ["row", "col", "context", "page", "pageIndex", "slide", "part"]) {
      if (el[key] != null) match[key] = el[key]
    }
    for (const key of OFFICE_ELEMENT_METADATA_FIELDS) {
      if (el[key] != null) match[key] = el[key]
    }

    const fillableKind = this.fillableKind(match)
    if (fillableKind) match.fillable_kind = fillableKind
    return match
  },

  officeFindSnippet(text, pattern, opts) {
    const compact = this.officeFindCompactText(text)
    if (compact.length <= OFFICE_FIND_TEXT_LIMIT) return compact

    const index = this.officeFindSnippetIndex(compact, pattern, opts)
    const radius = Math.floor(OFFICE_FIND_TEXT_LIMIT / 2)
    let start = Math.max(0, index - radius)
    start = Math.min(start, Math.max(0, compact.length - OFFICE_FIND_TEXT_LIMIT))
    const end = Math.min(compact.length, start + OFFICE_FIND_TEXT_LIMIT)
    return (start > 0 ? "..." : "") + compact.slice(start, end) + (end < compact.length ? "..." : "")
  },

  officeFindCompactText(text) {
    return String(text || "").replace(/\s+/g, " ").trim()
  },

  officeFindSnippetIndex(text, pattern, opts) {
    const pat = pattern != null ? String(pattern) : ""
    if (!pat) return 0

    if (opts && (opts.regex || opts.all)) {
      try {
        const match = text.match(new RegExp(pat, opts.case_sensitive ? "" : "i"))
        if (match && Number.isInteger(match.index)) return match.index
      } catch (_) {}
    }

    const hay = opts && opts.case_sensitive ? text : text.toLowerCase()
    const needle = opts && opts.case_sensitive ? pat : pat.toLowerCase()
    const index = hay.indexOf(needle)
    return index >= 0 ? index : 0
  },

  officeFindLimit(limit) {
    const n = Number(limit || 0)
    return n > 0 ? Math.min(2000, n) : Infinity
  },

  // The server's element-type taxonomy, mapped onto office IR types. Cell-state
  // filters (empty_cell/filled_cell/empty) key off the cell text being blank.
  filterByType(elements, type) {
    if (!type) return elements
    switch (type) {
      case "empty": return elements.filter((el) => this.blankText(el))
      case "fillable": return elements.filter((el) => this.fillableElement(el))
      case "cell": return elements.filter((el) => el.type === "cell")
      case "formula_cell": return elements.filter((el) => el.type === "cell" && this.officeCellHasFormula(el))
      case "empty_cell": return elements.filter((el) => el.type === "cell" && this.blankText(el))
      case "filled_cell": return elements.filter((el) => el.type === "cell" && !this.blankText(el))
      case "paragraph": return elements.filter((el) => el.type === "paragraph")
      default: return elements.filter((el) => el.type === type)
    }
  },

  officeFindText(el) {
    const formula = this.officeFormulaText(el)
    return formula ? String(el.text || "") + "\n" + formula : String(el.text || "")
  },

  officeFormulaText(el) {
    if (!el) return ""
    if (el.formula != null) return String(el.formula)
    const raw = el.raw || {}
    if (raw.formula != null) return String(raw.formula)
    const props = raw.props && typeof raw.props === "object" ? raw.props
      : raw.properties && typeof raw.properties === "object" ? raw.properties
        : {}
    if (props.formula != null) return String(props.formula)
    if (props.Formula != null) return String(props.Formula)
    return ""
  },

  officeCellHasFormula(el) {
    return this.officeFormulaText(el) !== ""
  },

  fillableElement(el) {
    return !!this.fillableKind(el)
  },

  placeholderKind(value) {
    const text = String(value || "").trim()
    if (!text || text.startsWith("※")) return null
    if (text.includes("____")) return "underscore"
    if (text.includes("[]") || /^[□☐]\s*/u.test(text)) return "checkbox"
    if (/[-‐‑‒–—―－─]{4,}.*\(이하/u.test(text)) return "signature_line"
    if (/\(\s{2,}\)/u.test(text)) return "paren_blank"
    if (/[:：]\s{2,}[회년월일원%]/u.test(text)) return "inline_gap"
    if (/[년월일]\s{2,}/u.test(text)) return "date_gap"
    if (text.endsWith(":") && text.length <= 80) return "trailing_label"
    return null
  },

  fillableKind(el) {
    const text = String((el && el.text) || "").trim()
    const type = (el && el.type) || "unknown"
    const hasContext = !!(el && el.context && String(el.context).trim())
    if (type === "cell" && text === "" && hasContext) return "empty_cell"
    if (type === "field" || type === "form") return type
    if (type === "paragraph" || type === "cell") return this.placeholderKind(text)
    return null
  },

  limitOfficeMatches(matches, limit) {
    const n = Number(limit || 0)
    return n > 0 ? matches.slice(0, Math.min(2000, n)) : matches
  },

  // ─── doc.read -> ref neighborhood ──────────────────────────────────────────
  // Clarify a single anchor ref from doc.find. No paging/full-document read.
  officeRead({ opts }) {
    const o = opts || {}
    if (!o.ref) return { error: "doc.read requires ref from doc.find" }
    return readOfficeElements(this.officeElements(), o.ref, o.nearby, {
      tableRead: (refs, nearby) => this.officeCompactTableRead(refs, nearby),
      tableNearby: (elements, target, nearby) => this.officeTableNearby(elements, target, nearby),
      tableKey: (ref) => this.officeTableKey(ref),
    })
  },

  findOfficeReadMatch(elements, refs) {
    for (const ref of refs) {
      const idx = elements.findIndex((el) => el.ref === ref)
      if (idx >= 0) return { ref, idx }
    }
    return null
  },

  officeReadRefCandidates(ref) {
    return officeReadRefCandidatesValue(ref)
  },

  normalizeOfficeNearby(input) {
    return normalizeOfficeNearbyValue(input)
  },

  officeCompactTableRead(ref, nearby) {
    const refs = Array.isArray(ref) ? ref.map((r) => String(r || "")) : [String(ref || "")]
    const refString = refs[0] || ""
    const key = refs.map((r) => this.officeTableKey(r)).find(Boolean)
    if (!key) return { ref: refString, error: "ref is not a table/cell ref" }
    const cells = this.officeElements()
      .filter((el) => el.type === "cell" && this.officeTableKey(el.ref) === key)
      .map((el) => ({ ...el, writable: this.officeWritableCell(el) }))
    if (!cells.length) return { ref: refString, error: "no cells for table ref" }
    return this.officeCompactTablePayload(refString, key, cells, null, nearby)
  },

  officeTableNearby(elements, target, nearby) {
    const key = this.officeTableKey(target.ref)
    const cells = elements.filter((el) => el.type === "cell" && this.officeTableKey(el.ref) === key)
    return cells.length ? this.officeCompactTablePayload(target.ref, key, cells, target, nearby) : {}
  },

  officeCompactTablePayload(ref, key, cells, target, nearby) {
    const sorted = cells.slice().sort((a, b) => ((a.row || 0) - (b.row || 0)) || ((a.col || 0) - (b.col || 0)))
    const targetRow = target && Number.isInteger(target.row) ? target.row : null
    const targetCol = target && Number.isInteger(target.col) ? target.col : null
    const out = {
      table: {
        key,
        anchor: { key },
        row_count: new Set(sorted.map((c) => c.row).filter((v) => Number.isInteger(v))).size,
        col_count: new Set(sorted.map((c) => c.col).filter((v) => Number.isInteger(v))).size
      }
    }
    if (nearby.headers) {
      out.table_headers = sorted
        .filter((c) => c.row === 1)
        .map((c) => ({ col: c.col, text: c.text || "" }))
      out.row_labels = sorted
        .filter((c) => (c.col || 0) === 1 && (c.row || 0) > 1)
        .filter((c) => String(c.text || "").trim() || c.row === targetRow)
        .map((c) => ({ row: c.row, text: c.text || "" }))
    }
    if (nearby.row && targetRow !== null) {
      out.row = sorted.filter((c) => c.row === targetRow).map((c) => this.officeCompactTableCell(c, ref))
    }
    if (nearby.column && targetCol !== null) {
      out.column = sorted.filter((c) => c.col === targetCol).map((c) => this.officeCompactTableCell(c, ref))
    }
    return out
  },

  officeCompactTableCell(cell, targetRef) {
    const out = {
      row: cell.row,
      col: cell.col,
      text: cell.text || "",
      type: cell.type || "cell"
    }
    if (cell.context) out.context = cell.context
    const writable = this.officeWritableCell(cell)
    if (writable) out.writable = true
    if (writable || cell.ref === targetRef) out.ref = cell.ref
    return out
  },

  officeWritableCell(cell) {
    return cell.type === "cell" && String(cell.text || "").trim() === "" &&
      (!!(cell.context && String(cell.context).trim()) ||
        (Number.isInteger(cell.row) && Number.isInteger(cell.col) && cell.row > 0 && cell.col > 0))
  },

  officeTableKey(ref) {
    const s = String(ref || "")
    const m = /^(tbl\[[^\]]+\])(?:\/cell\[.*\])?$/.exec(s)
    if (m) return m[1]
    const shape = /^(page\[[^\]]+\]\/shape\[[^\]]+\])(?:\/cell\[.*\])?$/.exec(s)
    return shape ? shape[1] : null
  },

  // ─── doc.get -> inspect one (or many) IR elements ──────────────────────────
  // Best-effort reflective read off the LIVE browser IR. Mirrors the server
  // Office arm's `doc.get`: type/kind, current values, settable UNO property
  // names, children, and the raw Libre IR node for agents that need structure.
  officeGet({ ref, refs, props }) {
    const elements = this.officeElements()
    const one = (r) => {
      const el = this.officeElementForGet(elements, String(r))
      if (!el) return { ref: String(r), error: "unresolved ref" }
      const kind = this.officeKindForType(el.type)
      const values = this.officeValuesForElement(el, props)
      return {
        ref: el.ref,
        type: el.type,
        kind,
        interfaces: this.officeInterfacesForKind(kind),
        values,
        properties: values,
        settable: this.officeSettableForKind(kind),
        children: this.officeChildrenFor(el.ref),
        ir: this.officeRawForElement(el)
      }
    }
    if (Array.isArray(refs)) return { results: refs.map(one) }
    return one(ref)
  },

  officeElementForGet(elements, ref) {
    const matches = elements.filter((el) => el.ref === ref)
    if (!matches.length) return null
    if (matches.length === 1) return matches[0]

    const first = { ...matches[0] }
    first.text = this.joinOfficeText(matches)
    Object.defineProperty(first, "raw", {
      value: {
        ref: first.ref,
        type: first.type,
        text: first.text,
        nodes: matches.map((el) => this.officeRawForElement(el))
      },
      enumerable: false
    })
    return first
  },

  officeValuesForElement(el, props) {
    const raw = (el && el.raw) || el || {}
    const rawProps = raw.props && typeof raw.props === "object" ? raw.props
      : raw.properties && typeof raw.properties === "object" ? raw.properties
        : {}
    const values = { ...rawProps, text: el.text || "" }
    if (el.context != null) values.context = el.context
    if (el.row != null) values.row = el.row
    if (el.col != null) values.col = el.col
    if (el.page != null) values.page = el.page
    if (el.pageIndex != null) values.pageIndex = el.pageIndex
    if (el.slide != null) values.slide = el.slide
    if (el.part != null) values.part = el.part
    for (const key of OFFICE_ELEMENT_METADATA_FIELDS) {
      if (el[key] != null && values[key] == null) values[key] = el[key]
    }
    const formula = this.officeFormulaText(el)
    if (formula && values.formula == null) values.formula = formula

    if (!Array.isArray(props) || props.length === 0) return values
    const wanted = new Set(props.map((p) => String(p)))
    return Object.fromEntries(Object.entries(values).filter(([k]) => wanted.has(k)))
  },

  officeKindForType(type) {
    switch (String(type || "")) {
      case "run": return "run"
      case "paragraph": return "paragraph"
      case "cell": return "cell"
      case "shape":
      case "text_frame": return "shape"
      case "table": return "table"
      case "page":
      case "slide": return "page"
      default: return String(type || "unknown")
    }
  },

  officeInterfacesForKind(kind) {
    switch (kind) {
      case "run": return ["TextRange", "CharProperties"]
      case "paragraph": return ["Paragraph", "CharProperties"]
      case "cell": return ["Cell", "Container", "CharProperties"]
      case "shape": return ["Shape", "Positioned", "CharProperties"]
      case "table": return ["Table", "Container"]
      case "page": return ["Page", "Container"]
      default: return []
    }
  },

  officeSettableForKind(kind) {
    const charProps = [
      "CharWeight",
      "CharPosture",
      "CharColor",
      "CharHeight",
      "CharUnderline",
      "CharStrikeout",
      "CharFontName",
      "CharBackColor"
    ]
    switch (kind) {
      case "run":
        return charProps
      case "paragraph":
        return [
          "ParaAdjust",
          "ParaLineSpacing",
          "ParaLeftMargin",
          "ParaRightMargin",
          "ParaFirstLineIndent",
          "ParaTopMargin",
          "ParaBottomMargin",
          "ParaStyleName",
          ...charProps
        ]
      case "cell":
        return ["BackColor", "CellBackColor", "VertOrient", ...charProps]
      case "shape":
        return ["FillColor", "LineColor", "RotateAngle", "Width", "Height", ...charProps]
      default:
        return []
    }
  },

  officeChildrenFor(ref) {
    const prefix = String(ref || "") + "/"
    return Array.from(new Set(this.officeElements()
      .filter((el) => el.ref !== ref && el.ref.startsWith(prefix))
      .map((el) => el.ref)))
  },

  officeRawForElement(el) {
    const raw = (el && el.raw) || el
    try {
      return JSON.parse(JSON.stringify(raw))
    } catch (_) {
      return { ref: el.ref, type: el.type, text: el.text || "" }
    }
  },

  // ─── doc.edit -> uno_apply(opJson) ─────────────────────────────────────────
  // Single op. uno_apply takes the op as a JSON string (the SAME op the server
  // normalised: {op, ref, text|query|replacement|count, …}). Settle the edit,
  // invalidate the IR cache, and re-render.
  async officeApplyEdit({ op }) {
    const r = await this.officeApplyOneOp(op)
    if (r.error) return { error: r.error }
    return this.finishAgentEdit(r.extra || {})
  },

  // Apply ONE edit op via uno_apply. NEVER renders — the
  // caller does that once (so a batch applies N ops and finishes once). uno_apply
  // may return a JSON status string ({ok}/{error}) or throw; treat a thrown error
  // OR an {error:…} payload as a per-op failure.
  async officeApplyOneOp(op) {
    const fn = this.api && this.api.unoApply
    if (typeof fn !== "function") return { error: "uno_apply export not found in this office WASM build" }
    const verb = op && op.op
    if (!verb) return { error: "edit op requires an 'op' verb" }

    // ── Edit-op shim (ecrits #150, narrowed after the full-parity relink) ─────
    // The deployed soffice.wasm `uno_apply` now carries the FULL server op set
    // (LokEditBindings uno_apply_impl is a port of the NIF's uno_bridge dispatch):
    // text ops, slide ops (insert_slide/insert_shape/set_geometry/delete_node),
    // Writer structure (insert_paragraph/delete_paragraph/split/merge/insert_table/
    // insert_footnote/insert_endnote/insert_equation/set_columns) and table
    // structure (row/col insert+delete, merge_cells, split_cell). Only THREE verbs
    // are still composed JS-side, because their faithful semantics need the IR:
    //   replace_text — the binary's replace_text === set_text (whole-element set);
    //                  the shim does a counted query->replacement substitution on
    //                  the element's current text, which is the contract.
    //   set_cell     — alias of set_text on a cell ref (kept for ref collapsing).
    //   delete_range — the binary has no offset granularity; whole-element clear.
    const rewritten = this.rewriteUnsupportedEditOp(op)
    if (rewritten && rewritten.error) return { error: `${verb} failed: ${rewritten.error}` }
    const finalOp = rewritten && rewritten.op ? rewritten.op : op
    const finalVerb = finalOp.op

    let res
    try {
      res = fn(JSON.stringify(finalOp))
      // uno_apply dispatches onto the LOK worker; await a possible thenable.
      if (res && typeof res.then === "function") res = await res
    } catch (error) {
      return { error: `${verb} failed: ${String((error && error.message) || error)}` }
    }
    const status = this.parseStatus(res)
    if (status && status.error) return { error: `${finalVerb} failed: ${status.error}` }
    const extra = status && typeof status === "object" ? this.editExtra(status) : {}
    // Surface the synthesized replace count when we composed the op ourselves.
    if (rewritten && typeof rewritten.replaced === "number") extra.replaced = rewritten.replaced
    // When we composed a set_text from the IR, the cached IR is now stale; a
    // following op in the SAME batch (e.g. another replace on the same ref) must
    // re-read the post-edit text. finishAgentEdit also clears it, but only once at
    // the end of the batch, so clear here too for intra-batch correctness.
    if (rewritten && rewritten.op) this._elementsCache = null
    return { ok: true, extra }
  },

  // Rewrite an edit op that the deployed `uno_apply` can't apply correctly into a
  // `set_text` op it CAN. Returns:
  //   { op: <set_text op> }   — apply this instead
  //   null                    — op is natively supported; apply it unchanged
  //   { error: "<reason>" }   — op can't be composed (e.g. query not found)
  // Targets the text-bearing element by its `ref` (paragraph `p<idx>` or a shape
  // `…/shape[Name]` text frame); a run ref `…/r<n>` collapses to its paragraph,
  // which is the only ref `set_text` resolves against (verified).
  // Office-arm edit-op shim → typed dispatch (wasm_office_ops.ts, #49 O4). The 3
  // IR-composed verbs (replace_text/delete_range/set_cell) rewrite to set_text;
  // every other (native) verb passes through to uno_apply (null). The editor
  // instance is the handler ctx (officeElements/setTextRefFor/replaceAllCounted/…).
  rewriteUnsupportedEditOp(op) {
    try {
      return rewriteOfficeOp(this, op)
    } catch (error) {
      return { error: String((error && error.message) || error) }
    }
  },

  officeElementForEdit(elements, ref) {
    const targetRef = this.setTextRefFor(ref)
    const matches = elements.filter(
      (el) => this.setTextRefFor(el.ref) === targetRef && this.isSetTextTarget(el.ref)
    )
    if (!matches.length) return null
    const first = { ...matches[0], ref: targetRef }
    first.text = this.joinOfficeText(matches)
    return first
  },

  joinOfficeText(elements) {
    const parts = []
    for (const el of elements) {
      const text = String((el && el.text) || "")
      if (!text) continue
      if (parts[parts.length - 1] === text) continue
      if (parts.join("\n").includes(text)) continue
      parts.push(text)
    }
    return parts.join("\n")
  },

  // The ref `set_text` resolves against: a run ref `…/r<n>` collapses to its
  // owning paragraph/shape; everything else passes through.
  setTextRefFor(ref) {
    return ref.replace(/\/r\d+$/, "")
  },

  singleParagraphText(value) {
    return String(value == null ? "" : value).replace(/\r\n|\r|\n/g, " ").replace(/[ \t]{2,}/g, " ").trim()
  },

  // True for refs `set_text` accepts as whole-text targets: a top-level paragraph
  // `p<idx>`, a paragraph under a shape `…/p<idx>`, or a shape text frame
  // `…/shape[Name]`. Excludes bare run refs and the slide container `page[…]`.
  isSetTextTarget(ref) {
    if (/\/r\d+$/.test(ref)) return false
    if (/^page\[[^\]]+\]$/.test(ref)) return false
    return /(?:^|\/)p\d+$/.test(ref) || /\/shape\[[^\]]+\]$/.test(ref) || /\/cell\[[^\]]+\]$/.test(ref)
  },

  // String replace-all that also returns how many occurrences were replaced.
  replaceAllCounted(haystack, needle, replacement) {
    let count = 0
    let out = ""
    let i = 0
    while (i <= haystack.length) {
      const at = haystack.indexOf(needle, i)
      if (at === -1) {
        out += haystack.slice(i)
        break
      }
      out += haystack.slice(i, at) + replacement
      count++
      i = at + needle.length
    }
    return { text: out, count }
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

  // Batch doc.edit (ops:[…]). Apply every op via uno_apply with ONE re-render
  // at the end. Best-effort: a bad op does NOT abort the rest; the
  // result carries a per-op `results` array, mirroring the HWP batch shape.
  async officeApplyEditBatch({ ops }) {
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
    this.finishAgentEdit({})
    return { ok: true, result: { ok: true, applied, failed, results } }
  },

  // ─── doc.set -> uno_set(ref, propsJson) ────────────────────────────────────
  // Single set. CHAR properties must address the PARAGRAPH ref `p<idx>` (verified:
  // a run ref like "p0/r0" returns {"error":"unresolved ref"}), so we coerce a
  // run ref down to its paragraph for the uno_set call.
  async officeApplySet({ ref, props }) {
    const r = await this.officeApplySetOne(ref, props)
    if (r.error) return { error: r.error }
    return this.finishAgentEdit({})
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
  async officeApplySetBatch({ sets }) {
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
    this.finishAgentEdit({})
    return { ok: true, result: { ok: true, applied, failed, results } }
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

  async saveLocalDocument(payload = {}) {
    const requestId = payload.request_id || `local-save:${Date.now()}`
    const documentId = payload.document_id || this.documentId
    try {
      if (this._loadInFlight) await this._loadInFlight
      if (this._agentInFlight) await this._agentInFlight.catch(() => {})
      if (!this.api || !this.handle || !documentId) throw new Error("document_not_loaded")
      const saved = await this.officeSave()
      this.pushEvent("local_document.viewer_save", {
        request_id: requestId,
        document_id: documentId,
        ...saved
      })
    } catch (error) {
      console.error("[office-wasm] save failed", error)
      this.pushEvent("local_document.viewer_save", {
        request_id: requestId,
        document_id: documentId,
        error: String((error && error.message) || error)
      })
    }
  },

  saveShortcut(event) {
    return (event.metaKey || event.ctrlKey) && (event.key === "s" || event.key === "S")
  },

  // ─── shared edit-finish + helpers ──────────────────────────────────────────

  // Post-edit step (mirrors the HWP finishAgentEdit): the IR changed so the
  // cached element list is stale; re-render the visible pages so the edit shows
  // in the viewer.
  finishAgentEdit(extra) {
    this._elementsCache = null
    this.rendered.clear()
    this.renderVisiblePages()
    if (this.caret) this.refreshCaret()
    return { ok: true, result: { ok: true, ...extra } }
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
