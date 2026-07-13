import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { importOfficeWasmInternals } from "./support/colocated_hook.ts"
import { loadHwpColocatedHook } from "./support/hwp_colocated.ts"

const documentStub: any = {
  body: { dataset: {} },
  addEventListener() {},
  removeEventListener() {},
  dispatchEvent: () => true,
  querySelector: () => null,
  querySelectorAll: () => [],
  createElement: () => {
    const children: unknown[] = []
    return {
      dataset: {},
      style: {},
      children,
      classList: { add() {}, remove() {}, toggle() {} },
      append() {},
      appendChild(child: unknown) { children.push(child) },
      setAttribute() {},
    }
  },
}

;(globalThis as any).document = (globalThis as any).document || documentStub
;(globalThis as any).window = (globalThis as any).window || {}

const { WasmOfficeEditor } = await importOfficeWasmInternals()
const hwp = await loadHwpColocatedHook()
const { WasmHwpEditor } = hwp
const picker = hwp

describe("WasmOfficeEditor toolbar toggle state", () => {
  it("routes toolbar format/align commands through native UNO dispatch", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      el: { isConnected: true },
      api: {},
      handle: {},
      format: "docx",
      documentId: "doc-1",
      parts: [{ width: 100, height: 100 }],
      hasApiMethod: (name: string) => name === "postUnoCommand",
      callApi: (...args: unknown[]) => calls.push({ name: "callApi", args }),
      renderAfterInput: () => calls.push({ name: "renderAfterInput" }),
      refreshCaret: () => calls.push({ name: "refreshCaret" }),
      settleCaretAfterInput: () => calls.push({ name: "settleCaretAfterInput" }),
      markViewerMutated: () => calls.push({ name: "markViewerMutated" }),
      imeProxy: { value: "" },
    } as any

    for (const [command, uno] of [
      ["bold", ".uno:Bold"],
      ["strikethrough", ".uno:Strikeout"],
      ["align-center", ".uno:CenterPara"],
      ["align-justify", ".uno:JustifyPara"],
    ] as const) {
      calls.length = 0
      editor.handleToolbarCommand({ command, document_id: "doc-1" })
      assert.deepEqual(
        calls.find(c => c.name === "callApi")?.args,
        ["postUnoCommand", uno, ""],
        `${command} → ${uno}`
      )
      assert.ok(calls.some(c => c.name === "renderAfterInput"), `${command} repaints`)
      assert.ok(calls.some(c => c.name === "markViewerMutated"), `${command} marks mutated`)
    }
  })

  it("routes font row commands through UNO with args JSON payloads", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      el: { isConnected: true },
      api: {},
      handle: {},
      format: "docx",
      documentId: "doc-1",
      parts: [{ width: 100, height: 100 }],
      hasApiMethod: (name: string) => name === "postUnoCommand",
      callApi: (...args: unknown[]) => calls.push({ name: "callApi", args }),
      renderAfterInput: () => calls.push({ name: "renderAfterInput" }),
      refreshCaret: () => calls.push({ name: "refreshCaret" }),
      settleCaretAfterInput: () => calls.push({ name: "settleCaretAfterInput" }),
      markViewerMutated: () => calls.push({ name: "markViewerMutated" }),
      imeProxy: { value: "" },
    } as any

    for (const [detail, uno, args] of [
      [
        { command: "font-size-set", size: 13 },
        ".uno:FontHeight",
        JSON.stringify({ "FontHeight.Height": { type: "float", value: 13 } }),
      ],
      [
        { command: "text-color", color: "#e11d48" },
        ".uno:Color",
        JSON.stringify({ Color: { type: "long", value: 0xe11d48 } }),
      ],
      [
        { command: "highlight", color: "#fde047" },
        ".uno:CharBackColor",
        JSON.stringify({ CharBackColor: { type: "long", value: 0xfde047 } }),
      ],
    ] as const) {
      calls.length = 0
      editor.handleToolbarCommand({ ...detail, document_id: "doc-1" })
      assert.deepEqual(
        calls.find(c => c.name === "callApi")?.args,
        ["postUnoCommand", uno, args],
        `${detail.command} → ${uno}`
      )
      assert.ok(calls.some(c => c.name === "markViewerMutated"), `${detail.command} marks mutated`)
    }

    // Malformed payloads must not reach the engine.
    for (const detail of [
      { command: "font-size-set", size: 0 },
      { command: "font-size-set", size: "abc" },
      { command: "text-color" },
      { command: "highlight", color: "not-a-color" },
    ]) {
      calls.length = 0
      editor.handleToolbarCommand({ ...detail, document_id: "doc-1" })
      assert.equal(calls.length, 0, `${JSON.stringify(detail)} is dropped`)
    }
  })

  it("broadcasts LOK format state on the local-editor-state bus", () => {
    const events: any[] = []
    const doc = (globalThis as any).document
    const originalDispatch = doc.dispatchEvent
    doc.dispatchEvent = (event: any) => {
      events.push(event)
      return true
    }

    try {
      const editor = {
        ...WasmOfficeEditor,
        officeHookAlive: true,
        api: {},
        documentId: "doc-7",
        callApi: (name: string) =>
          name === "getInteractionState"
            ? JSON.stringify({
                seq: 4,
                format: { bold: 1, italic: 0, underline: -1, strikeout: 0, align: "center" },
              })
            : null,
      } as any

      editor.emitToolbarState()

      assert.equal(events.length, 1)
      assert.equal(events[0].type, "ecrits:editor-state")
      assert.deepEqual(events[0].detail, {
        document_id: "doc-7",
        bold: true,
        italic: false,
        underline: false, // tri-state -1 (no update yet) maps to unlit
        strikethrough: false,
        alignment: "center",
        font_size_pt: null, // old wasm: no fontSizePt key → toolbar no-op
      })
    } finally {
      doc.dispatchEvent = originalDispatch
    }
  })

  it("mirrors the .uno:FontHeight feed into font_size_pt", () => {
    const events: any[] = []
    const doc = (globalThis as any).document
    const originalDispatch = doc.dispatchEvent
    doc.dispatchEvent = (event: any) => {
      events.push(event)
      return true
    }

    try {
      const editor = {
        ...WasmOfficeEditor,
        officeHookAlive: true,
        api: {},
        documentId: "doc-7",
        callApi: (name: string) =>
          name === "getInteractionState"
            ? JSON.stringify({
                seq: 9,
                format: {
                  bold: 0, italic: 0, underline: 0, strikeout: 0, align: null,
                  fontSizePt: 10.5, fontName: "Liberation Serif",
                },
              })
            : null,
      } as any

      editor.emitToolbarState()

      assert.equal(events.length, 1)
      assert.equal(events[0].detail.font_size_pt, 10.5)

      // Engine "unknown" (null) and garbage values stay null for the toolbar.
      for (const fontSizePt of [null, -1, 0, "abc"]) {
        events.length = 0
        editor.callApi = (name: string) =>
          name === "getInteractionState"
            ? JSON.stringify({
                seq: 10,
                format: { bold: 0, italic: 0, underline: 0, strikeout: 0, align: null, fontSizePt },
              })
            : null
        editor.emitToolbarState()
        assert.equal(events[0].detail.font_size_pt, null, `fontSizePt=${fontSizePt} → null`)
      }
    } finally {
      doc.dispatchEvent = originalDispatch
    }
  })

  it("stays silent when the wasm has no format feed (old builds)", () => {
    const events: any[] = []
    const doc = (globalThis as any).document
    const originalDispatch = doc.dispatchEvent
    doc.dispatchEvent = (event: any) => {
      events.push(event)
      return true
    }

    try {
      const editor = {
        ...WasmOfficeEditor,
        officeHookAlive: true,
        api: {},
        documentId: "doc-7",
        callApi: () => JSON.stringify({ seq: 4 }),
      } as any

      editor.emitToolbarState()
      assert.equal(events.length, 0)
    } finally {
      doc.dispatchEvent = originalDispatch
    }
  })

  it("falls back to the uno_set path when postUnoCommand is unavailable", () => {
    let toggled: unknown[] = []
    const editor = {
      ...WasmOfficeEditor,
      el: { isConnected: true },
      api: {},
      handle: {},
      format: "docx",
      documentId: "doc-1",
      hasApiMethod: () => false,
      officeToolbarToggleProp: async (...args: unknown[]) => { toggled = args },
    } as any

    editor.handleToolbarCommand({ command: "bold", document_id: "doc-1" })
    assert.deepEqual(toggled, ["Bold", "CharWeight"])
  })

  it("treats CharWeight >= 150 as bold", () => {
    const editor = {
      ...WasmOfficeEditor,
      officeElements: () => [
        { ref: "p0", type: "paragraph" },
        { ref: "p0/r0", type: "run", raw: { props: { CharWeight: 150 } } },
      ],
    } as any

    assert.equal(editor.officeToolbarCharPropEnabled("p0", "CharWeight"), true)
  })

  it("treats CharWeight below 150 as not bold", () => {
    const editor = {
      ...WasmOfficeEditor,
      officeElements: () => [
        { ref: "p0/r0", type: "run", raw: { props: { CharWeight: 100 } } },
      ],
    } as any

    assert.equal(editor.officeToolbarCharPropEnabled("p0/r0", "CharWeight"), false)
  })

  it("treats positive CharPosture as italic", () => {
    const editor = {
      ...WasmOfficeEditor,
      officeElements: () => [
        { ref: "shape[Title]/p0/r0", type: "run", raw: { props: { CharPosture: 2 } } },
      ],
    } as any

    assert.equal(editor.officeToolbarCharPropEnabled("shape[Title]/p0", "CharPosture"), true)
  })

  it("fills the picker hover preview before drawing the outline", () => {
    const calls: Array<{ name: string; args?: number[]; value?: unknown }> = []
    const ctx = {
      save() {
        calls.push({ name: "save" })
      },
      restore() {
        calls.push({ name: "restore" })
      },
      setLineDash(value: number[]) {
        calls.push({ name: "setLineDash", value })
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
      width: 200,
      height: 100,
      getContext: (kind: string) => (kind === "2d" ? ctx : null),
    }
    const editor = {
      ...WasmOfficeEditor,
      scale: 1,
      pickerEnabled: () => true,
      pickerHover: { rects: [{ pageIndex: 0, x: 10, y: 20, width: 30, height: 40 }] },
      currentDocumentPicks: () => [],
      caretOverlay: () => overlay,
      pageLogicalSize: () => ({ width: 100, height: 100 }),
    } as any

    editor.paintAdornmentsOnPage(0)

    assert.equal(calls.find(call => call.name === "fillStyle")?.value, "rgba(99, 102, 241, 0.13)")
    assert.equal(calls.find(call => call.name === "lineWidth")?.value, 2)

    const fillRectIndex = calls.findIndex(call => call.name === "fillRect")
    const strokeRectIndex = calls.findIndex(call => call.name === "strokeRect")
    assert.notEqual(fillRectIndex, -1)
    assert.notEqual(strokeRectIndex, -1)
    assert.ok(fillRectIndex < strokeRectIndex)
    assert.deepEqual(calls[fillRectIndex].args, [20, 20, 60, 40])
    assert.deepEqual(calls[strokeRectIndex].args, [20, 20, 60, 40])
  })

  it("paints the Office native selection visual on the overlay", () => {
    const calls: Array<{ name: string; args?: number[]; value?: unknown }> = []
    const ctx = {
      save() {
        calls.push({ name: "save" })
      },
      restore() {
        calls.push({ name: "restore" })
      },
      setLineDash(value: number[]) {
        calls.push({ name: "setLineDash", value })
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
      width: 200,
      height: 100,
      getContext: (kind: string) => (kind === "2d" ? ctx : null),
    }
    const editor = {
      ...WasmOfficeEditor,
      scale: 1,
      selectionVisual: {
        confirmed: true,
        rects: [{ pageIndex: 0, x: 10, y: 20, width: 30, height: 12 }],
      },
      currentDocumentPicks: () => [],
      caretOverlay: () => overlay,
      pageLogicalSize: () => ({ width: 100, height: 100 }),
    } as any

    editor.paintAdornmentsOnPage(0)

    assert.equal(calls.find(call => call.name === "fillStyle")?.value, "rgba(37, 99, 235, 0.30)")
    assert.deepEqual(calls.find(call => call.name === "fillRect")?.args, [20, 20, 60, 12])
  })

  it("derives the Office selection visual from the drag line geometry", () => {
    const editor = {
      ...WasmOfficeEditor,
    } as any
    const ds = {
      startLoc: { pageIndex: 0, x: 150, y: 50 },
      visualProbe: {
        rects: [{ pageIndex: 0, x: 100, y: 40, width: 300, height: 20 }],
      },
    }

    const rects = editor.selectionVisualRects(ds, { pageIndex: 0, x: 260, y: 50 })

    assert.deepEqual(rects, [{ pageIndex: 0, x: 150, y: 40, width: 110, height: 20 }])
  })

  it("derives the Office selection visual from drag coordinates without resolving during drag", () => {
    const editor = {
      ...WasmOfficeEditor,
      selectionVisualProbe: () => {
        throw new Error("must not resolve while dragging")
      },
    } as any
    const ds = {
      startLoc: { pageIndex: 0, x: 338, y: 196 },
      visualProbe: null,
    }

    const rects = editor.selectionVisualRects(ds, { pageIndex: 0, x: 462, y: 196 })

    assert.deepEqual(rects, [{ pageIndex: 0, x: 338, y: 188, width: 124, height: 16 }])
  })

  it("retries an empty native Office paint before reporting render failure", () => {
    const statuses: string[] = []
    const timers: Array<{ callback: () => void; delay: number }> = []
    const requests: Array<{ index: number; force: boolean | undefined }> = []
    const paintCalls: unknown[][] = []
    const warnings: unknown[][] = []
    const timerToken = { id: "paint-retry" }
    const canvas = { width: 1, height: 1 }
    const section = {
      querySelector: (selector: string) =>
        selector === "[data-role='office-wasm-canvas']" ? canvas : null,
    }
    const editor = {
      ...WasmOfficeEditor,
      officeHookAlive: true,
      el: {
        isConnected: true,
        getAttribute: (name: string) =>
          name === "data-role" ? "office-wasm-viewer" :
            name === "phx-hook" ? "WasmOfficeEditor" :
              null,
      },
      api: {
        shape: "module-functions",
        loadStatus: () => 2,
        paintTile: (...args: unknown[]) => {
          paintCalls.push(args)
          return new Uint8Array()
        },
      },
      docType: 1,
      scale: 1,
      parts: [{ width: 100, height: 80 }],
      pageRects: [],
      rendered: new Map(),
      visible: new Set(),
      renderQueue: new Map(),
      paintEmptyRetries: new Map(),
      paintRetryTimers: new Map(),
      pageSection: () => section,
      setStatus: (text: string) => statuses.push(text),
      setOfficeTimer: (callback: () => void, delay: number) => {
        timers.push({ callback, delay })
        return timerToken
      },
      clearOfficeTimer: () => {},
      requestRenderPage: (index: number, opts: { force?: boolean } = {}) => {
        requests.push({ index, force: opts.force })
      },
    } as any

    const originalWarn = console.warn
    console.warn = (...args: unknown[]) => warnings.push(args)
    try {
      editor.renderPage(0)
    } finally {
      console.warn = originalWarn
    }

    assert.equal(paintCalls.length, 1)
    assert.equal(warnings.length, 1)
    assert.equal(editor.paintEmptyRetries.get(0), 1)
    assert.equal(timers.length, 1)
    assert.equal(timers[0].delay, 80)
    assert.equal(statuses[statuses.length - 1], "Rendering page 1...")
    assert.equal(statuses.some(status => status.startsWith("Render failed")), false)

    timers[0].callback()
    assert.deepEqual(requests, [{ index: 0, force: true }])
  })

  it("suppresses Office status updates from inactive hooks", () => {
    const statusEl = { textContent: "" }
    const editor = {
      ...WasmOfficeEditor,
      officeHookAlive: false,
      el: {
        isConnected: true,
        getAttribute: (name: string) =>
          name === "data-role" ? "office-wasm-viewer" :
            name === "phx-hook" ? "WasmOfficeEditor" :
              null,
      },
      statusEl,
    } as any

    editor.setStatus("Render failed on page 1")

    assert.equal(statusEl.textContent, "")
  })

  it("does not build picker rects from invalid Office caret geometry", () => {
    const editor = {
      ...WasmOfficeEditor,
      api: {
        resolveRef: () => ({
          ok: true,
          ref: "p2",
          type: "paragraph",
          text: "(COSE461 - 02)",
          caret: { ok: false, page: 1, x: 0, y: 0, height: 0 },
        }),
      },
      el: { dataset: { documentPath: "/tmp/report.docx" } },
    } as any

    const pick = editor.officeResolveAt({ pageIndex: 0, x: 338, y: 196 }, false)

    assert.deepEqual(pick.rects, [])
  })

  it("keeps presentation object dragging on the native mouse path", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: {},
      presentationLikeDoc: () => true,
      hasApiMethod: () => false,
      LOK_MOUSEEVENT_MOUSEMOVE: 2,
      LOK_MOUSEEVENT_MOUSEBUTTONUP: 1,
      LOK_MOUSE_LEFT: 1,
      dragSelect: {
        page: 0,
        startX: 10,
        startY: 10,
        lastLoc: { pageIndex: 0, x: 10, y: 10 },
        mode: "native",
        moved: false,
        selectionStarted: false,
        modifier: 0,
      },
      eventToPageLocal: () => ({ pageIndex: 0, x: 50, y: 40 }),
      postNativeMouseEvent: (...args: unknown[]) => calls.push({ name: "postNativeMouseEvent", args }),
      requestDragRenderPage: (...args: unknown[]) => calls.push({ name: "requestDragRenderPage", args }),
      renderPage: (...args: unknown[]) => calls.push({ name: "renderPage", args }),
      refreshCaret: () => calls.push({ name: "refreshCaret" }),
      settleAfterMouseSelection: (...args: unknown[]) => calls.push({ name: "settleAfterMouseSelection", args }),
      anchorProxy: () => calls.push({ name: "anchorProxy" }),
      imeProxy: null,
      hasActiveSelection: false,
    } as any
    const moveEvent = {
      buttons: 1,
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any

    editor.onCanvasMouseMove(moveEvent)

    assert.equal(editor.dragSelect.moved, true)
    assert.equal(editor.dragSelect.selectionStarted, true)
    assert.equal(editor.hasActiveSelection, true)
    assert.ok(calls.some(call => call.name === "postNativeMouseEvent" && call.args?.[0] === 2))
    assert.ok(calls.some(call => call.name === "requestDragRenderPage"))
    assert.equal(calls.some(call => call.name === "renderPage"), false)
    assert.equal(calls.some(call => call.name === "refreshCaret"), false)

    calls.length = 0
    editor.onCanvasMouseUp({
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect, null)
    assert.ok(calls.some(call => call.name === "postNativeMouseEvent" && call.args?.[0] === 1))
    assert.ok(calls.some(call => call.name === "renderPage"))
    assert.ok(calls.some(call => call.name === "settleAfterMouseSelection"))
  })

  it("uses direct text selection for presentation drags while text edit is active", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: {},
      parts: [{ width: 100, height: 100 }],
      pageRects: [{ x: 1000, y: 2000, w: 4000, h: 3000 }],
      LOK_SETTEXTSELECTION_RESET: 2,
      LOK_SETTEXTSELECTION_END: 1,
      presentationLikeDoc: () => true,
      hasApiMethod: (name: string) => name === "setTextSelection" || name === "isTextEditActive",
      callApi: (name: string, ...args: unknown[]) => {
        calls.push({ name: "callApi:" + name, args })
        return name === "isTextEditActive" ? true : undefined
      },
      eventToPageLocal: (event: any) => event.loc,
      lokModifierMask: () => 0,
      postNativeMouseEvent: (...args: unknown[]) => calls.push({ name: "postNativeMouseEvent", args }),
      requestDragRenderPage: (...args: unknown[]) => calls.push({ name: "requestDragRenderPage", args }),
      renderPage: (...args: unknown[]) => calls.push({ name: "renderPage", args }),
      settleAfterMouseSelection: (...args: unknown[]) => calls.push({ name: "settleAfterMouseSelection", args }),
      settleCaretAfterHit: (...args: unknown[]) => calls.push({ name: "settleCaretAfterHit", args }),
      clearSelectionState: () => calls.push({ name: "clearSelectionState" }),
      anchorProxy: () => calls.push({ name: "anchorProxy" }),
      imeProxy: null,
      hasActiveSelection: false,
      dragSelect: null,
    } as any

    editor.onCanvasMouseDown({
      button: 0,
      detail: 1,
      loc: { pageIndex: 0, x: 10, y: 10 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect.mode, "text")
    assert.ok(
      calls.some(call =>
        call.name === "callApi:setTextSelection" &&
        call.args?.[0] === 0 &&
        call.args?.[1] === 150 &&
        call.args?.[2] === 150
      )
    )
    assert.equal(calls.some(call => call.name === "postNativeMouseEvent"), false)

    calls.length = 0
    editor.onCanvasMouseMove({
      buttons: 1,
      loc: { pageIndex: 0, x: 50, y: 40 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.ok(
      calls.some(call =>
        call.name === "callApi:setTextSelection" &&
        call.args?.[0] === 1 &&
        call.args?.[1] === 750 &&
        call.args?.[2] === 600
      )
    )
    assert.ok(calls.some(call => call.name === "requestDragRenderPage"))
    assert.equal(calls.some(call => call.name === "postNativeMouseEvent"), false)

    calls.length = 0
    editor.onCanvasMouseUp({
      loc: { pageIndex: 0, x: 60, y: 40 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect, null)
    assert.ok(
      calls.some(call =>
        call.name === "callApi:setTextSelection" &&
        call.args?.[0] === 1 &&
        call.args?.[1] === 900 &&
        call.args?.[2] === 600
      )
    )
    assert.equal(calls.some(call => call.name === "postNativeMouseEvent"), false)
    assert.ok(calls.some(call => call.name === "settleAfterMouseSelection"))
  })

  it("uses native mouse events for writer drags", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: {},
      parts: [{ width: 100, height: 100 }],
      pageRects: [{ x: 1000, y: 2000, w: 4000, h: 3000 }],
      LOK_MOUSEEVENT_MOUSEBUTTONDOWN: 0,
      LOK_MOUSEEVENT_MOUSEBUTTONUP: 1,
      LOK_MOUSEEVENT_MOUSEMOVE: 2,
      LOK_MOUSE_LEFT: 1,
      LOK_SETTEXTSELECTION_RESET: 2,
      LOK_SETTEXTSELECTION_END: 1,
      presentationLikeDoc: () => false,
      spreadsheetLikeDoc: () => false,
      hasApiMethod: (name: string) => name === "setTextSelection",
      callApi: (name: string, ...args: unknown[]) => calls.push({ name: "callApi:" + name, args }),
      eventToPageLocal: (event: any) => event.loc,
      lokModifierMask: () => 0,
      postNativeMouseEvent: (...args: unknown[]) => calls.push({ name: "postNativeMouseEvent", args }),
      requestDragRenderPage: (...args: unknown[]) => calls.push({ name: "requestDragRenderPage", args }),
      renderPage: (...args: unknown[]) => calls.push({ name: "renderPage", args }),
      settleAfterMouseSelection: (...args: unknown[]) => calls.push({ name: "settleAfterMouseSelection", args }),
      settleCaretAfterHit: (...args: unknown[]) => calls.push({ name: "settleCaretAfterHit", args }),
      clearSelectionState: () => calls.push({ name: "clearSelectionState" }),
      anchorProxy: () => calls.push({ name: "anchorProxy" }),
      imeProxy: null,
      hasActiveSelection: false,
      dragSelect: null,
    } as any

    editor.onCanvasMouseDown({
      button: 0,
      detail: 1,
      loc: { pageIndex: 0, x: 10, y: 10 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect.mode, "native")
    assert.ok(calls.some(call => call.name === "postNativeMouseEvent" && call.args?.[0] === 0))
    assert.equal(calls.some(call => call.name === "callApi:setTextSelection"), false)

    calls.length = 0
    editor.onCanvasMouseMove({
      buttons: 1,
      loc: { pageIndex: 0, x: 50, y: 40 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.ok(calls.some(call => call.name === "postNativeMouseEvent" && call.args?.[0] === 2))
    assert.ok(calls.some(call => call.name === "requestDragRenderPage"))
    assert.equal(calls.some(call => call.name === "callApi:setTextSelection"), false)

    calls.length = 0
    editor.onCanvasMouseUp({
      loc: { pageIndex: 0, x: 60, y: 40 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect, null)
    assert.ok(calls.some(call => call.name === "postNativeMouseEvent" && call.args?.[0] === 1))
    assert.equal(calls.some(call => call.name === "callApi:setTextSelection"), false)
    assert.ok(calls.some(call => call.name === "settleAfterMouseSelection"))
  })

  it("uses one-based native mouse pages for spreadsheets", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: {},
      spreadsheetLikeDoc: () => true,
      callApi: (name: string, ...args: unknown[]) => calls.push({ name: "callApi:" + name, args }),
    } as any

    editor.postNativeMouseEvent(0, { pageIndex: 0, x: 96, y: 50 }, 1, 1, 0)

    assert.deepEqual(calls, [
      { name: "callApi:postMouseEvent", args: [0, 1, 96, 50, 1, 1, 0] },
    ])
  })

  it("defers presentation mouse-down, then uses native object drag for non-text targets", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: { resolveRef: () => ({ ok: false }) },
      parts: [{ width: 100, height: 100 }],
      LOK_MOUSEEVENT_MOUSEBUTTONDOWN: 0,
      LOK_MOUSEEVENT_MOUSEBUTTONUP: 1,
      LOK_MOUSEEVENT_MOUSEMOVE: 2,
      LOK_MOUSE_LEFT: 1,
      presentationLikeDoc: () => true,
      hasApiMethod: (name: string) => name === "setTextSelection" || name === "isTextEditActive",
      callApi: (name: string, ...args: unknown[]) => {
        calls.push({ name: "callApi:" + name, args })
        return name === "isTextEditActive" ? false : undefined
      },
      officeResolveAt: (...args: unknown[]) => {
        calls.push({ name: "officeResolveAt", args })
        return null
      },
      eventToPageLocal: (event: any) => event.loc,
      lokModifierMask: () => 0,
      postNativeMouseEvent: (...args: unknown[]) => calls.push({ name: "postNativeMouseEvent", args }),
      requestDragRenderPage: (...args: unknown[]) => calls.push({ name: "requestDragRenderPage", args }),
      renderPage: (...args: unknown[]) => calls.push({ name: "renderPage", args }),
      settleAfterMouseSelection: (...args: unknown[]) => calls.push({ name: "settleAfterMouseSelection", args }),
      settleCaretAfterHit: (...args: unknown[]) => calls.push({ name: "settleCaretAfterHit", args }),
      clearSelectionState: () => calls.push({ name: "clearSelectionState" }),
      anchorProxy: () => calls.push({ name: "anchorProxy" }),
      imeProxy: null,
      hasActiveSelection: false,
      dragSelect: null,
    } as any

    editor.onCanvasMouseDown({
      button: 0,
      detail: 1,
      loc: { pageIndex: 0, x: 10, y: 10 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect.mode, "pending")
    assert.equal(calls.some(call => call.name === "postNativeMouseEvent"), false)

    editor.onCanvasMouseMove({
      buttons: 1,
      loc: { pageIndex: 0, x: 45, y: 35 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect.mode, "native")
    assert.ok(calls.some(call => call.name === "officeResolveAt" && call.args?.[1] === true))
    assert.ok(calls.some(call => call.name === "postNativeMouseEvent" && call.args?.[0] === 0))
    assert.ok(calls.some(call => call.name === "postNativeMouseEvent" && call.args?.[0] === 2))
    assert.equal(calls.some(call => call.name === "callApi:setTextSelection"), false)
  })

  it("does not substitute native object drag for a text-bearing presentation target", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: { resolveRef: () => ({ ok: true }) },
      parts: [{ width: 100, height: 100 }],
      pageRects: [{ x: 1000, y: 2000, w: 4000, h: 3000 }],
      presentationLikeDoc: () => true,
      hasApiMethod: (name: string) => name === "setTextSelection" || name === "isTextEditActive",
      callApi: (name: string, ...args: unknown[]) => {
        calls.push({ name: "callApi:" + name, args })
        return name === "isTextEditActive" ? false : undefined
      },
      officeResolveAt: (...args: unknown[]) => {
        calls.push({ name: "officeResolveAt", args })
        return {
          ref: "page[page1]/shape[Title]",
          text: "COSE321 Computer Systems Design",
          rects: [{ pageIndex: 0, x: 144, y: 256, width: 688, height: 64 }],
        }
      },
      eventToPageLocal: (event: any) => event.loc,
      lokModifierMask: () => 0,
      postNativeMouseEvent: (...args: unknown[]) => calls.push({ name: "postNativeMouseEvent", args }),
      requestDragRenderPage: (...args: unknown[]) => calls.push({ name: "requestDragRenderPage", args }),
      renderPage: (...args: unknown[]) => calls.push({ name: "renderPage", args }),
      settleAfterMouseSelection: (...args: unknown[]) => calls.push({ name: "settleAfterMouseSelection", args }),
      settleCaretAfterHit: (...args: unknown[]) => calls.push({ name: "settleCaretAfterHit", args }),
      clearSelectionState: () => calls.push({ name: "clearSelectionState" }),
      anchorProxy: () => calls.push({ name: "anchorProxy" }),
      imeProxy: null,
      hasActiveSelection: false,
      dragSelect: null,
    } as any

    editor.onCanvasMouseDown({
      button: 0,
      detail: 1,
      loc: { pageIndex: 0, x: 152, y: 264 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    editor.onCanvasMouseMove({
      buttons: 1,
      loc: { pageIndex: 0, x: 272, y: 264 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect.mode, "text-blocked")
    assert.ok(calls.some(call => call.name === "officeResolveAt" && call.args?.[1] === true))
    assert.equal(calls.some(call => call.name === "postNativeMouseEvent"), false)
    assert.equal(calls.some(call => call.name === "callApi:setTextSelection"), false)
  })

  it("commits a pending presentation drag into direct text selection when the native editor activates", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    let activated = false
    const editor = {
      ...WasmOfficeEditor,
      api: { resolveRef: () => ({ ok: true, ref: "page[page1]/shape[Title]" }) },
      parts: [{ width: 100, height: 100 }],
      pageRects: [{ x: 1000, y: 2000, w: 4000, h: 3000 }],
      LOK_SETTEXTSELECTION_RESET: 2,
      LOK_SETTEXTSELECTION_END: 1,
      presentationLikeDoc: () => true,
      hasApiMethod: (name: string) => name === "setTextSelection" || name === "isTextEditActive",
      callApi: (name: string, ...args: unknown[]) => {
        calls.push({ name: "callApi:" + name, args })
        return name === "isTextEditActive" ? activated : undefined
      },
      officeResolveAt: (...args: unknown[]) => {
        calls.push({ name: "officeResolveAt", args })
        activated = true
        return { ref: "page[page1]/shape[Title]" }
      },
      eventToPageLocal: (event: any) => event.loc,
      lokModifierMask: () => 0,
      postNativeMouseEvent: (...args: unknown[]) => calls.push({ name: "postNativeMouseEvent", args }),
      requestDragRenderPage: (...args: unknown[]) => calls.push({ name: "requestDragRenderPage", args }),
      renderPage: (...args: unknown[]) => calls.push({ name: "renderPage", args }),
      settleAfterMouseSelection: (...args: unknown[]) => calls.push({ name: "settleAfterMouseSelection", args }),
      settleCaretAfterHit: (...args: unknown[]) => calls.push({ name: "settleCaretAfterHit", args }),
      clearSelectionState: () => calls.push({ name: "clearSelectionState" }),
      anchorProxy: () => calls.push({ name: "anchorProxy" }),
      imeProxy: null,
      hasActiveSelection: false,
      dragSelect: null,
    } as any

    editor.onCanvasMouseDown({
      button: 0,
      detail: 1,
      loc: { pageIndex: 0, x: 10, y: 10 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect.mode, "pending")
    assert.equal(calls.some(call => call.name === "postNativeMouseEvent"), false)

    editor.onCanvasMouseMove({
      buttons: 1,
      loc: { pageIndex: 0, x: 50, y: 40 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect.mode, "text")
    assert.ok(calls.some(call => call.name === "officeResolveAt" && call.args?.[1] === true))
    assert.ok(
      calls.some(call =>
        call.name === "callApi:setTextSelection" &&
        call.args?.[0] === 0 &&
        call.args?.[1] === 150 &&
        call.args?.[2] === 150
      )
    )
    assert.ok(
      calls.some(call =>
        call.name === "callApi:setTextSelection" &&
        call.args?.[0] === 1 &&
        call.args?.[1] === 750 &&
        call.args?.[2] === 600
      )
    )
    assert.equal(calls.some(call => call.name === "postNativeMouseEvent"), false)
  })

  it("activates a text-bearing presentation shape at its center before drag-selecting from the real start point", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    let activated = false
    const editor = {
      ...WasmOfficeEditor,
      api: { resolveRef: () => ({ ok: true }), doubleClick: () => undefined },
      parts: [{ width: 100, height: 100 }],
      pageRects: [{ x: 1000, y: 2000, w: 4000, h: 3000 }],
      LOK_SETTEXTSELECTION_RESET: 2,
      LOK_SETTEXTSELECTION_END: 1,
      presentationLikeDoc: () => true,
      hasApiMethod: (name: string) => (
        name === "setTextSelection" ||
        name === "isTextEditActive" ||
        name === "doubleClick"
      ),
      callApi: (name: string, ...args: unknown[]) => {
        calls.push({ name: "callApi:" + name, args })
        if (name === "doubleClick") activated = true
        return name === "isTextEditActive" ? activated : undefined
      },
      officeResolveAt: (...args: unknown[]) => {
        calls.push({ name: "officeResolveAt", args })
        return {
          ref: "page[page1]/shape[Title]",
          text: "COSE321 Computer Systems Design",
          rects: [{ pageIndex: 0, x: 144, y: 256, width: 688, height: 64 }],
        }
      },
      eventToPageLocal: (event: any) => event.loc,
      lokModifierMask: () => 0,
      postNativeMouseEvent: (...args: unknown[]) => calls.push({ name: "postNativeMouseEvent", args }),
      requestDragRenderPage: (...args: unknown[]) => calls.push({ name: "requestDragRenderPage", args }),
      renderPage: (...args: unknown[]) => calls.push({ name: "renderPage", args }),
      settleAfterMouseSelection: (...args: unknown[]) => calls.push({ name: "settleAfterMouseSelection", args }),
      settleCaretAfterHit: (...args: unknown[]) => calls.push({ name: "settleCaretAfterHit", args }),
      clearSelectionState: () => calls.push({ name: "clearSelectionState" }),
      anchorProxy: () => calls.push({ name: "anchorProxy" }),
      imeProxy: null,
      hasActiveSelection: false,
      dragSelect: null,
    } as any

    editor.onCanvasMouseDown({
      button: 0,
      detail: 1,
      loc: { pageIndex: 0, x: 152, y: 264 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    editor.onCanvasMouseMove({
      buttons: 1,
      loc: { pageIndex: 0, x: 272, y: 264 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect.mode, "text")
    assert.ok(calls.some(call => call.name === "officeResolveAt" && call.args?.[1] === true))
    assert.ok(
      calls.some(call =>
        call.name === "callApi:doubleClick" &&
        call.args?.[0] === 1 &&
        call.args?.[1] === 488 &&
        call.args?.[2] === 288
      )
    )
    assert.ok(
      calls.some(call =>
        call.name === "callApi:setTextSelection" &&
        call.args?.[0] === 0 &&
        call.args?.[1] === 2280 &&
        call.args?.[2] === 3960
      )
    )
    assert.ok(
      calls.some(call =>
        call.name === "callApi:setTextSelection" &&
        call.args?.[0] === 1 &&
        call.args?.[1] === 4080 &&
        call.args?.[2] === 3960
      )
    )
    assert.equal(calls.some(call => call.name === "postNativeMouseEvent"), false)
  })

  it("turns a pending presentation click into a normal native click on mouse-up", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: { resolveRef: () => ({ ok: false }) },
      parts: [{ width: 100, height: 100 }],
      LOK_MOUSEEVENT_MOUSEBUTTONDOWN: 0,
      LOK_MOUSEEVENT_MOUSEBUTTONUP: 1,
      LOK_MOUSE_LEFT: 1,
      presentationLikeDoc: () => true,
      hasApiMethod: (name: string) => name === "setTextSelection" || name === "isTextEditActive",
      callApi: (name: string, ...args: unknown[]) => {
        calls.push({ name: "callApi:" + name, args })
        return name === "isTextEditActive" ? false : undefined
      },
      eventToPageLocal: (event: any) => event.loc,
      lokModifierMask: () => 0,
      postNativeMouseEvent: (...args: unknown[]) => calls.push({ name: "postNativeMouseEvent", args }),
      renderPage: (...args: unknown[]) => calls.push({ name: "renderPage", args }),
      settleCaretAfterHit: (...args: unknown[]) => calls.push({ name: "settleCaretAfterHit", args }),
      clearSelectionState: () => calls.push({ name: "clearSelectionState" }),
      anchorProxy: () => calls.push({ name: "anchorProxy" }),
      imeProxy: null,
      hasActiveSelection: false,
      dragSelect: null,
    } as any

    editor.onCanvasMouseDown({
      button: 0,
      detail: 1,
      loc: { pageIndex: 0, x: 10, y: 10 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)
    calls.length = 0

    editor.onCanvasMouseUp({
      loc: { pageIndex: 0, x: 10, y: 10 },
      cancelable: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any)

    assert.equal(editor.dragSelect, null)
    assert.ok(calls.some(call => call.name === "postNativeMouseEvent" && call.args?.[0] === 0))
    assert.ok(calls.some(call => call.name === "postNativeMouseEvent" && call.args?.[0] === 1))
    assert.equal(calls.some(call => call.name === "callApi:setTextSelection"), false)
    assert.ok(calls.some(call => call.name === "settleCaretAfterHit"))
  })

  it("routes Office undo through native key events and repaints the editor", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: { postKeyEvent: (...args: unknown[]) => calls.push({ name: "postKeyEvent", args }) },
      parts: [{ width: 100, height: 100 }],
      hasActiveSelection: true,
      renderAfterInput: () => calls.push({ name: "renderAfterInput" }),
      refreshCaret: () => calls.push({ name: "refreshCaret" }),
      settleCaretAfterInput: (...args: unknown[]) => calls.push({ name: "settleCaretAfterInput", args }),
      markViewerMutated: () => calls.push({ name: "markViewerMutated" }),
      imeProxy: { value: "stale" },
    } as any
    const event = {
      key: "z",
      ctrlKey: true,
      metaKey: false,
      altKey: false,
      shiftKey: false,
      preventDefault: () => calls.push({ name: "preventDefault" }),
      stopPropagation: () => calls.push({ name: "stopPropagation" }),
    } as any

    assert.equal(editor.handleEditShortcut(event), true)

    assert.ok(calls.some(call => call.name === "postKeyEvent" && call.args?.[2] === (editor.AWT_KEY.Z | editor.LOK_KEY_MOD1)))
    assert.ok(calls.some(call => call.name === "renderAfterInput"))
    assert.ok(calls.some(call => call.name === "refreshCaret"))
    assert.ok(calls.some(call => call.name === "settleCaretAfterInput" && call.args?.[1] === true))
    assert.equal(editor.imeProxy.value, "")
  })

  it("routes Office undo from the document keydown when the canvas is active", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: { postKeyEvent: (...args: unknown[]) => calls.push({ name: "postKeyEvent", args }) },
      parts: [{ width: 100, height: 100 }],
      el: { contains: () => false },
      imeProxy: { value: "" },
      renderAfterInput: () => calls.push({ name: "renderAfterInput" }),
      refreshCaret: () => calls.push({ name: "refreshCaret" }),
      settleCaretAfterInput: (...args: unknown[]) => calls.push({ name: "settleCaretAfterInput", args }),
      markViewerMutated: () => calls.push({ name: "markViewerMutated" }),
    } as any
    const previousActive = (globalThis as any).document.activeElement
    ;(globalThis as any).document.activeElement = (globalThis as any).document.body
    editor.activateKeyboardShortcuts()

    editor.handleDocumentKeyDown({
      key: "z",
      ctrlKey: true,
      metaKey: false,
      altKey: false,
      shiftKey: false,
      target: (globalThis as any).document.body,
      preventDefault: () => calls.push({ name: "preventDefault" }),
      stopPropagation: () => calls.push({ name: "stopPropagation" }),
    } as any)

    ;(globalThis as any).document.activeElement = previousActive
    assert.ok(calls.some(call => call.name === "postKeyEvent" && call.args?.[2] === (editor.AWT_KEY.Z | editor.LOK_KEY_MOD1)))
    assert.ok(calls.some(call => call.name === "preventDefault"))
  })

  it("routes Office redo from document keydown shortcuts", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: { postKeyEvent: (...args: unknown[]) => calls.push({ name: "postKeyEvent", args }) },
      parts: [{ width: 100, height: 100 }],
      el: { contains: () => false },
      imeProxy: { value: "" },
      renderAfterInput: () => calls.push({ name: "renderAfterInput" }),
      refreshCaret: () => calls.push({ name: "refreshCaret" }),
      settleCaretAfterInput: (...args: unknown[]) => calls.push({ name: "settleCaretAfterInput", args }),
      markViewerMutated: () => calls.push({ name: "markViewerMutated" }),
    } as any
    const previousActive = (globalThis as any).document.activeElement
    ;(globalThis as any).document.activeElement = (globalThis as any).document.body
    editor.activateKeyboardShortcuts()

    editor.handleDocumentKeyDown({
      key: "y",
      ctrlKey: true,
      metaKey: false,
      altKey: false,
      shiftKey: false,
      target: (globalThis as any).document.body,
      preventDefault: () => calls.push({ name: "preventDefault" }),
      stopPropagation: () => calls.push({ name: "stopPropagation" }),
    } as any)

    ;(globalThis as any).document.activeElement = previousActive
    assert.ok(calls.some(call => call.name === "postKeyEvent" && call.args?.[2] === (editor.AWT_KEY.Y | editor.LOK_KEY_MOD1)))
  })

  it("routes Office shift-z redo through the native shortcut chord", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: { postKeyEvent: (...args: unknown[]) => calls.push({ name: "postKeyEvent", args }) },
      parts: [{ width: 100, height: 100 }],
      renderAfterInput: () => calls.push({ name: "renderAfterInput" }),
      refreshCaret: () => calls.push({ name: "refreshCaret" }),
      settleCaretAfterInput: (...args: unknown[]) => calls.push({ name: "settleCaretAfterInput", args }),
      markViewerMutated: () => calls.push({ name: "markViewerMutated" }),
      imeProxy: { value: "" },
    } as any

    assert.equal(editor.handleEditShortcut({
      key: "z",
      ctrlKey: true,
      metaKey: false,
      altKey: false,
      shiftKey: true,
      preventDefault: () => calls.push({ name: "preventDefault" }),
      stopPropagation: () => calls.push({ name: "stopPropagation" }),
    } as any), true)

    assert.ok(calls.some(call =>
      call.name === "postKeyEvent" &&
        call.args?.[2] === (editor.AWT_KEY.Z | editor.LOK_KEY_MOD1 | editor.LOK_KEY_SHIFT)
    ))
  })

  it("does not steal document shortcuts from external editable controls", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const externalInput = {
      closest: (selector: string) => selector.includes("input") ? externalInput : null,
    }
    const editor = {
      ...WasmOfficeEditor,
      api: { postKeyEvent: (...args: unknown[]) => calls.push({ name: "postKeyEvent", args }) },
      parts: [{ width: 100, height: 100 }],
      el: { contains: () => false },
      imeProxy: { value: "" },
    } as any
    editor.activateKeyboardShortcuts()

    editor.handleDocumentKeyDown({
      key: "z",
      ctrlKey: true,
      metaKey: false,
      altKey: false,
      shiftKey: false,
      target: externalInput,
      preventDefault: () => calls.push({ name: "preventDefault" }),
      stopPropagation: () => calls.push({ name: "stopPropagation" }),
    } as any)

    assert.equal(calls.length, 0)
  })

  it("lets the Office IME proxy handle its own shortcut keydown", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const imeProxy = { value: "" }
    const editor = {
      ...WasmOfficeEditor,
      api: { postKeyEvent: (...args: unknown[]) => calls.push({ name: "postKeyEvent", args }) },
      parts: [{ width: 100, height: 100 }],
      el: { contains: () => false },
      imeProxy,
    } as any
    editor.activateKeyboardShortcuts()

    editor.handleDocumentKeyDown({
      key: "z",
      ctrlKey: true,
      metaKey: false,
      altKey: false,
      shiftKey: false,
      target: imeProxy,
      preventDefault: () => calls.push({ name: "preventDefault" }),
      stopPropagation: () => calls.push({ name: "stopPropagation" }),
    } as any)

    assert.equal(calls.length, 0)
  })

  it("replaces a provisional Hangul jamo when the final syllable arrives as trailing composition input", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: { postKeyEvent: (...args: unknown[]) => calls.push({ name: "postKeyEvent", args }) },
      parts: [{ width: 100, height: 100 }],
      AWT_KEY: { ...WasmOfficeEditor.AWT_KEY },
      LOK_KEYEVENT_KEYINPUT: 0,
      LOK_KEYEVENT_KEYUP: 1,
      presentationLikeDoc: () => false,
      renderAfterInput: () => calls.push({ name: "renderAfterInput" }),
      refreshCaret: () => calls.push({ name: "refreshCaret" }),
      settleCaretAfterInput: (...args: unknown[]) => calls.push({ name: "settleCaretAfterInput", args }),
      markViewerMutated: () => calls.push({ name: "markViewerMutated" }),
      selectionVisual: null,
      imeProxy: { value: "" },
    } as any

    editor.handleCompositionStart({} as any)
    editor.handleCompositionUpdate({ data: "ㄱ" } as any)
    editor.handleCompositionEnd({ data: "" } as any)
    editor.handleInput({
      inputType: "insertCompositionText",
      data: "김",
      isComposing: false,
    } as any)

    assert.deepEqual(
      calls
        .filter(call => call.name === "postKeyEvent")
        .map(call => call.args),
      [
        [0, "ㄱ".codePointAt(0), 0],
        [1, "ㄱ".codePointAt(0), 0],
        [0, 8, editor.AWT_KEY.BACKSPACE],
        [1, 8, editor.AWT_KEY.BACKSPACE],
        [0, "김".codePointAt(0), 0],
        [1, "김".codePointAt(0), 0],
      ]
    )
    assert.equal(editor.imeProxy.value, "")
    assert.equal(editor.skipNextCompositionInput, null)
  })

  it("uses the Office IME proxy text when trailing Hangul input has empty data", () => {
    let text = ""
    const editor = {
      ...WasmOfficeEditor,
      api: {
        postKeyEvent: (_type: number, charCode: number, keyCode: number) => {
          if (_type !== 0) return
          if (charCode === 8 || keyCode === WasmOfficeEditor.AWT_KEY.BACKSPACE) {
            text = Array.from(text).slice(0, -1).join("")
          } else if (charCode) {
            text += String.fromCodePoint(charCode)
          }
        },
      },
      parts: [{ width: 100, height: 100 }],
      AWT_KEY: { ...WasmOfficeEditor.AWT_KEY },
      LOK_KEYEVENT_KEYINPUT: 0,
      LOK_KEYEVENT_KEYUP: 1,
      presentationLikeDoc: () => false,
      renderAfterInput: () => {},
      refreshCaret: () => {},
      settleCaretAfterInput: () => {},
      markViewerMutated: () => {},
      selectionVisual: null,
      imeProxy: { value: "" },
    } as any
    const compose = (provisional: string, committed: string) => {
      editor.handleCompositionStart({} as any)
      editor.imeProxy.value = provisional
      editor.handleCompositionUpdate({ data: provisional } as any)
      editor.handleCompositionEnd({ data: "" } as any)
      editor.imeProxy.value = committed
      editor.handleInput({
        inputType: "insertCompositionText",
        data: "",
        isComposing: false,
      } as any)
    }

    compose("ㄱ", "김")
    compose("ㅇ", "일")
    compose("ㅇ", "영")

    assert.equal(text, "김일영")
    assert.equal(editor.imeProxy.value, "")
    assert.equal(editor.skipNextCompositionInput, null)
  })

  it("commits DOCX Hangul composition through Office extended text input when available", () => {
    let committed = ""
    let preedit = ""
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: {
        postKeyEvent: (...args: unknown[]) => {
          calls.push({ name: "postKeyEvent", args })
          const [_type, charCode, keyCode] = args as [number, number, number]
          if (_type !== 0) return
          if (charCode === 8 || keyCode === WasmOfficeEditor.AWT_KEY.BACKSPACE) {
            if (preedit) preedit = Array.from(preedit).slice(0, -1).join("")
            else committed = Array.from(committed).slice(0, -1).join("")
          }
        },
        postWindowExtTextInputEvent: (...args: unknown[]) => {
          calls.push({ name: "postWindowExtTextInputEvent", args })
          const [windowId, type, value] = args as [number, number, string]
          if (windowId === 0 && type === WasmOfficeEditor.LOK_EXT_TEXTINPUT) preedit = value
          if (windowId === 0 && type === WasmOfficeEditor.LOK_EXT_TEXTINPUT_END) {
            committed += preedit
            preedit = ""
          }
        },
      },
      parts: [{ width: 100, height: 100 }],
      AWT_KEY: { ...WasmOfficeEditor.AWT_KEY },
      LOK_KEYEVENT_KEYINPUT: 0,
      LOK_KEYEVENT_KEYUP: 1,
      LOK_EXT_TEXTINPUT: WasmOfficeEditor.LOK_EXT_TEXTINPUT,
      LOK_EXT_TEXTINPUT_END: WasmOfficeEditor.LOK_EXT_TEXTINPUT_END,
      presentationLikeDoc: () => false,
      renderAfterInput: () => {},
      refreshCaret: () => {},
      settleCaretAfterInput: () => {},
      markViewerMutated: () => {},
      selectionVisual: null,
      imeProxy: { value: "" },
    } as any
    const compose = (provisional: string, committed: string) => {
      editor.handleCompositionStart({} as any)
      editor.imeProxy.value = provisional
      editor.handleCompositionUpdate({ data: provisional } as any)
      editor.handleCompositionEnd({ data: "" } as any)
      editor.imeProxy.value = committed
      editor.handleInput({
        inputType: "insertCompositionText",
        data: "",
        isComposing: false,
      } as any)
    }

    compose("ㄱ", "김")
    compose("ㅇ", "일")
    compose("ㅇ", "영")

    assert.equal(committed + preedit, "김일영")
    assert.deepEqual(
      calls
        .filter(call => call.name === "postWindowExtTextInputEvent")
        .map(call => call.args),
      [
        [0, editor.LOK_EXT_TEXTINPUT, "ㄱ"],
        [0, editor.LOK_EXT_TEXTINPUT, "김"],
        [0, editor.LOK_EXT_TEXTINPUT_END, ""],
        [0, editor.LOK_EXT_TEXTINPUT, "ㅇ"],
        [0, editor.LOK_EXT_TEXTINPUT, "일"],
        [0, editor.LOK_EXT_TEXTINPUT_END, ""],
        [0, editor.LOK_EXT_TEXTINPUT, "ㅇ"],
        [0, editor.LOK_EXT_TEXTINPUT, "영"],
        [0, editor.LOK_EXT_TEXTINPUT_END, ""],
      ]
    )
    assert.equal(
      calls.some(call =>
        call.name === "postKeyEvent" &&
        ["김", "일", "영"].includes(String.fromCodePoint(Number(call.args?.[1] || 0)))
      ),
      false
    )
  })

  it("replaces delayed multi-syllable Hangul IME finals instead of appending them to provisional jamo", () => {
    let text = ""
    const editor = {
      ...WasmOfficeEditor,
      api: {
        postKeyEvent: (_type: number, charCode: number, keyCode: number) => {
          if (_type !== 0) return
          if (charCode === 8 || keyCode === WasmOfficeEditor.AWT_KEY.BACKSPACE) {
            text = Array.from(text).slice(0, -1).join("")
          } else if (charCode) {
            text += String.fromCodePoint(charCode)
          }
        },
      },
      parts: [{ width: 100, height: 100 }],
      AWT_KEY: { ...WasmOfficeEditor.AWT_KEY },
      LOK_KEYEVENT_KEYINPUT: 0,
      LOK_KEYEVENT_KEYUP: 1,
      presentationLikeDoc: () => false,
      renderAfterInput: () => {},
      refreshCaret: () => {},
      settleCaretAfterInput: () => {},
      markViewerMutated: () => {},
      selectionVisual: null,
      imeProxy: { value: "" },
    } as any

    editor.handleCompositionStart({} as any)
    editor.handleCompositionUpdate({ data: "ㅇ" } as any)
    editor.handleCompositionEnd({ data: "" } as any)
    editor.handleInput({
      inputType: "insertCompositionText",
      data: "안",
      isComposing: true,
    } as any)

    editor.handleCompositionStart({} as any)
    editor.handleCompositionUpdate({ data: "녀" } as any)
    editor.handleCompositionEnd({ data: "" } as any)
    editor.skipNextCompositionInput = { ...editor.skipNextCompositionInput, at: performance.now() - 600 }
    editor.handleInput({
      inputType: "insertText",
      data: "녕",
      isComposing: false,
    } as any)

    assert.equal(text, "안녕")
  })

  it("posts spreadsheet printable keys eagerly to the native cell editor", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: { postKeyEvent: (...args: unknown[]) => calls.push({ name: "postKeyEvent", args }) },
      parts: [{ width: 100, height: 100 }],
      docType: 1,
      AWT_KEY: { RETURN: 1280, ESCAPE: 1281, BACKSPACE: 1283 },
      LOK_KEYEVENT_KEYINPUT: 1,
      LOK_KEYEVENT_KEYUP: 2,
      saveShortcut: () => false,
      koreanImeKey: () => false,
      handleEditShortcut: () => false,
      presentationLikeDoc: () => false,
      renderAfterInput: () => calls.push({ name: "renderAfterInput" }),
      refreshCaret: () => calls.push({ name: "refreshCaret" }),
      settleCaretAfterInput: (...args: unknown[]) => calls.push({ name: "settleCaretAfterInput", args }),
      markViewerMutated: () => calls.push({ name: "markViewerMutated" }),
      anchorProxy: () => calls.push({ name: "anchorProxy" }),
      imeProxy: { value: "" },
    } as any
    const keyEvent = (key: string) => ({
      key,
      preventDefault: () => calls.push({ name: "preventDefault", args: [key] }),
      stopPropagation: () => calls.push({ name: "stopPropagation", args: [key] }),
    }) as any

    editor.handleKeyDown(keyEvent("Z"))
    editor.handleKeyDown(keyEvent("9"))

    // No JS-side buffer/debounce: each printable key reaches the engine at once,
    // so typed text shows immediately instead of after a 1.2s idle flush.
    assert.deepEqual(
      calls.filter(call => call.name === "postKeyEvent").map(call => call.args),
      [
        [1, 90, 0],
        [2, 90, 0],
        [1, 57, 0],
        [2, 57, 0],
      ]
    )

    editor.handleKeyDown(keyEvent("Enter"))

    assert.deepEqual(
      calls.filter(call => call.name === "postKeyEvent").map(call => call.args),
      [
        [1, 90, 0],
        [2, 90, 0],
        [1, 57, 0],
        [2, 57, 0],
        [1, 13, 1280],
        [2, 13, 1280],
      ]
    )
    // One mutation notification per posted keystroke (Z, 9, Enter).
    assert.equal(calls.filter(call => call.name === "markViewerMutated").length, 3)
    assert.equal(editor.imeProxy.value, "")
  })

  it("copies and pastes Office text through the IME proxy clipboard events", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmOfficeEditor,
      api: {
        getTextSelection: () => "selected text",
        postKeyEvent: (...args: unknown[]) => calls.push({ name: "postKeyEvent", args }),
      },
      parts: [{ width: 100, height: 100 }],
      AWT_KEY: { RETURN: 1280 },
      LOK_KEYEVENT_KEYINPUT: 1,
      LOK_KEYEVENT_KEYUP: 2,
      presentationLikeDoc: () => false,
      renderAfterInput: () => calls.push({ name: "renderAfterInput" }),
      refreshCaret: () => calls.push({ name: "refreshCaret" }),
      settleCaretAfterInput: (...args: unknown[]) => calls.push({ name: "settleCaretAfterInput", args }),
      markViewerMutated: () => calls.push({ name: "markViewerMutated" }),
      imeProxy: { value: "stale" },
    } as any
    const clipboard: Record<string, string> = {}
    const copyEvent = {
      clipboardData: { setData: (type: string, value: string) => { clipboard[type] = value } },
      preventDefault: () => calls.push({ name: "copyPreventDefault" }),
    } as any

    editor.handleCopy(copyEvent)

    assert.equal(clipboard["text/plain"], "selected text")
    assert.ok(calls.some(call => call.name === "copyPreventDefault"))

    const pasteEvent = {
      clipboardData: { getData: () => "A\nB" },
      preventDefault: () => calls.push({ name: "pastePreventDefault" }),
    } as any
    editor.handlePaste(pasteEvent)

    assert.ok(calls.some(call => call.name === "pastePreventDefault"))
    assert.ok(calls.some(call => call.name === "postKeyEvent" && call.args?.[1] === 65))
    assert.ok(calls.some(call => call.name === "postKeyEvent" && call.args?.[2] === 1280))
    assert.equal(editor.imeProxy.value, "")
  })
})

describe("WasmHwpEditor clipboard editing", () => {
  it("copies selected HWP model text instead of the IME proxy textarea", () => {
    const clipboard: Record<string, string> = {}
    const calls: string[] = []
    const editor = {
      ...WasmHwpEditor,
      doc: {
        getTextRange: (_section: number, paragraph: number, start: number, count: number) => {
          const text = paragraph === 0 ? "hello" : "world"
          return text.slice(start, start + count)
        },
      },
      sel: {
        kind: "text",
        section: 0,
        cell: null,
        anchor: { paragraph: 0, offset: 1 },
        focus: { paragraph: 1, offset: 3 },
      },
      hwpToolbarParagraphLength: (_section: number, paragraph: number) => paragraph === 0 ? 5 : 5,
      imeProxy: { value: "stale" },
    } as any
    const event = {
      clipboardData: { setData: (type: string, value: string) => { clipboard[type] = value } },
      preventDefault: () => calls.push("preventDefault"),
    } as any

    editor.handleCopy(event)

    assert.equal(clipboard["text/plain"], "ello\nwor")
    assert.deepEqual(calls, ["preventDefault"])
    assert.equal(editor.imeProxy.value, "")
  })

  it("pastes clipboard text into the HWP model", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      caret: { section: 0, paragraph: 0, offset: 0 },
      hasSelection: () => false,
      insertPlainTextAtCaret: (...args: unknown[]) => calls.push({ name: "insertPlainTextAtCaret", args }),
    } as any
    const event = {
      clipboardData: { getData: () => "A\nB" },
      preventDefault: () => calls.push({ name: "preventDefault" }),
    } as any

    editor.handlePaste(event)

    assert.ok(calls.some(call => call.name === "preventDefault"))
    assert.ok(calls.some(call => call.name === "insertPlainTextAtCaret" && call.args?.[0] === "A\nB"))
  })
})

describe("WasmHwpEditor image move", () => {
  const imagePick = {
    document: "/tmp/doc.hwp",
    backend: "hwp",
    format: "hwp",
    type: "image",
    ref: JSON.stringify({ section: 0, paragraph: 2, control: 3 }),
    text: "",
    rects: [{ pageIndex: 0, x: 4, y: 5, width: 120, height: 80 }],
    ir: {},
  }

  const imageDrag = (props: Record<string, unknown> = {}) => ({
    mode: "move",
    moved: true,
    section: 0,
    paraIdx: 2,
    controlIdx: 3,
    pageIndex: 0,
    curX: 24,
    curY: 36,
    w: 120,
    h: 80,
    pick: imagePick,
    props: {
      binDataId: "image-bin",
      width: 10,
      height: 20,
      cropLeft: 0,
      cropTop: 0,
      cropRight: 90,
      cropBottom: 80,
      ...props,
    },
  })

  it("commits picture moves with geometry-only properties and does not echo crop", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmHwpEditor,
      imageDrag: imageDrag(),
      doc: {
        pxToHwpUnit: (px: number) => px * 10,
        setPictureProperties: (...args: unknown[]) => calls.push({ name: "setPictureProperties", args }),
      },
      clearImageDragGhost: (...args: unknown[]) => calls.push({ name: "clearImageDragGhost", args }),
      renderPage: (...args: unknown[]) => calls.push({ name: "renderPage", args }),
      pictureGeometryProps: WasmHwpEditor.pictureGeometryProps,
      scheduleSnapshot: () => calls.push({ name: "scheduleSnapshot" }),
      paintPickedHighlights: () => calls.push({ name: "paintPickedHighlights" }),
    } as any

    editor.endImageDrag()

    const setCall = calls.find(call => call.name === "setPictureProperties")
    assert.ok(setCall)
    assert.deepEqual(JSON.parse(setCall.args?.[3] as string), {
      width: 10,
      height: 20,
      treatAsChar: false,
      horzRelTo: "Paper",
      vertRelTo: "Paper",
      horzAlign: "Left",
      vertAlign: "Top",
      horzOffset: 240,
      vertOffset: 360,
    })
    assert.ok(calls.some(call => call.name === "scheduleSnapshot"))
    assert.ok(calls.some(call => call.name === "paintPickedHighlights"))
    assert.equal(JSON.parse(editor.localImagePick.ref).control, 3)
    assert.deepEqual(editor.localImagePick.rects[0], { pageIndex: 0, x: 24, y: 36, width: 120, height: 80 })
  })

  it("plain image clicks select locally without adding chat composer picks", () => {
    picker.clearPicks()
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmHwpEditor,
      imageDrag: {
        ...imageDrag(),
        moved: false,
      },
      localImagePick: null,
      clearImageDragGhost: (...args: unknown[]) => calls.push({ name: "clearImageDragGhost", args }),
      clearSelection: () => calls.push({ name: "clearSelection" }),
      paintPickedHighlights: () => calls.push({ name: "paintPickedHighlights" }),
    } as any

    editor.endImageDrag()

    assert.deepEqual(picker.pickedElements(), [])
    assert.equal(editor.localImagePick, imagePick)
    assert.ok(calls.some(call => call.name === "paintPickedHighlights"))
  })

  it("uses the server-transmitted picker state when deciding whether an image click goes to chat", () => {
    picker.clearPicks()
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmHwpEditor,
      pickerEnabled: () => false,
      doc: {},
      format: "hwp",
      canvasState: { documentPath: "/tmp/doc.hwp" },
      el: { dataset: {} },
      hitTestEvent: () => ({ hit: { x: 10, y: 20 }, pageIndex: 0 }),
      hwpPick: () => ({
        type: "image",
        ref: { section: 0, paragraph: 2, control: 3 },
        rects: [{ pageIndex: 0, x: 4, y: 5, width: 120, height: 80 }],
        controlIndex: 3,
      }),
      hwpTextForPick: () => "",
      imeProxy: { focus: (...args: unknown[]) => calls.push({ name: "focus", args }) },
      beginImageDrag: (...args: unknown[]) => calls.push({ name: "beginImageDrag", args }),
    } as any
    const event = {
      button: 0,
      preventDefault: () => calls.push({ name: "preventDefault" }),
      stopPropagation: () => calls.push({ name: "stopPropagation" }),
    } as any

    editor.onCanvasMouseDown(event)

    assert.equal(editor.pickerEnabled(), false)
    assert.deepEqual(picker.pickedElements(), [])
    assert.ok(calls.some(call => call.name === "beginImageDrag"))
    assert.ok(calls.some(call => call.name === "focus"))
    assert.equal(calls.some(call => call.name === "stopPropagation"), false)
  })

  it("falls back from missing pickAtPoint to hitTest paragraph picks", () => {
    const editor = {
      ...WasmHwpEditor,
      doc: {
        getPageControlLayout: () => JSON.stringify({ controls: [] }),
        getParagraphLength: () => 6,
        getSelectionRects: () => JSON.stringify([
          { pageIndex: 2, x: 10, y: 20, width: 30, height: 40 },
        ]),
      },
    } as any

    const pick = editor.hwpPick(
      { sectionIndex: 1, paragraphIndex: 2, charOffset: 3, x: 111, y: 222 },
      2
    )

    assert.equal(pick.type, "paragraph")
    assert.deepEqual(pick.ref, { section: 1, paragraph: 2, offset: 3 })
    assert.deepEqual(pick.rects, [{ pageIndex: 2, x: 10, y: 20, width: 30, height: 40 }])
  })

  it("keeps native hitTest paragraph picks paintable when selection rects are empty", () => {
    const editor = {
      ...WasmHwpEditor,
      doc: {
        getPageControlLayout: () => JSON.stringify({ controls: [] }),
        getParagraphLength: () => 6,
        getSelectionRects: () => JSON.stringify([]),
      },
    } as any

    const pick = editor.hwpPick(
      { sectionIndex: 1, paragraphIndex: 2, charOffset: 3, x: 111, y: 222 },
      2
    )

    assert.equal(pick.type, "paragraph")
    assert.deepEqual(pick.ref, { section: 1, paragraph: 2, offset: 3 })
    assert.deepEqual(pick.rects, [{ pageIndex: 2, x: 87, y: 198, width: 48, height: 48, fallbackPoint: true }])
  })

  it("previews a hover box when the cursor moves in picker mode (no drag)", () => {
    const calls: string[] = []
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      pickerEnabled: () => true,
      imageDrag: null,
      dragSelect: null,
      pickerHover: null,
      queuePickerHover: () => calls.push("queuePickerHover"),
    } as any

    editor.onCanvasMouseMove({ buttons: 0 } as any)

    assert.deepEqual(calls, ["queuePickerHover"])
  })

  it("falls back from missing pickAtPoint to hitTest cell picks", () => {
    const editor = {
      ...WasmHwpEditor,
      doc: {
        getPageControlLayout: () => JSON.stringify({ controls: [] }),
        getTableCellBboxes: () => JSON.stringify([
          { cellIdx: 4, pageIndex: 3, x: 11, y: 22, w: 33, h: 44 },
        ]),
      },
    } as any

    const pick = editor.hwpPick(
      {
        sectionIndex: 1,
        paragraphIndex: 7,
        charOffset: 2,
        parentParaIndex: 5,
        controlIndex: 6,
        cellIndex: 4,
        cellParaIndex: 0,
        cellPath: [{ controlIndex: 6, cellIndex: 4, cellParaIndex: 0 }],
        x: 111,
        y: 222,
      },
      3
    )

    assert.equal(pick.type, "cell")
    assert.deepEqual(pick.ref, {
      section: 1,
      paragraph: 5,
      offset: 0,
      cell: {
        parentParaIndex: 5,
        controlIndex: 6,
        cellIndex: 4,
        cellParaIndex: 0,
        cellPath: [{ controlIndex: 6, cellIndex: 4, cellParaIndex: 0 }],
      },
    })
    assert.deepEqual(pick.rects, [{ pageIndex: 3, x: 11, y: 22, width: 33, height: 44 }])
  })

  it("does not add a null document-element pick when hit resolution fails", () => {
    picker.clearPicks()
    const calls: Array<{ name: string }> = []
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      pickerEnabled: () => true,
      sel: null,
      hitTestEvent: () => ({ hit: { sectionIndex: 0, paragraphIndex: 0, charOffset: 0, x: 1, y: 2 }, pageIndex: 0 }),
      hwpPickFromHit: () => null,
    } as any
    const event = {
      button: 0,
      preventDefault: () => calls.push({ name: "preventDefault" }),
      stopPropagation: () => calls.push({ name: "stopPropagation" }),
    } as any

    try {
      editor.onCanvasMouseDown(event)
      assert.deepEqual(picker.pickedElements(), [])
      assert.ok(calls.some(call => call.name === "preventDefault"))
      assert.ok(calls.some(call => call.name === "stopPropagation"))
    } finally {
      picker.clearPicks()
    }
  })

  it("uses local image selection for document adornments without exposing it to current chat picks", () => {
    picker.clearPicks()
    const editor = {
      ...WasmHwpEditor,
      canvasState: { documentPath: "/tmp/doc.hwp" },
      el: { dataset: {} },
      localImagePick: imagePick,
    } as any

    assert.deepEqual(editor.currentDocumentPicks(), [])
    assert.deepEqual(editor.documentAdornmentPicks(), [imagePick])
  })

  it("does not expose mirror preview image selections as current chat picks", () => {
    picker.clearPicks()
    const editor = {
      ...WasmHwpEditor,
      mirror: true,
      canvasState: { documentPath: "/tmp/doc.hwp", editorMirror: true },
      el: { dataset: {} },
      localImagePick: imagePick,
    } as any
    const documentAny = (globalThis as any).document
    const originalQuerySelectorAll = documentAny.querySelectorAll
    documentAny.querySelectorAll = (selector: string) =>
      selector === "[data-role='local-hwp-editor']"
        ? [{ dataset: { canvasState: JSON.stringify({ editorMirror: true }) }, __wasmHwpEditor: editor }]
        : []

    try {
      assert.deepEqual(editor.currentDocumentPicks(), [])
      assert.deepEqual(editor.agentSelectionPicks(), [])
      assert.deepEqual(picker.compactPicks(), [])
    } finally {
      documentAny.querySelectorAll = originalQuerySelectorAll
      picker.clearPicks()
    }
  })

  it("sends local image selection as an implicit agent pick", () => {
    picker.clearPicks()
    const editor = {
      ...WasmHwpEditor,
      canvasState: { documentPath: "/tmp/doc.hwp" },
      el: { dataset: {} },
      localImagePick: imagePick,
    } as any
    const documentAny = (globalThis as any).document
    const originalQuerySelectorAll = documentAny.querySelectorAll
    documentAny.querySelectorAll = (selector: string) =>
      selector === "[data-role='local-hwp-editor']"
        ? [{ dataset: { canvasState: "{}" }, __wasmHwpEditor: editor }]
        : []

    try {
      assert.deepEqual(editor.currentDocumentPicks(), [])

      const picks = picker.compactPicks()
      assert.equal(picks.length, 1)
      assert.equal(picks[0].document, "/tmp/doc.hwp")
      assert.equal(picks[0].type, "image")
      assert.equal(picks[0].ref, imagePick.ref)
      assert.equal(picks[0].text, "")
      assert.equal(
        picks[0].hint,
        "active HWP image selection; VFS nested target section=0; paragraph=2; picture-control order=3"
      )
    } finally {
      documentAny.querySelectorAll = originalQuerySelectorAll
      picker.clearPicks()
    }
  })

  it("deletes the selected picture with Backspace even when no text caret is active", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmHwpEditor,
      doc: {
        deletePictureControl: (...args: unknown[]) => calls.push({ name: "deletePictureControl", args }),
      },
      caret: null,
      localImagePick: imagePick,
      clearSelection: () => calls.push({ name: "clearSelection" }),
      clearSelectionOverlays: () => calls.push({ name: "clearSelectionOverlays" }),
      recordOp: (...args: unknown[]) => calls.push({ name: "recordOp", args }),
      finishAgentEdit: (...args: unknown[]) => calls.push({ name: "finishAgentEdit", args }),
      imeProxy: { value: "stale" },
    } as any
    const event = {
      key: "Backspace",
      isComposing: false,
      metaKey: false,
      ctrlKey: false,
      altKey: false,
      preventDefault: () => calls.push({ name: "preventDefault" }),
      stopPropagation: () => calls.push({ name: "stopPropagation" }),
    } as any

    editor.handleKeyDown(event)

    assert.deepEqual(
      calls.map(call => call.name),
      [
        "preventDefault",
        "stopPropagation",
        "deletePictureControl",
        "clearSelection",
        "clearSelectionOverlays",
        "recordOp",
        "finishAgentEdit",
      ]
    )
    assert.deepEqual(calls.find(call => call.name === "deletePictureControl")?.args, [0, 2, 3])
    assert.deepEqual(calls.find(call => call.name === "recordOp")?.args, [
      "PictureDeleted",
      { section: 0, paragraph: 2, control: 3 },
    ])
    assert.equal(editor.localImagePick, null)
    assert.equal(editor.imeProxy.value, "")
  })

  it("falls back to live picture layout hit-testing after geometry changes", () => {
    const editor = {
      ...WasmHwpEditor,
      doc: {
        pickAtPoint: () => JSON.stringify({
          type: "paragraph",
          ref: { section: 0, paragraph: 2, offset: 0 },
          rects: [],
        }),
        getPageControlLayout: () => JSON.stringify({
          controls: [{ secIdx: 0, paraIdx: 2, controlIdx: 3, x: 100, y: 120, w: 220, h: 160 }],
        }),
        getPictureProperties: () => JSON.stringify({ width: 22000, height: 16000 }),
      },
      collectElements: () => [
        { type: "picture", ref: { section: 0, paragraph: 2, control: 3, type: "picture" } },
      ],
    } as any

    const pick = editor.hwpPick({ x: 180, y: 150 }, 0)

    assert.equal(pick.type, "picture")
    assert.deepEqual(pick.ref, { section: 0, paragraph: 2, control: 3, type: "picture" })
    assert.deepEqual(pick.rects, [{ pageIndex: 0, x: 100, y: 120, width: 220, height: 160 }])
  })

  it("commits picture resizes with geometry-only properties and does not echo crop", () => {
    const calls: Array<{ name: string; args?: unknown[] }> = []
    const editor = {
      ...WasmHwpEditor,
      imageDrag: {
        mode: "resize",
        moved: true,
        section: 0,
        paraIdx: 2,
        controlIdx: 3,
        pageIndex: 0,
        x: 4,
        y: 5,
        curW: 44,
        curH: 33,
        props: {
          binDataId: "image-bin",
          width: 10,
          height: 20,
          cropLeft: 0,
          cropTop: 0,
          cropRight: 0,
          cropBottom: 0,
        },
      },
      doc: {
        pxToHwpUnit: (px: number) => px * 10,
        setPictureProperties: (...args: unknown[]) => calls.push({ name: "setPictureProperties", args }),
      },
      clearImageDragGhost: (...args: unknown[]) => calls.push({ name: "clearImageDragGhost", args }),
      renderPage: (...args: unknown[]) => calls.push({ name: "renderPage", args }),
      pictureGeometryProps: WasmHwpEditor.pictureGeometryProps,
      scheduleSnapshot: () => calls.push({ name: "scheduleSnapshot" }),
      paintPickedHighlights: () => calls.push({ name: "paintPickedHighlights" }),
    } as any

    editor.endImageDrag()

    const setCall = calls.find(call => call.name === "setPictureProperties")
    assert.ok(setCall)
    assert.deepEqual(JSON.parse(setCall.args?.[3] as string), {
      width: 440,
      height: 330,
    })
    assert.ok(calls.some(call => call.name === "scheduleSnapshot"))
    assert.equal(JSON.parse(editor.localImagePick.ref).control, 3)
  })
})
