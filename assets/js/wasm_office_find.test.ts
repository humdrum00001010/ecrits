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

;(globalThis as any).document = documentStub
;(globalThis as any).window = {}

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
})
