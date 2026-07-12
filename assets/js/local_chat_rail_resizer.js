// LocalChatRailResizer — the workspace layout hook: chat-rail / file-tree
// resize + collapse, mobile pane switching, file-open dispatch (with office
// WASM prewarm + fast-open on intent), agent option menus, streaming
// text/reasoning append, and the chat composer single-flight submit guard.
import {WasmOfficeEditor} from "./wasm_office_editor.js"
import {AGENT_TEXT_APPEND_EVENT, AGENT_REASONING_APPEND_EVENT} from "./editor_events.ts"
import {SEL} from "./selectors.ts"

const OFFICE_PREWARM_EXTENSIONS = new Set([
  "doc", "docx", "docm", "dot", "dotx", "dotm",
  "xls", "xlsx", "xlsm", "xlt", "xltx", "xltm",
  "ppt", "pptx", "pptm", "pps", "ppsx", "ppsm", "pot", "potx", "potm",
  "rtf",
])
const OFFICE_FAST_OPEN_IMPORT_DELAY_MS = 80
const BODY_DRAG_CLASSES = ["cursor-col-resize", "select-none"]

function officeFileRow(row) {
  return OFFICE_PREWARM_EXTENSIONS.has(String(row?.dataset?.fileExtension || "").toLowerCase())
}

function startOfficeRuntimePrewarmForGrid(grid, reason) {
  if (!grid) return false
  const state = grid.dataset.officeWasmPrewarm || ""
  if (state === "starting" || state === "ready") return true
  const assetVersion = grid.dataset.officeAssetVersion || ""
  if (!assetVersion) return false
  if (typeof WasmOfficeEditor.prewarmRuntime !== "function") return false
  if (typeof SharedArrayBuffer === "undefined" || !window.crossOriginIsolated) return false

  grid.dataset.officeWasmPrewarm = "starting"
  WasmOfficeEditor.prewarmRuntime(assetVersion)
    .then(() => {
      if (grid.isConnected) grid.dataset.officeWasmPrewarm = "ready"
    })
    .catch(error => {
      if (grid.isConnected) grid.dataset.officeWasmPrewarm = "failed"
      console.warn("[office-wasm] runtime prewarm failed", {reason, error})
    })
  return true
}

function officeDocumentBytesUrl(row) {
  return row?.dataset?.bytesUrl || null
}

