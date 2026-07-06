// Ctrl/⌘+wheel zoom for any `[data-editor-zoomable]` editor surface: smoothed
// (critically damped toward the target scale), anchored at the pointer so the
// content under the cursor stays put, with the layout footprint (margins)
// adjusted so the scaled content still scrolls naturally.
import {SEL} from "./selectors.ts"
const editorZoomAnimations = new WeakMap()
const editorZoomSmoothingMs = 36
const editorZoomMin = 0.5
const editorZoomMax = 4
const editorZoomMaxStep = 0.8
const editorZoomSensitivity = 0.01

export function installEditorZoom() {
  window.addEventListener("wheel", event => {
    if (!event.ctrlKey || !event.target || typeof event.target.closest !== "function") return
    const content = event.target.closest(SEL.editorZoomable)
    if (!content) return

    event.preventDefault()
    const scroller = findEditorZoomScroller(content)
    const rect = scroller.getBoundingClientRect()
    const scale = readEditorZoom(content)
    const state = editorZoomAnimations.get(content) || {
      scale,
      target: scale,
      frame: null,
      lastTime: null,
    }
    const step = Math.min(editorZoomMaxStep, Math.abs(event.deltaY) * editorZoomSensitivity)
    const factor = 1 + step
    const next = clampEditorZoom(event.deltaY < 0 ? state.target * factor : state.target / factor)

    state.scroller = scroller
    state.anchorX = event.clientX - rect.left
    state.anchorY = event.clientY - rect.top
    state.target = next

    content.dataset.editorZoom = formatEditorZoom(next)
    content.style.zoom = ""
    content.style.transformOrigin = "0 0"
    content.style.transition = ""
    content.style.willChange = "transform"

    editorZoomAnimations.set(content, state)
    if (!state.frame) {
      state.lastTime = performance.now()
      state.frame = requestAnimationFrame(time => animateEditorZoom(content, time))
    }
  }, {passive: false, capture: true})
}

function animateEditorZoom(content, time) {
  const state = editorZoomAnimations.get(content)
  if (!state || !content.isConnected) {
    editorZoomAnimations.delete(content)
    return
  }

  const dt = Math.min(40, Math.max(0, time - (state.lastTime || time)))
  const alpha = 1 - Math.exp(-dt / editorZoomSmoothingMs)
  const scale = Math.exp(Math.log(state.scale) + (Math.log(state.target) - Math.log(state.scale)) * alpha)
  applyEditorZoom(content, state, scale)
  state.lastTime = time

  if (Math.abs(state.target - state.scale) > 0.001) {
    state.frame = requestAnimationFrame(nextTime => animateEditorZoom(content, nextTime))
  } else {
    applyEditorZoom(content, state, state.target)
    state.frame = null
    state.lastTime = null
    content.style.willChange = ""
  }
}

function applyEditorZoom(content, state, scale) {
  const previous = state.scale || scale
  const ratio = previous > 0 ? scale / previous : 1
  const scroller = state.scroller?.isConnected ? state.scroller : findEditorZoomScroller(content)
  content.style.transform = `scale(${formatEditorZoom(scale)})`
  updateEditorZoomFootprint(content, scale)
  if (ratio !== 1) {
    scroller.scrollLeft = (scroller.scrollLeft + state.anchorX) * ratio - state.anchorX
    scroller.scrollTop = (scroller.scrollTop + state.anchorY) * ratio - state.anchorY
  }
  state.scroller = scroller
  state.scale = scale
}

function updateEditorZoomFootprint(content, scale) {
  const height = content.offsetHeight
  const delta = height * (scale - 1)
  const overviewInset = scale < 1 ? content.offsetWidth * (1 - scale) / 2 : 0
  content.style.marginBottom = Math.abs(delta) > 0.5 ? `${delta}px` : ""
  content.style.marginLeft = overviewInset > 0.5 ? `${overviewInset}px` : ""
  content.style.marginRight = overviewInset > 0.5 ? `${-overviewInset}px` : ""
}

function readEditorZoom(content) {
  const transform = window.getComputedStyle(content).transform
  if (transform && transform !== "none") {
    try {
      const scale = new DOMMatrixReadOnly(transform).a
      if (Number.isFinite(scale) && scale > 0) return scale
    } catch (_error) {
      // Fall back to the stored zoom value below.
    }
  }
  return Number.parseFloat(content.dataset.editorZoom || "1") || 1
}

function clampEditorZoom(scale) {
  return Math.min(editorZoomMax, Math.max(editorZoomMin, scale))
}

function formatEditorZoom(scale) {
  return String(Number(scale.toFixed(4)))
}

function findEditorZoomScroller(content) {
  for (let el = content.parentElement; el; el = el.parentElement) {
    const style = window.getComputedStyle(el)
    if (/(auto|scroll)/.test(`${style.overflow}${style.overflowX}${style.overflowY}`) && (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) return el
  }
  return document.scrollingElement || document.documentElement
}
