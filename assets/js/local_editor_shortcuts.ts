// Keyboard shortcuts for the local document editor toolbar.
//
// This is the HOTKEY twin of the click toolbar: chords resolve to the SAME
// `data-command` vocabulary the toolbar buttons emit, so a hotkey and a button
// press flow through one `ecrits:local-editor-command` bus and the identical
// per-editor `handleToolbarCommand`. No engine-specific key handling lives
// here — the resolver is pure DATA + guards so it can be unit tested without
// the LiveView hook or a live DOM.
//
// Chord convention follows Google Docs (⌘B/I/U; ⌘⇧X strikethrough;
// ⌘⇧L/E/R/J alignment) — the rhwp-studio/Hancom Alt+Shift chords collide with
// both macOS Option-char input and Korean IME jamo, so we deliberately stay on
// the ⌘/Ctrl(+Shift) plane.
export const LOCAL_EDITOR_SHORTCUT_COMMANDS: Record<string, string> = {
  b: "bold",
  i: "italic",
  u: "underline",
}

export const LOCAL_EDITOR_SHIFT_SHORTCUT_COMMANDS: Record<string, string> = {
  x: "strikethrough",
  l: "align-left",
  e: "align-center",
  r: "align-right",
  j: "align-justify",
}

const EDITABLE_SELECTOR =
  "input, textarea, select, [contenteditable=''], [contenteditable='true']"

// True when `node` is an editable control OUTSIDE the editor surface (e.g. the
// chat composer, a file-tree rename box, the agent title field). Those must keep
// their own ⌘B/⌘I/⌘U behaviour — but the editor's OWN inputs (the HWP/Office IME
// proxy, the markdown source textarea) live inside the surface and SHOULD get the
// formatting shortcut, so surface-contained editables are explicitly allowed.
function editableOutsideSurface(node: any, surface: any): boolean {
  if (!node || typeof node.closest !== "function") return false
  const editable = node.closest(EDITABLE_SELECTOR)
  if (!editable) return false
  return !(surface && surface.contains && surface.contains(editable))
}

// Resolve a KeyboardEvent to a toolbar command, or null to leave it alone.
// `surface` is the studio-document-surface element (toolbar + canvas live inside
// it); `activeElement` is document.activeElement at event time. The command bus
// is already document-id/format filtered downstream, so only the ACTIVE editor
// acts on whatever we dispatch.
export function resolveEditorShortcut(
  event: any,
  surface: any = null,
  activeElement: any = null,
): string | null {
  if (!event) return null
  // Primary modifier required: ⌘ (mac) or Ctrl (win/linux). Alt/AltGr chords
  // (⌥, Ctrl+Alt=AltGr) belong to the OS/IME, never to us.
  if (event.altKey) return null
  if (!(event.metaKey || event.ctrlKey)) return null

  const key = String(event.key || "").toLowerCase()
  const command = event.shiftKey
    ? LOCAL_EDITOR_SHIFT_SHORTCUT_COMMANDS[key]
    : LOCAL_EDITOR_SHORTCUT_COMMANDS[key]
  if (!command) return null

  if (editableOutsideSurface(event.target, surface)) return null
  if (editableOutsideSurface(activeElement, surface)) return null

  return command
}
