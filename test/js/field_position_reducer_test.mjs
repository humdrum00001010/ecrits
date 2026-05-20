import test from "node:test"
import assert from "node:assert/strict"

import {applyEvent, applyEvents, INVALID} from "../../assets/js/field_position_reducer.js"

// ─── 본문 텍스트 편집 ─────────────────────────────────────

test("TextInserted in same para before field shifts charOffset", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 3, charOffset: 10}
  const ev = {type: "TextInserted", sectionIndex: 0, paragraphIndex: 3, charOffset: 5, len: 2}
  assert.deepEqual(applyEvent(pos, ev), {sectionIndex: 0, paragraphIndex: 3, charOffset: 12})
})

test("TextInserted at exactly field.offset shifts (insert-before semantics)", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 3, charOffset: 10}
  const ev = {type: "TextInserted", sectionIndex: 0, paragraphIndex: 3, charOffset: 10, len: 1}
  assert.equal(applyEvent(pos, ev).charOffset, 11)
})

test("TextInserted after field is no-op", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 3, charOffset: 10}
  const ev = {type: "TextInserted", sectionIndex: 0, paragraphIndex: 3, charOffset: 50, len: 3}
  assert.equal(applyEvent(pos, ev), pos)
})

test("TextInserted in different para is no-op", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 3, charOffset: 10}
  const ev = {type: "TextInserted", sectionIndex: 0, paragraphIndex: 4, charOffset: 0, len: 5}
  assert.equal(applyEvent(pos, ev), pos)
})

test("TextDeleted entirely before field shifts back", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 3, charOffset: 10}
  const ev = {type: "TextDeleted", sectionIndex: 0, paragraphIndex: 3, charOffset: 2, count: 3}
  assert.equal(applyEvent(pos, ev).charOffset, 7)
})

test("TextDeleted including field anchor invalidates", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 3, charOffset: 10}
  const ev = {type: "TextDeleted", sectionIndex: 0, paragraphIndex: 3, charOffset: 8, count: 5}
  assert.equal(applyEvent(pos, ev), INVALID)
})

test("Range field deleted entirely is INVALID", () => {
  const pos = {start: {sectionIndex: 0, paragraphIndex: 3, charOffset: 10},
               end:   {sectionIndex: 0, paragraphIndex: 3, charOffset: 18}}
  const ev = {type: "TextDeleted", sectionIndex: 0, paragraphIndex: 3, charOffset: 5, count: 30}
  assert.equal(applyEvent(pos, ev), INVALID)
})

// ─── 문단 split / merge / delete / insert ─────────────────

test("ParagraphSplit before field: same para, charOffset before split → unchanged", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 3, charOffset: 5}
  const ev = {type: "ParagraphSplit", sectionIndex: 0, paragraphIndex: 3, charOffset: 10}
  assert.deepEqual(applyEvent(pos, ev), pos)
})

test("ParagraphSplit after field: same para, charOffset after split → moves to next para", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 3, charOffset: 20}
  const ev = {type: "ParagraphSplit", sectionIndex: 0, paragraphIndex: 3, charOffset: 10}
  assert.deepEqual(applyEvent(pos, ev), {sectionIndex: 0, paragraphIndex: 4, charOffset: 10})
})

test("ParagraphSplit in earlier para shifts all later paras +1", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 5, charOffset: 7}
  const ev = {type: "ParagraphSplit", sectionIndex: 0, paragraphIndex: 2, charOffset: 0}
  assert.deepEqual(applyEvent(pos, ev), {sectionIndex: 0, paragraphIndex: 6, charOffset: 7})
})

test("ParagraphMerged: para+1 fields move to para with offset += prevLen", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 4, charOffset: 3}
  const ev = {type: "ParagraphMerged", sectionIndex: 0, paragraphIndex: 3, prevLen: 20}
  assert.deepEqual(applyEvent(pos, ev), {sectionIndex: 0, paragraphIndex: 3, charOffset: 23})
})

test("ParagraphDeleted on the field's para invalidates", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 3, charOffset: 10}
  const ev = {type: "ParagraphDeleted", sectionIndex: 0, paragraphIndex: 3}
  assert.equal(applyEvent(pos, ev), INVALID)
})

test("ParagraphDeleted on earlier para shifts later -1", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 5, charOffset: 0}
  const ev = {type: "ParagraphDeleted", sectionIndex: 0, paragraphIndex: 2}
  assert.deepEqual(applyEvent(pos, ev), {sectionIndex: 0, paragraphIndex: 4, charOffset: 0})
})

test("ParagraphInserted before field shifts +1", () => {
  const pos = {sectionIndex: 0, paragraphIndex: 3, charOffset: 0}
  const ev = {type: "ParagraphInserted", sectionIndex: 0, paragraphIndex: 3}
  assert.deepEqual(applyEvent(pos, ev), {sectionIndex: 0, paragraphIndex: 4, charOffset: 0})
})

// ─── 표 셀: row/col insert/delete (hard cases) ───────────

