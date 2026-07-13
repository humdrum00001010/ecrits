import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { loadHwpColocatedHook } from "./support/hwp_colocated.ts"

const documentStub: any = {
  body: { dataset: {} },
  addEventListener() {},
  removeEventListener() {},
  dispatchEvent: () => true,
  querySelector: () => null,
  querySelectorAll: () => [],
}

;(globalThis as any).document = (globalThis as any).document || documentStub
;(globalThis as any).window = (globalThis as any).window || {}

const { WasmHwpEditor } = await loadHwpColocatedHook()

const ENGINE_HITS = [
  { sec: 0, para: 1, charOffset: 4, length: 5 },
  {
    sec: 0,
    para: 3,
    charOffset: 0,
    length: 5,
    cellContext: { parentPara: 3, ctrlIdx: 0, cellIdx: 2, cellPara: 1 },
  },
  { sec: 0, para: 6, charOffset: 10, length: 5 },
]

function engineResult(index: number, wrapped = false) {
  return JSON.stringify({
    found: true,
    total: ENGINE_HITS.length,
    index: index + 1,
    wrapped,
    hit: ENGINE_HITS[index],
  })
}

function findEditor(overrides: any = {}) {
  const selected: any[] = []
  const calls: any[] = []
  const editor = {
    ...WasmHwpEditor,
    mirror: false,
    documentId: "hwp-find-doc",
    format: "hwp",
    el: { isConnected: true, scrollTop: 0, clientHeight: 600 },
    caret: null,
    sel: null,
    hwpFind: null,
    doc: {
      find(query: string, optionsJson: string) {
        calls.push({ query, options: JSON.parse(optionsJson) })
        return engineResult(0)
      },
    },
    refreshCursorRect() {},
    hwpFindScrollIntoView() {},
    renderSelection() {},
    drawCaret() {},
    hasSelection: () => false,
    collapseSelection() {},
    ...overrides,
  } as any
  const realSelect = editor.hwpFindSelect
  editor.hwpFindSelect = function (match: any) {
    selected.push(match)
    return realSelect.call(this, match)
  }
  return { editor, selected, calls }
}

function captureFindStates(fn: () => void) {
  const states: any[] = []
  const doc = (globalThis as any).document
  const oldDispatch = doc.dispatchEvent
  doc.dispatchEvent = (event: any) => {
    if (event && event.type === "ecrits:document-search-result") states.push(event.detail)
    return true
  }
  try {
    fn()
  } finally {
    doc.dispatchEvent = oldDispatch
  }
  return states
}

