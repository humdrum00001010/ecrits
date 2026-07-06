import { describe, it } from "node:test"
import assert from "node:assert/strict"

const listeners = new Map<string, Function[]>()
const documentStub: any = {
  body: { dataset: {} },
  addEventListener: (name: string, fn: Function) => {
    listeners.set(name, [...(listeners.get(name) || []), fn])
  },
  removeEventListener: (name: string, fn: Function) => {
    listeners.set(name, (listeners.get(name) || []).filter((entry) => entry !== fn))
  },
  dispatchEvent: () => true,
  querySelector: () => null,
  querySelectorAll: () => [],
  createElement: () => ({
    dataset: {},
    style: {},
    classList: { add() {}, remove() {}, toggle() {} },
    append() {},
    appendChild() {},
    setAttribute() {},
  }),
}

;(globalThis as any).document = (globalThis as any).document || documentStub
;(globalThis as any).window = (globalThis as any).window || {}

const { WasmOfficeEditor } = await import("../js/wasm_office_editor.js")

describe("WasmOfficeEditor runtime prewarm API", () => {
  it("exposes a document-free runtime prewarm entrypoint", () => {
    assert.equal(typeof WasmOfficeEditor.prewarmRuntime, "function")
  })

  it("exposes a document-cache fast-open entrypoint", () => {
    assert.equal(typeof WasmOfficeEditor.fastOpenDocument, "function")
  })
})

describe("WasmOfficeEditor scroll preservation", () => {
  it("restores a document scroll offset across hook remounts", () => {
    const win = (globalThis as any).window
    const oldRaf = win.requestAnimationFrame
    win.requestAnimationFrame = (fn: Function) => {
      fn()
      return 1
    }

    try {
      const first = Object.create(WasmOfficeEditor)
      first.mirror = false
      first.documentId = "office-scroll-doc"
      first.loadedUrl = "/bytes/office-scroll-doc"
      first.el = {
        dataset: { documentPath: "drafts/reference.docx", bytesUrl: "/bytes/office-scroll-doc" },
        scrollTop: 512,
        scrollLeft: 24,
      }

      first.rememberScrollPosition()

      let rendered = 0
      const second = Object.create(WasmOfficeEditor)
      second.mirror = false
      second.documentId = "office-scroll-doc"
      second.loadedUrl = "/bytes/office-scroll-doc"
      second.el = {
        dataset: { documentPath: "drafts/reference.docx", bytesUrl: "/bytes/office-scroll-doc" },
        scrollTop: 0,
        scrollLeft: 0,
      }
      second.officeHookActive = () => true
      second.renderVisiblePages = () => {
        rendered += 1
      }

      second.restoreScrollPosition()

      assert.equal(second.el.scrollTop, 512)
      assert.equal(second.el.scrollLeft, 24)
      assert.equal(rendered, 1)
    } finally {
      if (oldRaf) win.requestAnimationFrame = oldRaf
      else delete win.requestAnimationFrame
    }
  })

  it("restores a server-persisted scroll offset when no local cache exists", () => {
    const win = (globalThis as any).window
    const oldRaf = win.requestAnimationFrame
    win.requestAnimationFrame = (fn: Function) => {
      fn()
      return 1
    }

    try {
      let rendered = 0
      const editor = Object.create(WasmOfficeEditor)
      editor.mirror = false
      editor.documentId = "office-server-scroll-doc"
      editor.loadedUrl = "/bytes/office-server-scroll-doc"
      editor.el = {
        dataset: {
          documentPath: "drafts/server-scroll.docx",
          bytesUrl: "/bytes/office-server-scroll-doc",
          scrollTop: "611",
          scrollLeft: "12",
        },
        scrollTop: 0,
        scrollLeft: 0,
      }
      editor.officeHookActive = () => true
      editor.renderVisiblePages = () => {
        rendered += 1
      }

      editor.restoreScrollPosition()

      assert.equal(editor.el.scrollTop, 611)
      assert.equal(editor.el.scrollLeft, 12)
      assert.equal(rendered, 1)
    } finally {
      if (oldRaf) win.requestAnimationFrame = oldRaf
      else delete win.requestAnimationFrame
    }
  })

  it("pushes document scroll with the document path", () => {
    const pushed: any[] = []
    const editor = Object.create(WasmOfficeEditor)
    editor.mirror = false
    editor.documentId = "office-persist-scroll-doc"
    editor.loadedUrl = "/bytes/office-persist-scroll-doc"
    editor.el = {
      dataset: {
        documentPath: "drafts/persist-scroll.docx",
        bytesUrl: "/bytes/office-persist-scroll-doc",
      },
      scrollTop: 140,
      scrollLeft: 3,
    }
    editor.pushEvent = (event: string, payload: any) => pushed.push({ event, payload })

    editor.rememberScrollPosition()
    editor.flushScrollPosition()

    assert.deepEqual(pushed, [
      {
        event: "local_document.viewport_changed",
        payload: {
          document_path: "drafts/persist-scroll.docx",
          document_id: "office-persist-scroll-doc",
          top: 140,
          left: 3,
        },
      },
    ])
  })
})

