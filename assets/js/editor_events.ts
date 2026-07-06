// The cross-module event contract — single source of truth for every
// CustomEvent name that crosses a module boundary (editor surfaces ↔ toolbar ↔
// picker ↔ chat rail). Modules import these instead of re-declaring string
// literals, so a typo is an import error rather than a silently dead listener.
//
// `ecrits:*` events are client-to-client (dispatched on document/element);
// `phx:*` events are pushed by the server (LiveView push_event, on window).

// Toolbar/hotkey → editor command bus, and the editor's caret-state broadcast
// back to the toolbar.
export const LOCAL_EDITOR_COMMAND_EVENT = "ecrits:local-editor-command"
export const LOCAL_EDITOR_STATE_EVENT = "ecrits:local-editor-state"

// Editor-authoritative chat-rail preview: full editors announce authority and
// stream render deltas to the embedded preview.
export const PREVIEW_AUTHORITY_EVENT = "ecrits:editor-preview-authority"
export const PREVIEW_DELTA_EVENT = "ecrits:editor-preview-delta"

// Document element picker (chat composer chips ↔ editor hit-testing).
export const PICKER_TOGGLE_EVENT = "ecrits:document-element-picker.toggle"
export const PICKER_STATE_EVENT = "ecrits:document-element-picker.state"
export const PICKER_PICKS_EVENT = "ecrits:document-element-picker.picks"
export const PICKER_SERVER_STATE_EVENT = "phx:document_element_picker:set"

// Streaming agent turn output appended into the chat rail DOM.
export const AGENT_TEXT_APPEND_EVENT = "phx:local_agent_text_append"
export const AGENT_REASONING_APPEND_EVENT = "phx:local_agent_reasoning_append"
