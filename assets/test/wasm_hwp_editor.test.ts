import { describe, it } from "node:test"
import assert from "node:assert/strict"

const documentStub: any = {
  body: { dataset: {} },
  addEventListener() {},
  removeEventListener() {},
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

const { WasmHwpEditor } = await import("../js/wasm_hwp_editor.ts")

describe("WasmHwpEditor scroll preservation", () => {
  it("restores a document scroll offset across hook remounts", () => {
    const win = (globalThis as any).window
    const oldRaf = win.requestAnimationFrame
    win.requestAnimationFrame = (fn: Function) => {
      fn()
      return 1
    }

    try {
      const first = Object.create(WasmHwpEditor)
      first.mirror = false
      first.documentId = "hwp-scroll-doc"
      first.loadedUrl = "/bytes/hwp-scroll-doc"
      first.el = {
        dataset: { documentPath: "drafts/service.hwpx", bytesUrl: "/bytes/hwp-scroll-doc" },
        scrollTop: 640,
        scrollLeft: 18,
      }

      first.rememberScrollPosition()

      let rendered = 0
      const second = Object.create(WasmHwpEditor)
      second.mirror = false
      second.documentId = "hwp-scroll-doc"
      second.loadedUrl = "/bytes/hwp-scroll-doc"
      second.el = {
        dataset: { documentPath: "drafts/service.hwpx", bytesUrl: "/bytes/hwp-scroll-doc" },
        isConnected: true,
        scrollTop: 0,
        scrollLeft: 0,
      }
      second.renderVisiblePages = () => {
        rendered += 1
      }

      second.restoreScrollPosition()

      assert.equal(second.el.scrollTop, 640)
      assert.equal(second.el.scrollLeft, 18)
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
      const editor = Object.create(WasmHwpEditor)
      editor.mirror = false
      editor.documentId = "hwp-server-scroll-doc"
      editor.loadedUrl = "/bytes/hwp-server-scroll-doc"
      editor.el = {
        dataset: {
          documentPath: "drafts/server-scroll.hwpx",
          bytesUrl: "/bytes/hwp-server-scroll-doc",
          scrollTop: "731",
          scrollLeft: "9",
        },
        isConnected: true,
        scrollTop: 0,
        scrollLeft: 0,
      }
      editor.renderVisiblePages = () => {
        rendered += 1
      }

      editor.restoreScrollPosition()

      assert.equal(editor.el.scrollTop, 731)
      assert.equal(editor.el.scrollLeft, 9)
      assert.equal(rendered, 1)
    } finally {
      if (oldRaf) win.requestAnimationFrame = oldRaf
      else delete win.requestAnimationFrame
    }
  })

  it("pushes document scroll with the document path", () => {
    const pushed: any[] = []
    const editor = Object.create(WasmHwpEditor)
    editor.mirror = false
    editor.documentId = "hwp-persist-scroll-doc"
    editor.loadedUrl = "/bytes/hwp-persist-scroll-doc"
    editor.el = {
      dataset: {
        documentPath: "drafts/persist-scroll.hwpx",
        bytesUrl: "/bytes/hwp-persist-scroll-doc",
      },
      scrollTop: 88,
      scrollLeft: 4,
    }
    editor.pushEvent = (event: string, payload: any) => pushed.push({ event, payload })

    editor.rememberScrollPosition()
    editor.flushScrollPosition()

    assert.deepEqual(pushed, [
      {
        event: "local_document.viewport_changed",
        payload: {
          document_path: "drafts/persist-scroll.hwpx",
          document_id: "hwp-persist-scroll-doc",
          top: 88,
          left: 4,
        },
      },
    ])
  })
})

describe("WasmHwpEditor IME composition preview", () => {
  function withElementFactory(fn: (created: any[]) => void) {
    const doc = (globalThis as any).document
    const oldCreateElement = doc.createElement
    const created: any[] = []
    doc.createElement = (_tag: string) => {
      const el = {
        dataset: {},
        style: {},
        hidden: false,
        textContent: "",
        isConnected: true,
        remove() {
          this.isConnected = false
        },
      }
      created.push(el)
      return el
    }
    try {
      fn(created)
    } finally {
      doc.createElement = oldCreateElement
    }
  }

  function baseEditor() {
    return {
      ...WasmHwpEditor,
      doc: {},
      scale: 1,
      caret: {
        section: 0,
        paragraph: 0,
        offset: 0,
        cell: null,
        note: null,
        cursorRect: { pageIndex: 0, x: 12, y: 20, height: 18 },
      },
      composing: { start: 0, length: 0 },
      imeProxy: {
        value: "",
        style: { left: "0px", top: "0px", height: "16px" },
        dataset: {},
      },
      el: {
        scrollLeft: 0,
        scrollTop: 0,
        appendChild(node: any) {
          node.parentNode = this
        },
        getBoundingClientRect() {
          return { left: 0, top: 0 }
        },
      },
      pageSection() {
        return {
          querySelector() {
            return {
              width: 800,
              getBoundingClientRect() {
                return { left: 0, top: 0, width: 800 }
              },
            }
          },
        }
      },
      refreshCursorRect() {},
      drawCaret() {},
      recordOp() {},
    } as any
  }

  it("shows composition text immediately and defers the WASM render sync", () => {
    withElementFactory((created) => {
      let queued = ""
      let rendered = 0
      const editor = {
        ...baseEditor(),
        imeProxy: {
          value: "ㅎ",
          style: { left: "0px", top: "0px", height: "16px" },
          dataset: {},
        },
        queueCompositionModelSync(text: string) {
          queued = text
        },
        renderCaretPage() {
          rendered += 1
        },
      } as any

      editor.handleCompositionUpdate({ data: "하" })

      assert.equal(queued, "하")
      assert.equal(rendered, 0)
      assert.equal(created.length, 1)
      assert.equal(created[0].hidden, false)
      assert.equal(created[0].textContent, "하")
      assert.equal(created[0].style.left, "12px")
      assert.equal(created[0].style.top, "20px")
    })
  })

  it("flushes the final composition into the document and hides the preview", () => {
    const inserted: any[] = []
    const deleted: any[] = []
    let rendered = 0
    let snapshots = 0
    const preview = {
      hidden: false,
      textContent: "ㅎ",
      style: {},
    }
    const editor = {
      ...baseEditor(),
      composing: { start: 0, length: 1 },
      pendingCompositionText: "ㅎ",
      compositionSyncQueued: true,
      compositionPreviewEl: preview,
      imeProxy: {
        value: "하",
        style: { left: "0px", top: "0px", height: "16px" },
        dataset: {},
      },
      doc: {
        deleteText(...args: any[]) {
          deleted.push(args)
        },
        insertText(...args: any[]) {
          inserted.push(args)
        },
      },
      renderCaretPage() {
        rendered += 1
      },
      anchorProxy() {},
      scheduleSnapshot() {
        snapshots += 1
      },
    } as any

    editor.handleCompositionEnd({ data: "하" })

    assert.deepEqual(deleted[0], [0, 0, 0, 1])
    assert.deepEqual(inserted[0], [0, 0, 0, "하"])
    assert.equal(editor.caret.offset, 1)
    assert.equal(editor.composing, null)
    assert.equal(editor.pendingCompositionText, null)
    assert.equal(editor.compositionSyncQueued, false)
    assert.equal(preview.hidden, true)
    assert.equal(preview.textContent, "")
    assert.equal(rendered, 1)
    assert.equal(snapshots, 1)
  })
})

describe("WasmHwpEditor preview patch safety", () => {
  it("does not patch preview text into the main editor or schedule a snapshot", () => {
    let inserted = ""
    let rendered = 0
    let highlighted = 0
    let scheduled = 0

    const editor = {
      ...WasmHwpEditor,
      mirror: false,
      previewPatchCursor: { section: 0, paragraph: 8, offset: 0 },
      _elementsCache: {},
      rendered: { clear() {} },
      el: { scrollTop: 420 },
      doc: {
        insertText(_section: number, _paragraph: number, _offset: number, text: string) {
          inserted += text
        },
        splitParagraph() {
          throw new Error("unexpected split")
        },
      },
      renderVisiblePages() {
        rendered += 1
      },
      renderPreviewPatchHighlight() {
        highlighted += 1
      },
      scrollPreviewPatchIntoView() {
        throw new Error("preview patch must not move the viewer viewport")
      },
      scheduleSnapshot() {
        scheduled += 1
      },
    } as any

    editor.patchPreviewSuffixIntoDoc("AGENT_TOKEN")

    assert.equal(inserted, "")
    assert.equal(editor.previewPatchCursor.offset, 0)
    assert.equal(editor.el.scrollTop, 420)
    assert.equal(rendered, 0)
    assert.equal(highlighted, 0)
    assert.equal(scheduled, 0)
  })

  it("patches preview text only inside mirror editors without scheduling a snapshot", () => {
    let inserted = ""
    let rendered = 0
    let highlighted = 0
    let scheduled = 0

    const editor = {
      ...WasmHwpEditor,
      mirror: true,
      previewPatchCursor: { section: 0, paragraph: 8, offset: 0 },
      _elementsCache: {},
      rendered: { clear() {} },
      el: { scrollTop: 420 },
      doc: {
        insertText(_section: number, _paragraph: number, _offset: number, text: string) {
          inserted += text
        },
        splitParagraph() {
          throw new Error("unexpected split")
        },
      },
      renderVisiblePages() {
        rendered += 1
      },
      renderPreviewPatchHighlight() {
        highlighted += 1
      },
      scrollPreviewPatchIntoView() {
        throw new Error("preview patch must not move the viewer viewport")
      },
      scheduleSnapshot() {
        scheduled += 1
      },
    } as any

    editor.patchPreviewSuffixIntoDoc("AGENT_TOKEN")

    assert.equal(inserted, "AGENT_TOKEN")
    assert.equal(editor.previewPatchCursor.offset, "AGENT_TOKEN".length)
    assert.equal(editor.el.scrollTop, 420)
    assert.equal(rendered, 1)
    assert.equal(highlighted, 1)
    assert.equal(scheduled, 0)
  })

  it("paints every saved VFS edit highlight without patching text into the mirror", () => {
    let inserted = ""
    const fills: any[] = []

    const editor = {
      ...WasmHwpEditor,
      mirror: true,
      previewPatchText: "",
      previewPatchCursor: null,
      previewPatchAnchor: null,
      previewSavedHighlight: null,
      rendered: new Map([[0, true], [2, true], [3, true]]),
      scale: 1,
      el: {
        scrollTop: 0,
        dataset: {
          previewHighlights: JSON.stringify([
            {
              kind: "text",
              op: "replace_text",
              ref: { section: 0, paragraph: 1, offset: 0 },
              text: "STAGE_PROOF_PARA_A"
            },
            {
              kind: "text",
              op: "set_cell",
              ref: {
                section: 0,
                paragraph: 2,
                offset: 0,
                cell: {
                  parentParaIndex: 2,
                  controlIndex: 0,
                  cellIndex: 3,
                  cellParaIndex: 0
                }
              },
              text: "STAGE_PROOF_CELL_A"
            }
          ])
        }
      },
      doc: {
        getParagraphLength() {
          return 4
        },
        getSelectionRects() {
          return JSON.stringify([{ pageIndex: 0, x: 1, y: 2, width: 3, height: 4 }])
        },
        getCellParagraphLength() {
          return 5
        },
        getSelectionRectsInCell() {
          return JSON.stringify([
            { pageIndex: 2, x: 10, y: 40, width: 12, height: 13 },
            { pageIndex: 3, x: 20, y: 21, width: 22, height: 23 }
          ])
        },
        insertText(_section: number, _paragraph: number, _offset: number, text: string) {
          inserted += text
        },
      },
      pageInfo() {
        return { w: 100, h: 100 }
      },
      pageSection(pageIndex: number) {
        return {
          offsetTop: pageIndex * 1000,
          getBoundingClientRect() {
            return { height: 100 }
          },
        }
      },
      pageOverlay(_pageIndex: number) {
        return {
          getContext() {
            return {
              fillStyle: "",
              fillRect(...args: any[]) {
                fills.push(args)
              },
            }
          },
        }
      },
    } as any

    editor.renderSavedEditHighlights()

    assert.equal(inserted, "")
    assert.equal(editor.el.dataset.previewHighlightMode, "saved-edit-regions")
    assert.equal(editor.el.dataset.previewHighlightCount, "3")
    assert.equal(editor.el.dataset.previewHighlightPages, "0,2,3")
    assert.equal(editor.el.dataset.previewFrameMode, "saved-cell")
    assert.equal(editor.el.dataset.previewFramePage, "2")
    assert.equal(editor.el.scrollTop, 2016)
    assert.equal(fills.length, 3)
  })

  it("fills insert_table cell payloads in the authoritative browser editor", () => {
    const inserted: any[] = []
    const cellProps: any[] = []
    const recorded: any[] = []

    const editor = {
      ...WasmHwpEditor,
      doc: {
        createTable(section: number, paragraph: number, offset: number, rows: number, cols: number) {
          assert.deepEqual([section, paragraph, offset, rows, cols], [0, 3, 4, 2, 2])
          return JSON.stringify({ ok: true, paraIdx: 9, controlIdx: 2 })
        },
        insertTextInCell(...args: any[]) {
          inserted.push(args)
        },
        splitParagraphInCell() {
          throw new Error("unexpected split")
        },
        setCellProperties(...args: any[]) {
          cellProps.push(args)
        },
      },
      recordOp(kind: string, payload: any) {
        recorded.push({ kind, payload })
      },
    } as any

    const result = editor.applyOneOp({
      op: "insert_table",
      ref: { section: 0, paragraph: 3, offset: 4 },
      rows: 2,
      cols: 2,
      cells: [["A1", "B1"], ["A2", "B2"]],
      header: true,
    })

    assert.deepEqual(result, {
      ok: true,
      extra: { rows: 2, cols: 2, cells_filled: 4, paraIdx: 9, controlIdx: 2 },
    })
    assert.deepEqual(
      inserted.map(args => args.slice(0, 7)),
      [
        [0, 9, 2, 0, 0, 0, "A1"],
        [0, 9, 2, 1, 0, 0, "B1"],
        [0, 9, 2, 2, 0, 0, "A2"],
        [0, 9, 2, 3, 0, 0, "B2"],
      ]
    )
    assert.equal(cellProps.length, 2)
    assert.equal(recorded[0].kind, "AgentInsertTable")
    assert.equal(recorded[0].payload.cellsFilled, 4)
  })

  it("sets picture geometry through the authoritative browser editor", () => {
    const pictureProps: any[] = []
    const recorded: any[] = []

    const editor = {
      ...WasmHwpEditor,
      doc: {
        setPictureProperties(...args: any[]) {
          pictureProps.push(args)
        },
      },
      recordOp(kind: string, payload: any) {
        recorded.push({ kind, payload })
      },
    } as any

    const result = editor.applySetOne(
      { section: 0, paragraph: 12, control: 4, type: "picture" },
      { kind: "picture", Width: 12_000, Height: 8_000, PosX: 1_500, PosY: 2_500 }
    )

    assert.deepEqual(result, { ok: true })
    assert.equal(pictureProps.length, 1)
    assert.deepEqual(pictureProps[0].slice(0, 3), [0, 12, 4])
    assert.deepEqual(JSON.parse(pictureProps[0][3]), {
      height: 8000,
      horzAlign: "Left",
      horzOffset: 1500,
      horzRelTo: "Paper",
      treatAsChar: false,
      vertAlign: "Top",
      vertOffset: 2500,
      vertRelTo: "Paper",
      width: 12000,
    })
    assert.equal(recorded[0].kind, "AgentSetPicture")
    assert.deepEqual(recorded[0].payload, {
      section: 0,
      para: 12,
      control: 4,
      cell: null,
      props: { Width: 12_000, Height: 8_000, PosX: 1_500, PosY: 2_500 },
    })
  })

  it("sets cell picture geometry with a JSON cell path for wasm", () => {
    const pictureProps: any[] = []
    const recorded: any[] = []

    const editor = {
      ...WasmHwpEditor,
      doc: {
        setCellPicturePropertiesByPath(...args: any[]) {
          pictureProps.push(args)
        },
      },
      recordOp(kind: string, payload: any) {
        recorded.push({ kind, payload })
      },
    } as any

    const cellPath = [{ controlIndex: 2, cellIndex: 5, cellParaIndex: 1 }]
    const result = editor.applySetOne(
      {
        section: 0,
        paragraph: 9,
        control: 4,
        type: "picture",
        cellPath,
        cell: { parentParaIndex: 9, controlIndex: 2, cellIndex: 5, cellParaIndex: 1, cellPath },
      },
      { kind: "picture", Width: 12_000, Height: 8_000 }
    )

    assert.deepEqual(result, { ok: true })
    assert.deepEqual(pictureProps[0].slice(0, 4), [
      0,
      9,
      JSON.stringify(cellPath),
      4,
    ])
    assert.deepEqual(JSON.parse(pictureProps[0][4]), {
      height: 8000,
      width: 12000,
    })
    assert.equal(recorded[0].kind, "AgentSetPicture")
    assert.deepEqual(recorded[0].payload.cell.cellPath, cellPath)
  })

  it("builds toolbar cell refs that parseRef resolves to the SAME cell paragraph", () => {
    const editor = { ...WasmHwpEditor } as any
    // A textbox selection cell (single-level path) whose cellPath still carries
    // the selection ANCHOR's paragraph (19) — the shape that used to poison
    // parseRef and made every toolbar format fail with 셀 문단을 찾을 수 없음.
    const selCell = {
      parentParaIndex: 5,
      controlIndex: 0,
      cellIndex: 0,
      cellParaIndex: 19,
      cellPath: [{ controlIndex: 0, cellIndex: 0, cellParaIndex: 19 }],
      isTextBox: true,
    }

    const ref = editor.hwpToolbarRef(0, 6, 0, selCell)
    const parsed = editor.parseRef(ref)

    assert.equal(parsed.cell.parentParaIndex, 5)
    assert.equal(parsed.cell.cellParaIndex, 6)
    assert.equal(parsed.cell.controlIndex, 0)
    // Single-level: no cellPath leaks through to override the flat address.
    assert.equal(ref.cellPath, undefined)
  })

  it("rebuilds nested cellPath refs per paragraph with the parent as ref.paragraph", () => {
    const editor = { ...WasmHwpEditor } as any
    const nestedCell = {
      parentParaIndex: 9,
      controlIndex: 1,
      cellIndex: 2,
      cellParaIndex: 7,
      cellPath: [
        { controlIndex: 1, cellIndex: 2, cellParaIndex: 0 },
        { controlIndex: 0, cellIndex: 3, cellParaIndex: 7 },
      ],
    }

    const ref = editor.hwpToolbarRef(0, 4, 0, nestedCell)
    const parsed = editor.parseRef(ref)

    assert.equal(ref.paragraph, 9) // parent body paragraph (parseRef grammar)
    assert.deepEqual(ref.cellPath[1], { controlIndex: 0, cellIndex: 3, cellParaIndex: 4 })
    assert.equal(parsed.cell.parentParaIndex, 9)
    assert.equal(parsed.cell.cellParaIndex, 4)
  })

  it("applies paragraph alignment through the para set kind", () => {
    const paraFormats: any[] = []
    const recorded: any[] = []

    const editor = {
      ...WasmHwpEditor,
      doc: {
        applyParaFormat(...args: any[]) {
          paraFormats.push(args)
          return "{}"
        },
      },
      recordOp(kind: string, payload: any) {
        recorded.push({ kind, payload })
      },
    } as any

    const result = editor.applySetOne(
      { section: 0, paragraph: 7, offset: 3 },
      { kind: "para", Alignment: "center" }
    )

    assert.deepEqual(result, { ok: true })
    assert.deepEqual(paraFormats[0].slice(0, 2), [0, 7])
    assert.deepEqual(JSON.parse(paraFormats[0][2]), { alignment: "center" })
    assert.equal(recorded[0].kind, "AgentSetPara")
  })

  it("routes cell-paragraph alignment to applyParaFormatInCell", () => {
    const paraFormats: any[] = []

    const editor = {
      ...WasmHwpEditor,
      doc: {
        applyParaFormatInCell(...args: any[]) {
          paraFormats.push(args)
          return "{}"
        },
      },
      recordOp() {},
    } as any

    const result = editor.applySetOne(
      {
        section: 0,
        paragraph: 2,
        offset: 0,
        cell: { parentParaIndex: 5, controlIndex: 1, cellIndex: 3, cellParaIndex: 2 },
      },
      { kind: "para", Alignment: "right", LineSpacing: 180 }
    )

    assert.deepEqual(result, { ok: true })
    assert.deepEqual(paraFormats[0].slice(0, 5), [0, 5, 1, 3, 2])
    assert.deepEqual(JSON.parse(paraFormats[0][5]), { alignment: "right", lineSpacing: 180 })
  })

  it("dispatches align toolbar commands over deduped selection paragraphs", () => {
    const sets: any[] = []
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      documentId: "doc-1",
      format: "hwp",
      el: { isConnected: true },
      hwpToolbarCharRefs: () => [
        { section: 0, paragraph: 4, offset: 0, length: 10 },
        { section: 0, paragraph: 4, offset: 12, length: 3 },
        { section: 0, paragraph: 5, offset: 0, length: 8 },
      ],
      applySetOne(ref: any, props: any) {
        sets.push({ ref, props })
        return { ok: true }
      },
      finishAgentEdit() {},
      scheduleToolbarStateSync() {},
    } as any

    editor.handleToolbarCommand({ command: "align-center", document_id: "doc-1" })

    assert.equal(sets.length, 2) // paragraph 4 deduped
    assert.deepEqual(sets.map(s => s.ref.paragraph), [4, 5])
    assert.deepEqual(sets[0].props, { kind: "para", Alignment: "center" })
  })

  it("routes font-size-set, text color, and highlight commands to char props", () => {
    const sets: any[] = []
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      documentId: "doc-1",
      format: "hwp",
      el: { isConnected: true },
      hwpToolbarCharRefs: () => [{ section: 0, paragraph: 2, offset: 0, length: 4 }],
      applySetOne(ref: any, props: any) {
        sets.push(props)
        return { ok: true }
      },
      finishAgentEdit() {},
      scheduleToolbarStateSync() {},
    } as any

    editor.handleToolbarCommand({ command: "font-size-set", size: 15, document_id: "doc-1" })
    editor.handleToolbarCommand({ command: "text-color", color: "#e11d48", document_id: "doc-1" })
    editor.handleToolbarCommand({ command: "highlight", color: "#fde047", document_id: "doc-1" })
    // Malformed payloads are dropped before reaching the engine.
    editor.handleToolbarCommand({ command: "font-size-set", size: 0, document_id: "doc-1" })
    editor.handleToolbarCommand({ command: "text-color", document_id: "doc-1" })

    assert.deepEqual(sets, [
      { kind: "char", FontSize: 15 },
      { kind: "char", TextColor: "#e11d48" },
      { kind: "char", shadeColor: "#fde047" },
    ])
  })

  it("syncs toolbar state even when rAF never fires (backgrounded tab)", async () => {
    const win = (globalThis as any).window
    const originalRaf = win.requestAnimationFrame
    win.requestAnimationFrame = () => 0 // background tab: callback never runs

    try {
      let emits = 0
      const editor = {
        ...WasmHwpEditor,
        mirror: false,
        emitToolbarState() { emits++ },
      } as any

      editor.scheduleToolbarStateSync()
      await new Promise(resolve => setTimeout(resolve, 200))
      assert.equal(emits, 1, "timeout twin fires when rAF is frozen")
      assert.equal(editor.toolbarStateSyncQueued, false, "queued flag resets")

      // The flag must not stick: a second sync still goes through.
      editor.scheduleToolbarStateSync()
      await new Promise(resolve => setTimeout(resolve, 200))
      assert.equal(emits, 2)
    } finally {
      win.requestAnimationFrame = originalRaf
    }
  })

  it("broadcasts the caret font size in points for the toolbar input", () => {
    const events: any[] = []
    const originalDispatch = (globalThis as any).document.dispatchEvent
    ;(globalThis as any).document.dispatchEvent = (event: any) => {
      events.push(event)
      return true
    }

    try {
      const editor = {
        ...WasmHwpEditor,
        documentId: "doc-3",
        caret: { section: 0, paragraph: 1, offset: 2, cell: null },
        doc: {
          getCharPropertiesAt: () => JSON.stringify({ bold: false, fontSize: 1150 }),
          getParaPropertiesAt: () => JSON.stringify({ alignment: "left" }),
        },
      } as any

      editor.emitToolbarState()
      assert.equal(events[0].detail.font_size_pt, 11.5)

      // No engine size → null, so the toolbar keeps its last display.
      events.length = 0
      editor.doc.getCharPropertiesAt = () => JSON.stringify({ bold: false })
      editor.emitToolbarState()
      assert.equal(events[0].detail.font_size_pt, null)
    } finally {
      ;(globalThis as any).document.dispatchEvent = originalDispatch
    }
  })

  it("broadcasts cell-caret paragraph alignment via getCellParaPropertiesAt", () => {
    const events: any[] = []
    const originalDispatch = (globalThis as any).document.dispatchEvent
    ;(globalThis as any).document.dispatchEvent = (event: any) => {
      events.push(event)
      return true
    }

    try {
      const cellParaCalls: any[] = []
      const editor = {
        ...WasmHwpEditor,
        documentId: "doc-2",
        caret: {
          section: 0,
          paragraph: 0,
          offset: 3,
          cell: { parentParaIndex: 0, controlIndex: 2, cellIndex: 0, cellParaIndex: 0 },
        },
        doc: {
          getCellCharPropertiesAt: () => JSON.stringify({ bold: true }),
          getCellParaPropertiesAt: (...args: any[]) => {
            cellParaCalls.push(args)
            return JSON.stringify({ alignment: "center" })
          },
        },
      } as any

      editor.emitToolbarState()

      assert.deepEqual(cellParaCalls[0], [0, 0, 2, 0, 0])
      assert.equal(events[0].detail.alignment, "center")
      assert.equal(events[0].detail.bold, true)
    } finally {
      ;(globalThis as any).document.dispatchEvent = originalDispatch
    }
  })

  it("broadcasts caret format state for the toolbar", () => {
    const events: any[] = []
    const originalDispatch = (globalThis as any).document.dispatchEvent
    ;(globalThis as any).document.dispatchEvent = (event: any) => {
      events.push(event)
      return true
    }

    try {
      const editor = {
        ...WasmHwpEditor,
        documentId: "doc-9",
        caret: { section: 0, paragraph: 3, offset: 5, cell: null },
        doc: {
          getCharPropertiesAt: () => JSON.stringify({ bold: true, underline: false }),
          getParaPropertiesAt: () => JSON.stringify({ alignment: "center" }),
        },
      } as any

      editor.emitToolbarState()

      assert.equal(events.length, 1)
      assert.equal(events[0].type, "ecrits:local-editor-state")
      assert.equal(events[0].detail.document_id, "doc-9")
      assert.equal(events[0].detail.bold, true)
      assert.equal(events[0].detail.underline, false)
      assert.equal(events[0].detail.alignment, "center")
    } finally {
      ;(globalThis as any).document.dispatchEvent = originalDispatch
    }
  })

  it("asks the open editor for authoritative bytes before rendering VFS highlights", () => {
    let requested: any = null

    const editor = {
      ...WasmHwpEditor,
      mirror: true,
      documentId: "doc-1",
      previewSavedHighlights: [],
      el: {
        dataset: {
          previewTurnId: "turn-1",
          previewText: "",
          previewDeltaCount: "9",
          previewHighlights: JSON.stringify([
            { op: "insert_table", ref: { section: 0, paragraph: 1, offset: 0 }, text: "A1" },
          ]),
        },
      },
      requestAuthoritativePreview(payload: any) {
        requested = payload
        return true
      },
      renderSavedEditHighlights() {
        throw new Error("mirror must not render saved-file highlights before asking authority")
      },
    } as any

    editor.updated()

    assert.equal(editor.el.dataset.previewAuthorityState, "waiting")
    assert.equal(requested.authority_bytes, true)
    assert.equal(requested.document_id, "doc-1")
    assert.equal(requested.turn_id, "turn-1")
    assert.equal(requested.preview_highlights.length, 1)
  })

  it("does not re-request authority after loading authoritative preview bytes", () => {
    let requested = 0
    let rendered = 0

    const editor = {
      ...WasmHwpEditor,
      mirror: true,
      previewSavedHighlights: [],
      el: {
        dataset: {
          previewHighlights: JSON.stringify([
            { op: "insert_table", ref: { section: 0, paragraph: 1, offset: 0 }, text: "A1" },
          ]),
        },
      },
      requestAuthoritativePreview() {
        requested += 1
        return true
      },
      renderSavedEditHighlights() {
        rendered += 1
      },
    } as any

    assert.equal(editor.handleLoadedPreviewHighlights(true, { document_id: "doc-1" }), true)
    assert.equal(requested, 0)
    assert.equal(rendered, 1)
  })

  it("restores saved VFS edit highlights when caret blink clears the overlay", () => {
    const calls: any[] = []

    const editor = {
      ...WasmHwpEditor,
      scale: 1,
      caretBlinkOn: false,
      caret: { cursorRect: { pageIndex: 0, x: 3, y: 4, height: 10 } },
      previewSavedHighlight: {
        rects: [{ pageIndex: 0, x: 10, y: 20, width: 30, height: 40 }],
      },
      pageSection() {
        return {
          querySelector() {
            return {
              width: 100,
              height: 100,
              getContext() {
                return {
                  fillStyle: "",
                  clearRect(...args: any[]) {
                    calls.push(["clear", ...args])
                  },
                  fillRect(...args: any[]) {
                    calls.push(["fill", ...args])
                  },
                }
              },
            }
          },
        }
      },
      pageOverlay() {
        return {
          getContext() {
            return {
              fillStyle: "",
              fillRect(...args: any[]) {
                calls.push(["saved", ...args])
              },
            }
          },
        }
      },
      paintPreviewPatchHighlightOnPage() {},
      paintAdornmentsOnPage() {},
    } as any

    editor.drawCaret(editor.caret)

    assert.deepEqual(calls[0], ["clear", 0, 0, 100, 100])
    assert.deepEqual(calls[1], ["saved", 10, 20, 30, 40])
    assert.equal(calls.some(([kind]) => kind === "fill"), false)
  })

  it("publishes authoritative preview bytes for mirror cards", () => {
    const oldUrl = (globalThis as any).URL
    const urls: string[] = []

    ;(globalThis as any).URL = {
      createObjectURL(blob: Blob) {
        assert.equal(blob.type, "application/vnd.hancom.hwpx")
        urls.push("blob:authority")
        return "blob:authority"
      },
      revokeObjectURL(url: string) {
        urls.push(`revoked:${url}`)
      },
    }

    try {
      const editor = {
        ...WasmHwpEditor,
        mirror: false,
        documentId: "doc-1",
        format: "hwpx",
        previewPatchCount: 0,
        previewPatchTurnId: "turn-1",
        previewPatchAnchor: null,
        previewPatchCursor: null,
        el: { id: "main-editor", dataset: { previewModelMatches: "true" } },
        doc: {},
        readPreviewModelText() {
          return "editor truth"
        },
        exportDocumentBytes() {
          return new Uint8Array([1, 2, 3])
        },
      } as any

      const state = editor.buildAuthoritativePreviewState({
        authority_bytes: true,
        document_id: "doc-1",
        turn_id: "turn-1",
      })

      assert.equal(state.bytes_url, "blob:authority")
      assert.equal(state.model_text, "editor truth")
      assert.equal(state.source_editor_id, "main-editor")
    } finally {
      ;(globalThis as any).URL = oldUrl
    }
  })
})

