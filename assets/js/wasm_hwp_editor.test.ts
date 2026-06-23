import { describe, it } from "node:test"
import assert from "node:assert/strict"

const documentStub: any = {
  body: { dataset: {} },
  addEventListener() {},
  removeEventListener() {},
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

const { WasmHwpEditor } = await import("./wasm_hwp_editor.ts")

describe("WasmHwpEditor preview patch viewport", () => {
  it("patches preview text without scrolling or focusing the viewer to the changed range", () => {
    let inserted = ""
    let rendered = 0
    let highlighted = 0
    let scheduled = 0

    const editor = {
      ...WasmHwpEditor,
      mirror: false,
      previewPatchCursor: { section: 0, paragraph: 8, offset: 0 },
      _elementsCache: {},
      rendered: { clear() {} },
      el: { scrollTop: 420 },
      doc: {
        insertText(_section: number, _paragraph: number, _offset: number, text: string) {
          inserted += text
        },
        splitParagraph() {
          throw new Error("unexpected split")
        },
      },
      renderVisiblePages() {
        rendered += 1
      },
      renderPreviewPatchHighlight() {
        highlighted += 1
      },
      scrollPreviewPatchIntoView() {
        throw new Error("preview patch must not move the viewer viewport")
      },
      scheduleSnapshot() {
        scheduled += 1
      },
    } as any

    editor.patchPreviewSuffixIntoDoc("AGENT_TOKEN")

    assert.equal(inserted, "AGENT_TOKEN")
    assert.equal(editor.previewPatchCursor.offset, "AGENT_TOKEN".length)
    assert.equal(editor.el.scrollTop, 420)
    assert.equal(rendered, 1)
    assert.equal(highlighted, 1)
    assert.equal(scheduled, 1)
  })
})
