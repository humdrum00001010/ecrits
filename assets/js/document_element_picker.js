const EVENT_TOGGLE = "ecrits:document-element-picker.toggle"
const EVENT_STATE = "ecrits:document-element-picker.state"
const EVENT_PICKS = "ecrits:document-element-picker.picks"
const BUTTON_SELECTOR = "[data-role='document-element-picker-toggle']"
const COMPOSER_SELECTOR = "#local-agent-input"
const BLOCK_HEADER = "Selected document elements"
// Matches the whole previously-injected block so it can be replaced in place.
const BLOCK_RE = /Selected document elements \(\d+\):\n```json\n[\s\S]*?\n```\n?/

const state = {
  enabled: false,
  // Multi-select: every picked element, keyed by its ref string. A second pick
  // of the same element REMOVES it (toggle).
  picks: [],
}

function setEnabled(enabled) {
  state.enabled = !!enabled
  document.body.dataset.documentElementPicker = String(state.enabled)

  for (const button of document.querySelectorAll(BUTTON_SELECTOR)) {
    button.setAttribute("aria-pressed", String(state.enabled))
    button.dataset.active = String(state.enabled)
  }

  // Deactivating the picker KEEPS the picks: the selection block stays in the
  // composer (and highlighted in the document) so the user can keep typing
  // around it. Picks are consumed when the message is sent (submit listener
  // below), or removed individually by re-entering picker mode and re-clicking.
  document.dispatchEvent(new CustomEvent(EVENT_STATE, { detail: { enabled: state.enabled } }))
}

function toggle() {
  setEnabled(!state.enabled)
}

function pickKey(pick) {
  return `${pick.document || ""}|${pick.ref || ""}`
}

function normalizePick(pick) {
  return {
    document: pick.document || "",
    backend: pick.backend || "",
    format: pick.format || "",
    type: pick.type || "unknown",
    ref: pick.ref || "",
    text: pick.text || "",
    ir: pick.ir || {},
    rects: pick.rects || [],
  }
}

function picksChanged() {
  syncComposer()
  document.dispatchEvent(new CustomEvent(EVENT_PICKS, { detail: { picks: state.picks } }))
}

export function elementPickerEnabled() {
  return state.enabled
}

export function pickedElements() {
  return state.picks
}

export function clearPicks() {
  if (state.picks.length === 0) return
  state.picks = []
  picksChanged()
}

// Add the pick; picking an already-picked element removes it (toggle).
// Returns true when the element is now selected, false when it was removed.
export function togglePickedElement(pick) {
  const normalized = normalizePick(pick)
  const key = pickKey(normalized)
  const existing = state.picks.findIndex(p => pickKey(p) === key)
  let added
  if (existing >= 0) {
    state.picks.splice(existing, 1)
    added = false
  } else {
    state.picks.push(normalized)
    added = true
  }
  picksChanged()
  return added
}

export function bindElementPickerTarget(target) {
  const apply = enabled => {
    target.elementPickerEnabled = !!enabled
    if (target.el) target.el.dataset.elementPicker = String(target.elementPickerEnabled)
    // Let the editor react to mode flips (e.g. clear its hover preview).
    if (typeof target.onElementPickerState === "function") {
      target.onElementPickerState(target.elementPickerEnabled)
    }
  }

  const onState = event => apply(event.detail && event.detail.enabled)
  const onPicks = () => {
    if (typeof target.paintPickedHighlights === "function") target.paintPickedHighlights()
  }
  apply(state.enabled)
  document.addEventListener(EVENT_STATE, onState)
  document.addEventListener(EVENT_PICKS, onPicks)

  return () => {
    document.removeEventListener(EVENT_STATE, onState)
    document.removeEventListener(EVENT_PICKS, onPicks)
  }
}

// Keep ONE compact block in the composer describing every current pick (the
// agent reads document/type/ref/text; rects/ir stay editor-side). Replaces the
// previous block in place so repeated picks don't pile up duplicate JSON.
function syncComposer() {
  const input = document.querySelector(COMPOSER_SELECTOR)
  if (!input) return

  const value = input.value || ""
  const stripped = value.replace(BLOCK_RE, "")

  let next = stripped
  if (state.picks.length > 0) {
    const compact = state.picks.map(p => ({
      document: p.document,
      type: p.type,
      ref: p.ref,
      text: (p.text || "").slice(0, 200),
    }))
    const block =
      `${BLOCK_HEADER} (${state.picks.length}):\n` +
      "```json\n" + JSON.stringify(compact, null, 2) + "\n```\n"
    const sep = stripped && !stripped.endsWith("\n") ? "\n\n" : ""
    next = `${stripped}${sep}${block}`
  }

  if (next !== value) {
    input.value = next
    input.dispatchEvent(new Event("input", { bubbles: true }))
  }
}

// Back-compat single-pick entry (now routes through the multi-select state).
export function appendPickedElementToComposer(pick) {
  return togglePickedElement(pick)
}

document.addEventListener(EVENT_TOGGLE, event => {
  event.preventDefault()
  toggle()
})

document.addEventListener("keydown", event => {
  if (event.key === "Escape" && state.enabled) {
    if (state.picks.length > 0) clearPicks()
    else setEnabled(false)
  }
})

// Sending the chat message consumes the picks: the block is part of the
// submitted composer value, so the references just went to the agent. Clear on
// the next tick — LiveView serializes the form synchronously during the submit
// dispatch, and stripping the block before that would drop it from the send.
// (The composer's double-submit guard stops propagation for dropped submits,
// so a blocked submit never reaches this listener.)
document.addEventListener("submit", event => {
  if (!event.target.closest?.('[data-role="chat-form"]')) return
  if (state.picks.length === 0) return
  setTimeout(() => clearPicks(), 0)
})

window.EcritsDocumentElementPicker = {
  get enabled() {
    return state.enabled
  },
  get picks() {
    return state.picks
  },
  setEnabled,
  toggle,
  clearPicks,
}