const cellPos = (row, col, opts = {}) => ({
  sectionIndex: 0, parentParaIndex: 16, controlIndex: 0,
  cellIndex: opts.cellIndex ?? (row * 4 + col), cellParaIndex: 0,
  row, col, charOffset: opts.off ?? 0,
})

test("TableRowInserted at row 1 shifts row 1 and 2 to 2 and 3", () => {
  const a = cellPos(0, 0)
  const b = cellPos(1, 2)
  const c = cellPos(2, 1)
  const ev = {type: "TableRowInserted", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, atRow: 1}
  assert.equal(applyEvent(a, ev).row, 0)
  assert.equal(applyEvent(b, ev).row, 2)
  assert.equal(applyEvent(c, ev).row, 3)
})

test("TableRowDeleted at row 1: row 1 fields INVALID, row 2 shifts to 1", () => {
  const row1Field = cellPos(1, 0)
  const row2Field = cellPos(2, 3)
  const ev = {type: "TableRowDeleted", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, atRow: 1}
  assert.equal(applyEvent(row1Field, ev), INVALID)
  assert.equal(applyEvent(row2Field, ev).row, 1)
})

test("TableColumnInserted at col 0 shifts every field's col +1", () => {
  const f = cellPos(2, 1)
  const ev = {type: "TableColumnInserted", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, atCol: 0}
  assert.equal(applyEvent(f, ev).col, 2)
})

test("TableColumnDeleted at col == field.col invalidates", () => {
  const f = cellPos(2, 3)
  const ev = {type: "TableColumnDeleted", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, atCol: 3}
  assert.equal(applyEvent(f, ev), INVALID)
})

test("TableRowInserted ignores fields in a different table (different controlIndex)", () => {
  const f = cellPos(2, 1)
  const ev = {type: "TableRowInserted", sectionIndex: 0, parentParaIndex: 16, controlIndex: 2, atRow: 0}
  assert.equal(applyEvent(f, ev), f)
})

test("TableDeleted invalidates every field of that table", () => {
  const f = cellPos(2, 1)
  const ev = {type: "TableDeleted", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0}
  assert.equal(applyEvent(f, ev), INVALID)
})

// ─── 셀 병합/분할 ────────────────────────────────────────

test("CellsMerged top-left survives, others invalidate", () => {
  const tl = cellPos(1, 1)
  const tr = cellPos(1, 2)
  const bl = cellPos(2, 1)
  const ev = {type: "CellsMerged", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0,
              startRow: 1, startCol: 1, endRow: 2, endCol: 2}
  assert.deepEqual(applyEvent(tl, ev), tl)
  assert.equal(applyEvent(tr, ev), INVALID)
  assert.equal(applyEvent(bl, ev), INVALID)
})

test("CellsMerged ignores fields outside merge range", () => {
  const outside = cellPos(0, 0)
  const ev = {type: "CellsMerged", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0,
              startRow: 1, startCol: 1, endRow: 2, endCol: 2}
  assert.deepEqual(applyEvent(outside, ev), outside)
})

// ─── 셀 안 텍스트 편집 ───────────────────────────────────

test("TextInserted in cell shifts only same-cell-para fields", () => {
  const f = {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 11,
             cellParaIndex: 0, row: 2, col: 1, charOffset: 5}
  const ev = {type: "TextInserted", sectionIndex: 0, parentParaIndex: 16,
              cellPath: [{controlIndex: 0, cellIndex: 11, cellParaIndex: 0}],
              charOffset: 2, len: 3}
  assert.equal(applyEvent(f, ev).charOffset, 8)
})

test("Body TextInserted does NOT affect cell field charOffset", () => {
  const f = {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 11,
             cellParaIndex: 0, row: 2, col: 1, charOffset: 5}
  const ev = {type: "TextInserted", sectionIndex: 0, paragraphIndex: 16, charOffset: 0, len: 3}
  assert.equal(applyEvent(f, ev), f)
})

test("ParagraphInserted before the table shifts cell field's parentParaIndex", () => {
  const f = {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 11,
             cellParaIndex: 0, row: 2, col: 1, charOffset: 0}
  const ev = {type: "ParagraphInserted", sectionIndex: 0, paragraphIndex: 5}
  assert.equal(applyEvent(f, ev).parentParaIndex, 17)
})

test("ParagraphDeleted before the table shifts parentParaIndex -1", () => {
  const f = {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 11,
             cellParaIndex: 0, row: 2, col: 1, charOffset: 0}
  const ev = {type: "ParagraphDeleted", sectionIndex: 0, paragraphIndex: 5}
  assert.equal(applyEvent(f, ev).parentParaIndex, 15)
})

test("body ParagraphMerged before the table shifts cell field's parentParaIndex -1", () => {
  // 본문에서 paragraph 11 와 paragraph 12가 합쳐짐. 표가 들어있는 parentParaIndex=16
  // 의 셀 필드는 parentParaIndex 15로 시프트해야 한다.
  const f = {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 11,
             cellParaIndex: 0, row: 2, col: 1, charOffset: 0}
  const ev = {type: "ParagraphMerged", sectionIndex: 0, paragraphIndex: 11, prevLen: 5}
  assert.equal(applyEvent(f, ev).parentParaIndex, 15)
})

