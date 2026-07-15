import { describe, it } from "node:test"
import assert from "node:assert/strict"
import { hwpColocatedSource, loadHwpColocatedHook } from "./support/hwp_colocated.ts"

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

;(globalThis as any).document = (globalThis as any).document || documentStub
;(globalThis as any).window = (globalThis as any).window || {}

const { WasmHwpEditor, HWP_VIEW_STATE_KEYS, installHwpViewState, unexpectedHwpLooseOwnStateKeys } =
  await loadHwpColocatedHook()

function fakeCanvas(width = 100, height = 100) {
  const ctx = {
    fillStyle: "",
    fillRect() {},
    clearRect() {},
    save() {},
    restore() {},
    strokeRect() {},
    setLineDash() {},
  }
  return {
    width,
    height,
    dataset: {},
    style: {},
    getContext: () => ctx,
    getBoundingClientRect: () => ({ left: 0, top: 0, right: width, bottom: height, width, height }),
  } as any
}

function fakeHwpSection(index: number, canvas = fakeCanvas(), overlay = fakeCanvas()) {
  return {
    dataset: { pageIndex: String(index) },
    offsetTop: index * 1000,
    querySelector(selector: string) {
      if (selector.includes("ehwp-canvas")) return canvas
      if (selector.includes("ehwp-caret-overlay")) return overlay
      return null
    },
    getBoundingClientRect: () => ({ height: 100, width: 100, top: 0, bottom: 100 }),
  } as any
}

function directHookStateAssignments() {
  const assigned = new Set<string>()

  for (const match of hwpColocatedSource().matchAll(/\bthis\.([A-Za-z_$][A-Za-z0-9_$]*)\s*=/g)) {
    assigned.add(match[1])
  }

  return [...assigned].sort()
}

function withMountedHook(fn: (editor: any) => void) {
  const win = (globalThis as any).window
  const oldWindowAdd = win.addEventListener
  const oldWindowRemove = win.removeEventListener
  const oldIntersectionObserver = (globalThis as any).IntersectionObserver

  win.addEventListener = win.addEventListener || (() => {})
  win.removeEventListener = win.removeEventListener || (() => {})
  ;(globalThis as any).IntersectionObserver = class {
    observe() {}
    disconnect() {}
  }

  const imeProxy = {
    addEventListener() {},
    removeEventListener() {},
  }
  const pageStack = {}
  const editor = Object.create(WasmHwpEditor)
  editor.el = {
    dataset: {
      canvasState: JSON.stringify({
        documentId: "hwp-state-guard-doc",
        localDocumentFormat: "hwp",
        editorMirror: true,
      }),
    },
    classList: { toggle() {} },
    addEventListener() {},
    removeEventListener() {},
    querySelector(selector: string) {
      if (selector === "[data-role='local-hwp-ime-proxy']") return imeProxy
      if (selector === "[data-role='local-hwp-pages']") return pageStack
      return null
    },
  }
  editor.handleEvent = () => {}

  try {
    editor.mounted()
    fn(editor)
  } finally {
    if (editor.blink) clearInterval(editor.blink)
    if (oldWindowAdd) win.addEventListener = oldWindowAdd
    else delete win.addEventListener
    if (oldWindowRemove) win.removeEventListener = oldWindowRemove
    else delete win.removeEventListener
    if (oldIntersectionObserver) {
      ;(globalThis as any).IntersectionObserver = oldIntersectionObserver
    } else {
      delete (globalThis as any).IntersectionObserver
    }
  }
}

function hwpViewStateEditor() {
  const editor = Object.create(WasmHwpEditor)
  installHwpViewState(editor)
  return editor
}

describe("WasmHwpEditor view_state carrier boundary", () => {
  it("keeps every direct HWP hook state write in the view_state key list", () => {
    assert.deepEqual(directHookStateAssignments(), [...HWP_VIEW_STATE_KEYS].sort())
  })

  it("does not create loose mutable hook state during mount and keyboard binding", () => {
    withMountedHook((editor) => {
      const allowedFrameworkKeys = ["el", "handleEvent"]
      assert.deepEqual(unexpectedHwpLooseOwnStateKeys(editor, allowedFrameworkKeys), [])

      for (const key of HWP_VIEW_STATE_KEYS) {
        const descriptor = Object.getOwnPropertyDescriptor(editor, key)
        assert.equal(typeof descriptor?.get, "function", `${key} must read through view_state`)
        assert.equal(typeof descriptor?.set, "function", `${key} must write through view_state`)
        assert.equal("value" in (descriptor || {}), false, `${key} must not be loose own data`)
      }

      assert.equal(editor.view_state.shortcutActive, false)
      assert.equal(editor.view_state.scrollPositions instanceof Map, true)
    })
  })
})

describe("WasmHwpEditor document load coalescing", () => {
  it("reuses the in-flight load for the same bytes URL", async () => {
    const editor = Object.create(WasmHwpEditor)
    let releaseLoad: (() => void) | undefined
    const inFlight = new Promise<void>((resolve) => {
      releaseLoad = resolve
    })
    const oldFetch = (globalThis as any).fetch
    let fetchCalls = 0

    ;(globalThis as any).fetch = () => {
      fetchCalls += 1
      throw new Error("a coalesced load must not fetch again")
    }

    editor.doc = null
    editor.loadedUrl = null
    editor._loadingUrl = "/bytes/same.hwp"
    editor._loadInFlight = inFlight

    try {
      const reused = editor.loadDocument({ url: "/bytes/same.hwp" })
      await Promise.resolve()
      assert.equal(fetchCalls, 0)
      releaseLoad?.()
      await reused
      assert.equal(fetchCalls, 0)
    } finally {
      if (oldFetch) (globalThis as any).fetch = oldFetch
      else delete (globalThis as any).fetch
    }
  })
})

describe("WasmHwpEditor text hover cursor", () => {
  it("uses an I-beam only when the pointer is near the engine text cursor rect", () => {
    const editor = Object.create(WasmHwpEditor)

    assert.equal(editor.hitIsText({
      x: 108,
      y: 214,
      cursorRect: { pageIndex: 0, x: 100, y: 200, height: 20 },
    }), true)
    assert.equal(editor.hitIsText({
      x: 180,
      y: 214,
      cursorRect: { pageIndex: 0, x: 100, y: 200, height: 20 },
    }), false)
    assert.equal(editor.hitIsText({ x: 108, y: 214 }), false)
  })

  it("clears the prior canvas cursor when hover moves away", () => {
    const editor = hwpViewStateEditor()
    const first = { style: { cursor: "" } }
    const second = { style: { cursor: "" } }

    editor.setTextCursorCanvas(first)
    assert.equal(first.style.cursor, "text")

    editor.setTextCursorCanvas(second)
    assert.equal(first.style.cursor, "")
    assert.equal(second.style.cursor, "text")

    editor.setTextCursorCanvas(null)
    assert.equal(second.style.cursor, "")
  })
})

describe("WasmHwpEditor scroll preservation", () => {
  it("restores a document scroll offset across hook remounts", () => {
    const win = (globalThis as any).window
    const oldRaf = win.requestAnimationFrame
    win.requestAnimationFrame = (fn: Function) => {
      fn()
      return 1
    }

    try {
      const scrollPositions = new Map()
      const first = hwpViewStateEditor()
      first.scrollPositions = scrollPositions
      first.mirror = false
      first.documentId = "hwp-scroll-doc"
      first.loadedUrl = "/bytes/hwp-scroll-doc"
      first.canvasState = {
        documentPath: "drafts/service.hwpx",
        bytesUrl: "/bytes/hwp-scroll-doc",
      }
      first.el = {
        dataset: {},
        scrollTop: 640,
        scrollLeft: 18,
      }

      first.rememberScrollPosition()

      let rendered = 0
      const second = hwpViewStateEditor()
      second.scrollPositions = scrollPositions
      second.mirror = false
      second.documentId = "hwp-scroll-doc"
      second.loadedUrl = "/bytes/hwp-scroll-doc"
      second.canvasState = {
        documentPath: "drafts/service.hwpx",
        bytesUrl: "/bytes/hwp-scroll-doc",
      }
      second.el = {
        dataset: {},
        isConnected: true,
        scrollTop: 0,
        scrollLeft: 0,
      }
      second.renderVisiblePages = () => {
        rendered += 1
      }

      second.restoreScrollPosition()

      assert.equal(second.el.scrollTop, 640)
      assert.equal(second.el.scrollLeft, 18)
      assert.equal(rendered, 1)
    } finally {
      if (oldRaf) win.requestAnimationFrame = oldRaf
      else delete win.requestAnimationFrame
    }
  })

  it("restores a server-persisted scroll offset when no local cache exists", () => {
    const win = (globalThis as any).window
    const oldRaf = win.requestAnimationFrame
    win.requestAnimationFrame = (fn: Function) => {
      fn()
      return 1
    }

    try {
      let rendered = 0
      const editor = hwpViewStateEditor()
      editor.scrollPositions = new Map()
      editor.mirror = false
      editor.documentId = "hwp-server-scroll-doc"
      editor.loadedUrl = "/bytes/hwp-server-scroll-doc"
      editor.canvasState = {
        documentPath: "drafts/server-scroll.hwpx",
        bytesUrl: "/bytes/hwp-server-scroll-doc",
        scrollTop: 731,
        scrollLeft: 9,
      }
      editor.el = {
        dataset: {},
        isConnected: true,
        scrollTop: 0,
        scrollLeft: 0,
      }
      editor.renderVisiblePages = () => {
        rendered += 1
      }

      editor.restoreScrollPosition()

      assert.equal(editor.el.scrollTop, 731)
      assert.equal(editor.el.scrollLeft, 9)
      assert.equal(rendered, 1)
    } finally {
      if (oldRaf) win.requestAnimationFrame = oldRaf
      else delete win.requestAnimationFrame
    }
  })

  it("pushes document scroll with the document path", () => {
    const pushed: any[] = []
    const editor = hwpViewStateEditor()
    editor.scrollPositions = new Map()
    editor.mirror = false
    editor.documentId = "hwp-persist-scroll-doc"
    editor.loadedUrl = "/bytes/hwp-persist-scroll-doc"
    editor.canvasState = {
      documentPath: "drafts/persist-scroll.hwpx",
      bytesUrl: "/bytes/hwp-persist-scroll-doc",
    }
    editor.el = {
      dataset: {},
      scrollTop: 88,
      scrollLeft: 4,
    }
    editor.pushEvent = (event: string, payload: any) => pushed.push({ event, payload })

    editor.rememberScrollPosition()
    editor.flushScrollPosition()

    assert.deepEqual(pushed, [
      {
        event: "document.viewport.changed",
        payload: {
          document_path: "drafts/persist-scroll.hwpx",
          document_id: "hwp-persist-scroll-doc",
          top: 88,
          left: 4,
        },
      },
    ])
  })
})

