const EVENT_TOGGLE = "ecrits:document-element-picker.toggle"
const EVENT_STATE = "ecrits:document-element-picker.state"
const EVENT_PICKS = "ecrits:document-element-picker.picks"
const BUTTON_SELECTOR = "[data-role='document-element-picker-toggle']"
// The chips strip above the composer textarea. LiveView renders the (empty)
// container with phx-update="ignore"; this module owns its children.
const PICKS_CONTAINER_SELECTOR = "#local-agent-picks"

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

  // Deactivating the picker KEEPS the picks: the chips stay above the composer
  // (and highlighted in the document) so the user can keep typing. Picks are
  // consumed when the message is sent (the ChatInput hook pushes them as
  // structured data and calls clearPicks), or removed via a chip's × button.
  renderComposerChips()
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
  renderComposerChips()
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

function compactPick(pick) {
  return {
    document: pick.document,
    type: pick.type,
    ref: pick.ref,
    text: (pick.text || "").slice(0, 200),
    hint: (pick.hint || "").slice(0, 300),
  }
}

function implicitAgentPicks() {
  const editors = document.querySelectorAll("[data-role='local-hwp-editor']")
  const picks = []

  for (const el of editors) {
    const editor = el.__wasmHwpEditor
    if (!editor || typeof editor.agentSelectionPicks !== "function") continue
    for (const pick of editor.agentSelectionPicks() || []) picks.push(pick)
  }

  return picks
}

function dedupeCompactPicks(picks) {
  const seen = new Set()

  return picks.filter(pick => {
    const key = pickKey(pick)
    if (!key || seen.has(key)) return false
    seen.add(key)
    return true
  })
}

// The compact pick shape the ChatInput hook pushes to the server (the agent
// reads document/type/ref/text/hint; rects/ir stay editor-side). Explicit
// composer picks are visible chips; implicit active editor selections are sent
// only when the user submits the chat message.
export function compactPicks() {
  return dedupeCompactPicks([...state.picks, ...implicitAgentPicks()]).map(compactPick)
}

// One small removable chip per pick, in a strip above the composer textarea.
// Children-only ownership: LiveView still patches the container's ATTRIBUTES
// (phx-update="ignore" only protects children), so every class lives on the
// JS-built row — an empty container stays zero-height.
function renderComposerChips() {
  const box = document.querySelector(PICKS_CONTAINER_SELECTOR)
  if (!box) return

  box.textContent = ""
  if (state.picks.length === 0) return

  const row = document.createElement("div")
  row.dataset.role = "composer-picks-row"
  row.className = "flex flex-wrap gap-1 px-2 pt-1.5"

  for (const pick of state.picks) {
    const chip = document.createElement("span")
    chip.dataset.role = "composer-pick-chip"
    chip.title = pick.ref
    chip.className =
      "inline-flex max-w-full min-w-0 items-center gap-1 rounded border border-base-300 " +
      "bg-base-200/70 px-1.5 py-0.5 text-[11px] leading-4 text-base-content/80"

    const icon = document.createElement("span")
    icon.setAttribute("aria-hidden", "true")
    icon.className = "hero-cursor-arrow-rays size-3 shrink-0 text-base-content/45"

    const type = document.createElement("span")
    type.className = "shrink-0 font-medium text-base-content/55"
    type.textContent = pick.type

    const snippet = chipLabel(pick)

    const remove = document.createElement("button")
    remove.type = "button"
    remove.dataset.role = "composer-pick-remove"
    remove.dataset.pickKey = pickKey(pick)
    remove.setAttribute("aria-label", "Remove selected element")
    remove.className =
      "inline-flex size-3.5 shrink-0 items-center justify-center rounded text-base-content/45 " +
      "transition-colors hover:bg-base-300 hover:text-base-content"
    remove.textContent = "×"

    chip.append(icon, type)
    if (snippet !== "") {
      const label = document.createElement("span")
      label.className = "min-w-0 truncate"
      label.textContent = snippet
      chip.appendChild(label)
    }
    chip.appendChild(remove)
    row.appendChild(chip)
  }

  box.appendChild(row)
}

// Snippet only: an empty element (blank paragraph, image, ...) keeps the chip
// compact — icon + type, ref on hover — instead of a filename that names the
// document, not the pick.
function chipLabel(pick) {
  return (pick.text || "").trim()
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

// A chip's × button removes that pick (works in or out of picker mode).
document.addEventListener("click", event => {
  const button = event.target.closest?.('[data-role="composer-pick-remove"]')
  if (!button) return
  event.preventDefault()

  const key = button.dataset.pickKey
  const index = state.picks.findIndex(p => pickKey(p) === key)
  if (index < 0) return
  state.picks.splice(index, 1)
  picksChanged()
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
  compactPicks,
}
