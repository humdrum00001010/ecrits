import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { loadEditorSurfaceColocatedHook } from "./support/editor_surface_colocated.ts"

const {installEditorZoom} = await loadEditorSurfaceColocatedHook()

function zoomHarness() {
  let wheelListener: ((event: any) => void) | null = null
  const frames: Array<(time: number) => void> = []
  let frameId = 0

  const scroller: any = {
    clientHeight: 500,
    clientWidth: 600,
    isConnected: true,
    parentElement: null,
    scrollHeight: 2000,
    scrollLeft: 0,
    scrollTop: 500,
    scrollWidth: 600,
    getBoundingClientRect: () => ({left: 0, top: 0}),
  }
  const content: any = {
    dataset: {},
    isConnected: true,
    offsetHeight: 1000,
    offsetWidth: 600,
    parentElement: scroller,
    style: {},
    closest: (selector: string) => selector === "[data-editor-zoomable]" ? content : null,
  }
  const ownerDocument: any = {documentElement: {}, scrollingElement: null}
  const host: any = {
    DOMMatrixReadOnly: class {
      a: number

      constructor(transform: string) {
        this.a = Number.parseFloat(transform.match(/scale\(([^)]+)\)/)?.[1] || "1")
      }
    },
    document: ownerDocument,
    performance: {now: () => 0},
    getComputedStyle(element: any) {
      if (element === content) return {transform: element.style.transform || "none"}
      return {overflow: "auto", overflowX: "auto", overflowY: "auto"}
    },
    requestAnimationFrame(callback: (time: number) => void) {
      frames.push(callback)
      frameId += 1
      return frameId
    },
  }
  ownerDocument.defaultView = host
  const root: any = {
    ownerDocument,
    contains: (element: any) => element === content,
    addEventListener(type: string, listener: (event: any) => void, options: any) {
      assert.equal(type, "wheel")
      assert.deepEqual(options, {passive: false, capture: true})
      wheelListener = listener
    },
    removeEventListener() {},
  }

  installEditorZoom(root)

  const wheel = (deltaY: number) => {
    let prevented = false
    wheelListener?.({
      clientX: 300,
      clientY: 250,
      ctrlKey: true,
      deltaY,
      target: content,
      preventDefault: () => prevented = true,
    })

    for (let time = 16; frames.length > 0 && time < 2000; time += 16) {
      frames.shift()?.(time)
    }
    return prevented
  }

  return {content, scroller, wheel}
}

describe("editor zoom", () => {
  it("zooms out and back in while restoring footprint and pointer anchor", () => {
    const {content, scroller, wheel} = zoomHarness()

    assert.equal(wheel(100), true)
    assert.equal(content.dataset.editorZoom, "0.5556")
    assert.equal(content.style.transform, "scale(0.5556)")
    assert.ok(Math.abs(Number.parseFloat(content.style.marginBottom) + 444.44) < 0.01)
    assert.ok(Math.abs(Number.parseFloat(content.style.marginLeft) - 133.33) < 0.01)
    assert.ok(Math.abs(Number.parseFloat(content.style.marginRight) + 133.33) < 0.01)
    assert.ok(Math.abs(scroller.scrollTop - 166.7) < 0.1)

    assert.equal(wheel(-100), true)
    assert.equal(content.dataset.editorZoom, "1")
    assert.equal(content.style.transform, "scale(1)")
    assert.equal(content.style.marginBottom, "")
    assert.equal(content.style.marginLeft, "")
    assert.equal(content.style.marginRight, "")
    assert.ok(Math.abs(scroller.scrollTop - 500) < 0.1)
  })
})