describe("WasmHwpEditor table cell-block selection", () => {
  // A 2x2 table: cellIndex 0..3 → (row,col) (0,0)(0,1)(1,0)(1,1), each a
  // 10x10 page-unit box laid out as a 20x20 grid on page 0.
  const ROWCOL: Record<number, { row: number; col: number }> = {
    0: { row: 0, col: 0 },
    1: { row: 0, col: 1 },
    2: { row: 1, col: 0 },
    3: { row: 1, col: 1 },
  }
  const BBOXES = [
    { cellIdx: 0, row: 0, col: 0, rowSpan: 1, colSpan: 1, pageIndex: 0, x: 0, y: 0, w: 10, h: 10 },
    { cellIdx: 1, row: 0, col: 1, rowSpan: 1, colSpan: 1, pageIndex: 0, x: 10, y: 0, w: 10, h: 10 },
    { cellIdx: 2, row: 1, col: 0, rowSpan: 1, colSpan: 1, pageIndex: 0, x: 0, y: 10, w: 10, h: 10 },
    { cellIdx: 3, row: 1, col: 1, rowSpan: 1, colSpan: 1, pageIndex: 0, x: 10, y: 10, w: 10, h: 10 },
  ]

  function makeEditor() {
    const painted: Array<{ x: number; y: number; w: number; h: number }> = []
    const ctx = {
      fillStyle: "",
      clearRect() {},
      fillRect(x: number, y: number, w: number, h: number) {
        painted.push({ x, y, w, h })
      },
    }
    const editor = {
      ...WasmHwpEditor,
      scale: 1,
      sel: { kind: "text", marker: "stale" }, // a stale text selection promotion must drop
      dragSelect: {
        section: 0,
        cell: { parentParaIndex: 5, controlIndex: 0, cellIndex: 0, cellPath: null },
      },
      doc: {
        getCellInfo(_s: number, _p: number, _c: number, cellIndex: number) {
          return JSON.stringify(ROWCOL[cellIndex])
        },
        getTableCellBboxes() {
          return JSON.stringify(BBOXES)
        },
      },
      // Bypass the DOM overlay plumbing; capture painted rects directly.
      clearSelectionOverlays() {},
      pageOverlay() {
        return { width: 20, height: 20, getContext: () => ctx }
      },
    } as any
    return { editor, painted }
  }

  function hit(cellIndex: number, extra: any = {}) {
    return {
      sectionIndex: 0,
      parentParaIndex: 5,
      controlIndex: 0,
      cellIndex,
      cellPath: null,
      ...extra,
    }
  }

  it("does not promote while the drag stays inside the anchor cell", () => {
    const { editor, painted } = makeEditor()
    assert.equal(editor.updateCellBlockFromHit(hit(0)), false)
    assert.equal(editor.cellSel(), null)
    assert.equal(painted.length, 0)
    assert.equal(editor.sel.marker, "stale") // text selection untouched
  })

  it("promotes to a cell-block when the drag crosses into another cell", () => {
    const { editor, painted } = makeEditor()
    const handled = editor.updateCellBlockFromHit(hit(3)) // (0,0) -> (1,1)
    assert.equal(handled, true)
    assert.ok(editor.cellSel())
    assert.deepEqual(editor.cellSel().anchor, { row: 0, col: 0 })
    assert.deepEqual(editor.cellSel().focus, { row: 1, col: 1 })
    assert.equal(editor.textSel(), null) // promotion supersedes text selection
    // Full 2x2 range → all four cells painted.
    assert.equal(painted.length, 4)
    assert.deepEqual((globalThis as any).window.__rhwpCellSelection.range, {
      startRow: 0,
      endRow: 1,
      startCol: 0,
      endCol: 1,
    })
  })

  it("extends (and shrinks) the focus on subsequent moves within the table", () => {
    const { editor, painted } = makeEditor()
    editor.updateCellBlockFromHit(hit(3)) // diagonal: 4 cells
    painted.length = 0
    const handled = editor.updateCellBlockFromHit(hit(1)) // back to the top row (0,1)
    assert.equal(handled, true)
    assert.deepEqual(editor.cellSel().focus, { row: 0, col: 1 })
    // Range is now just row 0 → two cells.
    assert.equal(painted.length, 2)
  })

  it("stays in block mode but keeps the last focus when the pointer leaves the table", () => {
    const { editor } = makeEditor()
    editor.updateCellBlockFromHit(hit(3))
    // A body hit (no cell context) must not break or reset the block.
    const handled = editor.updateCellBlockFromHit({ sectionIndex: 0, paragraphIndex: 9, charOffset: 2 })
    assert.equal(handled, true)
    assert.deepEqual(editor.cellSel().focus, { row: 1, col: 1 })
  })

  it("does not promote nested-table cell drags (out of scope)", () => {
    const { editor } = makeEditor()
    editor.dragSelect.cell.cellPath = [{ a: 1 }, { b: 2 }] // nested
    assert.equal(editor.updateCellBlockFromHit(hit(3, { cellPath: [{ a: 1 }, { b: 2 }] })), false)
    assert.equal(editor.cellSel(), null)
  })

  it("does not promote across a different table or section", () => {
    const { editor } = makeEditor()
    // Same section, different table control → not the anchor's table.
    assert.equal(editor.updateCellBlockFromHit(hit(3, { controlIndex: 1 })), false)
    assert.equal(editor.cellSel(), null)
  })
})

