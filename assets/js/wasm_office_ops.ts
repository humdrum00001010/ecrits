// Typed op vocabulary for the office (LibreOffice→WASM) browser arm — the office
// twin of wasm_ops.ts (#49 O4). The deployed `uno_apply` carries the FULL server
// op set (LokEditBindings ports the NIF's uno_bridge dispatch), so MOST verbs
// forward to it verbatim ("native"). Only THREE verbs are composed JS-side from
// the IR, because their faithful semantics need the element's current text:
//   replace_text — a counted query->replacement substitution, re-set whole
//   set_cell     — alias of set_text on a (ref-collapsed) cell
//   delete_range — whole-element clear (the binary has no offset granularity)
//
// Each verb is a STANDALONE handler `(ctx, op) => OfficeOpResult`; the registry is
// BUILT by chaining `OFFICE_OPS.define(verb, handler)` (no loose verb string-
// switch). `WasmOfficeEditor.rewriteUnsupportedEditOp` dispatches through
// `rewriteOfficeOp`, passing the editor instance as `ctx` (it structurally
// satisfies `OfficeEditorContext`).

/** A shim handler's outcome (mirrors the legacy rewriteUnsupportedEditOp return). */
export type OfficeOpResult =
  // forward the op to uno_apply unchanged (the C++ owns dispatch)
  | { native: true }
  // apply this IR-composed op (a set_text) instead; `replaced` = synthesized count
  | { op: Record<string, any>; replaced?: number }
  // the op can't be composed (e.g. query not found / unresolved ref)
  | { error: string }

/** The element a shim resolves against. */
export interface OfficeElement {
  ref: string
  text: string
  [k: string]: any
}

/**
 * The editor surface the shim handlers use as `ctx`. The `WasmOfficeEditor`
 * instance structurally satisfies this (it is plain JS; the contract is the
 * method NAMES).
 */
export interface OfficeEditorContext {
  officeElements(): OfficeElement[]
  officeElementForEdit(elements: OfficeElement[], ref: string): OfficeElement | null
  setTextRefFor(ref: string): string
  isSetTextTarget(ref: string): boolean
  replaceAllCounted(text: string, query: string, replacement: string): { text: string; count: number }
  singleParagraphText(v: any): string
  [k: string]: any
}

// The typed op-tag (discriminated union): `op.op` is the literal discriminant;
// per-variant fields stay open so handlers read their fields without per-field
// typing. Mirrors the Elixir Ecrits.Doc.Office.Op wire vocabulary.
type Base<T extends string> = { op: T; ref?: any; [k: string]: any }
export type OfficeOp =
  | (Base<"replace_text"> & { query?: string; replacement?: any })
  | (Base<"set_cell"> & { text?: any })
  | Base<"delete_range">
  | (Base<"insert_text"> & { text?: any })
  | (Base<"insert_paragraph"> & { text?: any; style?: string })
  | (Base<"insert_table"> & { rows?: number; cols?: number; name?: string })
  | Base<"insert_table_row"> | Base<"delete_table_row">
  | Base<"insert_table_column"> | Base<"delete_table_column">
  | Base<"merge_cells"> | Base<"split_cell">
  | Base<"insert_footnote"> | Base<"insert_endnote"> | Base<"insert_equation">
  | Base<"set_columns"> | Base<"insert_picture"> | Base<"insert_slide">
  | Base<"insert_shape"> | Base<"set_geometry"> | Base<"delete_node">
  | Base<"delete_paragraph"> | Base<"split"> | Base<"merge">

export type OfficeOpHandler = (ctx: OfficeEditorContext, op: OfficeOp) => OfficeOpResult

// ── shim handlers (the 3 IR-composed verbs) ──────────────────────────────────

/** Resolve a ref to its set_text target element (collapsing run→paragraph refs). */
function resolveSetText(ctx: OfficeEditorContext, ref: any): { targetRef: string; el: OfficeElement } | null {
  if (ref == null) return null
  const elements = ctx.officeElements()
  const targetRef = ctx.setTextRefFor(String(ref))
  const el = ctx.officeElementForEdit(elements, targetRef) || ctx.officeElementForEdit(elements, String(ref))
  return el ? { targetRef, el } : null
}

const opSetCell: OfficeOpHandler = (ctx, op) => {
  if (op.ref == null) return { error: "set_cell requires a 'ref'" }
  const hit = resolveSetText(ctx, op.ref)
  if (!hit) return { error: `unresolved ref: ${op.ref}` }
  return { op: { op: "set_text", ref: hit.targetRef, text: String((op as any).text == null ? "" : (op as any).text) } }
}