describe("WasmHwpEditor mirror resize anchoring", () => {
  it("reframes a saved edit after the preview surface changes size", () => {
    const win = (globalThis as any).window
    const oldRaf = win.requestAnimationFrame
    const oldCancelRaf = win.cancelAnimationFrame
    const oldSetTimeout = win.setTimeout
    const oldClearTimeout = win.clearTimeout
    const oldResizeObserver = (globalThis as any).ResizeObserver
    let resizeCallback: (() => void) | null = null
    let frameCallback: (() => void) | null = null
    let renderCallback: (() => void) | null = null
    let observed: any = null

    win.requestAnimationFrame = (callback: () => void) => {
      frameCallback = callback
      return 41
    }
    win.cancelAnimationFrame = () => {}
    win.setTimeout = (callback: () => void) => {
      renderCallback = callback
      return 73
    }
    win.clearTimeout = () => {}
    ;(globalThis as any).ResizeObserver = class {
      constructor(callback: () => void) {
        resizeCallback = callback
      }
      observe(element: any) {
        observed = element
      }
      disconnect() {}
    }

    try {
      withMountedHook((editor) => {
        const rects = [{ pageIndex: 3, x: 150, y: 406, width: 220, height: 13, savedHighlightHasCell: true }]
        let rendered = 0
        let framed: any = null
        editor.previewSavedHighlight = { rects }
        editor.renderVisiblePages = () => {
          rendered += 1
        }
        editor.frameSavedEditHighlights = (value: any) => {
          framed = value
        }

        assert.equal(observed, editor.el)
        resizeCallback?.()
        resizeCallback?.()
        assert.equal(typeof frameCallback, "function")
        assert.equal(rendered, 0)

        frameCallback?.()

        assert.equal(rendered, 0)
        assert.equal(framed, rects)

        renderCallback?.()

        assert.equal(rendered, 1)
      })
    } finally {
      if (oldRaf) win.requestAnimationFrame = oldRaf
      else delete win.requestAnimationFrame
      if (oldCancelRaf) win.cancelAnimationFrame = oldCancelRaf
      else delete win.cancelAnimationFrame
      if (oldSetTimeout) win.setTimeout = oldSetTimeout
      else delete win.setTimeout
      if (oldClearTimeout) win.clearTimeout = oldClearTimeout
      else delete win.clearTimeout
      if (oldResizeObserver) (globalThis as any).ResizeObserver = oldResizeObserver
      else delete (globalThis as any).ResizeObserver
    }
  })
})

describe("WasmHwpEditor renderer memory policy", () => {
  it("builds only saved-highlight pages for mirror previews", () => {
    const observed: string[] = []
    const stack = {
      replaceChildren() {
        observed.length = 0
      },
      appendChild(section: any) {
        observed.push(section.dataset.pageIndex)
      },
    }

    const oldDocument = (globalThis as any).document
    ;(globalThis as any).document = {
      ...documentStub,
      createElement: (tag: string) => ({
        dataset: {},
        style: {},
        className: "",
        appendChild() {},
        querySelector() {
          return null
        },
        getContext: tag === "canvas" ? () => ({ fillStyle: "", fillRect() {} }) : undefined,
      }),
    }

    try {
      const editor = Object.create(WasmHwpEditor)
      editor.mirror = true
      editor.pageCount = 4
      editor.pageStack = stack
      editor.rendered = new Map()
      editor.renderedPageOrder = new Map()
      editor.pageScales = new Map()
      editor.visible = new Set()
      editor.io = { disconnect() {}, observe() {} }
      editor.el = { dataset: {} }
      editor.doc = {
        getPageInfo() {
          return JSON.stringify({ width: 100, height: 120 })
        },
      }
      editor.previewPageFilter = [2]

      editor.buildPageStack()

      assert.deepEqual(observed, ["2"])
      assert.equal(editor.el.dataset.previewPageFilter, "2")
      assert.deepEqual(editor.pageStackIndexes(), [2])
    } finally {
      ;(globalThis as any).document = oldDocument
    }
  })

  it("shrinks offscreen page canvases and forgets their render state", () => {
    const canvas = fakeCanvas(1984, 2806)
    const overlay = fakeCanvas(1984, 2806)
    const section = fakeHwpSection(3, canvas, overlay)
    const editor = {
      ...WasmHwpEditor,
      pageCount: 8,
      rendered: new Map([[3, true]]),
      renderedPageOrder: new Map([[3, 42]]),
      pageScales: new Map([[3, 2]]),
      visible: new Set(),
      caret: null,
      pageSection: () => section,
      documentAdornmentPicks: () => [],
    } as any

    assert.equal(editor.releasePageCanvas(3), true)

    assert.equal(canvas.width, 1)
    assert.equal(canvas.height, 1)
    assert.equal(overlay.width, 1)
    assert.equal(overlay.height, 1)
    assert.equal(editor.rendered.has(3), false)
    assert.equal(editor.renderedPageOrder.has(3), false)
    assert.equal(editor.pageScales.has(3), false)
  })

  it("keeps active caret pages when an offscreen release is requested", () => {
    const canvas = fakeCanvas(1984, 2806)
    const overlay = fakeCanvas(1984, 2806)
    const section = fakeHwpSection(2, canvas, overlay)
    const editor = {
      ...WasmHwpEditor,
      pageCount: 8,
      rendered: new Map([[2, true]]),
      renderedPageOrder: new Map([[2, 1]]),
      pageScales: new Map([[2, 2]]),
      visible: new Set(),
      caret: { cursorRect: { pageIndex: 2 } },
      pageSection: () => section,
      documentAdornmentPicks: () => [],
    } as any

    assert.equal(editor.releasePageCanvas(2), false)
    assert.equal(canvas.width, 1984)
    assert.equal(overlay.width, 1984)
    assert.equal(editor.rendered.has(2), true)
  })

  it("caps HWP render scale on low-memory devices", () => {
    const win = (globalThis as any).window
    const oldDpr = win.devicePixelRatio
    const oldNavigator = Object.getOwnPropertyDescriptor(globalThis, "navigator")
    win.devicePixelRatio = 2
    Object.defineProperty(globalThis, "navigator", {
      configurable: true,
      value: { deviceMemory: 8 },
    })

    try {
      let usedScale = 0
      const canvas = fakeCanvas(1, 1)
      const overlay = fakeCanvas(1, 1)
      const section = fakeHwpSection(0, canvas, overlay)
      const editor = {
        ...WasmHwpEditor,
        mirror: false,
        pageCount: 1,
        rendered: new Map(),
        renderedPageOrder: new Map(),
        pageScales: new Map(),
        visible: new Set([0]),
        caret: null,
        previewPatchHighlight: null,
        previewSavedHighlight: null,
        documentAdornmentPicks: () => [],
        pageSection: () => section,
        pageInfo: () => ({ w: 1000, h: 1400 }),
        doc: {
          renderPageToCanvas(_index: number, target: any, scale: number) {
            usedScale = scale
            target.width = Math.round(1000 * scale)
            target.height = Math.round(1400 * scale)
          },
        },
      } as any

      editor.renderPage(0)

      assert.ok(usedScale < 2)
      assert.ok(usedScale <= 1.2)
      assert.equal(canvas.width, Math.round(1000 * usedScale))
      assert.equal(overlay.width, canvas.width)
      assert.equal(editor.pageScales.get(0), usedScale)
    } finally {
      if (oldDpr === undefined) delete win.devicePixelRatio
      else win.devicePixelRatio = oldDpr
      if (oldNavigator) Object.defineProperty(globalThis, "navigator", oldNavigator)
      else delete (globalThis as any).navigator
    }
  })

  it("sweeps rendered pages outside the visible, caret, and highlight retention set", () => {
    const sections = new Map<number, any>()
    for (let i = 0; i < 12; i++) sections.set(i, fakeHwpSection(i, fakeCanvas(100, 100), fakeCanvas(100, 100)))
    const renderedEntries = Array.from({ length: 12 }, (_value, index) => [index, true] as [number, boolean])
    const orderEntries = Array.from({ length: 12 }, (_value, index) => [index, index] as [number, number])
    const editor = {
      ...WasmHwpEditor,
      pageCount: 12,
      rendered: new Map(renderedEntries),
      renderedPageOrder: new Map(orderEntries),
      pageScales: new Map(orderEntries.map(([index]) => [index, 1])),
      visible: new Set([5]),
      caret: { cursorRect: { pageIndex: 2 } },
      previewSavedHighlight: { rects: [{ pageIndex: 9, x: 0, y: 0, width: 1, height: 1 }] },
      pageSection: (index: number) => sections.get(index),
      documentAdornmentPicks: () => [],
    } as any

    editor.enforcePageMemoryBudget()

    assert.equal(editor.rendered.has(0), false)
    assert.equal(editor.rendered.has(2), true)
    assert.equal(editor.rendered.has(4), true)
    assert.equal(editor.rendered.has(5), true)
    assert.equal(editor.rendered.has(6), true)
    assert.equal(editor.rendered.has(9), true)
    assert.equal(sections.get(0).querySelector("[data-role='ehwp-canvas']").width, 1)
    assert.equal(sections.get(2).querySelector("[data-role='ehwp-canvas']").width, 100)
  })

  it("renders only the caret page for plain typing unless visible refresh is requested", () => {
    const rendered: number[] = []
    const editor = {
      ...WasmHwpEditor,
      caret: { cursorRect: { pageIndex: 2 } },
      visible: new Set([1, 2, 3]),
      renderPage(index: number) {
        rendered.push(index)
      },
    } as any

    editor.renderCaretPage()
    assert.deepEqual(rendered, [2])

    rendered.length = 0
    editor.renderCaretPage({ refreshVisible: true })
    assert.deepEqual(rendered, [2, 1, 3])
  })

  it("uses the cached path cursor query with the current page as its hint", () => {
    const calls: any[] = []
    const editor = {
      ...WasmHwpEditor,
      caret: {
        section: 1,
        paragraph: 4,
        offset: 7,
        cursorRect: { pageIndex: 9 },
        cell: {
          parentParaIndex: 4,
          controlIndex: 2,
          cellIndex: 3,
          cellParaIndex: 5,
        },
      },
      doc: {
        getCursorRectByPathNear(...args: any[]) {
          calls.push(args)
          return JSON.stringify({ pageIndex: 9, x: 12, y: 34, height: 18 })
        },
        getCursorRectInCell() {
          throw new Error("legacy uncached cursor query must not run")
        },
      },
      scheduleToolbarStateSync() {},
    } as any

    editor.refreshCursorRect()

    assert.deepEqual(calls, [[
      1,
      4,
      JSON.stringify([{ controlIndex: 2, cellIndex: 3, cellParaIndex: 5 }]),
      7,
      9,
    ]])
    assert.deepEqual(editor.caret.cursorRect, { pageIndex: 9, x: 12, y: 34, height: 18 })
  })

  it("falls back to the legacy cell cursor query for older wasm builds", () => {
    const calls: any[] = []
    const editor = {
      ...WasmHwpEditor,
      caret: {
        section: 0,
        paragraph: 8,
        offset: 2,
        cursorRect: null,
        cell: {
          parentParaIndex: 8,
          controlIndex: 1,
          cellIndex: 6,
          cellParaIndex: 0,
        },
      },
      doc: {
        getCursorRectInCell(...args: any[]) {
          calls.push(args)
          return JSON.stringify({ pageIndex: 3, x: 20, y: 40, height: 16 })
        },
      },
      scheduleToolbarStateSync() {},
    } as any

    editor.refreshCursorRect()

    assert.deepEqual(calls, [[0, 8, 1, 6, 0, 2]])
    assert.equal(editor.caret.cursorRect.pageIndex, 3)
  })
})