describe("WasmHwpEditor picker hover preview", () => {
  // A canvas 2d context that records what the picker paints.
  function recordingCtx() {
    const rects: Array<{ x: number; y: number; w: number; h: number; dashed: boolean }> = []
    let dash: number[] = []
    const ctx = {
      fillStyle: "",
      strokeStyle: "",
      lineWidth: 0,
      save() {},
      restore() {
        dash = []
      },
      setLineDash(pattern: number[]) {
        dash = pattern
      },
      fillRect(x: number, y: number, w: number, h: number) {
        rects.push({ x, y, w, h, dashed: dash.length > 0 })
      },
      strokeRect() {},
    }
    return { ctx, rects }
  }

  const pageEvent = {
    target: {
      closest: (sel: string) => (sel.includes("local-hwp-page") ? {} : null),
    },
  }

  it("routes a picker-mode mousemove to the hover probe, not selection", () => {
    let queued: any = "unset"
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      imageDrag: null,
      dragSelect: null,
      elementPickerEnabled: true,
      queuePickerHover(event: any) {
        queued = event
      },
    } as any

    editor.onCanvasMouseMove(pageEvent)
    assert.equal(queued, pageEvent)
  })

  it("leaves selection alone when the picker is off", () => {
    let queued = false
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      imageDrag: null,
      dragSelect: null,
      elementPickerEnabled: false,
      queuePickerHover() {
        queued = true
      },
    } as any

    editor.onCanvasMouseMove(pageEvent)
    assert.equal(queued, false)
  })

  it("resolves the element under the cursor into a hover preview", () => {
    let painted = 0
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      elementPickerEnabled: true,
      pickerHover: null,
      hitTestEvent: () => ({ hit: { sectionIndex: 0 }, pageIndex: 0 }),
      hwpPick: () => ({ type: "paragraph", ref: '{"section":0}', rects: [{ x: 1, y: 2, width: 3, height: 4 }] }),
      paintPickedHighlights() {
        painted += 1
      },
    } as any

    editor.updatePickerHover(pageEvent)
    assert.deepEqual(editor.pickerHover.rects, [{ x: 1, y: 2, width: 3, height: 4, pageIndex: 0 }])
    assert.equal(painted, 1) // setPickerHover repaints so the box actually shows
  })

  it("does not preview the synthetic point-square fallback (no false hover)", () => {
    // hwpPick returns a fabricated 48px point-square (fallbackPoint) when the
    // engine resolved no real rects — the hover must show nothing, not a box
    // floating off the element under the cursor.
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      elementPickerEnabled: true,
      pickerHover: null,
      hitTestEvent: () => ({ hit: { sectionIndex: 0 }, pageIndex: 0 }),
      hwpPick: () => ({
        type: "paragraph",
        ref: '{"section":0}',
        rects: [{ x: 100, y: 40, width: 48, height: 48, pageIndex: 0, fallbackPoint: true }],
      }),
      paintPickedHighlights() {},
    } as any

    editor.updatePickerHover(pageEvent)
    assert.equal(editor.pickerHover, null)
  })

  it("clears the hover preview when the cursor leaves every page", () => {
    let painted = 0
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      elementPickerEnabled: true,
      pickerHover: { key: "stale", rects: [{ x: 0, y: 0, width: 1, height: 1, pageIndex: 0 }] },
      paintPickedHighlights() {
        painted += 1
      },
    } as any

    editor.updatePickerHover({ target: { closest: () => null } })
    assert.equal(editor.pickerHover, null)
    assert.equal(painted, 1)
  })

  it("paints the hover box dashed (distinct from a solid committed pick)", () => {
    const { ctx, rects } = recordingCtx()
    const editor = {
      ...WasmHwpEditor,
      scale: 1,
      elementPickerEnabled: true,
      pickerHover: { key: "x", rects: [{ x: 5, y: 6, width: 7, height: 8, pageIndex: 0 }] },
      documentAdornmentPicks: () => [],
      pageOverlay: () => ({ getContext: () => ctx }),
    } as any

    editor.paintAdornmentsOnPage(0)
    // Gathered union box, framed with 2px padding (scale 1): x/y shift -2, w/h +4.
    assert.deepEqual(rects, [{ x: 3, y: 4, w: 11, h: 12, dashed: true }])
  })

  it("gathers multiple element rects into ONE hover box (union)", () => {
    const { ctx, rects } = recordingCtx()
    const editor = {
      ...WasmHwpEditor,
      scale: 1,
      elementPickerEnabled: true,
      // two line-rects of the same element -> a single gathered box
      pickerHover: { key: "x", rects: [
        { x: 10, y: 10, width: 100, height: 12, pageIndex: 0 },
        { x: 10, y: 24, width: 60, height: 12, pageIndex: 0 },
      ] },
      documentAdornmentPicks: () => [],
      pageOverlay: () => ({ getContext: () => ctx }),
    } as any

    editor.paintAdornmentsOnPage(0)
    // union bbox = x10..110, y10..36 -> with 2px pad: x8 y8 w104 h30
    assert.deepEqual(rects, [{ x: 8, y: 8, w: 104, h: 30, dashed: true }])
  })
})
