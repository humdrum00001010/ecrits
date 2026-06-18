// Doc-edit op dispatch for the HWP browser (WASM) arm — the typed op vocabulary.
//
// Each edit verb is a STANDALONE handler `(ctx, op, ref, verb) => OpResult`; the
// registry is BUILT by chaining `OPS.define(verb, handler)` (no verb->method
// strategy map, no auto-register loop). `WasmHwpEditor.applyOneOp` parses the
// verb + ref once and dispatches through `OPS.registry[verb]`, passing the editor
// instance as `ctx` (it structurally satisfies `EditorContext`). Shared handlers
// (opInsertNote for footnote/endnote; opTableStructure for the 6-verb table
// family) switch on the typed op-tag `op.op`. New ops register through the same
// chain: `WasmHwpEditor.define(verb, handler)`.

export type RefInput = string | Record<string, any> | null | undefined

/** `parseRef` output: a resolved body/cell/note position (loosely typed). */
export interface ParsedRef { section: number; paragraph: number; offset?: number; cell?: any; note?: any; [k: string]: any }

/** Every handler returns success (+ optional `extra` evidence) or an error. */
export type OpResult = { ok: true; extra?: Record<string, any> } | { error: string }

/**
 * The editor surface the handlers use, as `ctx`. The `WasmHwpEditor` instance
 * structurally satisfies this; the contract is the method NAMES (the editor is
 * plain JS, so members are typed loosely).
 */
export interface EditorContext {
  doc: any
  recordOp(kind: string, payload: Record<string, any>): void
  replacedCount(raw: any): number
  resolveEndRef(ref: RefInput): ParsedRef | null
  singleParagraphText(v: any): string
  splitTextLines(v: any): string[]
  paragraphLength(section: number, paragraph: number): number
  collectElements(...a: any[]): any
  cellParagraphCount(...a: any[]): number
  cellParagraphLength(...a: any[]): number
  cellPathForPara(...a: any[]): any
  cellPathJson(...a: any[]): string
  cellRowCol(...a: any[]): any
  rawControlIndex(...a: any[]): number
  resolveTableTarget(...a: any[]): any
  getTextInCellRef(...a: any[]): string
  deleteTextInCellRef(...a: any[]): any
  insertTextInCellRef(...a: any[]): any
  insertTextLinesInCell(...a: any[]): any
  splitParagraphInCellRef(...a: any[]): any
  mergeParagraphInCellRef(...a: any[]): any
  insertTextLines(...a: any[]): any
  insertTextLinesInFootnote(...a: any[]): any
  noteParagraphText(...a: any[]): string
  shapeStylePropsFromOp(...a: any[]): any
  [k: string]: any
}

// The typed op-tag (discriminated union): `op.op` is the literal discriminant the
// shared handlers switch on; per-variant fields stay open (`[k:string]:any`) so the
// relocated bodies read their fields without per-field typing.
type Base<T extends string> = { op: T; ref?: RefInput; [k: string]: any }
export type Op =
  | (Base<"replace_text"> & { query?: string; replacement?: any; all?: boolean })
  | (Base<"insert_text"> & { text?: any })
  | (Base<"delete_range"> & { count?: number; to?: RefInput })
  | (Base<"set_cell"> & { text?: any })
  | Base<"insert_equation"> | Base<"insert_footnote"> | Base<"insert_endnote">
  | Base<"insert_shape"> | Base<"set_columns"> | Base<"insert_paragraph">
  | Base<"delete_paragraph"> | Base<"split"> | Base<"merge">
  | (Base<"insert_table"> & { rows?: number; cols?: number; cells?: any[][] })
  | Base<"insert_table_row"> | Base<"delete_table_row">
  | Base<"insert_table_column"> | Base<"delete_table_column">
  | Base<"merge_cells"> | Base<"split_cell"> | Base<"delete_node"> | Base<"insert_picture">

export type OpHandler = (ctx: EditorContext, op: Op, ref: ParsedRef | null, verb: string) => OpResult

