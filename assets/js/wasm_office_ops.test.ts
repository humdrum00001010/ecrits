// Unit tests for the office (LibreOffice→WASM) browser arm's typed op vocabulary
// (`wasm_office_ops.ts`, #49 O4). Pure logic, no wasm — drives `rewriteOfficeOp`
// against a fully-mocked `ctx` and asserts the CONTRACT: native verbs pass
// through (null), the 3 IR-composed shims (replace_text/set_cell/delete_range)
// produce the right set_text op + count, and the exact guard error strings.
//   node --test 'js/**/*.test.ts'   (from assets/)

import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { rewriteOfficeOp, OFFICE_OPS, type OfficeEditorContext, type OfficeElement } from "./wasm_office_ops.ts"

// A mock editor ctx whose elements are addressed by ref; setTextRefFor collapses
// a run ref (`…/r<n>`) to its paragraph, matching the real editor.
function mockCtx(elements: OfficeElement[]): OfficeEditorContext {
  const collapse = (ref: string) => ref.replace(/\/r\d+$/, "")
  return {
    officeElements: () => elements,
    setTextRefFor: (ref: string) => collapse(ref),
    isSetTextTarget: (ref: string) => !/\/r\d+$/.test(ref),
    officeElementForEdit: (els: OfficeElement[], ref: string) =>
      els.find((e) => collapse(e.ref) === collapse(ref) && !/\/r\d+$/.test(ref)) || null,
    replaceAllCounted: (text: string, query: string, replacement: string) => {
      const parts = text.split(query)
      return { text: parts.join(replacement), count: parts.length - 1 }
    },
    singleParagraphText: (v: any) => String(v == null ? "" : v).split("\n")[0],
  }
}

describe("rewriteOfficeOp — native passthrough", () => {
  it("returns null for every native verb (uno_apply owns dispatch)", () => {
    const ctx = mockCtx([])
    for (const op of [
      "insert_text", "insert_paragraph", "delete_paragraph", "split", "merge",
      "insert_table", "insert_table_row", "delete_table_row", "insert_table_column",
      "delete_table_column", "merge_cells", "split_cell", "insert_footnote",
      "insert_endnote", "insert_equation", "set_columns", "insert_picture",
      "insert_slide", "insert_shape", "set_geometry", "delete_node",
    ]) {
      assert.equal(rewriteOfficeOp(ctx, { op } as any), null, `${op} must pass through`)
    }
  })

  it("returns null for an unknown verb (forwarded; uno_apply rejects)", () => {
    assert.equal(rewriteOfficeOp(mockCtx([]), { op: "bogus_verb" } as any), null)
  })

  it("registers the 3 shims + 21 native verbs", () => {
    assert.equal(Object.keys(OFFICE_OPS.registry).length, 24)
  })
})

describe("rewriteOfficeOp — set_cell shim", () => {
  it("rewrites to set_text on the resolved ref", () => {
    const ctx = mockCtx([{ ref: "tbl[T]/cell[A1]", text: "old" }])
    assert.deepEqual(rewriteOfficeOp(ctx, { op: "set_cell", ref: "tbl[T]/cell[A1]", text: "new" } as any), {
      op: { op: "set_text", ref: "tbl[T]/cell[A1]", text: "new" },
    })
  })

  it("coerces a nil text to empty string", () => {
    const ctx = mockCtx([{ ref: "tbl[T]/cell[A1]", text: "old" }])
    const r = rewriteOfficeOp(ctx, { op: "set_cell", ref: "tbl[T]/cell[A1]" } as any) as any
    assert.equal(r.op.text, "")
  })

  it("guards a missing ref", () => {
    assert.deepEqual(rewriteOfficeOp(mockCtx([]), { op: "set_cell", text: "x" } as any), {
      error: "set_cell requires a 'ref'",
    })
  })

  it("errors on an unresolved ref", () => {
    const r = rewriteOfficeOp(mockCtx([]), { op: "set_cell", ref: "p9", text: "x" } as any) as any
    assert.equal(r.error, "unresolved ref: p9")
  })
})

describe("rewriteOfficeOp — delete_range shim", () => {
  it("rewrites to a whole-element clear (set_text empty)", () => {
    const ctx = mockCtx([{ ref: "p2", text: "stuff" }])
    assert.deepEqual(rewriteOfficeOp(ctx, { op: "delete_range", ref: "p2" } as any), {
      op: { op: "set_text", ref: "p2", text: "" },
    })
  })

  it("collapses a run ref to its paragraph", () => {
    const ctx = mockCtx([{ ref: "p2", text: "stuff" }])
    const r = rewriteOfficeOp(ctx, { op: "delete_range", ref: "p2/r0" } as any) as any
    assert.equal(r.op.ref, "p2")
  })
})

describe("rewriteOfficeOp — replace_text shim", () => {
  it("ref-scoped: counted substitution, re-set whole", () => {
    const ctx = mockCtx([{ ref: "p1", text: "a foo b foo c" }])
    assert.deepEqual(rewriteOfficeOp(ctx, { op: "replace_text", ref: "p1", query: "foo", replacement: "bar" } as any), {
      op: { op: "set_text", ref: "p1", text: "a bar b bar c" },
      replaced: 2,
    })
  })

  it("no ref: first text-bearing element containing the query", () => {
    const ctx = mockCtx([
      { ref: "p0", text: "nothing here" },
      { ref: "p1", text: "has needle inside" },
    ])
    const r = rewriteOfficeOp(ctx, { op: "replace_text", query: "needle", replacement: "X" } as any) as any
    assert.equal(r.op.ref, "p1")
    assert.equal(r.op.text, "has X inside")
    assert.equal(r.replaced, 1)
  })

  it("guards an empty query", () => {
    assert.deepEqual(rewriteOfficeOp(mockCtx([]), { op: "replace_text", query: "" } as any), {
      error: "replace_text requires a non-empty string 'query'",
    })
  })

  it("errors when the query is absent from the ref'd element", () => {
    const ctx = mockCtx([{ ref: "p1", text: "no match" }])
    const r = rewriteOfficeOp(ctx, { op: "replace_text", ref: "p1", query: "zzz", replacement: "x" } as any) as any
    assert.match(r.error, /query not found in p1/)
  })

  it("errors when the query is absent document-wide (no ref)", () => {
    const ctx = mockCtx([{ ref: "p1", text: "no match" }])
    const r = rewriteOfficeOp(ctx, { op: "replace_text", query: "zzz", replacement: "x" } as any) as any
    assert.match(r.error, /query not found in document/)
  })

  it("collapses the multi-line replacement to its first paragraph", () => {
    const ctx = mockCtx([{ ref: "p1", text: "x foo y" }])
    const r = rewriteOfficeOp(ctx, { op: "replace_text", ref: "p1", query: "foo", replacement: "L1\nL2" } as any) as any
    assert.equal(r.op.text, "x L1 y")
  })
})
