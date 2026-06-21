import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { MarkdownEditor } from "./markdown_editor.js"

function editor(value: string, start: number, end = start) {
  const el = {
    value,
    selectionStart: start,
    selectionEnd: end,
    setSelectionRange(selectionStart: number, selectionEnd: number) {
      this.selectionStart = selectionStart
      this.selectionEnd = selectionEnd
    },
  }

  return {
    instance: {
      ...MarkdownEditor,
      el,
      userEdited: false,
      syncCount: 0,
      sync() {
        this.syncCount += 1
      },
    } as any,
    el,
  }
}

describe("MarkdownEditor toolbar wrapping", () => {
  it("removes surrounding bold markers for an already-bold selection", () => {
    const { instance, el } = editor("a **bold** z", 4, 8)

    instance.wrapSelection("**", "**", "bold")

    assert.equal(el.value, "a bold z")
    assert.equal(el.selectionStart, 2)
    assert.equal(el.selectionEnd, 6)
    assert.equal(instance.userEdited, true)
    assert.equal(instance.syncCount, 1)
  })

  it("removes selected bold markers when the selection includes them", () => {
    const { instance, el } = editor("a **bold** z", 2, 10)

    instance.wrapSelection("**", "**", "bold")

    assert.equal(el.value, "a bold z")
    assert.equal(el.selectionStart, 2)
    assert.equal(el.selectionEnd, 6)
  })

  it("adds bold markers when the selection is plain", () => {
    const { instance, el } = editor("a bold z", 2, 6)

    instance.wrapSelection("**", "**", "bold")

    assert.equal(el.value, "a **bold** z")
    assert.equal(el.selectionStart, 4)
    assert.equal(el.selectionEnd, 8)
  })
})
