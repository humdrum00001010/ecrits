// Meticulous unit tests for the HWP browser (WASM) arm's typed op vocabulary
// (`wasm_ops.ts`). Each handler is a pure `(ctx, op, ref, verb) => OpResult`, so
// we drive `OPS.registry[verb]` directly against a fully-mocked `ctx`/`ctx.doc`
// and assert the CONTRACT: input guards (the exact error strings the agent is
// taught to correct from), branch dispatch (body vs cell vs note vs table),
// the precise engine/primitive calls + arguments, `recordOp` provenance, the
// `extra` evidence echoed back, and the throw→error mapping.
//
// Pure logic, no wasm — runs on node's built-in runner with type stripping:
//   node --test 'js/**/*.test.ts'   (from assets/)

import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { OPS, type EditorContext, type Op, type ParsedRef } from "./wasm_ops.ts"

// ─── spy + mock harness ──────────────────────────────────────────────────────

type Spy = ((...a: any[]) => any) & { calls: any[][]; impl: (...a: any[]) => any }

/** A call-recording spy. Pass an impl to return a value or `throw`. */
function spy(impl: (...a: any[]) => any = () => undefined): Spy {
  const f: any = (...a: any[]) => f.impl(...a)
  f.calls = []
  f.impl = (...a: any[]) => {
    f.calls.push(a)
    return impl(...a)
  }
  return f as Spy
}
/** Force a spy to throw — for error-mapping paths. */
function thrower(message: string): Spy {
  return spy(() => {
    throw new Error(message)
  })
}
const argsOf = (s: Spy, i = 0) => s.calls[i]
const called = (s: Spy) => s.calls.length > 0

// Default `doc` (wasm HwpDocument) — every method a spy with a sane default so
// happy paths succeed; tests override the few they exercise.
function makeDoc(over: Record<string, any> = {}) {
  const doc: Record<string, Spy> = {
    // text / body
    getTextRange: spy(() => ""),
    deleteText: spy(),
    insertText: spy(),
    searchAllText: spy(() => "[]"),
    replaceAll: spy(() => "1"),
    splitParagraph: spy(),
    mergeParagraph: spy(),
    insertParagraph: spy(),
    deleteParagraph: spy(),
    // notes
    insertFootnote: spy(() => JSON.stringify({ controlIdx: 0, paraIdx: 7, footnoteNumber: 3 })),
    insertEndnote: spy(() => JSON.stringify({ controlIdx: 1, paraIdx: 7, endnoteNumber: 2 })),
    insertFootnoteInCell: spy(() => JSON.stringify({ controlIdx: 0, paraIdx: 7, footnoteNumber: 9 })),
    insertTextInFootnote: spy(),
    deleteTextInFootnote: spy(),
    // equation / shape / columns / picture
    insertEquation: spy(),
    createShapeControl: spy(() => JSON.stringify({ paraIdx: 4, controlIdx: 0 })),
    setShapeProperties: spy(),
    setColumnDef: spy(),
    insertPicture: spy(),
    insertPictureEx: spy(),
    insertPictureBase64: spy(),
    // tables
    createTable: spy(),
    createTableEx: spy(),
    getTableDimensions: spy(() => JSON.stringify({ rowCount: 3, colCount: 2 })),
    insertTableRow: spy(),
    deleteTableRow: spy(),
    insertTableColumn: spy(),
    deleteTableColumn: spy(),
    mergeTableCells: spy(),
    splitTableCellInto: spy(),
    // delete_node removers
    deleteTableControl: spy(),
    deletePictureControl: spy(),
    deleteShapeControl: spy(),
    deleteEquationControl: spy(),
    deleteFootnote: spy(),
  }
  Object.assign(doc, over)
  return doc
}

// Default `ctx` (the WasmHwpEditor surface). Wrapper methods are spies with
// defaults; `recordOp` records provenance for assertions.
function makeCtx(over: Record<string, any> = {}, docOver: Record<string, any> = {}): EditorContext & Record<string, Spy> {
  const doc = makeDoc(docOver)
  const ctx: Record<string, any> = {
    doc,
    recordOp: spy(),
    replacedCount: spy((raw: any) => Number(raw) || 0),
    resolveEndRef: spy(() => ({ section: 0, paragraph: 9, offset: 0 })),
    singleParagraphText: spy((v: any) => (v == null ? "" : String(v))),
    splitTextLines: spy((v: any) => String(v).split("\n")),
    paragraphLength: spy(() => 10),
    collectElements: spy(),
    cellParagraphCount: spy(() => 1),
    cellParagraphLength: spy(() => 5),
    cellPathForPara: spy(),
    cellPathJson: spy(() => ""),
    cellRowCol: spy(() => ({ row: 1, col: 1 })),
    rawControlIndex: spy(() => NaN),
    resolveTableTarget: spy((ref: any) =>
      ref && ref.cell ? { section: ref.section ?? 0, paragraph: 2, control: 0 } : null
    ),
    getTextInCellRef: spy(() => ""),
    deleteTextInCellRef: spy(),
    insertTextInCellRef: spy(),
    insertTextLinesInCell: spy(),
    splitParagraphInCellRef: spy(),
    mergeParagraphInCellRef: spy(),
    insertTextLines: spy(),
    insertTextLinesInFootnote: spy(),
    noteParagraphText: spy(() => ""),
    shapeStylePropsFromOp: spy(() => ({})),
    base64ToBytes: spy(() => new Uint8Array([1, 2, 3])),
  }
  Object.assign(ctx, over)
  ctx.doc = Object.assign(doc, docOver)
  return ctx as any
}