const opReplaceText: OpHandler = (ctx, op, ref, verb) => {
    const query = op.query != null ? String(op.query) : ""
    if (!query) return { error: "replace_text requires a non-empty query" }
    // A MISSING replacement must never become a silent delete — that is how a
    // mis-fielded op (new text under `text`/`new`) wiped paragraphs. Require it
    // explicitly; to delete text the agent uses delete_range.
    if (op.replacement == null) {
      return { error: "replace_text requires a 'replacement' field (the field is 'replacement', not 'text'/'new'; to delete text use delete_range)" }
    }
    const replacement = ctx.singleParagraphText(op.replacement)

    // cell-scoped: the ref addresses text inside a TABLE CELL. Read/replace via
    // the cell primitives (getTextInCell/deleteTextInCell/insertTextInCell) — the
    // body getTextRange path can't see cell text, so without this the agent can
    // never fill a table (signature block, 계약금액 table, …).
    if (ref && ref.cell) {
      const cl = ref.cell
      let cellText = ""
      try {
        const len = ctx.cellParagraphLength(ref, cl, cl.cellParaIndex)
        cellText = ctx.getTextInCellRef(ref, cl, cl.cellParaIndex, 0, len) || ""
      } catch (error) {
        return { error: `cell read failed: ${String((error && error.message) || error)}` }
      }
      const idx = cellText.indexOf(query)
      if (idx < 0) {
        return { error: `replace_text: query not found in target cell (cell text: ${JSON.stringify(cellText.slice(0, 80))})` }
      }
      try {
        ctx.deleteTextInCellRef(ref, cl, cl.cellParaIndex, idx, query.length)
        ctx.insertTextInCellRef(ref, cl, cl.cellParaIndex, idx, replacement)
      } catch (error) {
        return { error: `cell replace failed: ${String((error && error.message) || error)}` }
      }
      ctx.recordOp("AgentReplaceText", { section: ref.section, cell: cl, offset: idx, query, replacement, replaced: 1 })
      return { ok: true, extra: { replaced: 1 } }
    }

    // note-scoped: replace the query inside a footnote/endnote BODY sub-paragraph.
    // Read the note text via getFootnoteInfo, find the literal offset, then
    // delete+insert via the note primitives (both control-type agnostic).
    // BUGFIX: guard `ref &&` — a no-ref (global) replace_text has ref===null,
    // and this branch (unlike the `if (ref && ref.cell)` above) used to read
    // `ref.note` → "Cannot read properties of null (reading 'note')", which
    // blocked every global replace_text. Null ref now falls through to the
    // count-guarded global path below.
    if (ref && ref.note) {
      const nt = ref.note
      const noteText = ctx.noteParagraphText(ref.section, ref.paragraph, nt)
      const idx = noteText.indexOf(query)
      if (idx < 0) {
        return { error: `replace_text: query not found in target note body (note text: ${JSON.stringify(noteText.slice(0, 80))})` }
      }
      try {
        ctx.doc.deleteTextInFootnote(ref.section, ref.paragraph, nt.controlIndex, nt.subParaIndex, idx, query.length)
        ctx.doc.insertTextInFootnote(ref.section, ref.paragraph, nt.controlIndex, nt.subParaIndex, idx, replacement)
      } catch (error) {
        return { error: `note replace failed: ${String((error && error.message) || error)}` }
      }
      ctx.recordOp("AgentReplaceText", { section: ref.section, para: ref.paragraph, note: nt, offset: idx, query, replacement, replaced: 1 })
      return { ok: true, extra: { replaced: 1 } }
    }

    // ref-scoped: replace the query ONLY inside the referenced paragraph, so a
    // phrase that recurs across sample blocks is edited exactly where intended.
    if (ref) {
      let paraText = ""
      try {
        const len = ctx.paragraphLength(ref.section, ref.paragraph)
        paraText = ctx.doc.getTextRange(ref.section, ref.paragraph, 0, len) || ""
      } catch (_) {
        paraText = ""
      }
      const idx = paraText.indexOf(query)
      if (idx >= 0) {
        try {
          ctx.doc.deleteText(ref.section, ref.paragraph, idx, query.length)
          ctx.doc.insertText(ref.section, ref.paragraph, idx, replacement)
        } catch (error) {
          return { error: `scoped replace failed: ${String((error && error.message) || error)}` }
        }
        ctx.recordOp("AgentReplaceText", { section: ref.section, para: ref.paragraph, offset: idx, query, replacement, replaced: 1 })
        return { ok: true, extra: { replaced: 1 } }
      }
      // Body-paragraph miss — the text most likely lives inside a TABLE CELL,
      // which getTextRange(section,paragraph) does not read. Don't error: fall
      // through to the global count-guarded path below, which searches the whole
      // document (cells included) and replaces the match.
      console.warn(
        `[wasm-hwp] ref-scoped replace: query not in body paragraph ${ref.section}/${ref.paragraph} ` +
          "(likely in a table cell) — falling back to global match"
      )
    }

    // global (no ref): count matches first; replacing >1 needs explicit all:true
    // so a paragraph-length query can never rewrite unrelated sample blocks.
    const all = op.all === true
    let matchCount = null
    try {
      const raw = ctx.doc.searchAllText(query, true, true)
      const parsed = raw ? JSON.parse(raw) : []
      const list = Array.isArray(parsed) ? parsed : (parsed.matches || [])
      matchCount = list.length
    } catch (_) {
      matchCount = null
    }
    if (matchCount === 0) {
      return { error: `replace_text: no match for query (it must be the document's exact current text)` }
    }
    if (matchCount != null && matchCount > 1 && !all) {
      return { error: `replace_text: query matches ${matchCount} places; pass a ref to target one, use a longer/unique query, or pass all:true to replace every match` }
    }

    let replaced = 0
    try {
      const raw = ctx.doc.replaceAll(query, replacement, true)
      replaced = ctx.replacedCount(raw)
    } catch (error) {
      return { error: `replaceAll failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentReplaceText", { query, replacement, replaced })
    return { ok: true, extra: { replaced } }
}

const opInsertText: OpHandler = (ctx, op, ref, verb) => {
    // ref "end" appends at the end of the last body paragraph (same shape
    // the docx guide teaches; agents reuse it on hwp).
    const at = ref || ctx.resolveEndRef(op.ref)
    if (!at) return { error: "insert_text requires a ref {section,paragraph,offset} (from doc.find) or \"end\"" }
    const ref2 = at
    const text = op.text != null ? String(op.text) : ""
    if (!text) return { error: "insert_text requires non-empty 'text'" }
    const offset = Number.isInteger(ref2.offset) ? ref2.offset : 0
    // note (footnote/endnote) BODY sub-paragraph: route to insertTextInFootnote,
    // which the native engine handles for both footnotes and endnotes. The body
    // paragraph at ref2.paragraph HOLDS the note anchor (ref2.note.controlIndex);
    // ref2.note.subParaIndex indexes the note's own paragraph. This is what makes
    // an (empty) endnote body a writable target via doc.* on a viewed doc.
    if (ref2.note) {
      const nt = ref2.note
      try {
        ctx.insertTextLinesInFootnote(ref, nt, offset, text)
      } catch (error) {
        return { error: `insertTextInFootnote failed: ${String((error && error.message) || error)}` }
      }
      ctx.recordOp("AgentInsertText", { section: ref2.section, para: ref2.paragraph, note: nt, offset, text })
      return { ok: true, extra: { inserted: text.length } }
    }
    if (ref2.cell) {
      const cl = ref2.cell
      try {
        ctx.insertTextLinesInCell(ref, cl, offset, text)
      } catch (error) {
        return { error: `insertTextInCell failed: ${String((error && error.message) || error)}` }
      }
      ctx.recordOp("AgentInsertText", { section: ref2.section, cell: cl, offset, text })
      return { ok: true, extra: { inserted: text.length } }
    }
    try {
      ctx.insertTextLines(ref, offset, text)
    } catch (error) {
      return { error: `insertText failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentInsertText", { section: ref2.section, para: ref2.paragraph, offset, text })
    return { ok: true, extra: { inserted: text.length } }
}

const opDeleteRange: OpHandler = (ctx, op, ref, verb) => {
    if (!ref) return { error: "delete_range requires a ref {section,paragraph,offset} (from doc.find)" }
    const offset = Number.isInteger(ref.offset) ? ref.offset : 0
    const cl = ref.cell
    const nt = ref.note
    // count defaults to "rest of the paragraph from offset" when omitted.
    let count = Number.isInteger(op.count) ? op.count : null
    if (count == null) {
      let len = 0
      try {
        if (cl) {
          len = ctx.cellParagraphLength(ref, cl, cl.cellParaIndex)
        } else if (nt) {
          len = ctx.noteParagraphText(ref.section, ref.paragraph, nt).length
        } else {
          len = ctx.paragraphLength(ref.section, ref.paragraph)
        }
      } catch (_) {
        len = 0
      }
      count = Math.max(0, len - offset)
    }
    if (count <= 0) return { error: "delete_range: nothing to delete (count must be > 0)" }
    try {
      if (cl) {
        ctx.deleteTextInCellRef(ref, cl, cl.cellParaIndex, offset, count)
      } else if (nt) {
        ctx.doc.deleteTextInFootnote(ref.section, ref.paragraph, nt.controlIndex, nt.subParaIndex, offset, count)
      } else {
        ctx.doc.deleteText(ref.section, ref.paragraph, offset, count)
      }
    } catch (error) {
      return { error: `deleteText failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentDeleteRange", { section: ref.section, cell: cl, note: nt, para: ref.paragraph, offset, count })
    return { ok: true, extra: { deleted: count } }
}

  // set_cell: REPLACE a whole table cell's content with `text`, one cell
  // paragraph per `\n`-separated line, each inheriting the cell's existing
  // paragraph/char formatting. Mirrors the server `set_cell` (engine
  // set_cell_text): collapse the cell to its first paragraph (which keeps its
  // ParaShape/CharShape), set line 0, then splitParagraphInCell + insert for
  // each further line (splitParagraphInCell clones the format, same as the
  // engine split_at).
const opSetCell: OpHandler = (ctx, op, ref, verb) => {
    if (!ref || !ref.cell) {
      return { error: "set_cell requires a CELL ref (doc.find text inside the cell)" }
    }
    const cl = ref.cell
    const text = op.text != null ? String(op.text) : ""
    const lines = text.split("\n")
    const { section } = ref
    try {
      // 1) Collapse to one cell paragraph: merge cellPara 1 back into 0 until
      //    only the first remains. mergeParagraphInCell at a non-zero cellPara
      //    joins it into the previous one; we keep merging index 1 until the
      //    cell no longer has a second paragraph (the merge returns the prior
      //    paragraph index / errors when there is nothing to merge).
      const count = ctx.cellParagraphCount(ref, cl)
      for (let cellPara = Math.min(count - 1, 4095); cellPara >= 1; cellPara--) {
        ctx.mergeParagraphInCellRef(ref, cl, cellPara)
      }
    } catch (_) {
      // No extra cell paragraphs (single-paragraph cell already) — nothing to collapse.
    }
    try {
      // 2) Clear cellPara 0 (keeps its ParaShape/CharShape) and set line 0.
      const len0 = ctx.cellParagraphLength(ref, cl, 0)
      if (len0 > 0) ctx.deleteTextInCellRef(ref, cl, 0, 0, len0)
      if (lines[0]) ctx.insertTextInCellRef(ref, cl, 0, 0, lines[0])
      // 3) Each further line: split at end of the current last paragraph
      //    (inherits format) then insert the line.
      for (let i = 1; i < lines.length; i++) {
        const prevLen = ctx.cellParagraphLength(ref, cl, i - 1)
        ctx.splitParagraphInCellRef(ref, cl, i - 1, prevLen)
        if (lines[i]) ctx.insertTextInCellRef(ref, cl, i, 0, lines[i])
      }
    } catch (error) {
      return { error: `set_cell failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentSetCell", { section, cell: cl, lines })
    // BUGFIX: obey the applyOneOp contract — return {ok, extra} and let the
    // CALLER (applyAgentEdit / applyAgentEditBatch) call finishAgentEdit. The
    // old line called `finishAgentEdit(...)` here, which is NOT this helper's
    // job and caused runtime failures on
    // every set_cell (single, and every set_cell op inside a batch).
    return { ok: true, extra: { cellParaCount: lines.length } }
}

  // insert_equation: an inline equation at the body ref. `script` is HWP
  // equation markup; font_size (HWPUNIT, default 1000=10pt) and color (packed
  // 0xBBGGRR, default 0) style it. Calls the EXISTING wasm insertEquation.
const opInsertEquation: OpHandler = (ctx, op, ref, verb) => {
    if (!ref) return { error: "insert_equation requires a ref {section,paragraph,offset} (from doc.find)" }
    const script = op.script != null ? String(op.script) : ""
    if (!script) return { error: "insert_equation requires a non-empty 'script' (HWP equation markup, e.g. 'x^2 + y^2 = z^2')" }
    const offset = Number.isInteger(ref.offset) ? ref.offset : 0
    const fontSize = Number.isInteger(op.font_size) ? op.font_size : 1000
    const color = Number.isInteger(op.color) ? op.color : 0
    try {
      ctx.doc.insertEquation(ref.section, ref.paragraph, offset, script, fontSize, color)
    } catch (error) {
      return { error: `insertEquation failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentInsertEquation", { section: ref.section, para: ref.paragraph, offset, script, fontSize, color })
    return { ok: true, extra: { script } }
}

  // insert_footnote / insert_endnote: a footnote/endnote anchor at the body
  // ref (number auto-assigned) PLUS the note's body text. The wasm
  // insertFootnote/insertEndnote only creates the anchor + a placeholder
  // inner paragraph ("  " — the auto-number marker sits between the two
  // spaces), so the op's `text` needs a SECOND call: insertTextInFootnote at
  // fn-para 0, char offset 2 — the same two-step the ehwp server arm does
  // (populate_note_text). Dropping that step silently loses the text while
  // still reporting ok (the doc.edit contract is {ref, text}).
const opInsertNote: OpHandler = (ctx, op, ref, verb) => {
    if (!ref) return { error: `${verb} requires a ref {section,paragraph,offset} (from doc.find)` }
    const offset = Number.isInteger(ref.offset) ? ref.offset : 0
    const text = op.text != null ? String(op.text) : ""
    const cell = ref.cell && Number.isInteger(ref.cell.parentParaIndex) ? ref.cell : null
    let noteInfo = {}
    try {
      if (verb === "insert_footnote" && cell && typeof ctx.doc.insertFootnoteInCell === "function") {
        // Cell ref → anchor INSIDE the table cell paragraph; the one-shot
        // native call also fills the note text. (Endnotes have no in-cell
        // engine variant — they render at the section end anyway.)
        const res = ctx.doc.insertFootnoteInCell(
          ref.section,
          cell.parentParaIndex,
          cell.controlIndex,
          cell.cellIndex,
          Number.isInteger(cell.cellParaIndex) ? cell.cellParaIndex : 0,
          offset,
          text
        )
        try { noteInfo = JSON.parse(res || "{}") } catch { noteInfo = {} }
      } else {
        const res = verb === "insert_footnote"
          ? ctx.doc.insertFootnote(ref.section, ref.paragraph, offset)
          : ctx.doc.insertEndnote(ref.section, ref.paragraph, offset)
        try { noteInfo = JSON.parse(res || "{}") } catch { noteInfo = {} }
        if (text) {
          if (!Number.isInteger(noteInfo.controlIdx)) {
            return { error: `${verb}: engine did not report controlIdx — anchor created but text NOT inserted` }
          }
          // insertTextInFootnote serves endnotes too (same native call on the
          // server arm); paraIdx comes from the engine reply because the engine
          // may re-anchor (e.g. a cell ref lands on the host body paragraph).
          const notePara = Number.isInteger(noteInfo.paraIdx) ? noteInfo.paraIdx : ref.paragraph
          ctx.doc.insertTextInFootnote(ref.section, notePara, noteInfo.controlIdx, 0, 2, text)
        }
      }
    } catch (error) {
      return { error: `${verb} failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp(verb === "insert_footnote" ? "AgentInsertFootnote" : "AgentInsertEndnote", { section: ref.section, para: ref.paragraph, offset, text, cell })
    // Echo the engine evidence so the agent can self-verify: the note number,
    // its anchor address (paraIdx/controlIdx — also the handle for a later
    // delete_node), and the text that actually went in.
    const number = noteInfo.footnoteNumber != null ? noteInfo.footnoteNumber : noteInfo.endnoteNumber
    return { ok: true, extra: { text, number, paraIdx: noteInfo.paraIdx, controlIdx: noteInfo.controlIdx } }
}

  // insert_shape: a drawing shape (rectangle/ellipse/line/textbox) at the body
  // ref. width/height are HWPUNIT (required); x/y are offsets. Calls the
  // EXISTING wasm createShapeControl(json) — map the verb fields onto its JSON.
const opInsertShape: OpHandler = (ctx, op, ref, verb) => {
    if (!ref) return { error: "insert_shape requires a ref {section,paragraph,offset} (from doc.find)" }
    const width = Number.isInteger(op.width) ? op.width : null
    const height = Number.isInteger(op.height) ? op.height : null
    if (width == null || height == null) {
      return { error: "insert_shape requires integer 'width' and 'height' (HWPUNIT, e.g. 8504 ≈ 3cm)" }
    }
    const offset = Number.isInteger(ref.offset) ? ref.offset : 0
    const shapeType = op.shape_type != null ? String(op.shape_type) : "rectangle"
    const shapeProps = ctx.shapeStylePropsFromOp(op)
    const shapeJson = JSON.stringify({
      sectionIdx: ref.section,
      paraIdx: ref.paragraph,
      charOffset: offset,
      width,
      height,
      horzOffset: Number.isInteger(op.x) ? op.x : 0,
      vertOffset: Number.isInteger(op.y) ? op.y : 0,
      shapeType,
      treatAsChar: true,
      ...shapeProps
    })
    let created = null
    try {
      created = ctx.doc.createShapeControl(shapeJson)
      if (Object.keys(shapeProps).length > 0 && created) {
        const info = JSON.parse(created)
        if (Number.isInteger(info.paraIdx) && Number.isInteger(info.controlIdx)) {
          ctx.doc.setShapeProperties(ref.section, info.paraIdx, info.controlIdx, JSON.stringify(shapeProps))
        }
      }
    } catch (error) {
      return { error: `createShapeControl failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentInsertShape", { section: ref.section, para: ref.paragraph, offset, shapeType, width, height, shapeProps })
    return { ok: true, extra: { shapeType, shapeProps } }
}

  // set_columns: the section's multi-column layout. `count` columns; column_type
  // 0=normal/1=distribute/2=parallel; same_width; spacing (HWPUNIT). The ref's
  // section selects the section. Calls the EXISTING wasm setColumnDef.
const opSetColumns: OpHandler = (ctx, op, ref, verb) => {
    const section = ref ? ref.section : 0
    const count = Number.isInteger(op.count) ? op.count : null
    if (count == null || count <= 0) {
      return { error: "set_columns requires an integer 'count' > 0 (the number of columns)" }
    }
    const columnType = Number.isInteger(op.column_type) ? op.column_type : 0
    const sameWidth = op.same_width === false ? 0 : 1
    const spacing = Number.isInteger(op.spacing) ? op.spacing : 0
    try {
      ctx.doc.setColumnDef(section, count, columnType, sameWidth, spacing)
    } catch (error) {
      return { error: `setColumnDef failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentSetColumns", { section, count, columnType, sameWidth, spacing })
    return { ok: true, extra: { count } }
}

  // ─── Structural & table ops (parity with the ehwp NIF EditOp dispatch) ───
  // The HWP NIF (deps/ehwp .../lib.rs apply_edit_op) handles these; the rhwp
  // wasm exports the same methods (insertTableRow, splitTableCellInto, …) — the
  // ONLY reason a viewed doc rejected them was the missing `if` cases here (the
  // live "add 10 empty rows" failure). Each verb below maps 1:1 to a wasm method;
  // the NIF dispatch is the reference for arg shapes. Table row/col/merge/split
  // address the table via a CELL ref (ref.cell carries parentParaIndex +
  // controlIndex); row/col come from the op or are derived from the picked cell.

const opInsertParagraph: OpHandler = (ctx, op, ref, verb) => {
    // Accept ref "end" (the shape the docx guide teaches — agents reuse it
    // on hwp) and HONOR `text`: the engine's insertParagraph ignores text,
    // so silently dropping it once turned "write 3 sonnets" into one empty
    // paragraph reported as ok (live 2026-06-13). Insert the paragraph,
    // write the text into it, echo evidence the model can check.
    const target = ref || ctx.resolveEndRef(op.ref)
    if (!target) return { error: "insert_paragraph requires a ref {section,paragraph} or \"end\"" }
    const text = op.text != null ? String(op.text) : ""
    // "end" appends AFTER the last paragraph; an explicit ref inserts AT it.
    const appending = target.appendIndex != null
    const idx = appending ? target.appendIndex : target.paragraph
    try {
      if (appending) {
        // Append a fresh paragraph past the last one — no existing paragraph
        // shifts, so the section ColumnDef in paragraph 0 stays put.
        ctx.doc.insertParagraph(target.section, idx)
        if (text) ctx.insertTextLines({ section: target.section, paragraph: idx }, 0, text)
      } else if (text) {
        // Insert BEFORE an existing paragraph: prepend the text + a break and
        // SPLIT, instead of insertParagraph(idx). insertParagraph shifts the
        // existing paragraph 0 (and its section ColumnDef) down to index 1,
        // where the renderer treats the ColumnDef as a page-breaking column
        // zone — the "body lands on page 2" bug. A split keeps the ColumnDef
        // in the FIRST (now-title) paragraph (mirrors the server arm).
        ctx.insertTextLines({ section: target.section, paragraph: idx }, 0, text + "\n")
      } else {
        ctx.doc.insertParagraph(target.section, idx)
      }
    } catch (error) {
      return { error: `insertParagraph failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentInsertParagraph", { section: target.section, para: idx, textLen: text.length })
    return { ok: true, extra: { paragraph: idx, inserted: text.length } }
}

const opDeleteParagraph: OpHandler = (ctx, op, ref, verb) => {
    if (!ref) return { error: "delete_paragraph requires a ref {section,paragraph}" }
    try {
      ctx.doc.deleteParagraph(ref.section, ref.paragraph)
    } catch (error) {
      return { error: `deleteParagraph failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentDeleteParagraph", { section: ref.section, para: ref.paragraph })
    return { ok: true, extra: {} }
}

  // split: break a paragraph at the ref's char offset. Routes to the cell
  // primitive when the ref addresses a table cell (so a cell paragraph splits in
  // place), else the body splitParagraph.
const opSplit: OpHandler = (ctx, op, ref, verb) => {
    if (!ref) return { error: "split requires a ref {section,paragraph,offset}" }
    const offset = Number.isInteger(ref.offset) ? ref.offset : 0
    try {
      if (ref.cell) {
        ctx.splitParagraphInCellRef(ref, ref.cell, ref.cell.cellParaIndex, offset)
      } else {
        ctx.doc.splitParagraph(ref.section, ref.paragraph, offset)
      }
    } catch (error) {
      return { error: `splitParagraph failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentSplit", { section: ref.section, para: ref.paragraph, cell: ref.cell || null, offset })
    return { ok: true, extra: {} }
}

  // merge: join the ref's paragraph into the previous one (cell-aware).
const opMerge: OpHandler = (ctx, op, ref, verb) => {
    if (!ref) return { error: "merge requires a ref {section,paragraph}" }
    try {
      if (ref.cell) {
        ctx.mergeParagraphInCellRef(ref, ref.cell, ref.cell.cellParaIndex)
      } else {
        ctx.doc.mergeParagraph(ref.section, ref.paragraph)
      }
    } catch (error) {
      return { error: `mergeParagraph failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentMerge", { section: ref.section, para: ref.paragraph, cell: ref.cell || null })
    return { ok: true, extra: {} }
}

  // insert_table: create a NEW R×C table at the body ref. treat_as_char (inline)
  // or explicit col_widths route to createTableEx; otherwise the plain
  // createTable. Mirrors the NIF InsertTable branch.
const opInsertTable: OpHandler = (ctx, op, ref, verb) => {
    if (!ref) return { error: "insert_table requires a ref {section,paragraph,offset}" }
    const rows = Number.isInteger(op.rows) ? op.rows : null
    const cols = Number.isInteger(op.cols) ? op.cols : null
    if (rows == null || cols == null || rows <= 0 || cols <= 0) {
      return { error: "insert_table requires integer 'rows' > 0 and 'cols' > 0" }
    }
    const offset = Number.isInteger(ref.offset) ? ref.offset : 0
    const treatAsChar = op.treat_as_char === true
    const colWidths = Array.isArray(op.col_widths) ? op.col_widths.filter(Number.isInteger) : null
    try {
      if (treatAsChar || (colWidths && colWidths.length)) {
        const optionsJson = JSON.stringify({
          sectionIdx: ref.section,
          paraIdx: ref.paragraph,
          charOffset: offset,
          rowCount: rows,
          colCount: cols,
          treatAsChar,
          ...(colWidths && colWidths.length ? { colWidths } : {})
        })
        ctx.doc.createTableEx(optionsJson)
      } else {
        ctx.doc.createTable(ref.section, ref.paragraph, offset, rows, cols)
      }
    } catch (error) {
      return { error: `createTable failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentInsertTable", { section: ref.section, para: ref.paragraph, offset, rows, cols, treatAsChar })
    return { ok: true, extra: { rows, cols } }
}

  // Table structure ops: insert/delete row+column, merge cells, split a cell.
  // All take the table address from a CELL ref (parentParaIndex = the paragraph
  // holding the table control; controlIndex = the table). row/col default to the
  // picked cell's own row/col (read via getCellInfo) so the agent can say
  // "insert a row below THIS cell" without separately supplying the index.
const opTableStructure: OpHandler = (ctx, op, ref, verb) => {
    const target = ctx.resolveTableTarget(ref)
    if (!target) {
      return { error: `${verb} requires a table CELL ref (doc.find a cell in the table; its ref.cell carries the table control)` }
    }
    const { section, paragraph, control } = target
    // Echo the table's dimensions AFTER the op in every result, so the agent
    // can SEE the structural effect ("asked for 10, rows_after says 2") and
    // self-correct instead of trusting a bare {ok:true}. (Live failure
    // 2026-06-12: "10 rows added" claimed, 1 actually inserted.)
    const dimsAfter = () => {
      try {
        const d = JSON.parse(ctx.doc.getTableDimensions(section, paragraph, control))
        return { rows_after: d.rowCount, cols_after: d.colCount }
      } catch (_) {
        return {}
      }
    }
    try {
      if (verb === "insert_table_row") {
        const row = Number.isInteger(op.row) ? op.row : ctx.cellRowCol(target).row
        if (!Number.isInteger(row)) return { error: "insert_table_row needs a 'row' index (or a cell ref to derive it)" }
        const below = op.below === true
        // `count` inserts N rows in one op ("add 10 rows below this cell").
        // The wasm primitive inserts ONE row per call, so loop — silently
        // ignoring count is exactly how "10 added" became 1 in the live run.
        const count = Number.isInteger(op.count) && op.count > 0 ? Math.min(op.count, 200) : 1
        for (let i = 0; i < count; i++) {
          ctx.doc.insertTableRow(section, paragraph, control, row, below)
        }
        ctx.recordOp("AgentInsertTableRow", { section, paragraph, control, row, below, count })
        return { ok: true, extra: { row, below, inserted: count, ...dimsAfter() } }
      }
      if (verb === "delete_table_row") {
        const row = Number.isInteger(op.row) ? op.row : ctx.cellRowCol(target).row
        if (!Number.isInteger(row)) return { error: "delete_table_row needs a 'row' index (or a cell ref to derive it)" }
        ctx.doc.deleteTableRow(section, paragraph, control, row)
        ctx.recordOp("AgentDeleteTableRow", { section, paragraph, control, row })
        return { ok: true, extra: { row, ...dimsAfter() } }
      }
      if (verb === "insert_table_column") {
        const col = Number.isInteger(op.col) ? op.col : ctx.cellRowCol(target).col
        if (!Number.isInteger(col)) return { error: "insert_table_column needs a 'col' index (or a cell ref to derive it)" }
        const right = op.right === true
        const count = Number.isInteger(op.count) && op.count > 0 ? Math.min(op.count, 64) : 1
        for (let i = 0; i < count; i++) {
          ctx.doc.insertTableColumn(section, paragraph, control, col, right)
        }
        ctx.recordOp("AgentInsertTableColumn", { section, paragraph, control, col, right, count })
        return { ok: true, extra: { col, right, inserted: count, ...dimsAfter() } }
      }
      if (verb === "delete_table_column") {
        const col = Number.isInteger(op.col) ? op.col : ctx.cellRowCol(target).col
        if (!Number.isInteger(col)) return { error: "delete_table_column needs a 'col' index (or a cell ref to derive it)" }
        ctx.doc.deleteTableColumn(section, paragraph, control, col)
        ctx.recordOp("AgentDeleteTableColumn", { section, paragraph, control, col })
        return { ok: true, extra: { col, ...dimsAfter() } }
      }
      if (verb === "merge_cells") {
        const sr = Number.isInteger(op.start_row) ? op.start_row : null
        const sc = Number.isInteger(op.start_col) ? op.start_col : null
        const er = Number.isInteger(op.end_row) ? op.end_row : null
        const ec = Number.isInteger(op.end_col) ? op.end_col : null
        if ([sr, sc, er, ec].some((v) => v == null)) {
          return { error: "merge_cells requires integer start_row/start_col/end_row/end_col" }
        }
        ctx.doc.mergeTableCells(section, paragraph, control, sr, sc, er, ec)
        ctx.recordOp("AgentMergeCells", { section, paragraph, control, sr, sc, er, ec })
        return { ok: true, extra: { start_row: sr, start_col: sc, end_row: er, end_col: ec } }
      }
      // split_cell: split one cell into an n_rows × m_cols grid. Mirrors the NIF
      // SplitCell → split_table_cell_into_native(.., equal_row_height=true, merge_first=false).
      const cellRC = ctx.cellRowCol(target)
      const row = Number.isInteger(op.row) ? op.row : cellRC.row
      const col = Number.isInteger(op.col) ? op.col : cellRC.col
      if (!Number.isInteger(row) || !Number.isInteger(col)) {
        return { error: "split_cell needs 'row' and 'col' (or a cell ref to derive them)" }
      }
      const nRows = Number.isInteger(op.rows) ? op.rows : 1
      const mCols = Number.isInteger(op.cols) ? op.cols : 1
      if (nRows <= 0 || mCols <= 0 || (nRows === 1 && mCols === 1)) {
        return { error: "split_cell needs 'rows'/'cols' (the target sub-grid, e.g. rows:2 to split a cell into 2)" }
      }
      ctx.doc.splitTableCellInto(section, paragraph, control, row, col, nRows, mCols, true, false)
      ctx.recordOp("AgentSplitCell", { section, paragraph, control, row, col, nRows, mCols })
      return { ok: true, extra: { row, col, rows: nRows, cols: mCols } }
    } catch (error) {
      return { error: `${verb} failed: ${String((error && error.message) || error)}` }
    }
}

  // delete_node: remove a control (table / picture / shape / equation / note).
  // A table cell ref deletes the whole table; a raw control ref (picture/shape/…)
  // deletes that control. Mirrors the NIF delete_any_control: try each remover in
  // order — every native validates the control's variant up front and errors
  // BEFORE mutating, so a wrong-kind call is a no-op and we fall through.
const opDeleteNode: OpHandler = (ctx, op, ref, verb) => {
    const target = ctx.resolveTableTarget(ref)
    let section, paragraph, control
    if (target) {
      ;({ section, paragraph, control } = target)
    } else {
      control = ctx.rawControlIndex(op && op.ref)
      section = ref ? ref.section : 0
      paragraph = ref ? ref.paragraph : null
    }
    if (!Number.isInteger(control) || !Number.isInteger(paragraph)) {
      return { error: "delete_node requires a ref to a control (a table cell ref, or an element ref carrying a control index)" }
    }
    // Order mirrors the NIF: table → picture → shape → equation → footnote
    // (deleteFootnote also removes endnotes; the wasm has no separate endnote remover).
    const removers = [
      ["table", (s, p, c) => ctx.doc.deleteTableControl(s, p, c)],
      ["picture", (s, p, c) => ctx.doc.deletePictureControl(s, p, c)],
      ["shape", (s, p, c) => ctx.doc.deleteShapeControl(s, p, c)],
      ["equation", (s, p, c) => ctx.doc.deleteEquationControl(s, p, c)],
      ["note", (s, p, c) => ctx.doc.deleteFootnote(s, p, c)]
    ]
    let removed = null
    let lastErr = null
    for (const [kind, fn] of removers) {
      try {
        fn(section, paragraph, control)
        removed = kind
        break
      } catch (error) {
        lastErr = error
      }
    }
    if (!removed) {
      return { error: `delete_node failed: control ${control} at p${paragraph} is not a deletable node (${String((lastErr && lastErr.message) || lastErr)})` }
    }
    ctx.recordOp("AgentDeleteNode", { section, paragraph, control, removed })
    return { ok: true, extra: { removed } }
}

  // insert_picture: embed an image at the body/cell ref. The browser arm cannot
  // read the server filesystem, so it needs the image BYTES delivered inline as
  // base64 — the server producer (tools.ex browser_picture_producer) reads `src`
  // and attaches image_base64 + extension + natural pixel dims before the op gets
  // here. width/height are HWPUNIT (the placed size).
const opInsertPicture: OpHandler = (ctx, op, ref, verb) => {
    if (!ref) return { error: "insert_picture requires a ref {section,paragraph,offset}" }
    const b64 = op.image_base64 || op.imageBase64
    if (!b64) {
      return { error: "insert_picture on a viewed doc needs inline image bytes ('image_base64'); the server producer must attach them from 'src'" }
    }
    const width = Number.isInteger(op.width) ? op.width : null
    const height = Number.isInteger(op.height) ? op.height : null
    if (width == null || height == null) {
      return { error: "insert_picture requires integer 'width' and 'height' (HWPUNIT)" }
    }
    const offset = Number.isInteger(ref.offset) ? ref.offset : 0
    const extension = op.extension != null ? String(op.extension) : "png"
    const naturalW = Number.isInteger(op.natural_width_px) ? op.natural_width_px : 0
    const naturalH = Number.isInteger(op.natural_height_px) ? op.natural_height_px : 0
    const description = op.description != null ? String(op.description) : ""
    let bytes
    try {
      bytes = ctx.base64ToBytes(b64)
    } catch (error) {
      return { error: `insert_picture: invalid base64 image data (${String((error && error.message) || error)})` }
    }
    const cellPathJson = ref.cell && ref.cell.cellPath ? JSON.stringify(ref.cell.cellPath) : ""
    try {
      ctx.doc.insertPicture(ref.section, ref.paragraph, offset, cellPathJson, bytes, width, height, naturalW, naturalH, extension, description)
    } catch (error) {
      return { error: `insertPicture failed: ${String((error && error.message) || error)}` }
    }
    ctx.recordOp("AgentInsertPicture", { section: ref.section, para: ref.paragraph, offset, width, height, extension })
    return { ok: true, extra: { width, height, extension } }
}

/**
 * The chained registry factory. `define(verb, handler)` returns the builder, so
 * the whole vocabulary is one `OPS.define(...).define(...)` chain. `registry[verb]`
 * is the lookup `applyOneOp` uses; `define` is also the public plugin door.
 */
class OpRegistry {
  registry: Record<string, OpHandler> = Object.create(null)
  define(verb: string, handler: OpHandler): this { this.registry[verb] = handler; return this }
}

export const OPS = new OpRegistry()
  .define("replace_text", opReplaceText)
  .define("insert_text", opInsertText)
  .define("delete_range", opDeleteRange)
  .define("set_cell", opSetCell)
  .define("insert_equation", opInsertEquation)
  .define("insert_footnote", opInsertNote)
  .define("insert_endnote", opInsertNote)
  .define("insert_shape", opInsertShape)
  .define("set_columns", opSetColumns)
  .define("insert_paragraph", opInsertParagraph)
  .define("delete_paragraph", opDeleteParagraph)
  .define("split", opSplit)
  .define("merge", opMerge)
  .define("insert_table", opInsertTable)
  .define("insert_table_row", opTableStructure)
  .define("delete_table_row", opTableStructure)
  .define("insert_table_column", opTableStructure)
  .define("delete_table_column", opTableStructure)
  .define("merge_cells", opTableStructure)
  .define("split_cell", opTableStructure)
  .define("delete_node", opDeleteNode)
  .define("insert_picture", opInsertPicture)