describe("WasmOfficeEditor bytes URL reload", () => {
  it("reloads when LiveView patches a new bytes URL", () => {
    const loads: any[] = []
    const editor = Object.create(WasmOfficeEditor)
    editor.mirror = false
    editor.documentId = "office-fuse-doc"
    editor.lastSeenBytesUrl = "/local/document-bytes?document=docx"
    editor.el = {
      dataset: { bytesUrl: "/local/document-bytes?document=docx&v=42" },
    }
    editor.deferLoadDocument = (payload: any) => loads.push(payload)

    editor.updated()

    assert.deepEqual(loads, [
      {
        url: "/local/document-bytes?document=docx&v=42",
        document_id: "office-fuse-doc",
      },
    ])
    assert.equal(editor.lastSeenBytesUrl, "/local/document-bytes?document=docx&v=42")
  })

  it("does not reload when LiveView patches the same bytes URL", () => {
    const loads: any[] = []
    const editor = Object.create(WasmOfficeEditor)
    editor.mirror = false
    editor.documentId = "office-fuse-doc"
    editor.lastSeenBytesUrl = "/local/document-bytes?document=docx&v=42"
    editor.el = {
      dataset: { bytesUrl: "/local/document-bytes?document=docx&v=42" },
    }
    editor.deferLoadDocument = (payload: any) => loads.push(payload)

    editor.updated()

    assert.deepEqual(loads, [])
  })
})