// Invoke a verb through the registry exactly as `applyOneOp` does.
function run(verb: string, op: Partial<Op>, ref: Partial<ParsedRef> | null, ctx: any) {
  const handler = OPS.registry[verb]
  assert.equal(typeof handler, "function", `no handler for ${verb}`)
  return handler(ctx, op as Op, ref as ParsedRef | null, verb)
}
const isErr = (r: any): r is { error: string } => r && typeof r.error === "string"
const isOk = (r: any): r is { ok: true; extra?: any } => r && r.ok === true
const png1x1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
const b64Bytes = (b64: string) => Uint8Array.from(Buffer.from(b64, "base64"))

// ─── registry shape ──────────────────────────────────────────────────────────

describe("OPS registry", () => {
  it("registers all 23 verbs as functions", () => {
    const verbs = [
      "replace_text", "insert_text", "delete_range", "set_cell", "insert_equation",
      "insert_footnote", "insert_endnote", "insert_shape", "set_columns",
      "insert_paragraph", "delete_paragraph", "split", "merge", "insert_table",
      "insert_table_row", "delete_table_row", "insert_table_column",
      "delete_table_column", "merge_cells", "split_cell", "delete_node", "insert_picture",
    ]
    for (const v of verbs) assert.equal(typeof OPS.registry[v], "function", v)
  })

  it("footnote and endnote share one handler; the 6 table verbs share one", () => {
    assert.equal(OPS.registry.insert_footnote, OPS.registry.insert_endnote)
    const t = OPS.registry.insert_table_row
    for (const v of ["delete_table_row", "insert_table_column", "delete_table_column", "merge_cells", "split_cell"]) {
      assert.equal(OPS.registry[v], t, v)
    }
  })

  it("define() chains and overwrites by verb", () => {
    const before = OPS.registry.replace_text
    const sentinel = () => ({ ok: true } as const)
    assert.equal(OPS.define("__probe__", sentinel), OPS) // returns the builder
    assert.equal(OPS.registry.__probe__, sentinel)
    delete (OPS.registry as any).__probe__
    assert.equal(OPS.registry.replace_text, before)
  })
})

// ─── replace_text ────────────────────────────────────────────────────────────

describe("replace_text", () => {
  it("rejects an empty query", () => {
    const r = run("replace_text", { query: "" }, null, makeCtx())
    assert.ok(isErr(r) && /non-empty query/.test(r.error))
  })

  it("rejects a missing replacement — never a silent delete", () => {
    const r = run("replace_text", { query: "x" }, null, makeCtx())
    assert.ok(isErr(r) && /'replacement'/.test(r.error) && /delete_range/.test(r.error))
  })

  it("treats replacement:'' (empty string) as valid, not missing", () => {
    const ctx = makeCtx({}, { searchAllText: spy(() => "[1]"), replaceAll: spy(() => "1") })
    const r = run("replace_text", { query: "x", replacement: "" }, null, ctx)
    assert.ok(isOk(r))
  })

  it("cell ref: reads the cell, deletes+inserts at the found offset", () => {
    const ctx = makeCtx({
      cellParagraphLength: spy(() => 11),
      getTextInCellRef: spy(() => "see [NAME] here"),
    })
    const ref = { section: 0, paragraph: 2, cell: { cellParaIndex: 0 } }
    const r = run("replace_text", { query: "[NAME]", replacement: "Kim" }, ref, ctx)
    assert.ok(isOk(r) && r.extra.replaced === 1)
    assert.deepEqual(argsOf(ctx.deleteTextInCellRef), [ref, ref.cell, 0, 4, 6]) // idx 4, len("[NAME]")=6
    assert.deepEqual(argsOf(ctx.insertTextInCellRef), [ref, ref.cell, 0, 4, "Kim"])
    assert.equal(argsOf(ctx.recordOp)[0], "AgentReplaceText")
  })

  it("cell ref: query not found → descriptive error, no mutation", () => {
    const ctx = makeCtx({ getTextInCellRef: spy(() => "nothing matches") })
    const ref = { section: 0, paragraph: 2, cell: { cellParaIndex: 0 } }
    const r = run("replace_text", { query: "ZZZ", replacement: "x" }, ref, ctx)
    assert.ok(isErr(r) && /not found in target cell/.test(r.error))
    assert.ok(!called(ctx.deleteTextInCellRef))
  })

  it("note ref: replaces inside the footnote body via the note primitives", () => {
    const ctx = makeCtx({ noteParagraphText: spy(() => "note says foo") })
    const ref = { section: 0, paragraph: 1, note: { controlIndex: 0, subParaIndex: 0 } }
    const r = run("replace_text", { query: "foo", replacement: "bar" }, ref, ctx)
    assert.ok(isOk(r) && r.extra.replaced === 1)
    assert.deepEqual(argsOf(ctx.doc.deleteTextInFootnote), [0, 1, 0, 0, 10, 3])
    assert.deepEqual(argsOf(ctx.doc.insertTextInFootnote), [0, 1, 0, 0, 10, "bar"])
  })

  it("body ref: scoped delete+insert at the in-paragraph offset", () => {
    const ctx = makeCtx({ paragraphLength: spy(() => 20) }, { getTextRange: spy(() => "the quick brown fox") })
    const ref = { section: 0, paragraph: 3 }
    const r = run("replace_text", { query: "quick", replacement: "slow" }, ref, ctx)
    assert.ok(isOk(r) && r.extra.replaced === 1)
    assert.deepEqual(argsOf(ctx.doc.deleteText), [0, 3, 4, 5])
    assert.deepEqual(argsOf(ctx.doc.insertText), [0, 3, 4, "slow"])
  })

  it("body ref miss → falls through to the global count-guarded path", () => {
    const ctx = makeCtx(
      {},
      { getTextRange: spy(() => "no match in body"), searchAllText: spy(() => "[1]"), replaceAll: spy(() => "1") }
    )
    const r = run("replace_text", { query: "elsewhere", replacement: "x" }, { section: 0, paragraph: 3 }, ctx)
    assert.ok(isOk(r))
    assert.ok(called(ctx.doc.searchAllText)) // proved it fell through, not errored
  })

  it("global: zero matches → 'no match' error", () => {
    const ctx = makeCtx({}, { searchAllText: spy(() => "[]") })
    const r = run("replace_text", { query: "ghost", replacement: "x" }, null, ctx)
    assert.ok(isErr(r) && /no match for query/.test(r.error))
    assert.ok(!called(ctx.doc.replaceAll))
  })

  it("global: >1 matches without all:true → guarded error (no rewrite)", () => {
    const ctx = makeCtx({}, { searchAllText: spy(() => "[1,2,3]") })
    const r = run("replace_text", { query: "the", replacement: "x" }, null, ctx)
    assert.ok(isErr(r) && /matches 3 places/.test(r.error))
    assert.ok(!called(ctx.doc.replaceAll))
  })

  it("global: >1 matches WITH all:true → replaceAll across the doc", () => {
    const ctx = makeCtx({}, { searchAllText: spy(() => "[1,2,3]"), replaceAll: spy(() => "3") })
    const r = run("replace_text", { query: "the", replacement: "x", all: true }, null, ctx)
    assert.ok(isOk(r) && r.extra.replaced === 3)
    assert.deepEqual(argsOf(ctx.doc.replaceAll), ["the", "x", true])
  })

  it("global: searchAllText accepts {matches:[...]} envelope too", () => {
    const ctx = makeCtx({}, { searchAllText: spy(() => JSON.stringify({ matches: [1] })), replaceAll: spy(() => "1") })
    const r = run("replace_text", { query: "z", replacement: "y" }, null, ctx)
    assert.ok(isOk(r))
  })

  it("maps an engine throw to a 'scoped replace failed' error", () => {
    const ctx = makeCtx({ paragraphLength: spy(() => 9) }, {
      getTextRange: spy(() => "has target"),
      deleteText: thrower("boom"),
    })
    const r = run("replace_text", { query: "target", replacement: "x" }, { section: 0, paragraph: 1 }, ctx)
    assert.ok(isErr(r) && /scoped replace failed: boom/.test(r.error))
  })
})