describe("WasmHwpEditor native IME routing", () => {
  function baseEditor(overrides = {}) {
    return {
      ...WasmHwpEditor,
      doc: {},
      scale: 1,
      caret: {
        section: 0,
        paragraph: 0,
        offset: 0,
        cell: null,
        note: null,
        cursorRect: { pageIndex: 0, x: 12, y: 20, height: 18 },
      },
      imeProxy: {
        value: "",
        style: { left: "0px", top: "0px", height: "16px" },
        dataset: {},
      },
      el: {
        scrollLeft: 0,
        scrollTop: 0,
        appendChild(node: any) {
          node.parentNode = this
        },
        getBoundingClientRect() {
          return { left: 0, top: 0 }
        },
      },
      pageSection() {
        return {
          querySelector() {
            return {
              width: 800,
              getBoundingClientRect() {
                return { left: 0, top: 0, width: 800 }
              },
            }
          },
        }
      },
      refreshCursorRect() {},
      drawCaret() {},
      recordOp() {},
      scheduleSnapshot() {},
      anchorProxy() {},
      renderPage() {},
      renderCaretPage() {},
      hasSelection: () => false,
      deleteSelection() {},
      pushHwpUndoCheckpoint() {},
      ...overrides,
    } as any
  }

  it("begins native composition at the current caret anchor without clearing browser composition", () => {
    let checkpointed = 0
    const rendered: number[] = []
    let anchor: any = null
    const editor = baseEditor({
      imeProxy: { value: "stale", style: {}, dataset: {} },
      doc: {
        beginImeComposition(raw: string) {
          anchor = JSON.parse(raw)
          return JSON.stringify({ active: true })
        },
        updateImeComposition() {},
        commitImeComposition() {},
        cancelImeComposition() {},
      },
      pushHwpUndoCheckpoint() {
        checkpointed += 1
      },
      renderPage(index: number) {
        rendered.push(index)
      },
    })

    editor.handleCompositionStart({ data: "" })

    assert.deepEqual(anchor, { kind: "body", sectionIdx: 0, paraIdx: 0, charOffset: 0 })
    assert.equal(checkpointed, 1)
    assert.deepEqual(rendered, [])
    assert.equal(editor.imeProxy.value, "stale")
  })

  it("updates native composition as document text without clearing browser composition", () => {
    const updates: any[] = []
    const rendered: number[] = []
    let refreshed = 0
    let drawn = 0
    let anchored = 0
    const editor = baseEditor({
      imeProxy: { value: "ㅎ", style: {}, dataset: {} },
      doc: {
        beginImeComposition() {},
        updateImeComposition(text: string, cursorOffset: number) {
          updates.push([text, cursorOffset])
          return JSON.stringify({ active: true, pageIndex: 2, invalidatedPages: [2], edit: { charOffset: 4 } })
        },
        commitImeComposition() {},
        cancelImeComposition() {},
      },
      renderPage(index: number) {
        rendered.push(index)
      },
      refreshCursorRect() {
        refreshed += 1
      },
      drawCaret() {
        drawn += 1
      },
      anchorProxy() {
        anchored += 1
      },
    })

    editor.handleCompositionUpdate({ data: "하" })

    assert.deepEqual(updates, [["하", 1]])
    assert.equal(editor.caret.offset, 4)
    assert.equal(refreshed, 1)
    assert.equal(drawn, 1)
    assert.equal(anchored, 1)
    assert.deepEqual(rendered, [2])
    assert.equal(editor.imeProxy.value, "ㅎ")
  })

  it("routes empty composition data immediately instead of stale proxy text", () => {
    const updates: any[] = []
    const rendered: number[] = []
    const editor = baseEditor({
      caret: {
        section: 0,
        paragraph: 0,
        offset: 1,
        cell: null,
        note: null,
        cursorRect: { pageIndex: 2, x: 12, y: 20, height: 18 },
      },
      imeProxy: { value: "하", style: {}, dataset: {} },
      doc: {
        beginImeComposition() {},
        updateImeComposition(text: string, cursorOffset: number) {
          updates.push([text, cursorOffset])
          return JSON.stringify({ active: true, pageIndex: 2, invalidatedPages: [2], edit: { charOffset: 1 } })
        },
        commitImeComposition() {},
        cancelImeComposition() {},
      },
      renderPage(index: number) {
        rendered.push(index)
      },
    })

    editor.handleCompositionUpdate({ data: "" })

    assert.deepEqual(updates, [["", 0]])
    assert.equal(editor.caret.offset, 1)
    assert.deepEqual(rendered, [2])
    assert.equal(editor.imeProxy.value, "하")
  })

  it("swallows textarea composition echoes without mutating the document", () => {
    const inserted: string[] = []
    const editor = baseEditor({
      imeProxy: { value: "안", style: {}, dataset: {} },
      insertPlainTextAtCaret(text: string) {
        inserted.push(text)
      },
    })

    editor.handleInput({ inputType: "insertCompositionText", data: "안", isComposing: true })

    assert.deepEqual(inserted, [])
    assert.equal(editor.imeProxy.value, "안")
  })

  it("commits final IME text through native and advances the caret from the native edit result", () => {
    const commits: string[] = []
    const rendered: number[] = []
    const ops: any[] = []
    let snapshots = 0
    let refreshed = 0
    const editor = baseEditor({
      caret: {
        section: 0,
        paragraph: 0,
        offset: 1,
        cell: null,
        note: null,
        cursorRect: { pageIndex: 1, x: 12, y: 20, height: 18 },
      },
      imeProxy: { value: "하", style: {}, dataset: {} },
      doc: {
        beginImeComposition() {},
        updateImeComposition() {},
        commitImeComposition(text: string) {
          commits.push(text)
          return JSON.stringify({
            ok: true,
            committed: true,
            active: false,
            invalidatedPages: [1],
            edit: { charOffset: 3 },
          })
        },
        cancelImeComposition() {},
      },
      refreshCursorRect() {
        refreshed += 1
      },
      renderPage(index: number) {
        rendered.push(index)
      },
      recordOp(type: string, payload: any) {
        ops.push([type, payload])
      },
      scheduleSnapshot() {
        snapshots += 1
      },
    })

    editor.handleCompositionEnd({ data: "하" })

    assert.deepEqual(commits, ["하"])
    assert.equal(editor.caret.offset, 3)
    assert.equal(refreshed, 1)
    assert.deepEqual(rendered, [1])
    assert.deepEqual(ops, [["TextInserted", { text: "하" }]])
    assert.equal(snapshots, 1)
    assert.equal(editor.imeProxy.value, "")
  })

  it("commits native IME from final insertCompositionText when compositionend is missed", () => {
    const commits: string[] = []
    const rendered: number[] = []
    const inserted: string[] = []
    let active = true
    const editor = baseEditor({
      caret: {
        section: 0,
        paragraph: 0,
        offset: 1,
        cell: null,
        note: null,
        cursorRect: { pageIndex: 4, x: 12, y: 20, height: 18 },
      },
      imeProxy: { value: "하", style: {}, dataset: {} },
      doc: {
        beginImeComposition() {},
        updateImeComposition() {},
        getImeCompositionRenderInfo() {
          return JSON.stringify({ active, pageIndex: 4 })
        },
        commitImeComposition(text: string) {
          commits.push(text)
          active = false
          return JSON.stringify({
            ok: true,
            committed: true,
            active: false,
            invalidatedPages: [4],
            edit: { charOffset: 2 },
          })
        },
        cancelImeComposition() {},
      },
      insertPlainTextAtCaret(text: string) {
        inserted.push(text)
      },
      renderPage(index: number) {
        rendered.push(index)
      },
    })

    editor.handleInput({ inputType: "insertCompositionText", data: "하", isComposing: false })

    assert.deepEqual(commits, ["하"])
    assert.deepEqual(inserted, [])
    assert.equal(editor.caret.offset, 2)
    assert.deepEqual(rendered, [4])
    assert.equal(editor.imeProxy.value, "")
  })

  it("cancels and repaints stale native composition text before non-composing keys", () => {
    const rendered: number[] = []
    let cancelled = 0
    const eventCalls: string[] = []
    const editor = baseEditor({
      doc: {
        beginImeComposition() {},
        updateImeComposition() {},
        commitImeComposition() {},
        getImeCompositionRenderInfo() {
          return JSON.stringify({ active: true, pageIndex: 7 })
        },
        cancelImeComposition() {
          cancelled += 1
          return JSON.stringify({ ok: true, active: false, invalidatedPages: [7] })
        },
      },
      renderPage(index: number) {
        rendered.push(index)
      },
      collapseSelection() {},
      moveHorizontal() {},
    })

    editor.handleKeyDown({
      key: "ArrowRight",
      isComposing: false,
      metaKey: false,
      ctrlKey: false,
      altKey: false,
      defaultPrevented: false,
      preventDefault: () => eventCalls.push("preventDefault"),
      stopPropagation: () => eventCalls.push("stopPropagation"),
    })

    assert.equal(cancelled, 1)
    assert.deepEqual(rendered, [7])
    assert.deepEqual(eventCalls, ["preventDefault"])
  })

  it("cancels and repaints stale native composition text before pointer caret moves", () => {
    const rendered: number[] = []
    let cancelled = 0
    const editor = baseEditor({
      doc: {
        beginImeComposition() {},
        updateImeComposition() {},
        commitImeComposition() {},
        getImeCompositionRenderInfo() {
          return JSON.stringify({ active: true, pageIndex: 5 })
        },
        cancelImeComposition() {
          cancelled += 1
          return JSON.stringify({ ok: true, active: false, invalidatedPages: [5] })
        },
      },
      renderPage(index: number) {
        rendered.push(index)
      },
      scheduleToolbarStateSync() {},
    })

    editor.setCaretFromHit({ sectionIndex: 0, paragraphIndex: 1, charOffset: 3 }, 0)

    assert.equal(cancelled, 1)
    assert.deepEqual(rendered, [5])
    assert.equal(editor.caret.paragraph, 1)
    assert.equal(editor.caret.offset, 3)
  })

  it("parks the browser IME proxy offscreen so browser marked text is not visible", () => {
    const proxy = { style: {} }
    const editor = baseEditor({
      imeProxy: proxy,
      anchorProxy: WasmHwpEditor.anchorProxy,
    })

    editor.anchorProxy()

    assert.equal(proxy.style.position, "fixed")
    assert.equal(proxy.style.left, "-10000px")
    assert.equal(proxy.style.top, "-10000px")
    assert.equal(proxy.style.width, "1px")
    assert.equal(proxy.style.height, "1px")
    assert.equal(proxy.style.maxWidth, "1px")
    assert.equal(proxy.style.maxHeight, "1px")
    assert.equal(proxy.style.fontSize, "1px")
    assert.equal(proxy.style.lineHeight, "1px")
    assert.equal(proxy.style.opacity, "0")
    assert.equal(proxy.style.color, "transparent")
    assert.equal(proxy.style.webkitTextFillColor, "transparent")
    assert.equal(proxy.style.caretColor, "transparent")
    assert.equal(proxy.style.clipPath, "inset(50%)")
    assert.equal(proxy.style.zIndex, "-1")
  })
})

