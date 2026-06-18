import type { OfficeElement } from "./wasm_office_ops.ts"

export type OfficeNearby = {
  before: number
  after: number
  row: boolean
  column: boolean
  headers: boolean
}

type TableContext = {
  tableRead?: (refs: string[], nearby: OfficeNearby) => Record<string, any> | null
  tableNearby?: (
    elements: OfficeElement[],
    target: OfficeElement,
    nearby: OfficeNearby,
  ) => Record<string, any>
  tableKey?: (ref: string) => string | null
}

export function normalizeOfficeNearby(input: any): OfficeNearby {
  const n = input && typeof input === "object" ? input : {}
  const clamp = (value: any, fallback: number) => {
    const x = Number(value)
    return Number.isFinite(x) ? Math.max(0, Math.min(10, Math.floor(x))) : fallback
  }
  return {
    before: clamp(n.before, 2),
    after: clamp(n.after, 2),
    row: n.row !== false,
    column: n.column === true,
    headers: n.headers !== false,
  }
}

export function officeReadRefCandidates(ref: string): string[] {
  const s = String(ref || "")
  const refs = [s]
  const run = /^(.*\/p\d+)\/r\d+$/.exec(s)
  if (run) refs.push(run[1])
  const shapeTextChild = /^(page\[[^\]]+\]\/shape\[[^\]]+\])(?:\/p\d+(?:\/r\d+)?)?$/.exec(s)
  if (shapeTextChild) refs.push(shapeTextChild[1])
  return Array.from(new Set(refs.filter(Boolean)))
}

export function readOfficeElements(
  elements: OfficeElement[],
  refInput: any,
  nearbyInput?: any,
  tableContext: TableContext = {},
): Record<string, any> {
  const ref = String(refInput || "")
  const nearby = normalizeOfficeNearby(nearbyInput)
  const matches = elements.filter((el) => el.type !== "run")
  const candidates = officeReadRefCandidates(ref)
  const hit = findOfficeReadMatch(matches, candidates)

  if (!hit) {
    const table = tableContext.tableRead ? tableContext.tableRead(candidates, nearby) : null
    return table && !table.error ? { ref, ...table } : { ref, error: "ref not found" }
  }

  const idx = hit.idx
  const resolvedRef = hit.ref
  const target = { ...matches[idx] }

  if (slideElement(target)) {
    return slideRead(matches, resolvedRef, ref, target)
  }

  const start = Math.max(0, idx - nearby.before)
  const win = matches.slice(start, idx + nearby.after + 1).map((el) => ({ ...el }))
  const out: Record<string, any> = {
    ref,
    target,
    elements: win,
    text: target.text || "",
  }
  if (resolvedRef !== ref) out.resolved_ref = resolvedRef

  const tableKey = tableContext.tableKey ? tableContext.tableKey(resolvedRef) : null
  if ((target.type === "cell" || tableKey) && tableContext.tableNearby) {
    Object.assign(out, tableContext.tableNearby(matches, target, nearby))
  }

  return out
}

function findOfficeReadMatch(elements: OfficeElement[], refs: string[]) {
  for (const ref of refs) {
    const idx = elements.findIndex((el) => el.ref === ref)
    if (idx >= 0) return { ref, idx }
  }
  return null
}

function slideElement(el: OfficeElement) {
  return el.type === "slide" || el.type === "page" || /^page\[[^\]]+\]$/.test(el.ref)
}

function slideRead(
  elements: OfficeElement[],
  slideRef: string,
  refString: string,
  target: OfficeElement,
) {
  const prefix = slideRef + "/"
  const leaves = elements.filter((el) =>
    el.ref.startsWith(prefix) &&
    ["text_frame", "cell", "shape"].includes(el.type) &&
    String(el.text || "") !== ""
  )
  const text = leaves.map((el) => el.text || "").join("\n")
  const out: Record<string, any> = {
    ref: refString,
    target: { ...target, text },
    elements: leaves.map((el) => ({ ...el })),
    text,
  }
  if (slideRef !== refString) out.resolved_ref = slideRef
  return out
}