// ─── insert_text ─────────────────────────────────────────────────────────────

describe("insert_text", () => {
  it("requires a ref (or resolvable 'end')", () => {
    const ctx = makeCtx({ resolveEndRef: spy(() => null) })
    const r = run("insert_text", { text: "hi" }, null, ctx)
    assert.ok(isErr(r) && /requires a ref/.test(r.error))
  })

  it("rejects empty text", () => {
    const r = run("insert_text", { text: "" }, { section: 0, paragraph: 1 }, makeCtx())
    assert.ok(isErr(r) && /non-empty 'text'/.test(r.error))
  })

  it("ref 'end' resolves via resolveEndRef and appends", () => {
    const ctx = makeCtx({ resolveEndRef: spy(() => ({ section: 0, paragraph: 9, offset: 0 })) })
    const r = run("insert_text", { ref: "end", text: "tail" }, null, ctx)
    assert.ok(isOk(r) && r.extra.inserted === 4)
    assert.ok(called(ctx.insertTextLines))
  })

  it("note ref → insertTextLinesInFootnote", () => {
    const ctx = makeCtx()
    const ref = { section: 0, paragraph: 1, offset: 0, note: { controlIndex: 0, subParaIndex: 0 } }
    const r = run("insert_text", { text: "fn body" }, ref, ctx)
    assert.ok(isOk(r) && r.extra.inserted === 7)
    assert.equal(argsOf(ctx.insertTextLinesInFootnote)[1], ref.note)
  })

  it("cell ref → insertTextLinesInCell", () => {
    const ctx = makeCtx()
    const ref = { section: 0, paragraph: 2, offset: 0, cell: { cellParaIndex: 0 } }
    const r = run("insert_text", { text: "cell" }, ref, ctx)
    assert.ok(isOk(r))
    assert.equal(argsOf(ctx.insertTextLinesInCell)[1], ref.cell)
  })

  it("body ref → insertTextLines at the given offset", () => {
    const ctx = makeCtx()
    const r = run("insert_text", { text: "yo" }, { section: 0, paragraph: 3, offset: 5 }, ctx)
    assert.ok(isOk(r))
    assert.deepEqual(argsOf(ctx.insertTextLines)[1], 5)
  })

  it("maps a throw to 'insertText failed'", () => {
    const ctx = makeCtx({ insertTextLines: thrower("nope") })
    const r = run("insert_text", { text: "x" }, { section: 0, paragraph: 1, offset: 0 }, ctx)
    assert.ok(isErr(r) && /insertText failed: nope/.test(r.error))
  })
})

// ─── delete_range ────────────────────────────────────────────────────────────