describe("WasmHwpEditor undo/redo history", () => {
  function historyEditor() {
    let nextSnapshot = 0
    const restored: number[] = []
    const discarded: number[] = []
    const finishes: any[] = []
    const editor = {
      ...WasmHwpEditor,
      mirror: false,
      pageCount: 1,
      undoStack: [],
      redoStack: [],
      imeProxy: { value: "stale" },
      doc: {
        saveSnapshot() {
          nextSnapshot += 1
          return nextSnapshot
        },
        restoreSnapshot(id: number) {
          restored.push(id)
          return "{}"
        },
        discardSnapshot(id: number) {
          discarded.push(id)
        },
        pageCount() {
          return 1
        },
      },
      finishAgentEdit(extra: any) {
        finishes.push(extra)
        return { ok: true, result: { ok: true, ...extra } }
      },
      scheduleToolbarStateSync() {},
      clearSelection() {},
      clearSelectionOverlays() {},
    } as any

    return { editor, restored, discarded, finishes }
  }

  function keyEvent(key: string, modifiers: any = {}) {
    const calls: string[] = []
    return {
      event: {
        key,
        ctrlKey: false,
        metaKey: false,
        altKey: false,
        shiftKey: false,
        isComposing: false,
        preventDefault: () => calls.push("preventDefault"),
        stopPropagation: () => calls.push("stopPropagation"),
        ...modifiers,
      } as any,
      calls,
    }
  }

  it("moves current and target snapshots across undo and redo stacks", () => {
    const { editor, restored, discarded, finishes } = historyEditor()

    assert.equal(editor.pushHwpUndoCheckpoint("typing"), true)
    assert.equal(editor.undoStack.length, 1)
    assert.equal(editor.undoStack[0].id, 1)

    assert.equal(editor.runHwpUndo(), true)
    assert.deepEqual(restored, [1])
    assert.deepEqual(discarded, [1])
    assert.equal(editor.undoStack.length, 0)
    assert.equal(editor.redoStack.length, 1)
    assert.equal(editor.redoStack[0].id, 2)
    assert.equal(editor.imeProxy.value, "")
    assert.deepEqual(finishes[0], { history_direction: "undo" })

    assert.equal(editor.runHwpRedo(), true)
    assert.deepEqual(restored, [1, 2])
    assert.deepEqual(discarded, [1, 2])
    assert.equal(editor.undoStack.length, 1)
    assert.equal(editor.undoStack[0].id, 3)
    assert.equal(editor.redoStack.length, 0)
    assert.deepEqual(finishes[1], { history_direction: "redo" })
  })

  it("handles Ctrl+Z through the HWP keydown path before caret checks", () => {
    const { editor, restored } = historyEditor()
    editor.pushHwpUndoCheckpoint("typing")
    editor.caret = null
    const { event, calls } = keyEvent("z", { ctrlKey: true })

    editor.handleKeyDown(event)

    assert.deepEqual(calls, ["preventDefault", "stopPropagation"])
    assert.deepEqual(restored, [1])
  })

  it("uses physical key codes for localized editor shortcuts", () => {
    const { editor, restored } = historyEditor()
    editor.pushHwpUndoCheckpoint("typing")

    const undo = keyEvent("ㅋ", { code: "KeyZ", ctrlKey: true })
    editor.handleKeyDown(undo.event)

    assert.deepEqual(undo.calls, ["preventDefault", "stopPropagation"])
    assert.deepEqual(restored, [1])
    assert.equal(editor.undoStack.length, 0)
    assert.equal(editor.redoStack.length, 1)

    const redo = keyEvent("ㅛ", { code: "KeyY", ctrlKey: true })
    editor.handleKeyDown(redo.event)

    assert.deepEqual(redo.calls, ["preventDefault", "stopPropagation"])
    assert.deepEqual(restored, [1, 2])
    assert.equal(editor.redoStack.length, 0)
    assert.equal(editor.saveShortcut({ key: "ㄴ", code: "KeyS", ctrlKey: true, metaKey: false }), true)
  })

  it("reactivates document-level undo when a checkpoint is recorded", () => {
    const { editor, restored } = historyEditor()
    editor.el = { contains: () => false }
    const doc = (globalThis as any).document
    const previousActive = doc.activeElement
    doc.activeElement = doc.body

    try {
      editor.pushHwpUndoCheckpoint("toolbar-format")
      const { event, calls } = keyEvent("z", { code: "KeyZ", ctrlKey: true, target: doc.body })

      editor.handleDocumentKeyDown(event)

      assert.deepEqual(calls, ["preventDefault", "stopPropagation"])
      assert.deepEqual(restored, [1])
      assert.equal(editor.undoStack.length, 0)
      assert.equal(editor.redoStack.length, 1)
    } finally {
      doc.activeElement = previousActive
      editor.handleDocumentPointerDown({ target: {} } as any)
    }
  })

  it("handles document-level redo shortcuts for the active HWP editor", () => {
    const { editor, restored } = historyEditor()
    editor.el = { contains: () => false }
    editor.redoStack = [{ id: 42 }]
    editor.activateKeyboardShortcuts()
    const doc = (globalThis as any).document
    const previousActive = doc.activeElement
    doc.activeElement = doc.body

    try {
      const { event, calls } = keyEvent("y", { ctrlKey: true, target: doc.body })
      editor.handleDocumentKeyDown(event)

      assert.deepEqual(calls, ["preventDefault", "stopPropagation"])
      assert.deepEqual(restored, [42])
    } finally {
      doc.activeElement = previousActive
      editor.handleDocumentPointerDown({ target: {} } as any)
    }
  })

  it("records a typing checkpoint and clears stale redo history", () => {
    const discarded: number[] = []
    const inserted: string[] = []
    const editor = {
      ...WasmHwpEditor,
      mirror: false,
      caret: { section: 0, paragraph: 0, offset: 0, cell: null, note: null },
      undoStack: [],
      redoStack: [{ id: 9 }],
      imeProxy: { value: "" },
      doc: {
        saveSnapshot: () => 7,
        restoreSnapshot: () => "{}",
        discardSnapshot: (id: number) => discarded.push(id),
      },
      hasSelection: () => false,
      insertPlainTextAtCaret: (text: string) => inserted.push(text),
    } as any

    editor.handleInput({ inputType: "insertText", data: "A", isComposing: false })

    assert.deepEqual(inserted, ["A"])
    assert.equal(editor.undoStack.length, 1)
    assert.equal(editor.undoStack[0].id, 7)
    assert.equal(editor.redoStack.length, 0)
    assert.deepEqual(discarded, [9])
  })
})

