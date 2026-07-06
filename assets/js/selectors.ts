// The JS↔HEEx DOM contract — every selector JS uses to find server-rendered
// markup, gathered in one place (the twin of `editor_events.ts` for event
// names). The other half of each entry is a HEEx template attribute; when you
// rename a data-role here, grep lib/ecrits_web for the same name.
//
// Parameterized lookups compose off these bases at the call site, e.g.
// `${SEL.hwpPage}[data-page-index='${index}']`.

export const SEL = {
  // ── Workspace layout + chat rail (local_chat_rail_resizer) ──────────────
  chatForm: '[data-role="chat-form"]',
  chatRail: '[data-local-chat-rail="true"]',
  chatRailResizer: '[data-role="chat-rail-resizer"]',
  fileTreePanel: '[data-local-file-tree-panel="true"]',
  fileTreeResizer: '[data-role="file-tree-resizer"]',
  fileTreeContent: '[data-role="file-tree-content"]',
  fileTreeRestore: '[data-role="file-tree-restore"]',
  fileTreeHide: '[data-role="file-tree-hide"]',
  fileTreeShow: '[data-role="file-tree-show"]',
  editorShell: '[data-local-editor-shell="true"]',
  mobileOpenDocument: '[data-role="mobile-open-document"]',
  mobileOpenChat: '[data-role="mobile-open-chat"]',
  repoBrowserHeader: '[data-role="repo-browser-header"]',
  repoBrowserFileRow: '[data-role="repo-browser-row"][data-node-kind="file"][data-openable="true"]',
  providerOptionMenus: '[data-role="provider-options"] details',
  providerOptionMenusOpen: '[data-role="provider-options"] details[open]',
  agentOptionControls:
    '[data-role="agent-model-option"], [data-role="provider-reasoning-option"], [data-role="agent-access-option"], [data-role="agent-provider-config-open"]',
  agentTitleLabel: "#local-agent-title-label",

  // Streaming agent turn output (append targets; compose with
  // `[data-message-id="${id}"]`).
  agentLoading: '[data-role="agent-loading"]',
  agentText: '[data-role="agent-text"]',
  agentTextBody: '[data-role="agent-text-body"]',
  agentReasoningText: '[data-role="agent-reasoning-text"]',
  agentReasoningDetailsText: '[data-role="agent-reasoning-details-text"]',

  // ── Document element picker (chat composer chips) ───────────────────────
  pickerToggle: "[data-role='document-element-picker-toggle']",
  composerPicks: "#local-agent-picks",
  composerPickRemove: '[data-role="composer-pick-remove"]',

  // ── Quick toolbar (local_editor_toolbar) ────────────────────────────────
  studioSurface: "[data-component='studio-document-surface']",
  localDocumentIdHolder: "[data-local-document-id]",
  toolbarImageInput: "[data-role='local-editor-toolbar-image-input']",
  commandButton: "[data-command]",
  alignCommandButtons: "[data-command^='align-']",
  alignIcons: "[data-align-icon]",
  alignDropdown: "[data-role='align-dropdown']",
  alignMenu: "[data-role='align-menu']",
  alignMenuButton: "[data-role='align-menu-button']",
  fontSizeInput: "[data-role='font-size-input']",
  textColorInput: "[data-role='text-color-input']",
  textColorBar: "[data-role='text-color-bar']",
  highlightColorInput: "[data-role='highlight-color-input']",
  highlightColorBar: "[data-role='highlight-color-bar']",

  // ── HWP editor surface (wasm_hwp_editor) ────────────────────────────────
  hwpEditor: "[data-role='local-hwp-editor']",
  hwpEditorUnmirrored: "[data-role='local-hwp-editor'][data-editor-mirror='false']",
  hwpImeProxy: "[data-role='local-hwp-ime-proxy']",
  hwpPages: "[data-role='local-hwp-pages']",
  hwpPage: "[data-role='local-hwp-page']",
  ehwpCanvas: "[data-role='ehwp-canvas']",
  ehwpCaretOverlay: "[data-role='ehwp-caret-overlay']",

  // ── Office editor surface (wasm_office_editor) ──────────────────────────
  officePages: "[data-role='office-wasm-pages']",
  officePage: "[data-role='office-wasm-page']",
  officeCanvas: "[data-role='office-wasm-canvas']",
  officeCaretOverlay: "[data-role='office-wasm-caret-overlay']",
  officeImeProxy: "[data-role='office-wasm-ime-proxy']",
  officeStatus: "[data-role='office-wasm-status']",

  // ── Markdown editor ──────────────────────────────────────────────────────
  markdownEditor: "[data-role='markdown-editor']",

  // ── Shared editor chrome ─────────────────────────────────────────────────
  editorZoomable: "[data-editor-zoomable]",
} as const
