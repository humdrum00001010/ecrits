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

const { WasmOfficeEditor } = await import("./wasm_office_editor.js")

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
})
