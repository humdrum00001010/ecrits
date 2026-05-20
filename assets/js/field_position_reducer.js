// rhwp DocumentEvent → fieldHighlight.position 결정적 변환 (pure module)
//
// rhwp WASM이 발행하는 이벤트 (또는 우리가 mutation 호출 시점에 합성하는
// 동일 shape의 이벤트)를 받아 각 필드의 position을 그 자리에서 갱신한다.
// 본 모듈은 IR/DOM/WASM에 의존하지 않는 **순수 함수**라 결정성 테스트가
// 가능하다.
//
// ─── 입력 ─────────────────────────────────────────────
//
// position 두 가지 shape (rhwp.js의 fieldHighlights[*].position):
//   A. text_field: {start: {sectionIndex, paragraphIndex, charOffset,
//                          parentParaIndex?, controlIndex?, cellIndex?,
//                          cellParaIndex?, row?, col?},
//                   end: {...}}
//   B. table_cell: 위 inner 객체와 동일 shape (top-level이 곧 위치)
//
// event 형태 (rhwp DocumentEvent + 우리 합성 정보 추가):
//   {type: "TextInserted",    sectionIndex, paragraphIndex, charOffset, len,
//                              cellPath?}
//   {type: "TextDeleted",     sectionIndex, paragraphIndex, charOffset, count,
//                              cellPath?}
//   {type: "ParagraphSplit",  sectionIndex, paragraphIndex, charOffset,
//                              cellPath?}
//   {type: "ParagraphMerged", sectionIndex, paragraphIndex, prevLen,
//                              cellPath?}
//   {type: "ParagraphDeleted",sectionIndex, paragraphIndex, cellPath?}
//   {type: "ParagraphInserted", sectionIndex, paragraphIndex, cellPath?}
//   {type: "TableRowInserted",  sectionIndex, parentParaIndex, controlIndex,
//                                atRow}
//   {type: "TableRowDeleted",   sectionIndex, parentParaIndex, controlIndex,
//                                atRow}
//   {type: "TableColumnInserted", sectionIndex, parentParaIndex, controlIndex,
//                                  atCol}
//   {type: "TableColumnDeleted",  sectionIndex, parentParaIndex, controlIndex,
//                                  atCol}
//   {type: "CellsMerged",  sectionIndex, parentParaIndex, controlIndex,
//                          startRow, startCol, endRow, endCol}
//   {type: "CellSplit",    sectionIndex, parentParaIndex, controlIndex,
//                          row, col}
//   {type: "TableDeleted", sectionIndex, parentParaIndex, controlIndex}
//
// `cellPath` 는 `[{controlIndex, cellIndex, cellParaIndex}]` 배열. 텍스트
// 편집 이벤트가 셀 안에서 일어났다면 동봉. 없으면 본문 편집.

export const INVALID = Symbol("rhwp.fieldPosition.INVALID")