describe("WasmHwpEditor preview patch safety", () => {
  it("does not patch preview text into the main editor or schedule a snapshot", () => {
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

    assert.equal(inserted, "")
    assert.equal(editor.previewPatchCursor.offset, 0)
    assert.equal(editor.el.scrollTop, 420)
    assert.equal(rendered, 0)
    assert.equal(highlighted, 0)
    assert.equal(scheduled, 0)
  })

  it("patches preview text only inside mirror editors without scheduling a snapshot", () => {
    let inserted = ""
    let rendered = 0
    let highlighted = 0
    let scheduled = 0

    const editor = {
      ...WasmHwpEditor,
      mirror: true,
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
    assert.equal(scheduled, 0)
  })

  it("paints every saved VFS edit highlight without patching text into the mirror", () => {
    let inserted = ""
    const fills: any[] = []

    const editor = {
      ...WasmHwpEditor,
      mirror: true,
      previewPatchText: "",
      previewPatchCursor: null,
      previewPatchAnchor: null,
      previewSavedHighlight: null,
      rendered: new Map([[0, true], [2, true], [3, true]]),
      scale: 1,
      canvasState: {
        previewHighlights: JSON.stringify([
          {
            kind: "text",
            op: "replace_text",
            ref: { section: 0, paragraph: 1, offset: 0 },
            text: "STAGE_PROOF_PARA_A"
          },
          {
            kind: "text",
            op: "set_cell",
            ref: {
              section: 0,
              paragraph: 2,
              offset: 0,
              cell: {
                parentParaIndex: 2,
                controlIndex: 0,
                cellIndex: 3,
                cellParaIndex: 0
              }
            },
            text: "STAGE_PROOF_CELL_A"
          }
        ])
      },
      el: {
        scrollTop: 0,
        dataset: {}
      },
      doc: {
        getParagraphLength() {
          return 4
        },
        getSelectionRects() {
          return JSON.stringify([{ pageIndex: 0, x: 1, y: 2, width: 3, height: 4 }])
        },
        getCellParagraphLength() {
          return 5
        },
        getSelectionRectsInCell() {
          return JSON.stringify([
            { pageIndex: 2, x: 10, y: 40, width: 12, height: 13 },
            { pageIndex: 3, x: 20, y: 21, width: 22, height: 23 }
          ])
        },
        insertText(_section: number, _paragraph: number, _offset: number, text: string) {
          inserted += text
        },
      },
      pageInfo() {
        return { w: 100, h: 100 }
      },
      pageSection(pageIndex: number) {
        return {
          offsetTop: pageIndex * 1000,
          getBoundingClientRect() {
            return { height: 100 }
          },
        }
      },
      pageOverlay(_pageIndex: number) {
        return {
          getContext() {
            return {
              fillStyle: "",
              fillRect(...args: any[]) {
                fills.push(args)
              },
            }
          },
        }
      },
    } as any

    editor.renderSavedEditHighlights()

    assert.equal(inserted, "")
    assert.equal(editor.el.dataset.previewHighlightMode, "saved-edit-regions")
    assert.equal(editor.el.dataset.previewHighlightCount, "3")
    assert.equal(editor.el.dataset.previewHighlightPages, "0,2,3")
    assert.equal(editor.el.dataset.previewHighlightAuthority, "selection:1,selection-cell:2")
    assert.equal(editor.el.dataset.previewHighlightFallbackCount, "0")
    assert.equal(editor.el.dataset.previewFrameMode, "saved-cell")
    assert.equal(editor.el.dataset.previewFramePage, "2")
    assert.equal(editor.el.scrollTop, 2016)
    assert.equal(fills.length, 3)
  })

  it("uses explicit saved VFS replace_text ranges instead of the whole paragraph", () => {
    const calls: any[] = []
    const title = "범용(용역[지식ㆍ정보성과물]업 분야) 표준하도급계약서 "
    const marker = "CHATRAIL_FSKIT_HWP_OK"
    const fills: any[] = []

    const editor = {
      ...WasmHwpEditor,
      mirror: true,
      previewPatchText: "",
      previewPatchCursor: null,
      previewPatchAnchor: null,
      previewSavedHighlight: null,
      rendered: new Map([[0, true]]),
      scale: 1,
      canvasState: {
        previewHighlights: JSON.stringify([
          {
            kind: "text",
            op: "replace_text",
            ref: { section: 0, paragraph: 0, offset: 0 },
            offset: title.length,
            length: marker.length,
            text: marker
          }
        ])
      },
      el: {
        scrollTop: 0,
        dataset: {}
      },
      doc: {
        getParagraphLength() {
          return title.length + marker.length
        },
        getSelectionRects(...args: any[]) {
          calls.push(args)
          return JSON.stringify([{ pageIndex: 0, x: 1, y: 2, width: 3, height: 4 }])
        },
      },
      pageInfo() {
        return { w: 100, h: 100 }
      },
      pageSection() {
        return {
          offsetTop: 0,
          getBoundingClientRect() {
            return { height: 100 }
          },
        }
      },
      pageOverlay() {
        return {
          getContext() {
            return {
              fillStyle: "",
              fillRect(...args: any[]) {
                fills.push(args)
              },
            }
          },
        }
      },
    } as any

    editor.renderSavedEditHighlights()

    assert.deepEqual(calls, [[0, 0, title.length, 0, title.length + marker.length]])
    assert.equal(editor.el.dataset.previewHighlightCount, "1")
    assert.equal(editor.el.dataset.previewHighlightAuthority, "selection:1")
    assert.equal(editor.el.dataset.previewHighlightFallbackCount, "0")
    assert.equal(fills.length, 1)
  })

  it("frames saved VFS edits from cursor geometry when HWP selection rects are empty", () => {
    const fills: any[] = []

    const editor = {
      ...WasmHwpEditor,
      mirror: true,
      previewSavedHighlight: null,
      rendered: new Map([[4, true]]),
      scale: 1,
      pageCount: 8,
      canvasState: {
        previewHighlights: JSON.stringify([
          {
            kind: "text",
            op: "replace_text",
            ref: { section: 0, paragraph: 42, offset: 0 },
            offset: 13,
            length: 11,
            text: "EDITED_LINE"
          }
        ])
      },
      el: {
        scrollTop: 0,
        dataset: {}
      },
      doc: {
        getParagraphLength() {
          return 80
        },
        getSelectionRects() {
          return JSON.stringify([])
        },
        getCursorRect() {
          return JSON.stringify({ pageIndex: 4, x: 120, y: 620, height: 18 })
        },
      },
      pageInfo() {
        return { w: 700, h: 1000 }
      },
      pageSection() {
        return {
          offsetTop: 0,
          getBoundingClientRect() {
            return { height: 1000 }
          },
        }
      },
      pageOverlay() {
        return {
          getContext() {
            return {
              fillStyle: "",
              fillRect(...args: any[]) {
                fills.push(args)
              },
            }
          },
        }
      },
    } as any

    assert.deepEqual(editor.previewPageIndexesForSavedHighlights(), [4])

    editor.renderSavedEditHighlights()

    assert.equal(editor.el.dataset.previewHighlightCount, "1")
    assert.equal(editor.el.dataset.previewHighlightAuthority, "cursor:1")
    assert.equal(editor.el.dataset.previewHighlightFallbackCount, "1")
    assert.equal(editor.el.dataset.previewFrameMode, "saved-text")
    assert.equal(editor.el.dataset.previewFramePage, "4")
    assert.equal(editor.el.scrollTop, 596)
    assert.equal(fills.length, 1)
  })

  it("estimates the saved VFS edit frame from HWP ref order when geometry is unavailable", () => {
    const fills: any[] = []
    const elements = Array.from({ length: 12 }, (_value, index) => ({
      type: "paragraph",
      ref: { section: 0, paragraph: index, offset: 0 },
      text: `paragraph ${index}`
    }))

    const editor = {
      ...WasmHwpEditor,
      mirror: true,
      previewSavedHighlight: null,
      rendered: new Map([[2, true]]),
      scale: 1,
      pageCount: 3,
      canvasState: {
        previewHighlights: JSON.stringify([
          {
            kind: "text",
            op: "replace_text",
            ref: { section: 0, paragraph: 9, offset: 0 },
            text: "ESTIMATED_LINE"
          }
        ])
      },
      el: {
        scrollTop: 0,
        dataset: {}
      },
      doc: {
        getParagraphLength() {
          return 50
        },
        getSelectionRects() {
          return JSON.stringify([])
        },
        getCursorRect() {
          return ""
        },
      },
      collectElements() {
        return elements
      },
      pageInfo() {
        return { w: 700, h: 1000 }
      },
      pageSection() {
        return {
          offsetTop: 0,
          getBoundingClientRect() {
            return { height: 1000 }
          },
        }
      },
      pageOverlay() {
        return {
          getContext() {
            return {
              fillStyle: "",
              fillRect(...args: any[]) {
                fills.push(args)
              },
            }
          },
        }
      },
    } as any

    editor.renderSavedEditHighlights()

    assert.equal(editor.el.dataset.previewHighlightCount, "1")
    assert.equal(editor.el.dataset.previewHighlightAuthority, "element-estimate:1")
    assert.equal(editor.el.dataset.previewHighlightFallbackCount, "1")
    assert.equal(editor.el.dataset.previewFrameMode, "saved-text")
    assert.equal(editor.el.dataset.previewFramePage, "2")
    assert.equal(editor.el.scrollTop, 376)
    assert.equal(fills.length, 1)
  })

  it("fills insert_table cell payloads in the authoritative browser editor", () => {
    const inserted: any[] = []
    const cellProps: any[] = []
    const recorded: any[] = []

    const editor = {
      ...WasmHwpEditor,
      doc: {
        createTable(section: number, paragraph: number, offset: number, rows: number, cols: number) {
          assert.deepEqual([section, paragraph, offset, rows, cols], [0, 3, 4, 2, 2])
          return JSON.stringify({ ok: true, paraIdx: 9, controlIdx: 2 })
        },
        insertTextInCell(...args: any[]) {
          inserted.push(args)
        },
        splitParagraphInCell() {
          throw new Error("unexpected split")
        },
        setCellProperties(...args: any[]) {
          cellProps.push(args)
        },
      },
      recordOp(kind: string, payload: any) {
        recorded.push({ kind, payload })
      },
    } as any

    const result = editor.applyOneOp({
      op: "insert_table",
      ref: { section: 0, paragraph: 3, offset: 4 },
      rows: 2,
      cols: 2,
      cells: [["A1", "B1"], ["A2", "B2"]],
      header: true,
    })

    assert.deepEqual(result, {
      ok: true,
      extra: { rows: 2, cols: 2, cells_filled: 4, paraIdx: 9, controlIdx: 2 },
    })
    assert.deepEqual(
      inserted.map(args => args.slice(0, 7)),
      [
        [0, 9, 2, 0, 0, 0, "A1"],
        [0, 9, 2, 1, 0, 0, "B1"],
        [0, 9, 2, 2, 0, 0, "A2"],
        [0, 9, 2, 3, 0, 0, "B2"],
      ]
    )
    assert.equal(cellProps.length, 2)
    assert.equal(recorded[0].kind, "AgentInsertTable")
    assert.equal(recorded[0].payload.cellsFilled, 4)
  })

  it("sets picture geometry through the authoritative browser editor", () => {
    const pictureProps: any[] = []
    const recorded: any[] = []

    const editor = {
      ...WasmHwpEditor,
      doc: {
        setPictureProperties(...args: any[]) {
          pictureProps.push(args)
        },
      },
      recordOp(kind: string, payload: any) {
        recorded.push({ kind, payload })
      },
    } as any

    const result = editor.applySetOne(
      { section: 0, paragraph: 12, control: 4, type: "picture" },
      { kind: "picture", Width: 12_000, Height: 8_000, PosX: 1_500, PosY: 2_500 }
    )

    assert.deepEqual(result, { ok: true })
    assert.equal(pictureProps.length, 1)
    assert.deepEqual(pictureProps[0].slice(0, 3), [0, 12, 4])
    assert.deepEqual(JSON.parse(pictureProps[0][3]), {
      height: 8000,
      horzAlign: "Left",
      horzOffset: 1500,
      horzRelTo: "Paper",
      treatAsChar: false,
      vertAlign: "Top",
      vertOffset: 2500,
      vertRelTo: "Paper",
      width: 12000,
    })
    assert.equal(recorded[0].kind, "AgentSetPicture")
    assert.deepEqual(recorded[0].payload, {
      section: 0,
      para: 12,
      control: 4,
      cell: null,
      props: { Width: 12_000, Height: 8_000, PosX: 1_500, PosY: 2_500 },
    })
  })

  it("sets cell picture geometry with a JSON cell path for wasm", () => {
    const pictureProps: any[] = []
    const recorded: any[] = []

    const editor = {
      ...WasmHwpEditor,
      doc: {
        setCellPicturePropertiesByPath(...args: any[]) {
          pictureProps.push(args)
        },
      },
      recordOp(kind: string, payload: any) {
        recorded.push({ kind, payload })
      },
    } as any

    const cellPath = [{ controlIndex: 2, cellIndex: 5, cellParaIndex: 1 }]
    const result = editor.applySetOne(
      {
        section: 0,
        paragraph: 9,
        control: 4,
        type: "picture",
        cellPath,
        cell: { parentParaIndex: 9, controlIndex: 2, cellIndex: 5, cellParaIndex: 1, cellPath },
      },
      { kind: "picture", Width: 12_000, Height: 8_000 }
    )

    assert.deepEqual(result, { ok: true })
    assert.deepEqual(pictureProps[0].slice(0, 4), [
      0,
      9,
      JSON.stringify(cellPath),
      4,
    ])
    assert.deepEqual(JSON.parse(pictureProps[0][4]), {
      height: 8000,
      width: 12000,
    })
    assert.equal(recorded[0].kind, "AgentSetPicture")
    assert.deepEqual(recorded[0].payload.cell.cellPath, cellPath)
  })

  it("builds toolbar cell refs that parseRef resolves to the SAME cell paragraph", () => {
    const editor = { ...WasmHwpEditor } as any
    // A textbox selection cell (single-level path) whose cellPath still carries
    // the selection ANCHOR's paragraph (19) — the shape that used to poison
    // parseRef and made every toolbar format fail with 셀 문단을 찾을 수 없음.
    const selCell = {
      parentParaIndex: 5,
      controlIndex: 0,
      cellIndex: 0,
      cellParaIndex: 19,
      cellPath: [{ controlIndex: 0, cellIndex: 0, cellParaIndex: 19 }],
      isTextBox: true,
    }

    const ref = editor.hwpToolbarRef(0, 6, 0, selCell)
    const parsed = editor.parseRef(ref)

    assert.equal(parsed.cell.parentParaIndex, 5)
    assert.equal(parsed.cell.cellParaIndex, 6)
    assert.equal(parsed.cell.controlIndex, 0)
    // Single-level: no cellPath leaks through to override the flat address.
    assert.equal(ref.cellPath, undefined)
  })

  it("rebuilds nested cellPath refs per paragraph with the parent as ref.paragraph", () => {
    const editor = { ...WasmHwpEditor } as any
    const nestedCell = {
      parentParaIndex: 9,
      controlIndex: 1,
      cellIndex: 2,
      cellParaIndex: 7,
      cellPath: [
        { controlIndex: 1, cellIndex: 2, cellParaIndex: 0 },
        { controlIndex: 0, cellIndex: 3, cellParaIndex: 7 },
      ],
    }

    const ref = editor.hwpToolbarRef(0, 4, 0, nestedCell)
    const parsed = editor.parseRef(ref)

    assert.equal(ref.paragraph, 9) // parent body paragraph (parseRef grammar)
    assert.deepEqual(ref.cellPath[1], { controlIndex: 0, cellIndex: 3, cellParaIndex: 4 })
    assert.equal(parsed.cell.parentParaIndex, 9)
    assert.equal(parsed.cell.cellParaIndex, 4)
  })

  it("applies paragraph alignment through the para set kind", () => {
    const paraFormats: any[] = []
    const recorded: any[] = []

    const editor = {
      ...WasmHwpEditor,
      doc: {
        applyParaFormat(...args: any[]) {
          paraFormats.push(args)
          return "{}"
        },
      },
      recordOp(kind: string, payload: any) {
        recorded.push({ kind, payload })
      },
    } as any

    const result = editor.applySetOne(
      { section: 0, paragraph: 7, offset: 3 },
      { kind: "para", Alignment: "center" }
    )

    assert.deepEqual(result, { ok: true })
    assert.deepEqual(paraFormats[0].slice(0, 2), [0, 7])
    assert.deepEqual(JSON.parse(paraFormats[0][2]), { alignment: "center" })
    assert.equal(recorded[0].kind, "AgentSetPara")
  })

  it("routes cell-paragraph alignment to applyParaFormatInCell", () => {
    const paraFormats: any[] = []

    const editor = {
      ...WasmHwpEditor,
      doc: {
        applyParaFormatInCell(...args: any[]) {
          paraFormats.push(args)
          return "{}"
        },
      },
      recordOp() {},
    } as any

    const result = editor.applySetOne(
      {
        section: 0,
        paragraph: 2,
        offset: 0,
        cell: { parentParaIndex: 5, controlIndex: 1, cellIndex: 3, cellParaIndex: 2 },
      },
      { kind: "para", Alignment: "right", LineSpacing: 180 }
    )

    assert.deepEqual(result, { ok: true })
    assert.deepEqual(paraFormats[0].slice(0, 5), [0, 5, 1, 3, 2])
    assert.deepEqual(JSON.parse(paraFormats[0][5]), { alignment: "right", lineSpacing: 180 })
  })

  it("dispatches align toolbar commands over deduped selection paragraphs", () => {
    const sets: any[] = []
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      documentId: "doc-1",
      format: "hwp",
      el: { isConnected: true },
      hwpToolbarCharRefs: () => [
        { section: 0, paragraph: 4, offset: 0, length: 10 },
        { section: 0, paragraph: 4, offset: 12, length: 3 },
        { section: 0, paragraph: 5, offset: 0, length: 8 },
      ],
      applySetOne(ref: any, props: any) {
        sets.push({ ref, props })
        return { ok: true }
      },
      finishAgentEdit() {},
      scheduleToolbarStateSync() {},
    } as any

    editor.handleToolbarCommand({ command: "align-center", document_id: "doc-1" })

    assert.equal(sets.length, 2) // paragraph 4 deduped
    assert.deepEqual(sets.map(s => s.ref.paragraph), [4, 5])
    assert.deepEqual(sets[0].props, { kind: "para", Alignment: "center" })
  })

  it("routes font-size-set, text color, and highlight commands to char props", () => {
    const sets: any[] = []
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      documentId: "doc-1",
      format: "hwp",
      el: { isConnected: true },
      hwpToolbarCharRefs: () => [{ section: 0, paragraph: 2, offset: 0, length: 4 }],
      applySetOne(ref: any, props: any) {
        sets.push(props)
        return { ok: true }
      },
      finishAgentEdit() {},
      scheduleToolbarStateSync() {},
    } as any

    editor.handleToolbarCommand({ command: "font-size-set", size: 15, document_id: "doc-1" })
    editor.handleToolbarCommand({ command: "text-color", color: "#e11d48", document_id: "doc-1" })
    editor.handleToolbarCommand({ command: "highlight", color: "#fde047", document_id: "doc-1" })
    // Malformed payloads are dropped before reaching the engine.
    editor.handleToolbarCommand({ command: "font-size-set", size: 0, document_id: "doc-1" })
    editor.handleToolbarCommand({ command: "text-color", document_id: "doc-1" })

    assert.deepEqual(sets, [
      { kind: "char", FontSize: 15 },
      { kind: "char", TextColor: "#e11d48" },
      { kind: "char", shadeColor: "#fde047" },
    ])
  })

  it("syncs toolbar state even when rAF never fires (backgrounded tab)", async () => {
    const win = (globalThis as any).window
    const originalRaf = win.requestAnimationFrame
    win.requestAnimationFrame = () => 0 // background tab: callback never runs

    try {
      let emits = 0
      const editor = {
        ...WasmHwpEditor,
        mirror: false,
        emitToolbarState() { emits++ },
      } as any

      editor.scheduleToolbarStateSync()
      await new Promise(resolve => setTimeout(resolve, 200))
      assert.equal(emits, 1, "timeout twin fires when rAF is frozen")
      assert.equal(editor.toolbarStateSyncQueued, false, "queued flag resets")

      // The flag must not stick: a second sync still goes through.
      editor.scheduleToolbarStateSync()
      await new Promise(resolve => setTimeout(resolve, 200))
      assert.equal(emits, 2)
    } finally {
      win.requestAnimationFrame = originalRaf
    }
  })

  it("broadcasts the caret font size in points for the toolbar input", () => {
    const events: any[] = []
    const originalDispatch = (globalThis as any).document.dispatchEvent
    ;(globalThis as any).document.dispatchEvent = (event: any) => {
      events.push(event)
      return true
    }

    try {
      const editor = {
        ...WasmHwpEditor,
        documentId: "doc-3",
        caret: { section: 0, paragraph: 1, offset: 2, cell: null },
        doc: {
          getCharPropertiesAt: () => JSON.stringify({ bold: false, fontSize: 1150 }),
          getParaPropertiesAt: () => JSON.stringify({ alignment: "left" }),
        },
      } as any

      editor.emitToolbarState()
      assert.equal(events[0].detail.font_size_pt, 11.5)

      // No engine size → null, so the toolbar keeps its last display.
      events.length = 0
      editor.doc.getCharPropertiesAt = () => JSON.stringify({ bold: false })
      editor.emitToolbarState()
      assert.equal(events[0].detail.font_size_pt, null)
    } finally {
      ;(globalThis as any).document.dispatchEvent = originalDispatch
    }
  })

  it("broadcasts cell-caret paragraph alignment via getCellParaPropertiesAt", () => {
    const events: any[] = []
    const originalDispatch = (globalThis as any).document.dispatchEvent
    ;(globalThis as any).document.dispatchEvent = (event: any) => {
      events.push(event)
      return true
    }

    try {
      const cellParaCalls: any[] = []
      const editor = {
        ...WasmHwpEditor,
        documentId: "doc-2",
        caret: {
          section: 0,
          paragraph: 0,
          offset: 3,
          cell: { parentParaIndex: 0, controlIndex: 2, cellIndex: 0, cellParaIndex: 0 },
        },
        doc: {
          getCellCharPropertiesAt: () => JSON.stringify({ bold: true }),
          getCellParaPropertiesAt: (...args: any[]) => {
            cellParaCalls.push(args)
            return JSON.stringify({ alignment: "center" })
          },
        },
      } as any

      editor.emitToolbarState()

      assert.deepEqual(cellParaCalls[0], [0, 0, 2, 0, 0])
      assert.equal(events[0].detail.alignment, "center")
      assert.equal(events[0].detail.bold, true)
    } finally {
      ;(globalThis as any).document.dispatchEvent = originalDispatch
    }
  })

  it("broadcasts caret format state for the toolbar", () => {
    const events: any[] = []
    const originalDispatch = (globalThis as any).document.dispatchEvent
    ;(globalThis as any).document.dispatchEvent = (event: any) => {
      events.push(event)
      return true
    }

    try {
      const editor = {
        ...WasmHwpEditor,
        documentId: "doc-9",
        caret: { section: 0, paragraph: 3, offset: 5, cell: null },
        doc: {
          getCharPropertiesAt: () => JSON.stringify({ bold: true, underline: false }),
          getParaPropertiesAt: () => JSON.stringify({ alignment: "center" }),
        },
      } as any

      editor.emitToolbarState()

      assert.equal(events.length, 1)
      assert.equal(events[0].type, "ecrits:editor-state")
      assert.equal(events[0].detail.document_id, "doc-9")
      assert.equal(events[0].detail.bold, true)
      assert.equal(events[0].detail.underline, false)
      assert.equal(events[0].detail.alignment, "center")
    } finally {
      ;(globalThis as any).document.dispatchEvent = originalDispatch
    }
  })

  it("asks the open editor for authoritative bytes before rendering VFS highlights", () => {
    let requested: any = null

    const editor = {
      ...WasmHwpEditor,
      mirror: true,
      documentId: "doc-1",
      previewSavedHighlights: [],
      canvasState: {
        previewTurnId: "turn-1",
        previewText: "",
        previewDeltaCount: 9,
        previewHighlights: JSON.stringify([
          { op: "insert_table", ref: { section: 0, paragraph: 1, offset: 0 }, text: "A1" },
        ]),
      },
      readCanvasState() {
        return this.canvasState
      },
      el: {
        dataset: {},
      },
      requestAuthoritativePreview(payload: any) {
        requested = payload
        return true
      },
      renderSavedEditHighlights() {
        throw new Error("mirror must not render saved-file highlights before asking authority")
      },
    } as any

    editor.updated()

    assert.equal(editor.el.dataset.previewAuthorityState, "waiting")
    assert.equal(requested.authority_bytes, true)
    assert.equal(requested.document_id, "doc-1")
    assert.equal(requested.turn_id, "turn-1")
    assert.equal(requested.preview_highlights.length, 1)
  })

  it("does not re-request authority after loading authoritative preview bytes", () => {
    let requested = 0
    let rendered = 0

    const editor = {
      ...WasmHwpEditor,
      mirror: true,
      previewSavedHighlights: [],
      canvasState: {
        previewHighlights: JSON.stringify([
          { op: "insert_table", ref: { section: 0, paragraph: 1, offset: 0 }, text: "A1" },
        ]),
      },
      el: {
        dataset: {},
      },
      requestAuthoritativePreview() {
        requested += 1
        return true
      },
      renderSavedEditHighlights() {
        rendered += 1
      },
    } as any

    assert.equal(editor.handleLoadedPreviewHighlights(true, { document_id: "doc-1" }), true)
    assert.equal(requested, 0)
    assert.equal(rendered, 1)
  })

  it("uses native saved-edit highlight rects before TS coordinate fallbacks", () => {
    let nativeInput = ""
    const editor = {
      ...WasmHwpEditor,
      doc: {
        getSavedEditHighlightRects(input: string) {
          nativeInput = input
          return JSON.stringify([{ pageIndex: 2, x: 210, y: 320, width: 48, height: 17 }])
        },
        getSelectionRectsInCell() {
          throw new Error("legacy selection rects must not run when native preview rects exist")
        },
      },
    } as any

    const highlight = {
      op: "set_cell",
      ref: {
        section: 0,
        paragraph: 5,
        offset: 0,
        cell: { parentParaIndex: 5, controlIndex: 0, cellIndex: 0, cellParaIndex: 0 },
      },
      text: "AI 내부 편집 데모",
    }
    const rects = editor.rectsForSavedEditHighlight(highlight)

    assert.deepEqual(rects, [
      { pageIndex: 2, x: 210, y: 320, width: 48, height: 17, savedHighlightNative: true, savedHighlightAuthority: "saved-edit-api" },
    ])
    assert.deepEqual(JSON.parse(nativeInput), highlight)
  })

  it("does not inflate precise native saved-edit rects with fallback minimums", () => {
    const fills: any[] = []
    const editor = {
      ...WasmHwpEditor,
    } as any
    const overlay = {
      width: 200,
      height: 100,
      getBoundingClientRect() {
        return { width: 100, height: 50 }
      },
    }
    const ctx = {
      fillStyle: "",
      strokeStyle: "",
      lineWidth: 0,
      fillRect(...args: any[]) {
        fills.push(args)
      },
      strokeRect() {},
    }

    editor.paintEditHighlightRect(
      ctx,
      overlay,
      { pageIndex: 0, x: 10, y: 20, width: 6, height: 8, savedHighlightNative: true },
      1
    )
    editor.paintEditHighlightRect(
      ctx,
      overlay,
      { pageIndex: 0, x: 10, y: 20, width: 6, height: 8 },
      1
    )

    assert.deepEqual(fills[0], [10, 20, 6, 8])
    assert.deepEqual(fills[1], [0, 10, 56, 28])
  })

  it("uses a bounded text estimate when a saved cell edit only has degenerate rects", () => {
    const editor = {
      ...WasmHwpEditor,
      doc: {
        getSelectionRectsInCell() {
          return JSON.stringify([
            { pageIndex: 10, x: 98.3, y: 264.3, width: 3.8, height: 1.3 },
            { pageIndex: 10, x: 98.3, y: 266.4, width: 3.8, height: 1.3 },
          ])
        },
        getCellParagraphLength() {
          return 8
        },
        getTableCellBboxes() {
          return JSON.stringify([
            { cellIdx: 0, row: 0, col: 0, pageIndex: 10, x: 98.3, y: 264.3, w: 3.8, h: 5.6 },
            { cellIdx: 1, row: 0, col: 1, pageIndex: 10, x: 102.1, y: 264.3, w: 44.9, h: 5.6 },
            { cellIdx: 2, row: 0, col: 2, pageIndex: 10, x: 147, y: 264.3, w: 473.4, h: 5.6 },
          ])
        },
      },
    } as any

    const rects = editor.rectsForSavedEditHighlight({
      op: "set_cell",
      ref: {
        section: 1,
        paragraph: 5,
        offset: 0,
        cell: { parentParaIndex: 5, controlIndex: 0, cellIndex: 0, cellParaIndex: 0 },
      },
      text: "최종 내부 편집",
    })

    assert.equal(rects.length, 1)
    assert.deepEqual(
      {
        ...rects[0],
        width: Math.round(rects[0].width * 10) / 10,
        height: Math.round(rects[0].height * 10) / 10,
      },
      { pageIndex: 10, x: 98.3, y: 264.3, width: 93, height: 17, savedHighlightAuthority: "cell-bbox" }
    )
  })

  it("uses a bounded text estimate before cursor fallback when saved cell rects are empty", () => {
    const editor = {
      ...WasmHwpEditor,
      doc: {
        getSelectionRectsInCell() {
          return "[]"
        },
        getCellParagraphLength() {
          return 8
        },
        getTableCellBboxes() {
          return JSON.stringify([
            { cellIdx: 0, row: 0, col: 0, pageIndex: 10, x: 98.3, y: 264.3, w: 3.8, h: 3.8 },
            { cellIdx: 1, row: 0, col: 1, pageIndex: 10, x: 102.1, y: 264.3, w: 44.9, h: 3.8 },
            { cellIdx: 2, row: 0, col: 2, pageIndex: 10, x: 147, y: 264.3, w: 473.4, h: 3.8 },
            { cellIdx: 3, row: 0, col: 3, pageIndex: 10, x: 620.4, y: 264.3, w: 3.8, h: 3.8 },
          ])
        },
        getCursorRectInCell() {
          return JSON.stringify({ pageIndex: 10, x: 98, y: 266, width: 72, height: 1 })
        },
      },
    } as any

    const rects = editor.rectsForSavedEditHighlight({
      op: "set_cell",
      ref: {
        section: 1,
        paragraph: 5,
        offset: 0,
        cell: { parentParaIndex: 5, controlIndex: 0, cellIndex: 0, cellParaIndex: 0 },
      },
      text: "최종 내부 편집",
    })

    assert.equal(rects.length, 1)
    assert.equal(rects[0].pageIndex, 10)
    assert.equal(Math.round(rects[0].width * 10) / 10, 93)
    assert.equal(Math.round(rects[0].height * 10) / 10, 17)
  })

  it("keeps precise saved cell text rects when the engine returns usable geometry", () => {
    const editor = {
      ...WasmHwpEditor,
      doc: {
        getSelectionRectsInCell() {
          return JSON.stringify([
            { pageIndex: 2, x: 120, y: 210, width: 64, height: 18 },
          ])
        },
        getCellParagraphLength() {
          return 8
        },
        getTableCellBboxes() {
          throw new Error("usable text rects should not fall back to table bboxes")
        },
      },
    } as any

    const rects = editor.rectsForSavedEditHighlight({
      op: "set_cell",
      ref: {
        section: 0,
        paragraph: 5,
        offset: 0,
        cell: { parentParaIndex: 5, controlIndex: 0, cellIndex: 0, cellParaIndex: 0 },
      },
      text: "정상 셀",
    })

    assert.deepEqual(rects, [
      { pageIndex: 2, x: 120, y: 210, width: 64, height: 18, savedHighlightNative: true, savedHighlightAuthority: "selection-cell" },
    ])
  })

  it("asks the engine for every paragraph changed by a multiline saved cell edit", () => {
    let requested: number[] = []
    const editor = {
      ...WasmHwpEditor,
      doc: {
        getSelectionRectsInCell(...args: number[]) {
          requested = args
          return JSON.stringify([
            { pageIndex: 3, x: 400, y: 360, width: 220, height: 13 },
            { pageIndex: 3, x: 400, y: 380, width: 150, height: 13 },
          ])
        },
      },
    } as any

    const rects = editor.rectsForSavedEditHighlight({
      op: "set_cell",
      ref: {
        section: 0,
        paragraph: 76,
        offset: 0,
        cell: { parentParaIndex: 76, controlIndex: 0, cellIndex: 3, cellParaIndex: 0 },
      },
      text: "첫째 줄\n둘째 줄\n마지막",
    })

    assert.deepEqual(requested, [0, 76, 0, 3, 0, 0, 2, 3])
    assert.equal(rects.length, 2)
    assert.ok(rects.every((rect: any) => rect.savedHighlightNative === true))
  })

  it("restores saved VFS edit highlights when caret blink clears the overlay", () => {
    const calls: any[] = []

    const editor = {
      ...WasmHwpEditor,
      scale: 1,
      caretBlinkOn: false,
      caret: { cursorRect: { pageIndex: 0, x: 3, y: 4, height: 10 } },
      previewSavedHighlight: {
        rects: [{ pageIndex: 0, x: 10, y: 20, width: 30, height: 40 }],
      },
      pageSection() {
        return {
          querySelector() {
            return {
              width: 100,
              height: 100,
              getContext() {
                return {
                  fillStyle: "",
                  clearRect(...args: any[]) {
                    calls.push(["clear", ...args])
                  },
                  fillRect(...args: any[]) {
                    calls.push(["fill", ...args])
                  },
                }
              },
            }
          },
        }
      },
      pageOverlay() {
        return {
          getContext() {
            return {
              fillStyle: "",
              fillRect(...args: any[]) {
                calls.push(["saved", ...args])
              },
            }
          },
        }
      },
      paintPreviewPatchHighlightOnPage() {},
      paintAdornmentsOnPage() {},
    } as any

    editor.drawCaret(editor.caret)

    assert.deepEqual(calls[0], ["clear", 0, 0, 100, 100])
    assert.deepEqual(calls[1], ["saved", 10, 20, 30, 40])
    assert.equal(calls.some(([kind]) => kind === "fill"), false)
  })

  it("publishes authoritative preview bytes for mirror cards", () => {
    const oldUrl = (globalThis as any).URL
    const urls: string[] = []

    ;(globalThis as any).URL = {
      createObjectURL(blob: Blob) {
        assert.equal(blob.type, "application/vnd.hancom.hwpx")
        urls.push("blob:authority")
        return "blob:authority"
      },
      revokeObjectURL(url: string) {
        urls.push(`revoked:${url}`)
      },
    }

    try {
      const editor = {
        ...WasmHwpEditor,
        mirror: false,
        documentId: "doc-1",
        format: "hwpx",
        previewPatchCount: 0,
        previewPatchTurnId: "turn-1",
        previewPatchAnchor: null,
        previewPatchCursor: null,
        el: { id: "main-editor", dataset: { previewModelMatches: "true" } },
        doc: {},
        readPreviewModelText() {
          return "editor truth"
        },
        exportDocumentBytes() {
          return new Uint8Array([1, 2, 3])
        },
      } as any

      const state = editor.buildAuthoritativePreviewState({
        authority_bytes: true,
        document_id: "doc-1",
        turn_id: "turn-1",
      })

      assert.equal(state.bytes_url, "blob:authority")
      assert.equal(state.model_text, "editor truth")
      assert.equal(state.source_editor_id, "main-editor")
    } finally {
      ;(globalThis as any).URL = oldUrl
    }
  })
})