describe("delete_range", () => {
  it("requires a ref", () => {
    assert.ok(isErr(run("delete_range", {}, null, makeCtx())))
  })

  it("omitted count → deletes the rest of the paragraph from offset", () => {
    const ctx = makeCtx({ paragraphLength: spy(() => 10) })
    const r = run("delete_range", {}, { section: 0, paragraph: 1, offset: 3 }, ctx)
    assert.ok(isOk(r) && r.extra.deleted === 7)
    assert.deepEqual(argsOf(ctx.doc.deleteText), [0, 1, 3, 7])
  })

  it("count <= 0 → 'nothing to delete'", () => {
    const ctx = makeCtx({ paragraphLength: spy(() => 3) })
    const r = run("delete_range", {}, { section: 0, paragraph: 1, offset: 3 }, ctx)
    assert.ok(isErr(r) && /nothing to delete/.test(r.error))
  })

  it("cell ref → deleteTextInCellRef", () => {
    const ctx = makeCtx({ cellParagraphLength: spy(() => 8) })
    const ref = { section: 0, paragraph: 2, offset: 0, cell: { cellParaIndex: 0 } }
    const r = run("delete_range", { count: 4 }, ref, ctx)
    assert.ok(isOk(r) && r.extra.deleted === 4)
    assert.deepEqual(argsOf(ctx.deleteTextInCellRef), [ref, ref.cell, 0, 0, 4])
  })

  it("note ref → deleteTextInFootnote", () => {
    const ctx = makeCtx()
    const ref = { section: 0, paragraph: 1, offset: 2, note: { controlIndex: 0, subParaIndex: 0 } }
    const r = run("delete_range", { count: 3 }, ref, ctx)
    assert.ok(isOk(r))
    assert.deepEqual(argsOf(ctx.doc.deleteTextInFootnote), [0, 1, 0, 0, 2, 3])
  })
})

// ─── set_cell ────────────────────────────────────────────────────────────────

describe("set_cell", () => {
  it("requires a CELL ref", () => {
    const r = run("set_cell", { text: "x" }, { section: 0, paragraph: 1 }, makeCtx())
    assert.ok(isErr(r) && /requires a CELL ref/.test(r.error))
  })

  it("single line: clears cellPara 0 then inserts the line", () => {
    const ctx = makeCtx({ cellParagraphCount: spy(() => 1), cellParagraphLength: spy(() => 4) })
    const ref = { section: 0, paragraph: 2, cell: { cellParaIndex: 0 } }
    const r = run("set_cell", { text: "Total" }, ref, ctx)
    assert.ok(isOk(r) && r.extra.cellParaCount === 1)
    assert.deepEqual(argsOf(ctx.deleteTextInCellRef), [ref, ref.cell, 0, 0, 4])
    assert.deepEqual(argsOf(ctx.insertTextInCellRef), [ref, ref.cell, 0, 0, "Total"])
    assert.ok(!called(ctx.splitParagraphInCellRef))
  })

  it("multi-line: splits the cell paragraph per extra line", () => {
    const ctx = makeCtx({ cellParagraphCount: spy(() => 1), cellParagraphLength: spy(() => 0) })
    const ref = { section: 0, paragraph: 2, cell: { cellParaIndex: 0 } }
    const r = run("set_cell", { text: "a\nb\nc" }, ref, ctx)
    assert.ok(isOk(r) && r.extra.cellParaCount === 3)
    assert.equal(ctx.splitParagraphInCellRef.calls.length, 2) // 3 lines → 2 splits
  })

  it("does NOT call finishAgentEdit — returns {ok,extra} for the caller", () => {
    const ctx = makeCtx({ cellParagraphCount: spy(() => 1), cellParagraphLength: spy(() => 0) })
    ;(ctx as any).finishAgentEdit = spy()
    const ref = { section: 0, paragraph: 2, cell: { cellParaIndex: 0 } }
    run("set_cell", { text: "x" }, ref, ctx)
    assert.ok(!called((ctx as any).finishAgentEdit))
  })
})

// ─── insert_equation ─────────────────────────────────────────────────────────

describe("insert_equation", () => {
  it("requires a ref and a non-empty script", () => {
    assert.ok(isErr(run("insert_equation", { script: "x^2" }, null, makeCtx())))
    assert.ok(isErr(run("insert_equation", { script: "" }, { section: 0, paragraph: 1 }, makeCtx())))
  })

  it("defaults font_size=1000 and color=0", () => {
    const ctx = makeCtx()
    const r = run("insert_equation", { script: "x^2" }, { section: 0, paragraph: 1, offset: 2 }, ctx)
    assert.ok(isOk(r) && r.extra.script === "x^2")
    assert.deepEqual(argsOf(ctx.doc.insertEquation), [0, 1, 2, "x^2", 1000, 0])
  })

  it("passes explicit font_size/color through", () => {
    const ctx = makeCtx()
    run("insert_equation", { script: "a", font_size: 1400, color: 255 }, { section: 0, paragraph: 1, offset: 0 }, ctx)
    assert.deepEqual(argsOf(ctx.doc.insertEquation), [0, 1, 0, "a", 1400, 255])
  })
})

// ─── insert_footnote / insert_endnote ────────────────────────────────────────