const opDeleteRange: OfficeOpHandler = (ctx, op) => {
  if (op.ref == null) return { error: "delete_range requires a 'ref'" }
  const hit = resolveSetText(ctx, op.ref)
  if (!hit) return { error: `unresolved ref: ${op.ref}` }
  // No offset granularity in the binary; a whole-element clear is the closest
  // faithful effect (the agent then sees an empty paragraph/shape).
  return { op: { op: "set_text", ref: hit.targetRef, text: "" } }
}

const opReplaceText: OfficeOpHandler = (ctx, op) => {
  const query = (op as any).query
  const replacement = ctx.singleParagraphText((op as any).replacement)
  if (typeof query !== "string" || query === "") {
    return { error: "replace_text requires a non-empty string 'query'" }
  }
  const elements = ctx.officeElements()

  // Ref-scoped: substitute within that element.
  if (op.ref != null) {
    const hit = resolveSetText(ctx, op.ref)
    if (!hit) return { error: `unresolved ref: ${op.ref}` }
    if (!hit.el.text.includes(query)) {
      return { error: `query not found in ${op.ref}: ${JSON.stringify(query)}` }
    }
    const { text: next, count } = ctx.replaceAllCounted(hit.el.text, query, replacement)
    return { op: { op: "set_text", ref: hit.targetRef, text: next }, replaced: count }
  }

  // No ref: the first text-bearing PARAGRAPH/SHAPE containing the query (skip run
  // refs to avoid double-application; set_text targets paragraphs).
  const target = elements.find((el) => ctx.isSetTextTarget(el.ref) && el.text.includes(query))
  if (!target) return { error: `query not found in document: ${JSON.stringify(query)}` }
  const targetRef = ctx.setTextRefFor(target.ref)
  const el = ctx.officeElementForEdit(elements, targetRef) || target
  const { text: next, count } = ctx.replaceAllCounted(el.text, query, replacement)
  return { op: { op: "set_text", ref: targetRef, text: next }, replaced: count }
}

/** Native passthrough: the deployed uno_apply applies these verbatim. */
const NATIVE: OfficeOpHandler = () => ({ native: true })

// ── chained registry ─────────────────────────────────────────────────────────

class OfficeOpRegistry {
  registry: Record<string, OfficeOpHandler> = {}
  define(verb: string, handler: OfficeOpHandler): this {
    this.registry[verb] = handler
    return this
  }
}

export const OFFICE_OPS = new OfficeOpRegistry()
  // IR-composed shims:
  .define("replace_text", opReplaceText)
  .define("set_cell", opSetCell)
  .define("delete_range", opDeleteRange)
  // native (uno_apply owns dispatch):
  .define("insert_text", NATIVE)
  .define("insert_paragraph", NATIVE)
  .define("delete_paragraph", NATIVE)
  .define("split", NATIVE)
  .define("merge", NATIVE)
  .define("insert_table", NATIVE)
  .define("insert_table_row", NATIVE)
  .define("delete_table_row", NATIVE)
  .define("insert_table_column", NATIVE)
  .define("delete_table_column", NATIVE)
  .define("merge_cells", NATIVE)
  .define("split_cell", NATIVE)
  .define("insert_footnote", NATIVE)
  .define("insert_endnote", NATIVE)
  .define("insert_equation", NATIVE)
  .define("set_columns", NATIVE)
  .define("insert_picture", NATIVE)
  .define("insert_slide", NATIVE)
  .define("insert_shape", NATIVE)
  .define("set_geometry", NATIVE)
  .define("delete_node", NATIVE)

/**
 * Classify + rewrite an agent edit op for the office browser arm.
 * Returns (matching the legacy rewriteUnsupportedEditOp contract):
 *   null                 — apply the op UNCHANGED (native verb / unknown → uno_apply)
 *   { op, replaced? }     — apply this IR-composed set_text op instead
 *   { error }             — the op can't be composed
 */
export function rewriteOfficeOp(
  ctx: OfficeEditorContext,
  op: OfficeOp,
): { op: Record<string, any>; replaced?: number } | { error: string } | null {
  const handler = op && op.op ? OFFICE_OPS.registry[op.op] : undefined
  if (!handler) return null
  const result = handler(ctx, op)
  if ("native" in result) return null
  return result
}