describe("WasmHwpEditor table cell-block selection", () => {
  // A 2x2 table: cellIndex 0..3 → (row,col) (0,0)(0,1)(1,0)(1,1), each a
  // 10x10 page-unit box laid out as a 20x20 grid on page 0.
  const ROWCOL: Record<number, { row: number; col: number }> = {
    0: { row: 0, col: 0 },
    1: { row: 0, col: 1 },
    2: { row: 1, col: 0 },
    3: { row: 1, col: 1 },
  }
  const BBOXES = [
    { cellIdx: 0, row: 0, col: 0, rowSpan: 1, colSpan: 1, pageIndex: 0, x: 0, y: 0, w: 10, h: 10 },
    { cellIdx: 1, row: 0, col: 1, rowSpan: 1, colSpan: 1, pageIndex: 0, x: 10, y: 0, w: 10, h: 10 },
    { cellIdx: 2, row: 1, col: 0, rowSpan: 1, colSpan: 1, pageIndex: 0, x: 0, y: 10, w: 10, h: 10 },
    { cellIdx: 3, row: 1, col: 1, rowSpan: 1, colSpan: 1, pageIndex: 0, x: 10, y: 10, w: 10, h: 10 },
  ]

  function makeEditor() {
    const painted: Array<{ x: number; y: number; w: number; h: number }> = []
    const ctx = {
      fillStyle: "",
      clearRect() {},
      fillRect(x: number, y: number, w: number, h: number) {
        painted.push({ x, y, w, h })
      },
    }
    const editor = {
      ...WasmHwpEditor,
      scale: 1,
      sel: { kind: "text", marker: "stale" }, // a stale text selection promotion must drop
      dragSelect: {
        section: 0,
        cell: { parentParaIndex: 5, controlIndex: 0, cellIndex: 0, cellPath: null },
      },
      doc: {
        getCellInfo(_s: number, _p: number, _c: number, cellIndex: number) {
          return JSON.stringify(ROWCOL[cellIndex])
        },
        getTableCellBboxes() {
          return JSON.stringify(BBOXES)
        },
      },
      // Bypass the DOM overlay plumbing; capture painted rects directly.
      clearSelectionOverlays() {},
      pageOverlay() {
        return { width: 20, height: 20, getContext: () => ctx }
      },
    } as any
    return { editor, painted }
  }

  function hit(cellIndex: number, extra: any = {}) {
    return {
      sectionIndex: 0,
      parentParaIndex: 5,
      controlIndex: 0,
      cellIndex,
      cellPath: null,
      ...extra,
    }
  }

  it("does not promote while the drag stays inside the anchor cell", () => {
    const { editor, painted } = makeEditor()
    assert.equal(editor.updateCellBlockFromHit(hit(0)), false)
    assert.equal(editor.cellSel(), null)
    assert.equal(painted.length, 0)
    assert.equal(editor.sel.marker, "stale") // text selection untouched
  })

  it("promotes to a cell-block when the drag crosses into another cell", () => {
    const { editor, painted } = makeEditor()
    const handled = editor.updateCellBlockFromHit(hit(3)) // (0,0) -> (1,1)
    assert.equal(handled, true)
    assert.ok(editor.cellSel())
    assert.deepEqual(editor.cellSel().anchor, { row: 0, col: 0 })
    assert.deepEqual(editor.cellSel().focus, { row: 1, col: 1 })
    assert.equal(editor.textSel(), null) // promotion supersedes text selection
    // Full 2x2 range → all four cells painted.
    assert.equal(painted.length, 4)
    assert.deepEqual((globalThis as any).window.__rhwpCellSelection.range, {
      startRow: 0,
      endRow: 1,
      startCol: 0,
      endCol: 1,
    })
  })

  it("extends (and shrinks) the focus on subsequent moves within the table", () => {
    const { editor, painted } = makeEditor()
    editor.updateCellBlockFromHit(hit(3)) // diagonal: 4 cells
    painted.length = 0
    const handled = editor.updateCellBlockFromHit(hit(1)) // back to the top row (0,1)
    assert.equal(handled, true)
    assert.deepEqual(editor.cellSel().focus, { row: 0, col: 1 })
    // Range is now just row 0 → two cells.
    assert.equal(painted.length, 2)
  })

  it("stays in block mode but keeps the last focus when the pointer leaves the table", () => {
    const { editor } = makeEditor()
    editor.updateCellBlockFromHit(hit(3))
    // A body hit (no cell context) must not break or reset the block.
    const handled = editor.updateCellBlockFromHit({ sectionIndex: 0, paragraphIndex: 9, charOffset: 2 })
    assert.equal(handled, true)
    assert.deepEqual(editor.cellSel().focus, { row: 1, col: 1 })
  })

  it("does not promote nested-table cell drags (out of scope)", () => {
    const { editor } = makeEditor()
    editor.dragSelect.cell.cellPath = [{ a: 1 }, { b: 2 }] // nested
    assert.equal(editor.updateCellBlockFromHit(hit(3, { cellPath: [{ a: 1 }, { b: 2 }] })), false)
    assert.equal(editor.cellSel(), null)
  })

  it("does not promote across a different table or section", () => {
    const { editor } = makeEditor()
    // Same section, different table control → not the anchor's table.
    assert.equal(editor.updateCellBlockFromHit(hit(3, { controlIndex: 1 })), false)
    assert.equal(editor.cellSel(), null)
  })
})