describe("insert_footnote / insert_endnote", () => {
  it("requires a ref (error names the verb)", () => {
    const r = run("insert_endnote", {}, null, makeCtx())
    assert.ok(isErr(r) && /insert_endnote requires a ref/.test(r.error))
  })

  it("footnote: creates the anchor then inserts text at char offset 2, echoes evidence", () => {
    const ctx = makeCtx()
    const r = run("insert_footnote", { text: "src" }, { section: 0, paragraph: 1, offset: 4 }, ctx)
    assert.ok(isOk(r))
    assert.deepEqual(argsOf(ctx.doc.insertFootnote), [0, 1, 4])
    assert.deepEqual(argsOf(ctx.doc.insertTextInFootnote), [0, 7, 0, 0, 2, "src"]) // paraIdx 7 from engine reply
    assert.deepEqual(r.extra, { text: "src", number: 3, paraIdx: 7, controlIdx: 0 })
    assert.equal(argsOf(ctx.recordOp)[0], "AgentInsertFootnote")
  })

  it("endnote: routes to insertEndnote and records AgentInsertEndnote", () => {
    const ctx = makeCtx()
    const r = run("insert_endnote", { text: "e" }, { section: 0, paragraph: 1, offset: 0 }, ctx)
    assert.ok(isOk(r) && r.extra.number === 2)
    assert.ok(called(ctx.doc.insertEndnote) && !called(ctx.doc.insertFootnote))
    assert.equal(argsOf(ctx.recordOp)[0], "AgentInsertEndnote")
  })

  it("footnote in a cell → one-shot insertFootnoteInCell (text included)", () => {
    const ctx = makeCtx()
    const ref = {
      section: 0, paragraph: 1, offset: 0,
      cell: { parentParaIndex: 5, controlIndex: 0, cellIndex: 3, cellParaIndex: 0 },
    }
    const r = run("insert_footnote", { text: "c" }, ref, ctx)
    assert.ok(isOk(r))
    assert.ok(called(ctx.doc.insertFootnoteInCell))
    assert.ok(!called(ctx.doc.insertFootnote)) // didn't fall to the body path
  })

  it("text present but engine omits controlIdx → explicit 'text NOT inserted' error", () => {
    const ctx = makeCtx({}, { insertFootnote: spy(() => JSON.stringify({ footnoteNumber: 1 })) })
    const r = run("insert_footnote", { text: "x" }, { section: 0, paragraph: 1, offset: 0 }, ctx)
    assert.ok(isErr(r) && /did not report controlIdx/.test(r.error))
  })

  it("no text → anchor only, no insertTextInFootnote", () => {
    const ctx = makeCtx()
    const r = run("insert_footnote", {}, { section: 0, paragraph: 1, offset: 0 }, ctx)
    assert.ok(isOk(r))
    assert.ok(!called(ctx.doc.insertTextInFootnote))
  })
})

// ─── insert_shape ────────────────────────────────────────────────────────────

describe("insert_shape", () => {
  it("requires a ref and integer width+height", () => {
    assert.ok(isErr(run("insert_shape", { width: 100, height: 100 }, null, makeCtx())))
    assert.ok(isErr(run("insert_shape", { width: 100 }, { section: 0, paragraph: 1 }, makeCtx())))
  })

  it("builds the shape JSON (defaults to rectangle, treatAsChar) and creates it", () => {
    const ctx = makeCtx()
    const r = run("insert_shape", { width: 8504, height: 4252 }, { section: 0, paragraph: 1, offset: 0 }, ctx)
    assert.ok(isOk(r) && r.extra.shapeType === "rectangle")
    const json = JSON.parse(argsOf(ctx.doc.createShapeControl)[0])
    assert.equal(json.width, 8504)
    assert.equal(json.height, 4252)
    assert.equal(json.shapeType, "rectangle")
    assert.equal(json.treatAsChar, true)
  })

  it("applies styleProps via setShapeProperties when present", () => {
    const ctx = makeCtx({ shapeStylePropsFromOp: spy(() => ({ fillColor: 255 })) })
    run("insert_shape", { width: 10, height: 10, shape_type: "ellipse" }, { section: 0, paragraph: 1, offset: 0 }, ctx)
    assert.ok(called(ctx.doc.setShapeProperties))
    assert.deepEqual(argsOf(ctx.doc.setShapeProperties), [0, 4, 0, JSON.stringify({ fillColor: 255 })])
  })

  it("skips setShapeProperties when there are no style props", () => {
    const ctx = makeCtx({ shapeStylePropsFromOp: spy(() => ({})) })
    run("insert_shape", { width: 10, height: 10 }, { section: 0, paragraph: 1, offset: 0 }, ctx)
    assert.ok(!called(ctx.doc.setShapeProperties))
  })
})

// ─── set_columns ─────────────────────────────────────────────────────────────

describe("set_columns", () => {
  it("requires integer count > 0", () => {
    assert.ok(isErr(run("set_columns", {}, { section: 0 }, makeCtx())))
    assert.ok(isErr(run("set_columns", { count: 0 }, { section: 0 }, makeCtx())))
  })

  it("defaults type=0, sameWidth=1, spacing=0; section from the ref", () => {
    const ctx = makeCtx()
    const r = run("set_columns", { count: 2 }, { section: 1 }, ctx)
    assert.ok(isOk(r) && r.extra.count === 2)
    assert.deepEqual(argsOf(ctx.doc.setColumnDef), [1, 2, 0, 1, 0])
  })

  it("same_width:false maps to 0", () => {
    const ctx = makeCtx()
    run("set_columns", { count: 3, same_width: false, spacing: 850, column_type: 2 }, { section: 0 }, ctx)
    assert.deepEqual(argsOf(ctx.doc.setColumnDef), [0, 3, 2, 0, 850])
  })
})

// ─── insert_paragraph ────────────────────────────────────────────────────────