describe("WasmHwpEditor engine-backed find", () => {
  it("delegates caret-relative ordering and counts to RHWP", () => {
    const calls: any[] = []
    const { editor, selected } = findEditor({
      doc: {
        find(query: string, optionsJson: string) {
          calls.push({ query, options: JSON.parse(optionsJson) })
          return engineResult(1)
        },
      },
    })
    editor.caret = { section: 0, paragraph: 2, offset: 7, cell: null }

    const states = captureFindStates(() => {
      editor.handleFindCommand({ action: "search", query: "query", document_id: "hwp-find-doc" })
    })

    assert.deepEqual(calls, [{
      query: "query",
      options: {
        direction: "forward",
        caseSensitive: false,
        includeCells: true,
        includeNotes: false,
        skipCurrent: false,
        anchor: { sec: 0, para: 2, charOffset: 7 },
      },
    }])
    assert.deepEqual(selected[0].cell, {
      parentParaIndex: 3,
      controlIndex: 0,
      cellIndex: 2,
      cellParaIndex: 1,
    })
    assert.deepEqual(states, [
      { document_id: "hwp-find-doc", query: "query", total: 3, index: 2 },
    ])
  })

  it("builds the native text selection over the engine-returned range", () => {
    const { editor } = findEditor()
    editor.caret = { section: 0, paragraph: 0, offset: 0, cell: null }

    captureFindStates(() => {
      editor.handleFindCommand({ action: "search", query: "query", document_id: "hwp-find-doc" })
    })

    assert.deepEqual(editor.sel, {
      kind: "text",
      section: 0,
      cell: null,
      anchor: { paragraph: 1, offset: 4 },
      focus: { paragraph: 1, offset: 9 },
    })
    assert.equal(editor.caret.paragraph, 1)
    assert.equal(editor.caret.offset, 9)
  })

  it("asks RHWP to step and wrap instead of walking a JS match list", () => {
    const calls: any[] = []
    const sequence = [0, 1, 2, 0, 2]
    const { editor } = findEditor({
      doc: {
        find(query: string, optionsJson: string) {
          const options = JSON.parse(optionsJson)
          const index = sequence[calls.length]
          calls.push({ query, options })
          return engineResult(index, calls.length === 4 || calls.length === 5)
        },
      },
    })
    editor.caret = { section: 0, paragraph: 0, offset: 0, cell: null }

    const states = captureFindStates(() => {
      editor.handleFindCommand({ action: "search", query: "query", document_id: "hwp-find-doc" })
      editor.handleFindCommand({ action: "next", query: "query", document_id: "hwp-find-doc" })
      editor.handleFindCommand({ action: "next", query: "query", document_id: "hwp-find-doc" })
      editor.handleFindCommand({ action: "next", query: "query", document_id: "hwp-find-doc" })
      editor.handleFindCommand({ action: "prev", query: "query", document_id: "hwp-find-doc" })
    })

    assert.deepEqual(states.map((state) => state.index), [1, 2, 3, 1, 3])
    assert.deepEqual(calls.map((call) => call.options.direction), [
      "forward", "forward", "forward", "forward", "backward",
    ])
    assert.deepEqual(calls.map((call) => call.options.skipCurrent), [false, true, true, true, true])
    assert.equal(calls[1].options.anchor.charOffset, ENGINE_HITS[0].charOffset)
  })

  it("uses the caret after an edit invalidates the current engine hit", () => {
    const calls: any[] = []
    const { editor } = findEditor({
      doc: {
        find(query: string, optionsJson: string) {
          calls.push(JSON.parse(optionsJson))
          return engineResult(calls.length === 1 ? 0 : 2)
        },
      },
    })
    editor.caret = { section: 0, paragraph: 0, offset: 0, cell: null }
    captureFindStates(() => {
      editor.handleFindCommand({ action: "search", query: "query", document_id: "hwp-find-doc" })
    })

    editor.hwpFind = null
    editor.caret = { section: 0, paragraph: 5, offset: 0, cell: null }
    const states = captureFindStates(() => {
      editor.handleFindCommand({ action: "next", query: "query", document_id: "hwp-find-doc" })
    })

    assert.equal(calls[1].skipCurrent, false)
    assert.deepEqual(calls[1].anchor, { sec: 0, para: 5, charOffset: 0 })
    assert.deepEqual(states, [
      { document_id: "hwp-find-doc", query: "query", total: 3, index: 3 },
    ])
  })

  it("reports no matches and clears an empty query", () => {
    const { editor } = findEditor({
      doc: { find: () => JSON.stringify({ found: false, total: 0, index: null }) },
    })

    const noMatch = captureFindStates(() => {
      editor.handleFindCommand({ action: "search", query: "zzz", document_id: "hwp-find-doc" })
    })
    assert.deepEqual(noMatch, [
      { document_id: "hwp-find-doc", query: "zzz", total: 0, index: null },
    ])

    const cleared = captureFindStates(() => {
      editor.handleFindCommand({ action: "search", query: "", document_id: "hwp-find-doc" })
    })
    assert.deepEqual(cleared, [
      { document_id: "hwp-find-doc", query: "", total: null, index: null },
    ])
    assert.equal(editor.hwpFind, null)
  })

  it("ignores find events for other documents, mirrors, and office formats", () => {
    const { editor, selected } = findEditor()
    editor.caret = { section: 0, paragraph: 0, offset: 0, cell: null }

    assert.deepEqual(captureFindStates(() => {
      editor.handleFindCommand({ action: "search", query: "query", document_id: "other-doc" })
    }), [])
    assert.equal(selected.length, 0)

    const { editor: mirror } = findEditor({ mirror: true })
    assert.deepEqual(captureFindStates(() => {
      mirror.handleFindCommand({ action: "search", query: "query", document_id: "hwp-find-doc" })
    }), [])

    const { editor: office } = findEditor({ format: "docx" })
    assert.deepEqual(captureFindStates(() => {
      office.handleFindCommand({ action: "search", query: "query", document_id: "hwp-find-doc" })
    }), [])
  })
})

describe("WasmHwpEditor.hwpFindScrollIntoView", () => {
  function scrollEditor(scrollTop: number) {
    return {
      ...WasmHwpEditor,
      el: { scrollTop, clientHeight: 500 },
      sel: {
        kind: "text",
        section: 0,
        cell: null,
        anchor: { paragraph: 1, offset: 4 },
        focus: { paragraph: 1, offset: 9 },
      },
      caret: null,
      doc: {
        getSelectionRects: () =>
          JSON.stringify([{ pageIndex: 2, x: 40, y: 300, width: 80, height: 16 }]),
      },
      pageInfo: () => ({ w: 700, h: 1000 }),
      pageSection: (index: number) => ({
        offsetTop: index * 1000,
        getBoundingClientRect: () => ({ height: 1000 }),
      }),
    } as any
  }

  it("scrolls an offscreen match into the top third of the viewport", () => {
    const editor = scrollEditor(0)
    editor.hwpFindScrollIntoView()
    assert.equal(editor.el.scrollTop, 2300 - 165)
  })

  it("keeps the viewport still when the match is already visible", () => {
    const editor = scrollEditor(2200)
    editor.hwpFindScrollIntoView()
    assert.equal(editor.el.scrollTop, 2200)
  })
})