describe("WasmOfficeEditor.officeFind", () => {
  it("handles batched patterns with one element enumeration", () => {
    let elementCalls = 0
    const editor = Object.create(WasmOfficeEditor)
    editor.officeElements = () => {
      elementCalls += 1

      return [
        { ref: "page[1]", text: "private timer clock and PERIPHCLK", type: "slide" },
        { ref: "page[1]/shape[clock]", text: "Private Timer Clock", type: "text_frame" },
        { ref: "page[1]/shape[clock]/p0/r0", text: "333MHz PERIPHCLK", type: "run" },
        { ref: "page[2]/shape[bus]", text: "PERIPHCLK 333MHz", type: "text_frame" },
      ]
    }

    const result = editor.officeFind({
      case_sensitive: false,
      limit: 10,
      patterns: ["private timer clock", "PERIPHCLK", "333MHz"],
    })

    assert.equal(elementCalls, 1)
    assert.deepEqual(
      result.results.map((entry: any) => [entry.pattern, entry.matches.length]),
      [
        ["private timer clock", 2],
        ["PERIPHCLK", 3],
        ["333MHz", 2],
      ],
    )
  })

  it("returns compact snippets for long text-frame matches", () => {
    const editor = Object.create(WasmOfficeEditor)
    editor.officeElements = () => [
      {
        ref: "page[1]/shape[long]",
        text: "Intro ".repeat(40) + "Private Timer Clock " + "tail ".repeat(40),
        type: "text_frame",
      },
    ]

    const result = editor.officeFind({ pattern: "Private Timer Clock" })
    const match = result.matches[0]

    assert.equal(match.ref, "page[1]/shape[long]")
    assert.match(match.text, /Private Timer Clock/)
    assert.equal(match.text_truncated, true)
    assert.ok(match.text.length <= 54)
    assert.equal(match.text_length, undefined)
  })

  it("surfaces spreadsheet formula metadata through find and get", () => {
    const editor = Object.create(WasmOfficeEditor)
    const formulaCell = editor.normElement({
      ref: "sheet[Calc]/cell[B3]",
      text: "3",
      type: "cell",
      context: "Calc",
      row: 3,
      col: 2,
      value: 3,
      value_type: "number",
      formula: "=SUM(B1:B2)",
    })

    editor.officeElements = () => [formulaCell]

    const formulaMatches = editor.officeFind({ type: "formula_cell", all: true })
    assert.equal(formulaMatches.matches.length, 1)
    assert.equal(formulaMatches.matches[0].formula, "=SUM(B1:B2)")

    const formulaSearch = editor.officeFind({ pattern: "SUM" })
    assert.equal(formulaSearch.matches.length, 1)
    assert.equal(formulaSearch.matches[0].ref, "sheet[Calc]/cell[B3]")
    assert.match(formulaSearch.matches[0].text, /SUM/)

    const cell = editor.officeGet({ ref: "sheet[Calc]/cell[B3]" })
    assert.equal(cell.values.text, "3")
    assert.equal(cell.values.value, 3)
    assert.equal(cell.values.formula, "=SUM(B1:B2)")
    assert.equal(cell.ir.formula, "=SUM(B1:B2)")
  })

  it("keeps mirror preview events scoped and non-authoritative", async () => {
    const editor = Object.create(WasmOfficeEditor)
    const applied: any[] = []
    let dispatched: any = null
    let rendered = 0
    let modelText = ""

    editor.mirror = true
    editor.documentId = "doc-1"
    editor.loaded = true
    editor.handle = true
    editor.rendered = new Map()
    editor.visible = new Set([0])
    editor.renderVisiblePages = () => {
      rendered += 1
    }
    editor.api = {
      getElements: () =>
        JSON.stringify([{ ref: "p0", type: "paragraph", text: modelText }]),
      unoApply: (json: string) => {
        const op = JSON.parse(json)
        applied.push(op)
        if (op.op === "set_text" && op.ref === "p0") modelText = op.text
        return JSON.stringify({ ok: true })
      },
    }
    editor.el = {
      dataset: {},
      querySelector: () => null,
      appendChild: () => {
        throw new Error("mirror preview must not create an overlay")
      },
      dispatchEvent: (event: any) => {
        dispatched = event
        return true
      },
    }

    assert.equal(editor.eventMatchesDocument({ document_id: "doc-1" }), true)
    assert.equal(editor.eventMatchesDocument({ document_id: "doc-2" }), false)
    assert.equal(editor.eventMatchesDocument({}), false)

    editor.handlePreviewDelta({
      document_id: "doc-1",
      turn_id: "turn-1",
      delta: "Draft",
      delta_count: 1,
    })

    await editor.previewPatchInFlight

    assert.equal(editor.el.dataset.previewText, "Draft")
    assert.equal(editor.el.dataset.previewDeltaCount, "1")
    assert.equal(applied.length, 1)
    assert.deepEqual(applied[0], { op: "set_text", ref: "p0", text: "Draft" })
    assert.equal(modelText, "Draft")
    assert.equal(rendered, 1)
    assert.equal(editor.el.dataset.previewPatchMode, "direct-doc")
    assert.equal(editor.el.dataset.previewPatchRef, "p0")
    assert.equal(editor.el.dataset.previewModelMatches, "true")
    assert.equal(dispatched.detail.document_id, "doc-1")
    assert.equal(dispatched.detail.patch_mode, "direct-doc")
    assert.equal(dispatched.detail.model_matches, true)
  })

  it("frames and paints saved DOCX preview highlights at the edited ref", () => {
    const calls: Array<{ name: string; args?: number[]; value?: unknown }> = []
    const ctx = {
      save() {
        calls.push({ name: "save" })
      },
      restore() {
        calls.push({ name: "restore" })
      },
      fillRect(...args: number[]) {
        calls.push({ name: "fillRect", args })
      },
      strokeRect(...args: number[]) {
        calls.push({ name: "strokeRect", args })
      },
      set fillStyle(value: string) {
        calls.push({ name: "fillStyle", value })
      },
      set strokeStyle(value: string) {
        calls.push({ name: "strokeStyle", value })
      },
      set lineWidth(value: number) {
        calls.push({ name: "lineWidth", value })
      },
    }
    const overlay = {
      width: 1200,
      height: 1600,
      getContext: (kind: string) => (kind === "2d" ? ctx : null),
    }
    const section = {
      offsetTop: 300,
      getBoundingClientRect: () => ({ height: 800 }),
      querySelector: () => overlay,
    }
    const editor = Object.create(WasmOfficeEditor)
    editor.mirror = true
    editor.loaded = true
    editor.parts = [{ width: 600, height: 800 }, { width: 600, height: 800 }, { width: 600, height: 800 }]
    editor.rendered = new Map([[2, true]])
    editor.scale = 1
    editor.caret = null
    editor.selectionVisual = null
    editor.elementPickerEnabled = false
    editor.el = {
      dataset: {
        previewHighlights: JSON.stringify([{ ref: "p5", text: "Edited paragraph" }]),
      },
      scrollTop: 0,
    }
    editor.officeElements = () => [
      {
        ref: "p5",
        type: "paragraph",
        text: "Edited paragraph",
        rects: [{ pageIndex: 2, x: 20, y: 180, width: 240, height: 18 }],
      },
    ]
    editor.pageSection = (pageIndex: number) => (pageIndex === 2 ? section : null)
    editor.caretOverlay = (pageIndex: number) => (pageIndex === 2 ? overlay : null)
    editor.clearAllCaretOverlays = () => {}
    editor.currentDocumentPicks = () => []

    editor.renderSavedEditHighlights()

    assert.equal(editor.el.dataset.previewHighlightMode, "saved-edit-regions")
    assert.equal(editor.el.dataset.previewHighlightCount, "1")
    assert.equal(editor.el.dataset.previewHighlightPages, "2")
    assert.equal(editor.el.dataset.previewFrameMode, "saved-office")
    assert.equal(editor.el.dataset.previewFramePage, "2")
    assert.equal(editor.el.scrollTop, 456)
    assert.equal(calls.find(call => call.name === "fillStyle")?.value, "rgba(245, 158, 11, 0.26)")
    assert.deepEqual(calls.find(call => call.name === "fillRect")?.args, [40, 360, 480, 36])
    assert.deepEqual(calls.find(call => call.name === "strokeRect")?.args, [40, 360, 480, 36])
  })

  it("frames saved DOCX preview highlights after mirror document load", () => {
    const url = "/local/document-bytes?path=/tmp&document=form.docx"
    const seed = Object.create(WasmOfficeEditor)
    seed.officeAssetVersion = "test-asset"
    seed.format = "docx"
    seed.api = {}
    seed.handle = {}
    seed.docType = 0
    seed.pageRects = [{ x: 0, y: 0, w: 600, h: 900 }]
    seed.parts = [{ width: 600, height: 900 }]
    seed.rememberActiveDocument(url)

    let rendered = 0
    let patched = ""
    const editor = Object.create(WasmOfficeEditor)
    editor.mirror = true
    editor.officeAssetVersion = "test-asset"
    editor.format = "docx"
    editor.scale = 1
    editor.rendered = new Map([[0, true]])
    editor.caret = null
    editor.selectionVisual = null
    editor.elementPickerEnabled = false
    editor.el = {
      dataset: {
        bytesUrl: url,
        previewText: "",
        previewDeltaCount: "1",
        previewHighlights: JSON.stringify([{ ref: "p3", text: "Edited paragraph" }]),
      },
      isConnected: true,
      getAttribute: (name: string) => (
        name === "data-role" ? "office-wasm-viewer" :
        name === "phx-hook" ? "WasmOfficeEditor" :
        null
      ),
      scrollTop: 0,
    }
    editor.officeHookActive = () => true
    editor.officeElements = () => [
      { ref: "p0", type: "paragraph", text: "one" },
      { ref: "p1", type: "paragraph", text: "two" },
      { ref: "p2", type: "paragraph", text: "three" },
      { ref: "p3", type: "paragraph", text: "Edited paragraph" },
    ]
    editor.buildPageStack = () => {}
    editor.restoreScrollPosition = () => {}
    editor.renderVisiblePages = () => {
      rendered += 1
    }
    editor.patchPreviewToMountedDoc = (text: string) => {
      patched = text
    }
    editor.pageSection = () => ({
      offsetTop: 0,
      getBoundingClientRect: () => ({ height: 900 }),
      querySelector: () => ({ width: 600, height: 900, getContext: () => null }),
    })
    editor.caretOverlay = () => ({ width: 600, height: 900, getContext: () => null })
    editor.clearAllCaretOverlays = () => {}
    editor.currentDocumentPicks = () => []

    assert.equal(editor.attachCachedDocument(url), true)

    assert.equal(editor.loaded, true)
    assert.equal(rendered, 1)
    assert.equal(patched, "")
    assert.equal(editor.el.dataset.previewHighlightMode, "saved-edit-regions")
    assert.equal(editor.el.dataset.previewHighlightCount, "1")
    assert.equal(editor.el.dataset.previewFrameMode, "saved-office")
    assert.ok(editor.el.scrollTop > 400)
  })

  it("uses ref order instead of page top when DOCX preview highlight geometry is unavailable", () => {
    const editor = Object.create(WasmOfficeEditor)
    editor.mirror = true
    editor.loaded = true
    editor.parts = [{ width: 600, height: 900 }]
    editor.rendered = new Map([[0, true]])
    editor.scale = 1
    editor.caret = null
    editor.selectionVisual = null
    editor.elementPickerEnabled = false
    editor.el = {
      dataset: {
        previewHighlights: JSON.stringify([{ ref: "p3", text: "Edited paragraph" }]),
      },
      scrollTop: 0,
    }
    editor.officeElements = () => [
      { ref: "p0", type: "paragraph", text: "one" },
      { ref: "p1", type: "paragraph", text: "two" },
      { ref: "p2", type: "paragraph", text: "three" },
      { ref: "p3", type: "paragraph", text: "Edited paragraph" },
      { ref: "p4", type: "paragraph", text: "five" },
    ]
    editor.api = {}
    editor.pageSection = () => ({
      offsetTop: 0,
      getBoundingClientRect: () => ({ height: 900 }),
      querySelector: () => ({ width: 600, height: 900, getContext: () => null }),
    })
    editor.caretOverlay = () => ({ width: 600, height: 900, getContext: () => null })
    editor.clearAllCaretOverlays = () => {}
    editor.currentDocumentPicks = () => []

    editor.renderSavedEditHighlights()

    assert.equal(editor.el.dataset.previewHighlightCount, "1")
    assert.equal(editor.el.dataset.previewFramePage, "0")
    assert.ok(editor.el.scrollTop > 300)
  })
})