export const LocalChatRailResizer = {
  mounted() {
    this.root = document.documentElement
    this.chatStorageKey = "cs:local-chat-rail-width"
    this.fileTreeStorageKey = "cs:local-file-tree-width"
    this.fileTreeCollapsedStorageKey = "cs:local-file-tree-collapsed"
    this.chatMinWidth = 280
    this.chatMaxWidth = 720
    this.chatDefaultWidth = 340
    this.fileTreeMinWidth = 220
    this.fileTreeMaxWidth = 520
    this.fileTreeDefaultWidth = 260
    this.fileTreeCollapsedWidth = 40
    this.editorMinWidth = 360
    this.desktopMinWidth = 1024
    this.mobilePane = "desktop"
    this.dragging = false
    this.dragKind = null

    this.refreshWorkspaceRefs()

    const storedChatWidth = parseInt(localStorage.getItem(this.chatStorageKey), 10)
    const storedFileTreeWidth = parseInt(localStorage.getItem(this.fileTreeStorageKey), 10)

    this.chatWidth = Number.isNaN(storedChatWidth) ? this.chatDefaultWidth : storedChatWidth
    this.fileTreeWidth = Number.isNaN(storedFileTreeWidth)
      ? this.fileTreeDefaultWidth
      : storedFileTreeWidth
    this.fileTreeCollapsed = localStorage.getItem(this.fileTreeCollapsedStorageKey) === "true"

    this.applyFileTreeCollapsed(this.fileTreeCollapsed, {persist: false})
    this.normalizeLayout()

    this.onPointerDown = event => this.startDragFromEvent(event)
    this.onClick = event => this.handleLayoutClick(event)
    this.onOfficePrewarmIntent = event => this.handleOfficePrewarmIntent(event)
    this.onPointerMove = event => this.drag(event)
    this.onPointerUp = () => this.stopDrag()
    this.onDocumentClick = event => this.handleAgentMenuDocumentClick(event)
    this.onDocumentFocusIn = event => this.closeAgentOptionMenus(event.target)
    this.onResize = () => {
      this.normalizeLayout()
      this.applyMobilePane(this.mobilePane)
    }
    this.onLocalAgentTextAppend = event => this.appendLocalAgentText(event)
    this.onLocalAgentReasoningAppend = event => this.appendLocalAgentReasoning(event)
    this.agentSubmitPending = false
    this.onAgentFormSubmit = event => this.guardAgentFormSubmit(event)
    this.officeRuntimePrewarmStarted = false

    this.el.addEventListener("pointerdown", this.onPointerDown)
    this.el.addEventListener("pointerover", this.onOfficePrewarmIntent)
    this.el.addEventListener("focusin", this.onOfficePrewarmIntent)
    this.el.addEventListener("click", this.onClick)
    // Capture-phase so we can stop a rapid second submit (e.g. double-Enter while
    // a turn is streaming) BEFORE LiveView's form binding handles it.
    this.el.addEventListener("submit", this.onAgentFormSubmit, true)
    document.addEventListener("click", this.onDocumentClick)
    document.addEventListener("focusin", this.onDocumentFocusIn)
    window.addEventListener("resize", this.onResize)
    window.addEventListener(AGENT_TEXT_APPEND_EVENT, this.onLocalAgentTextAppend)
    window.addEventListener(AGENT_REASONING_APPEND_EVENT, this.onLocalAgentReasoningAppend)

    this.handleEvent("local_agent_title_reset", payload => {
      const input = this.el.querySelector(SEL.agentTitleLabel)
      if (!input) return

      const title = typeof payload?.title === "string" ? payload.title : ""
      input.value = title
      input.setAttribute("value", title)
    })
  },

  updated() {
    this.refreshWorkspaceRefs()
    this.applyFileTreeCollapsed(this.fileTreeCollapsed, {persist: false})
    this.normalizeLayout()
    this.applyMobilePane(this.mobilePane)
    // The server processed the in-flight send (form was re-rendered): release the
    // single-flight guard so the next deliberate submit can go through.
    this.agentSubmitPending = false
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    this.el.removeEventListener("pointerover", this.onOfficePrewarmIntent)
    this.el.removeEventListener("focusin", this.onOfficePrewarmIntent)
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("submit", this.onAgentFormSubmit, true)
    document.removeEventListener("click", this.onDocumentClick)
    document.removeEventListener("focusin", this.onDocumentFocusIn)
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener(AGENT_TEXT_APPEND_EVENT, this.onLocalAgentTextAppend)
    window.removeEventListener(AGENT_REASONING_APPEND_EVENT, this.onLocalAgentReasoningAppend)
    this.detachDragEvents()
    document.body.classList.remove(...BODY_DRAG_CLASSES)
  },

  // Single-flight guard for the chat composer. Sending a new message while a turn
  // is streaming is allowed (it cancels the in-flight turn and starts a new one),
  // but a SECOND submit fired before the first round-trip is acknowledged would
  // race the server's turn bookkeeping and can leave orphaned empty bubbles. Drop
  // any submit that arrives while one is still pending; `updated()` clears the
  // flag once the server has re-rendered the form.
  guardAgentFormSubmit(event) {
    const form = event.target.closest?.(SEL.chatForm)
    if (!form || !this.el.contains(form)) return

    if (this.agentSubmitPending) {
      event.preventDefault()
      event.stopPropagation()
      return
    }

    this.agentSubmitPending = true
  },

  refreshWorkspaceRefs() {
    this.chatHandle = this.el.querySelector(SEL.chatRailResizer)
    this.chatRail = this.el.querySelector(SEL.chatRail)
    this.fileTreeHandle = this.el.querySelector(SEL.fileTreeResizer)
    this.fileTreePanel = this.el.querySelector(SEL.fileTreePanel)
    this.fileTreeContent = this.el.querySelector(SEL.fileTreeContent)
    this.fileTreeRestore = this.el.querySelector(SEL.fileTreeRestore)
    this.fileTreeHide = this.el.querySelector(SEL.fileTreeHide)
    this.fileTreeShow = this.el.querySelector(SEL.fileTreeShow)
    this.editorShell = this.el.querySelector(SEL.editorShell)
    this.mobileOpenDocument = this.el.querySelector(SEL.mobileOpenDocument)
    // Several "back to chat" buttons can exist at once (editor toolbar + the
    // file-tree header shown on the single-pane document view).
    this.mobileOpenChatButtons = [...this.el.querySelectorAll(SEL.mobileOpenChat)]
  },

  handleLayoutClick(event) {
    const fileRow = event.target.closest(SEL.repoBrowserFileRow)
    if (fileRow && this.el.contains(fileRow) && this.isPlainPrimaryClick(event)) {
      const path = fileRow.dataset.nodePath
      if (!path) return

      event.preventDefault()
      event.stopPropagation()
      this.pushEvent("open_file", {path})
      if (this.officeFileRow(fileRow)) {
        this.startOfficeRuntimePrewarm("office-file-click")
        this.startOfficeDocumentFastOpen(fileRow)
      }
      return
    }

    const openDocument = event.target.closest(SEL.mobileOpenDocument)
    if (openDocument && this.el.contains(openDocument)) {
      event.preventDefault()
      this.applyMobilePane("document", {focus: true})
      return
    }

    const openChat = event.target.closest(SEL.mobileOpenChat)
    if (openChat && this.el.contains(openChat)) {
      event.preventDefault()
      this.applyMobilePane("chat", {focus: true})
      return
    }

    const hide = event.target.closest(SEL.fileTreeHide)
    if (hide && this.el.contains(hide)) {
      event.preventDefault()
      this.applyFileTreeCollapsed(true)
      this.normalizeLayout()
      return
    }

    const header = event.target.closest(SEL.repoBrowserHeader)
    if (header && this.el.contains(header) && !this.fileTreeCollapsed) {
      event.preventDefault()
      this.applyFileTreeCollapsed(true)
      this.normalizeLayout()
      return
    }

    const show = event.target.closest(SEL.fileTreeShow)
    if (show && this.el.contains(show)) {
      event.preventDefault()
      this.applyFileTreeCollapsed(false)
      this.normalizeLayout()
    }
  },

  isPlainPrimaryClick(event) {
    return event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey
  },

  handleOfficePrewarmIntent(event) {
    const row = event.target.closest?.(SEL.repoBrowserFileRow)
    if (!row || !this.el.contains(row) || !this.officeFileRow(row)) return

    this.startOfficeRuntimePrewarm("office-file-intent")
  },

  startOfficeRuntimePrewarm(reason) {
    if (this.officeRuntimePrewarmStarted) return
    if (startOfficeRuntimePrewarmForGrid(this.el, reason)) this.officeRuntimePrewarmStarted = true
  },

  startOfficeDocumentFastOpen(row) {
    if (typeof WasmOfficeEditor.fastOpenDocument !== "function") return
    const url = officeDocumentBytesUrl(row)
    if (!url) return
    const format = String(row.dataset.fileExtension || "").toLowerCase() || "docx"
    this.el.dataset.officeWasmFastOpen = "starting"

    WasmOfficeEditor.fastOpenDocument({
      url,
      assetVersion: this.el.dataset.officeAssetVersion || "",
      format,
      deferImportMs: OFFICE_FAST_OPEN_IMPORT_DELAY_MS,
    })
      .then(result => {
        if (this.el.isConnected) this.el.dataset.officeWasmFastOpen = result || "loaded"
      })
      .catch(error => {
        if (this.el.isConnected) this.el.dataset.officeWasmFastOpen = "failed"
        console.warn("[office-wasm] document fast-open failed", {url, format, error})
      })
  },

  officeFileRow(row) {
    return officeFileRow(row)
  },

  handleAgentMenuDocumentClick(event) {
    const target = event.target
    if (target.closest?.(SEL.agentOptionControls)) {
      this.closeAgentOptionMenus()
      return
    }

    this.closeAgentOptionMenus(target)
  },

  closeAgentOptionMenus(target = null) {
    const activeMenu = target?.closest?.(SEL.providerOptionMenus)
    this.el.querySelectorAll(SEL.providerOptionMenusOpen).forEach(details => {
      if (details !== activeMenu) details.removeAttribute("open")
    })
  },

  appendLocalAgentText(event) {
    const id = event.detail?.message_id
    const piece = event.detail?.piece
    if (!id || !piece) return

    const body = document.querySelector(
      `${SEL.agentTextBody}[data-message-id="${id}"]`
    )
    if (!body) return

    const container = body.closest(SEL.agentText)
    const indicator = container?.querySelector(SEL.agentLoading)
    if (indicator) indicator.remove()

    body.appendChild(document.createTextNode(piece))
  },

  appendLocalAgentReasoning(event) {
    const id = event.detail?.message_id
    const piece = event.detail?.piece
    if (!id || !piece) return

    const summary = document.querySelector(
      `${SEL.agentReasoningText}[data-message-id="${id}"]`
    )
    if (summary) summary.appendChild(document.createTextNode(piece))

    const details = document.querySelector(
      `${SEL.agentReasoningDetailsText}[data-message-id="${id}"]`
    )
    if (details) details.appendChild(document.createTextNode(piece))
  },

  startDragFromEvent(event) {
    const fileTreeHandle = event.target.closest(SEL.fileTreeResizer)
    if (fileTreeHandle && this.el.contains(fileTreeHandle) && !this.fileTreeCollapsed) {
      this.startDrag("fileTree", event)
      return
    }

    const chatHandle = event.target.closest(SEL.chatRailResizer)
    if (chatHandle && this.el.contains(chatHandle)) {
      this.startDrag("chat", event)
    }
  },

  startDrag(kind, event) {
    if (event.button !== 0 && event.pointerType !== "touch") return

    const target = this.dragTarget(kind)
    if (!target.handle || !target.panel) return

    event.preventDefault()
    this.dragging = true
    this.dragKind = kind
    this.startX = event.clientX
    this.startWidth = target.panel.getBoundingClientRect().width
    target.handle.setAttribute("data-dragging", "true")
    document.body.classList.add(...BODY_DRAG_CLASSES)
    window.addEventListener("pointermove", this.onPointerMove)
    window.addEventListener("pointerup", this.onPointerUp)
    window.addEventListener("pointercancel", this.onPointerUp)
  },

  drag(event) {
    if (!this.dragging) return

    event.preventDefault()
    const direction = this.dragKind === "fileTree" ? 1 : -1
    const nextWidth = this.startWidth + direction * (event.clientX - this.startX)

    if (this.dragKind === "fileTree") {
      this.applyFileTreeWidth(nextWidth)
      this.applyChatWidth(this.currentChatWidth())
    } else {
      this.applyChatWidth(nextWidth)
    }
  },

  stopDrag() {
    if (!this.dragging) return

    const kind = this.dragKind
    const target = this.dragTarget(kind)

    this.dragging = false
    this.dragKind = null
    target.handle?.removeAttribute("data-dragging")
    document.body.classList.remove(...BODY_DRAG_CLASSES)

    if (kind === "fileTree") {
      localStorage.setItem(this.fileTreeStorageKey, String(this.currentFileTreeWidth()))
    } else {
      localStorage.setItem(this.chatStorageKey, String(this.currentChatWidth()))
    }

    this.detachDragEvents()
  },

  detachDragEvents() {
    window.removeEventListener("pointermove", this.onPointerMove)
    window.removeEventListener("pointerup", this.onPointerUp)
    window.removeEventListener("pointercancel", this.onPointerUp)
  },

  dragTarget(kind) {
    if (kind === "fileTree") {
      return {handle: this.fileTreeHandle, panel: this.fileTreePanel}
    }

    return {handle: this.chatHandle, panel: this.chatRail}
  },

  normalizeLayout() {
    this.fileTreeWidth = this.clampFileTreeWidth(this.currentFileTreeWidth())
    this.chatWidth = this.clampChatWidth(this.currentChatWidth())

    if (this.fileTreeCollapsed) {
      this.root.style.setProperty("--local-file-tree-width", `${this.fileTreeCollapsedWidth}px`)
    } else {
      this.root.style.setProperty("--local-file-tree-width", `${this.fileTreeWidth}px`)
    }

    this.root.style.setProperty("--local-chat-rail-width", `${this.chatWidth}px`)
  },

  applyFileTreeCollapsed(collapsed, {persist = true} = {}) {
    this.fileTreeCollapsed = collapsed
    this.el.setAttribute("data-file-tree-collapsed", String(collapsed))
    this.fileTreePanel?.setAttribute("data-collapsed", String(collapsed))
    this.fileTreePanel?.setAttribute("aria-expanded", String(!collapsed))
    this.fileTreeContent?.classList.toggle("hidden", collapsed)
    this.fileTreeContent?.setAttribute("aria-hidden", String(collapsed))
    this.fileTreeRestore?.classList.toggle("hidden", !collapsed)
    this.fileTreeHide?.setAttribute("aria-expanded", String(!collapsed))
    this.fileTreeShow?.setAttribute("aria-expanded", String(!collapsed))
    if (this.fileTreeHandle) this.fileTreeHandle.hidden = collapsed

    if (persist) {
      localStorage.setItem(this.fileTreeCollapsedStorageKey, String(collapsed))
    }

    const width = collapsed ? this.fileTreeCollapsedWidth : this.currentFileTreeWidth()
    this.root.style.setProperty("--local-file-tree-width", `${width}px`)
  },

  applyMobilePane(_pane, _opts = {}) {
    this.mobilePane = "desktop"
    this.el.setAttribute("data-mobile-pane", this.mobilePane)

    this.fileTreePanel?.classList.remove("max-md:hidden")
    this.editorShell?.classList.remove("max-md:hidden")
    this.chatRail?.classList.remove("max-md:hidden")

    this.mobileOpenDocument?.setAttribute("aria-pressed", "false")
    this.mobileOpenChatButtons?.forEach(btn => btn.setAttribute("aria-pressed", "false"))
  },

  applyFileTreeWidth(width) {
    this.fileTreeWidth = this.clampFileTreeWidth(width)

    if (!this.fileTreeCollapsed) {
      this.root.style.setProperty("--local-file-tree-width", `${this.fileTreeWidth}px`)
    }
  },

  applyChatWidth(width) {
    this.chatWidth = this.clampChatWidth(width)
    this.root.style.setProperty("--local-chat-rail-width", `${this.chatWidth}px`)
  },

  currentFileTreeWidth() {
    if (Number.isFinite(this.fileTreeWidth)) return this.fileTreeWidth

    const width = parseInt(
      getComputedStyle(this.root).getPropertyValue("--local-file-tree-width"),
      10
    )
    return Number.isNaN(width) ? this.fileTreeDefaultWidth : width
  },

  currentChatWidth() {
    if (Number.isFinite(this.chatWidth)) return this.chatWidth

    const width = parseInt(
      getComputedStyle(this.root).getPropertyValue("--local-chat-rail-width"),
      10
    )
    return Number.isNaN(width) ? this.chatDefaultWidth : width
  },

  clampFileTreeWidth(width) {
    const maxWidth = this.availableFileTreeMaxWidth()
    return Math.min(maxWidth, Math.max(this.fileTreeMinWidth, width))
  },

  clampChatWidth(width) {
    const maxWidth = this.availableChatMaxWidth()
    return Math.min(maxWidth, Math.max(this.chatMinWidth, width))
  },

  availableFileTreeMaxWidth() {
    const layoutMax = this.layoutWidth() - this.currentChatWidth() - this.editorMinWidth
    return Math.max(this.fileTreeMinWidth, Math.min(this.fileTreeMaxWidth, layoutMax))
  },

  availableChatMaxWidth() {
    const fileTreeWidth = this.fileTreeCollapsed
      ? this.fileTreeCollapsedWidth
      : this.currentFileTreeWidth()
    const layoutMax = this.layoutWidth() - fileTreeWidth - this.editorMinWidth
    return Math.max(this.chatMinWidth, Math.min(this.chatMaxWidth, layoutMax))
  },

  layoutWidth() {
    return Math.max(window.innerWidth, this.desktopMinWidth)
  },
}