describe("WasmHwpEditor picker hover preview", () => {
  // A canvas 2d context that records what the picker paints.
  function recordingCtx() {
    const rects: Array<{ x: number; y: number; w: number; h: number; dashed: boolean }> = []
    let dash: number[] = []
    const ctx = {
      fillStyle: "",
      strokeStyle: "",
      lineWidth: 0,
      save() {},
      restore() {
        dash = []
      },
      setLineDash(pattern: number[]) {
        dash = pattern
      },
      fillRect(x: number, y: number, w: number, h: number) {
        rects.push({ x, y, w, h, dashed: dash.length > 0 })
      },
      strokeRect() {},
    }
    return { ctx, rects }
  }

  const pageEvent = {
    target: {
      closest: (sel: string) => (sel.includes("local-hwp-page") ? {} : null),
    },
  }

  it("routes a picker-mode mousemove to the hover probe, not selection", () => {
    let queued: any = "unset"
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      imageDrag: null,
      dragSelect: null,
      pickerEnabled: () => true,
      queuePickerHover(event: any) {
        queued = event
      },
    } as any

    editor.onCanvasMouseMove(pageEvent)
    assert.equal(queued, pageEvent)
  })

  it("routes a normal mousemove to the text-cursor probe when the picker is off", () => {
    let pickerQueued = false
    let textQueued: any = null
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      imageDrag: null,
      dragSelect: null,
      pickerEnabled: () => false,
      queuePickerHover() {
        pickerQueued = true
      },
      queueTextCursorHover(event: any) {
        textQueued = event
      },
    } as any

    editor.onCanvasMouseMove(pageEvent)
    assert.equal(pickerQueued, false)
    assert.equal(textQueued, pageEvent)
  })

  it("resolves the element under the cursor into a hover preview", () => {
    let painted = 0
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      pickerEnabled: () => true,
      pickerHover: null,
      hitTestEvent: () => ({ hit: { sectionIndex: 0 }, pageIndex: 0 }),
      hwpPick: () => ({ type: "paragraph", ref: '{"section":0}', rects: [{ x: 1, y: 2, width: 3, height: 4 }] }),
      paintPickedHighlights() {
        painted += 1
      },
    } as any

    editor.updatePickerHover(pageEvent)
    assert.deepEqual(editor.pickerHover.rects, [{ x: 1, y: 2, width: 3, height: 4, pageIndex: 0 }])
    assert.equal(painted, 1) // setPickerHover repaints so the box actually shows
  })

  it("does not preview the synthetic point-square fallback (no false hover)", () => {
    // hwpPick returns a fabricated 48px point-square (fallbackPoint) when the
    // engine resolved no real rects — the hover must show nothing, not a box
    // floating off the element under the cursor.
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      pickerEnabled: () => true,
      pickerHover: null,
      hitTestEvent: () => ({ hit: { sectionIndex: 0 }, pageIndex: 0 }),
      hwpPick: () => ({
        type: "paragraph",
        ref: '{"section":0}',
        rects: [{ x: 100, y: 40, width: 48, height: 48, pageIndex: 0, fallbackPoint: true }],
      }),
      paintPickedHighlights() {},
    } as any

    editor.updatePickerHover(pageEvent)
    assert.equal(editor.pickerHover, null)
  })

  it("clears the hover preview when the cursor leaves every page", () => {
    let painted = 0
    const editor = {
      ...WasmHwpEditor,
      doc: {},
      pickerEnabled: () => true,
      pickerHover: { key: "stale", rects: [{ x: 0, y: 0, width: 1, height: 1, pageIndex: 0 }] },
      paintPickedHighlights() {
        painted += 1
      },
    } as any

    editor.updatePickerHover({ target: { closest: () => null } })
    assert.equal(editor.pickerHover, null)
    assert.equal(painted, 1)
  })

  it("paints the hover box dashed (distinct from a solid committed pick)", () => {
    const { ctx, rects } = recordingCtx()
    const editor = {
      ...WasmHwpEditor,
      scale: 1,
      pickerEnabled: () => true,
      pickerHover: { key: "x", rects: [{ x: 5, y: 6, width: 7, height: 8, pageIndex: 0 }] },
      documentAdornmentPicks: () => [],
      pageOverlay: () => ({ getContext: () => ctx }),
    } as any

    editor.paintAdornmentsOnPage(0)
    // Gathered union box, framed with 2px padding (scale 1): x/y shift -2, w/h +4.
    assert.deepEqual(rects, [{ x: 3, y: 4, w: 11, h: 12, dashed: true }])
  })

  it("gathers multiple element rects into ONE hover box (union)", () => {
    const { ctx, rects } = recordingCtx()
    const editor = {
      ...WasmHwpEditor,
      scale: 1,
      pickerEnabled: () => true,
      // two line-rects of the same element -> a single gathered box
      pickerHover: { key: "x", rects: [
        { x: 10, y: 10, width: 100, height: 12, pageIndex: 0 },
        { x: 10, y: 24, width: 60, height: 12, pageIndex: 0 },
      ] },
      documentAdornmentPicks: () => [],
      pageOverlay: () => ({ getContext: () => ctx }),
    } as any

    editor.paintAdornmentsOnPage(0)
    // union bbox = x10..110, y10..36 -> with 2px pad: x8 y8 w104 h30
    assert.deepEqual(rects, [{ x: 8, y: 8, w: 104, h: 30, dashed: true }])
  })
})
