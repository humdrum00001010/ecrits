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

const { WasmHwpEditor } = await import("./wasm_hwp_editor.ts")

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
      props: { Width: 12_000, Height: 8_000, PosX: 1_500, PosY: 2_500 },
    })
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