describe("insert_paragraph", () => {
  it("requires a ref or 'end'", () => {
    const ctx = makeCtx({ resolveEndRef: spy(() => null) })
    assert.ok(isErr(run("insert_paragraph", {}, null, ctx)))
  })

  it("append (end): insertParagraph at appendIndex, then text", () => {
    const ctx = makeCtx({ resolveEndRef: spy(() => ({ section: 0, appendIndex: 12 })) })
    const r = run("insert_paragraph", { ref: "end", text: "new" }, null, ctx)
    assert.ok(isOk(r) && r.extra.paragraph === 12 && r.extra.inserted === 3)
    assert.deepEqual(argsOf(ctx.doc.insertParagraph), [0, 12])
    assert.ok(called(ctx.insertTextLines))
  })

  it("explicit ref + text: SPLIT path (text+\\n), NOT insertParagraph (keeps ColumnDef in para 0)", () => {
    const ctx = makeCtx()
    const r = run("insert_paragraph", { text: "Title" }, { section: 0, paragraph: 0 }, ctx)
    assert.ok(isOk(r))
    assert.deepEqual(argsOf(ctx.insertTextLines), [{ section: 0, paragraph: 0 }, 0, "Title\n"])
    assert.ok(!called(ctx.doc.insertParagraph))
  })

  it("explicit ref, no text: plain insertParagraph", () => {
    const ctx = makeCtx()
    run("insert_paragraph", {}, { section: 0, paragraph: 3 }, ctx)
    assert.deepEqual(argsOf(ctx.doc.insertParagraph), [0, 3])
  })
})

// ─── delete_paragraph / split / merge ────────────────────────────────────────

describe("delete_paragraph", () => {
  it("requires a ref; else deletes the paragraph", () => {
    assert.ok(isErr(run("delete_paragraph", {}, null, makeCtx())))
    const ctx = makeCtx()
    assert.ok(isOk(run("delete_paragraph", {}, { section: 0, paragraph: 4 }, ctx)))
    assert.deepEqual(argsOf(ctx.doc.deleteParagraph), [0, 4])
  })
})

describe("split", () => {
  it("requires a ref", () => assert.ok(isErr(run("split", {}, null, makeCtx()))))

  it("body: splitParagraph at the ref offset", () => {
    const ctx = makeCtx()
    run("split", {}, { section: 0, paragraph: 1, offset: 83 }, ctx)
    assert.deepEqual(argsOf(ctx.doc.splitParagraph), [0, 1, 83])
  })

  it("cell: routes to splitParagraphInCellRef", () => {
    const ctx = makeCtx()
    const ref = { section: 0, paragraph: 2, offset: 4, cell: { cellParaIndex: 0 } }
    run("split", {}, ref, ctx)
    assert.ok(called(ctx.splitParagraphInCellRef) && !called(ctx.doc.splitParagraph))
  })
})

describe("merge", () => {
  it("body: mergeParagraph; cell: mergeParagraphInCellRef", () => {
    const b = makeCtx()
    run("merge", {}, { section: 0, paragraph: 5 }, b)
    assert.deepEqual(argsOf(b.doc.mergeParagraph), [0, 5])

    const c = makeCtx()
    run("merge", {}, { section: 0, paragraph: 2, cell: { cellParaIndex: 1 } }, c)
    assert.ok(called(c.mergeParagraphInCellRef) && !called(c.doc.mergeParagraph))
  })
})

// ─── insert_table ────────────────────────────────────────────────────────────

describe("insert_table", () => {
  it("requires ref and rows>0, cols>0", () => {
    assert.ok(isErr(run("insert_table", { rows: 2, cols: 2 }, null, makeCtx())))
    assert.ok(isErr(run("insert_table", { rows: 0, cols: 2 }, { section: 0, paragraph: 1 }, makeCtx())))
  })

  it("plain R×C → createTable", () => {
    const ctx = makeCtx()
    const r = run("insert_table", { rows: 3, cols: 2 }, { section: 0, paragraph: 1, offset: 0 }, ctx)
    assert.ok(isOk(r) && r.extra.rows === 3 && r.extra.cols === 2)
    assert.deepEqual(argsOf(ctx.doc.createTable), [0, 1, 0, 3, 2])
    assert.ok(!called(ctx.doc.createTableEx))
  })

  it("treat_as_char → createTableEx with options JSON", () => {
    const ctx = makeCtx()
    run("insert_table", { rows: 2, cols: 2, treat_as_char: true }, { section: 0, paragraph: 1, offset: 0 }, ctx)
    const opts = JSON.parse(argsOf(ctx.doc.createTableEx)[0])
    assert.equal(opts.treatAsChar, true)
    assert.equal(opts.rowCount, 2)
  })

  it("col_widths → createTableEx carrying colWidths", () => {
    const ctx = makeCtx()
    run("insert_table", { rows: 1, cols: 2, col_widths: [4000, 6000] }, { section: 0, paragraph: 1, offset: 0 }, ctx)
    const opts = JSON.parse(argsOf(ctx.doc.createTableEx)[0])
    assert.deepEqual(opts.colWidths, [4000, 6000])
  })
})

// ─── table structure ops ─────────────────────────────────────────────────────