test("body ParagraphMerged on the absorbing para leaves cell field intact", () => {
  // mergedPara 또는 그 위에 있는 표는 영향 없음.
  const f = {sectionIndex: 0, parentParaIndex: 5, controlIndex: 0, cellIndex: 0,
             cellParaIndex: 0, row: 0, col: 0, charOffset: 0}
  const ev = {type: "ParagraphMerged", sectionIndex: 0, paragraphIndex: 11, prevLen: 5}
  assert.deepEqual(applyEvent(f, ev), f)
})

test("body ParagraphSplit before the table shifts cell field's parentParaIndex +1", () => {
  const f = {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 11,
             cellParaIndex: 0, row: 2, col: 1, charOffset: 0}
  const ev = {type: "ParagraphSplit", sectionIndex: 0, paragraphIndex: 5, charOffset: 3}
  assert.equal(applyEvent(f, ev).parentParaIndex, 17)
})

test("body ParagraphMerged does NOT invalidate body fields in the absorbed paragraph", () => {
  // 사용자가 본문 line 위를 지웠을 때 라인 위에 있던 매칭(start_date 등)이
  // 통째로 invalidate 되는 것을 막는 회귀 테스트.
  const f = {sectionIndex: 0, paragraphIndex: 12, charOffset: 12}
  const ev = {type: "ParagraphMerged", sectionIndex: 0, paragraphIndex: 11, prevLen: 0}
  const r = applyEvent(f, ev)
  assert.notEqual(r, INVALID)
  assert.deepEqual(r, {sectionIndex: 0, paragraphIndex: 11, charOffset: 12})
})

test("ParagraphDeleted on the table's paragraph invalidates cell fields", () => {
  const f = {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 11,
             cellParaIndex: 0, row: 2, col: 1, charOffset: 0}
  const ev = {type: "ParagraphDeleted", sectionIndex: 0, paragraphIndex: 16}
  assert.equal(applyEvent(f, ev), INVALID)
})

// ─── 결정성: 동일 이벤트 시퀀스 두 번 적용 결과가 일치 ──────

test("determinism: applying the same sequence twice yields equal output", () => {
  const seq = [
    {type: "TextInserted", sectionIndex: 0, paragraphIndex: 3, charOffset: 2, len: 4},
    {type: "ParagraphSplit", sectionIndex: 0, paragraphIndex: 3, charOffset: 5},
    {type: "TableRowInserted", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, atRow: 0},
    {type: "TextDeleted", sectionIndex: 0, paragraphIndex: 4, charOffset: 0, count: 2},
  ]
  const start = {sectionIndex: 0, paragraphIndex: 3, charOffset: 10}
  const a = applyEvents(start, seq)
  const b = applyEvents(start, seq)
  assert.deepEqual(a, b)
})

test("determinism: range field with cell-row delete", () => {
  const start = {
    start: {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 11,
            cellParaIndex: 0, row: 2, col: 1, charOffset: 0},
    end:   {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 11,
            cellParaIndex: 0, row: 2, col: 1, charOffset: 8},
  }
  const seq = [
    {type: "TableRowInserted", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, atRow: 0},
    {type: "TableRowDeleted",  sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, atRow: 0},
  ]
  // 행 추가 후 해당 추가된 행 즉시 삭제 — 필드는 원래 row 2 → 3 → 2로 복귀.
  const r = applyEvents(start, seq)
  assert.notEqual(r, INVALID)
  assert.equal(r.start.row, 2)
  assert.equal(r.end.row, 2)
})

test("determinism: delete the very row containing the field invalidates", () => {
  const start = {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 11,
                 cellParaIndex: 0, row: 2, col: 1, charOffset: 0}
  const r = applyEvent(start, {type: "TableRowDeleted", sectionIndex: 0,
                               parentParaIndex: 16, controlIndex: 0, atRow: 2})
  assert.equal(r, INVALID)
})

test("hard case: delete column under field, then delete row above; field stays gone", () => {
  const start = {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 11,
                 cellParaIndex: 0, row: 2, col: 3, charOffset: 0}
  // 1) 다른 column 삭제 (col=0)
  // 2) row 위쪽 삭제 (atRow=0)
  // → 필드 row: 2 → 1, col: 3 → 2.
  const seq = [
    {type: "TableColumnDeleted", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, atCol: 0},
    {type: "TableRowDeleted",   sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, atRow: 0},
  ]
  const r = applyEvents(start, seq)
  assert.deepEqual({row: r.row, col: r.col}, {row: 1, col: 2})
})

test("hard case: merge cells then delete top-left row also invalidates the merged cell field", () => {
  const tl = {sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, cellIndex: 5,
              cellParaIndex: 0, row: 1, col: 1, charOffset: 0}
  const seq = [
    {type: "CellsMerged", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0,
     startRow: 1, startCol: 1, endRow: 2, endCol: 2},
    {type: "TableRowDeleted", sectionIndex: 0, parentParaIndex: 16, controlIndex: 0, atRow: 1},
  ]
  const r = applyEvents(tl, seq)
  assert.equal(r, INVALID)
})