// 단일 inner-position(점) 갱신. 셀 안/본문 모두를 다루며, 무효화되면 INVALID
// 반환. inner는 mutate 하지 않고 새 객체를 반환한다.
function applyEventToInner(inner, event) {
  if (!inner) return inner
  const sec = event.sectionIndex
  const inCell = inner.parentParaIndex != null && inner.controlIndex != null && inner.cellIndex != null

  switch (event.type) {
    case "TextInserted": {
      if (inner.sectionIndex !== sec) return inner
      // 셀-내 이벤트면 inner도 같은 셀이어야 영향.
      if (event.cellPath?.length) {
        if (!inCell) return inner
        const ep = event.cellPath[0]
        if (inner.parentParaIndex !== event.parentParaIndex
          || inner.controlIndex !== ep.controlIndex
          || inner.cellIndex !== ep.cellIndex) return inner
        if ((inner.cellParaIndex ?? 0) !== (ep.cellParaIndex ?? 0)) return inner
        if (inner.charOffset >= event.charOffset) {
          return {...inner, charOffset: inner.charOffset + event.len}
        }
        return inner
      }
      // 본문 이벤트. inner가 셀-내라면 영향 없음 (셀 내부 offset은 독립).
      if (inCell) return inner
      if (inner.paragraphIndex !== event.paragraphIndex) return inner
      if (inner.charOffset >= event.charOffset) {
        return {...inner, charOffset: inner.charOffset + event.len}
      }
      return inner
    }

    case "TextDeleted": {
      if (inner.sectionIndex !== sec) return inner
      const delStart = event.charOffset
      const delEnd = event.charOffset + event.count
      const fieldOff = inner.charOffset
      if (event.cellPath?.length) {
        if (!inCell) return inner
        const ep = event.cellPath[0]
        if (inner.parentParaIndex !== event.parentParaIndex
          || inner.controlIndex !== ep.controlIndex
          || inner.cellIndex !== ep.cellIndex) return inner
        if ((inner.cellParaIndex ?? 0) !== (ep.cellParaIndex ?? 0)) return inner
      } else {
        if (inCell) return inner
        if (inner.paragraphIndex !== event.paragraphIndex) return inner
      }
      if (fieldOff <= delStart) return inner
      if (fieldOff >= delEnd) return {...inner, charOffset: fieldOff - event.count}
      // 필드 anchor가 삭제 범위 안 → invalid.
      return INVALID
    }

    case "ParagraphSplit": {
      if (event.cellPath?.length) {
        // 셀-내 split — 셀 위치는 (parentParaIndex, controlIndex, cellIndex)
        // 유지하되 셀 안의 cellParaIndex가 시프트.
        if (!inCell) return inner
        const ep = event.cellPath[0]
        if (inner.sectionIndex !== sec
          || inner.parentParaIndex !== event.parentParaIndex
          || inner.controlIndex !== ep.controlIndex
          || inner.cellIndex !== ep.cellIndex) return inner
        const splitPara = ep.cellParaIndex ?? 0
        if ((inner.cellParaIndex ?? 0) < splitPara) return inner
        if ((inner.cellParaIndex ?? 0) > splitPara) {
          return {...inner, cellParaIndex: (inner.cellParaIndex ?? 0) + 1}
        }
        // 같은 para에서 split: charOffset에 따라.
        if (inner.charOffset < event.charOffset) return inner
        return {
          ...inner,
          cellParaIndex: (inner.cellParaIndex ?? 0) + 1,
          charOffset: inner.charOffset - event.charOffset,
        }
      }
      // 본문 split
      if (inner.sectionIndex !== sec) return inner
      const splitPara = event.paragraphIndex
      if (inCell) {
        // 표가 들어있는 본문 paragraph가 split되면 parentParaIndex가 시프트.
        // splitPara 위는 그대로, splitPara 이하/같음은... 본문 split은 char-offset
        // 기준이므로 table control이 splitPara에 남는지 splitPara+1로 가는지가
        // 표의 paragraph 내 위치(control)와 split 지점(offset)의 관계에 달림.
        // 우리 측은 어느 쪽인지 모르므로, parentParaIndex >= splitPara+1 인 경우만
        // +1 시프트 (보수적). 같은 para에 anchor된 표는 그대로 둔다 — rebuild로 보정.
        if (inner.parentParaIndex > splitPara) {
          return {...inner, parentParaIndex: inner.parentParaIndex + 1}
        }
        return inner
      }
      if (inner.paragraphIndex < splitPara) return inner
      if (inner.paragraphIndex > splitPara) {
        return {...inner, paragraphIndex: inner.paragraphIndex + 1}
      }
      if (inner.charOffset < event.charOffset) return inner
      return {
        ...inner,
        paragraphIndex: inner.paragraphIndex + 1,
        charOffset: inner.charOffset - event.charOffset,
      }
    }

    case "ParagraphMerged": {
      // para와 para+1 합쳐짐 → para+1의 fields는 para로 내려오고
      // charOffset += prevLen. para > para+1은 -1.
      // prevLen = para의 합쳐지기 전 길이 (이벤트에 동봉되어야 함).
      if (event.cellPath?.length) {
        if (!inCell) return inner
        const ep = event.cellPath[0]
        if (inner.sectionIndex !== sec
          || inner.parentParaIndex !== event.parentParaIndex
          || inner.controlIndex !== ep.controlIndex
          || inner.cellIndex !== ep.cellIndex) return inner
        const mergedPara = ep.cellParaIndex ?? 0
        const cpi = inner.cellParaIndex ?? 0
        if (cpi < mergedPara) return inner
        if (cpi === mergedPara) return inner
        if (cpi === mergedPara + 1) {
          return {...inner, cellParaIndex: mergedPara, charOffset: inner.charOffset + (event.prevLen ?? 0)}
        }
        return {...inner, cellParaIndex: cpi - 1}
      }
      if (inner.sectionIndex !== sec) return inner
      const mergedPara = event.paragraphIndex
      if (inCell) {
        // 본문에서 paragraph 합치기 — 표가 들어있는 paragraph도 시프트가 필요.
        // mergedPara+1 의 표는 mergedPara 로 옮겨오고 (parentParaIndex = mergedPara),
        // mergedPara 또는 그 위는 그대로. mergedPara+1 보다 큰 것은 -1.
        if (inner.parentParaIndex < mergedPara) return inner
        if (inner.parentParaIndex === mergedPara) return inner
        if (inner.parentParaIndex === mergedPara + 1) {
          return {...inner, parentParaIndex: mergedPara}
        }
        return {...inner, parentParaIndex: inner.parentParaIndex - 1}
      }
      if (inner.paragraphIndex < mergedPara) return inner
      if (inner.paragraphIndex === mergedPara) return inner
      if (inner.paragraphIndex === mergedPara + 1) {
        return {...inner, paragraphIndex: mergedPara, charOffset: inner.charOffset + (event.prevLen ?? 0)}
      }
      return {...inner, paragraphIndex: inner.paragraphIndex - 1}
    }

    case "ParagraphDeleted": {
      if (event.cellPath?.length) {
        if (!inCell) return inner
        const ep = event.cellPath[0]
        if (inner.sectionIndex !== sec
          || inner.parentParaIndex !== event.parentParaIndex
          || inner.controlIndex !== ep.controlIndex
          || inner.cellIndex !== ep.cellIndex) return inner
        const deletedPara = ep.cellParaIndex ?? 0
        const cpi = inner.cellParaIndex ?? 0
        if (cpi < deletedPara) return inner
        if (cpi === deletedPara) return INVALID
        return {...inner, cellParaIndex: cpi - 1}
      }
      if (inner.sectionIndex !== sec) return inner
      if (inCell) {
        // 본문 paragraph 삭제가 표를 포함한 paragraph라면 셀-내 fields도 모두 invalid.
        // 단, 일반적으로 ParagraphDeleted는 표가 들어있지 않은 plain para 대상.
        // 안전하게: parentParaIndex와 같으면 invalid, 외엔 시프트.
        if (inner.parentParaIndex === event.paragraphIndex) return INVALID
        if (inner.parentParaIndex > event.paragraphIndex) {
          return {...inner, parentParaIndex: inner.parentParaIndex - 1}
        }
        return inner
      }
      const deletedPara = event.paragraphIndex
      if (inner.paragraphIndex < deletedPara) return inner
      if (inner.paragraphIndex === deletedPara) return INVALID
      return {...inner, paragraphIndex: inner.paragraphIndex - 1}
    }

    case "ParagraphInserted": {
      if (event.cellPath?.length) {
        if (!inCell) return inner
        const ep = event.cellPath[0]
        if (inner.sectionIndex !== sec
          || inner.parentParaIndex !== event.parentParaIndex
          || inner.controlIndex !== ep.controlIndex
          || inner.cellIndex !== ep.cellIndex) return inner
        const insAt = ep.cellParaIndex ?? 0
        const cpi = inner.cellParaIndex ?? 0
        if (cpi < insAt) return inner
        return {...inner, cellParaIndex: cpi + 1}
      }
      if (inner.sectionIndex !== sec) return inner
      if (inCell) {
        if (inner.parentParaIndex >= event.paragraphIndex) {
          return {...inner, parentParaIndex: inner.parentParaIndex + 1}
        }
        return inner
      }
      if (inner.paragraphIndex < event.paragraphIndex) return inner
      return {...inner, paragraphIndex: inner.paragraphIndex + 1}
    }

    case "TableRowInserted": {
      if (!inCell) return inner
      if (inner.sectionIndex !== sec
        || inner.parentParaIndex !== event.parentParaIndex
        || inner.controlIndex !== event.controlIndex) return inner
      if ((inner.row ?? 0) >= event.atRow) {
        return {...inner, row: (inner.row ?? 0) + 1}
      }
      return inner
    }

    case "TableRowDeleted": {
      if (!inCell) return inner
      if (inner.sectionIndex !== sec
        || inner.parentParaIndex !== event.parentParaIndex
        || inner.controlIndex !== event.controlIndex) return inner
      const row = inner.row ?? 0
      if (row === event.atRow) return INVALID
      if (row > event.atRow) return {...inner, row: row - 1}
      return inner
    }

    case "TableColumnInserted": {
      if (!inCell) return inner
      if (inner.sectionIndex !== sec
        || inner.parentParaIndex !== event.parentParaIndex
        || inner.controlIndex !== event.controlIndex) return inner
      if ((inner.col ?? 0) >= event.atCol) {
        return {...inner, col: (inner.col ?? 0) + 1}
      }
      return inner
    }

    case "TableColumnDeleted": {
      if (!inCell) return inner
      if (inner.sectionIndex !== sec
        || inner.parentParaIndex !== event.parentParaIndex
        || inner.controlIndex !== event.controlIndex) return inner
      const col = inner.col ?? 0
      if (col === event.atCol) return INVALID
      if (col > event.atCol) return {...inner, col: col - 1}
      return inner
    }

    case "CellsMerged": {
      // 병합 범위 안의 셀들 — top-left (startRow, startCol) 셀로 통합. 그 외는 사라짐.
      if (!inCell) return inner
      if (inner.sectionIndex !== sec
        || inner.parentParaIndex !== event.parentParaIndex
        || inner.controlIndex !== event.controlIndex) return inner
      const row = inner.row ?? 0
      const col = inner.col ?? 0
      const inRange = row >= event.startRow && row <= event.endRow
        && col >= event.startCol && col <= event.endCol
      if (!inRange) return inner
      if (row === event.startRow && col === event.startCol) return inner
      // 합쳐져 사라진 셀 — 필드 무효.
      return INVALID
    }

    case "CellSplit": {
      // 단일 셀이 여러 sub-cell로 split. 기존 콘텐츠는 top-left sub-cell로 옮겨가는
      // rhwp 동작을 가정 — (row, col)이 그 자리에 그대로 있으면 valid, 외엔 영향 없음
      // (other cells get inserted around it). 보수적으로 그대로 유지.
      return inner
    }

    case "TableDeleted": {
      if (!inCell) return inner
      if (inner.sectionIndex !== sec
        || inner.parentParaIndex !== event.parentParaIndex
        || inner.controlIndex !== event.controlIndex) return inner
      return INVALID
    }

    default:
      return inner
  }
}

// 전체 position(text_field: {start, end} 또는 table_cell: 단일 inner)을 갱신.
export function applyEvent(position, event) {
  if (!position) return position
  if (position.start && position.end) {
    const s = applyEventToInner(position.start, event)
    const e = applyEventToInner(position.end, event)
    if (s === INVALID || e === INVALID) return INVALID
    if (s === position.start && e === position.end) return position
    return {start: s, end: e}
  }
  return applyEventToInner(position, event)
}

export function applyEvents(position, events) {
  let p = position
  for (const ev of events) {
    p = applyEvent(p, ev)
    if (p === INVALID) return INVALID
  }
  return p
}