describe("table structure ops", () => {
  const cellRef = { section: 0, paragraph: 2, cell: { parentParaIndex: 2, controlIndex: 0 } }

  it("require a table cell ref", () => {
    const ctx = makeCtx({ resolveTableTarget: spy(() => null) })
    const r = run("insert_table_row", {}, { section: 0, paragraph: 1 }, ctx)
    assert.ok(isErr(r) && /requires a table CELL ref/.test(r.error))
  })

  it("insert_table_row: count loops the primitive and echoes rows_after", () => {
    const ctx = makeCtx({}, { getTableDimensions: spy(() => JSON.stringify({ rowCount: 13, colCount: 2 })) })
    const r = run("insert_table_row", { row: 0, below: true, count: 10 }, cellRef, ctx)
    assert.ok(isOk(r))
    assert.equal(ctx.doc.insertTableRow.calls.length, 10)
    assert.equal(r.extra.inserted, 10)
    assert.equal(r.extra.rows_after, 13) // post-op evidence
  })

  it("insert_table_row: caps count at 200", () => {
    const ctx = makeCtx()
    run("insert_table_row", { row: 0, count: 9999 }, cellRef, ctx)
    assert.equal(ctx.doc.insertTableRow.calls.length, 200)
  })

  it("insert_table_row: row derived from the picked cell when omitted", () => {
    const ctx = makeCtx({ cellRowCol: spy(() => ({ row: 4, col: 1 })) })
    run("insert_table_row", {}, cellRef, ctx)
    assert.equal(argsOf(ctx.doc.insertTableRow)[3], 4) // row arg
  })

  it("insert_table_column: caps count at 64", () => {
    const ctx = makeCtx()
    run("insert_table_column", { col: 0, count: 1000 }, cellRef, ctx)
    assert.equal(ctx.doc.insertTableColumn.calls.length, 64)
  })

  it("delete_table_row / delete_table_column delegate once", () => {
    const ctx = makeCtx()
    run("delete_table_row", { row: 1 }, cellRef, ctx)
    assert.deepEqual(argsOf(ctx.doc.deleteTableRow), [0, 2, 0, 1])
    run("delete_table_column", { col: 0 }, cellRef, ctx)
    assert.deepEqual(argsOf(ctx.doc.deleteTableColumn), [0, 2, 0, 0])
  })

  it("merge_cells: requires all four bounds", () => {
    const ctx = makeCtx()
    const bad = run("merge_cells", { start_row: 0, start_col: 0, end_row: 1 }, cellRef, ctx)
    assert.ok(isErr(bad) && /start_row\/start_col\/end_row\/end_col/.test(bad.error))
    const ok = run("merge_cells", { start_row: 0, start_col: 0, end_row: 1, end_col: 1 }, cellRef, ctx)
    assert.ok(isOk(ok))
    assert.deepEqual(argsOf(ctx.doc.mergeTableCells), [0, 2, 0, 0, 0, 1, 1])
  })

  it("split_cell: rejects a 1×1 no-op, accepts a real sub-grid", () => {
    const ctx = makeCtx()
    assert.ok(isErr(run("split_cell", { row: 0, col: 0, rows: 1, cols: 1 }, cellRef, ctx)))
    const r = run("split_cell", { row: 0, col: 0, rows: 2, cols: 1 }, cellRef, ctx)
    assert.ok(isOk(r))
    assert.deepEqual(argsOf(ctx.doc.splitTableCellInto), [0, 2, 0, 0, 0, 2, 1, true, false])
  })

  it("maps a primitive throw to a per-verb '<verb> failed' error", () => {
    const ctx = makeCtx({}, { insertTableRow: thrower("kaboom") })
    const r = run("insert_table_row", { row: 0, count: 1 }, cellRef, ctx)
    assert.ok(isErr(r) && /insert_table_row failed: kaboom/.test(r.error))
  })
})

// ─── delete_node ─────────────────────────────────────────────────────────────

describe("delete_node", () => {
  it("table cell ref → deletes the whole table (first remover wins)", () => {
    const ctx = makeCtx()
    const r = run("delete_node", {}, { section: 0, paragraph: 2, cell: { parentParaIndex: 2, controlIndex: 0 } }, ctx)
    assert.ok(isOk(r) && r.extra.removed === "table")
    assert.ok(called(ctx.doc.deleteTableControl))
    assert.ok(!called(ctx.doc.deletePictureControl)) // stopped after first success
  })

  it("raw control ref: falls through removers until one succeeds (picture)", () => {
    const ctx = makeCtx(
      { resolveTableTarget: spy(() => null), rawControlIndex: spy(() => 0) },
      { deleteTableControl: thrower("not a table") }
    )
    const r = run("delete_node", { ref: { section: 0, paragraph: 3, control: 0 } }, { section: 0, paragraph: 3 }, ctx)
    assert.ok(isOk(r) && r.extra.removed === "picture")
  })

  it("non-integer control → descriptive error", () => {
    const ctx = makeCtx({ resolveTableTarget: spy(() => null), rawControlIndex: spy(() => NaN) })
    const r = run("delete_node", {}, { section: 0, paragraph: 3 }, ctx)
    assert.ok(isErr(r) && /requires a ref to a control/.test(r.error))
  })

  it("every remover throws → 'not a deletable node'", () => {
    const allFail = {
      deleteTableControl: thrower("x"), deletePictureControl: thrower("x"),
      deleteShapeControl: thrower("x"), deleteEquationControl: thrower("x"), deleteFootnote: thrower("x"),
    }
    const ctx = makeCtx({}, allFail)
    const r = run("delete_node", {}, { section: 0, paragraph: 2, cell: { parentParaIndex: 2, controlIndex: 0 } }, ctx)
    assert.ok(isErr(r) && /not a deletable node/.test(r.error))
  })
})

// ─── insert_picture ──────────────────────────────────────────────────────────

describe("insert_picture", () => {
  it("requires a ref", () => {
    assert.ok(isErr(run("insert_picture", { image_base64: "AAA", width: 1, height: 1 }, null, makeCtx())))
  })

  it("requires inline image bytes (image_base64)", () => {
    const r = run("insert_picture", { width: 1, height: 1 }, { section: 0, paragraph: 1, offset: 0 }, makeCtx())
    assert.ok(isErr(r) && /inline image bytes/.test(r.error))
  })

  it("requires integer width AND height (HWPUNIT placed size)", () => {
    const r = run("insert_picture", { image_base64: "AAA", width: 100 }, { section: 0, paragraph: 1, offset: 0 }, makeCtx())
    assert.ok(isErr(r) && /integer 'width' and 'height'/.test(r.error))
  })

  it("decodes base64 and calls insertPictureBase64 with JSON options", () => {
    const ctx = makeCtx({ base64ToBytes: spy(() => new Uint8Array([9, 9])) })
    const op = {
      image_base64: "AAA", width: 4000, height: 3000,
      extension: "jpg", natural_width_px: 800, natural_height_px: 600, description: "logo",
    }
    const r = run("insert_picture", op, { section: 0, paragraph: 1, offset: 5 }, ctx)
    assert.ok(isOk(r) && r.extra.extension === "jpg" && r.extra.width === 4000)
    const [optionsJson, b64] = argsOf(ctx.doc.insertPictureBase64)
    assert.deepEqual(JSON.parse(optionsJson), {
      sectionIdx: 0,
      paraIdx: 1,
      charOffset: 5,
      cellPath: "",
      width: 4000,
      height: 3000,
      naturalWidthPx: 800,
      naturalHeightPx: 600,
      extension: "jpg",
      description: "logo",
      paperOffsetXHu: null,
      paperOffsetYHu: null,
    })
    assert.equal(b64, "AAA")
    assert.equal(called(ctx.doc.insertPictureEx), false)
    assert.equal(called(ctx.doc.insertPicture), false)
  })

  it("rejects inline image bytes whose natural dimensions contradict the image header", () => {
    const ctx = makeCtx({ base64ToBytes: spy(() => b64Bytes(png1x1)) })
    const r = run(
      "insert_picture",
      {
        image_base64: png1x1,
        width: 4376,
        height: 3287,
        extension: "png",
        natural_width_px: 3200,
        natural_height_px: 2400,
      },
      { section: 0, paragraph: 1, offset: 0 },
      ctx
    )
    assert.ok(isErr(r) && /bytes are 1x1px/.test(r.error))
    assert.equal(called(ctx.doc.insertPictureBase64), false)
  })

  it("passes the cell path JSON when the ref is a cell with a cellPath", () => {
    const ctx = makeCtx()
    const ref = { section: 0, paragraph: 2, offset: 0, cell: { cellPath: [1, 2] } }
    run("insert_picture", { image_base64: "AAA", width: 10, height: 10 }, ref, ctx)
    assert.equal(JSON.parse(argsOf(ctx.doc.insertPictureBase64)[0]).cellPath, JSON.stringify([1, 2]))
  })

  it("derives a cell path for regular table-cell refs from doc.find", () => {
    const ctx = makeCtx()
    const ref = {
      section: 0,
      paragraph: 9,
      offset: 0,
      cell: { parentParaIndex: 9, controlIndex: 2, cellIndex: 5, cellParaIndex: 1 },
    }
    run("insert_picture", { image_base64: "AAA", width: 10, height: 10 }, ref, ctx)
    assert.deepEqual(JSON.parse(JSON.parse(argsOf(ctx.doc.insertPictureBase64)[0]).cellPath), [
      { controlIndex: 2, cellIndex: 5, cellParaIndex: 1 },
    ])
  })

  it("falls back to insertPictureEx when insertPictureBase64 is unavailable", () => {
    const ctx = makeCtx({ base64ToBytes: spy(() => new Uint8Array([9, 9])) }, { insertPictureBase64: undefined })
    const r = run(
      "insert_picture",
      { image_base64: "AAA", width: 10, height: 20 },
      { section: 0, paragraph: 1, offset: 5 },
      ctx
    )
    assert.ok(isOk(r))
    const [optionsJson, bytes] = argsOf(ctx.doc.insertPictureEx)
    assert.equal(JSON.parse(optionsJson).paraIdx, 1)
    assert.deepEqual(bytes, new Uint8Array([9, 9]))
  })

  it("falls back to positional insertPicture for older wasm builds", () => {
    const ctx = makeCtx(
      { base64ToBytes: spy(() => new Uint8Array([9, 9])) },
      { insertPictureBase64: undefined, insertPictureEx: undefined }
    )
    const r = run(
      "insert_picture",
      { image_base64: "AAA", width: 10, height: 20, x: 30, y: 40 },
      { section: 0, paragraph: 1, offset: 5 },
      ctx
    )
    assert.ok(isOk(r))
    assert.deepEqual(argsOf(ctx.doc.insertPicture), [
      0, 1, 5, "", new Uint8Array([9, 9]), 10, 20, 0, 0, "png", "", 30, 40,
    ])
  })

  it("maps invalid base64 to a descriptive error", () => {
    const ctx = makeCtx({ base64ToBytes: thrower("bad b64") })
    const r = run("insert_picture", { image_base64: "!!", width: 1, height: 1 }, { section: 0, paragraph: 1, offset: 0 }, ctx)
    assert.ok(isErr(r) && /invalid base64/.test(r.error))
  })
})
