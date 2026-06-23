// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// You can `npm install some-package --prefix assets` and import
// dependencies using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/ecrits"
import topbar from "topbar"
import {WasmHwpEditor} from "./wasm_hwp_editor"
import {WasmOfficeEditor} from "./wasm_office_editor.js"
import {MarkdownEditor} from "./markdown_editor.js"
import {ObservexPreview} from "./observex_preview.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const LOCAL_EDITOR_COMMAND_EVENT = "ecrits:local-editor-command"

const DirectR2Upload = {
  mounted() {
    this.onChange = event => this.startDirectUpload(event)
    this.el.addEventListener("change", this.onChange)
  },

  destroyed() {
    this.el.removeEventListener("change", this.onChange)
  },

  async startDirectUpload(event) {
    const file = event.target.files?.[0]
    if (!file) return

    try {
      topbar.show(300)

      const prepare = await this.pushEventReply("document.direct_upload.prepare", {
        file_name: file.name,
        mime_type: file.type || "application/octet-stream",
        byte_size: file.size,
      })
      if (!prepare?.ok) throw new Error(prepare?.error || "direct upload prepare failed")

      const put = await fetch(prepare.upload_url, {
        method: prepare.upload_method || "PUT",
        credentials: "same-origin",
        headers: {
          "content-type": file.type || "application/octet-stream",
          "x-csrf-token": csrfToken,
          "x-object-key": prepare.object_key,
        },
        body: file,
      })
      if (!put.ok) throw new Error(await this.errorFromResponse(put))

      const sha256 = await this.sha256Hex(file)
      const complete = await this.pushEventReply("document.direct_upload.complete", {
        object_key: prepare.object_key,
        file_name: file.name,
        mime_type: file.type || "application/octet-stream",
        byte_size: file.size,
        sha256,
      })
      if (!complete?.ok || !complete.document_path) throw new Error(complete?.error || "direct upload completion failed")
      window.location.assign(complete.document_path)
    } catch (error) {
      console.warn("[upload] document upload failed", error)
    } finally {
      event.target.value = ""
      topbar.hide()
    }
  },

  pushEventReply(event, payload) {
    return new Promise(resolve => this.pushEvent(event, payload, resolve))
  },

  async errorFromResponse(response) {
    try {
      const body = await response.json()
      return body?.error || `document upload failed: HTTP ${response.status}`
    } catch (_) {
      return `document upload failed: HTTP ${response.status}`
    }
  },

  async sha256Hex(file) {
    const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer())
    return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("")
  },
}

const LocalEditorToolbar = {
  mounted() {
    this.imageInput = this.el.querySelector("[data-role='local-editor-toolbar-image-input']")
    this.onClick = event => this.handleClick(event)
    this.onImageChange = event => this.handleImageChange(event)

    this.el.addEventListener("click", this.onClick)
    if (this.imageInput) this.imageInput.addEventListener("change", this.onImageChange)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    if (this.imageInput) this.imageInput.removeEventListener("change", this.onImageChange)
  },

  handleClick(event) {
    const button = event.target.closest("[data-command]")
    if (!button || !this.el.contains(button)) return

    event.preventDefault()
    const command = button.dataset.command
    if (command === "image") {
      if (this.imageInput) this.imageInput.click()
      return
    }

    this.dispatchCommand(command)
  },

  async handleImageChange(event) {
    const file = event.target.files?.[0]
    event.target.value = ""
    if (!file) return

    try {
      this.dispatchCommand("image", await this.imagePayload(file))
    } catch (error) {
      console.warn("[local-editor-toolbar] image command failed", error)
    }
  },

  dispatchCommand(command, payload = {}) {
    const documentId =
      this.el.dataset.localDocumentId ||
      this.el.closest("[data-local-document-id]")?.dataset.localDocumentId ||
      ""

    document.dispatchEvent(new CustomEvent(LOCAL_EDITOR_COMMAND_EVENT, {
      detail: {
        command,
        source: "local-editor-toolbar",
        document_id: documentId,
        format: this.el.dataset.localDocumentFormat || "",
        ...payload
      }
    }))
  },

  async imagePayload(file) {
    const bytes = new Uint8Array(await file.arrayBuffer())
    const extension = this.fileExtension(file)
    const image = await this.imageSize(file)
    const imageBase64 = this.bytesToBase64(bytes)

    return {
      file_name: file.name || "image",
      mime_type: file.type || "application/octet-stream",
      extension,
      bytes,
      image_base64: imageBase64,
      data_url: `data:${file.type || "application/octet-stream"};base64,${imageBase64}`,
      natural_width_px: image.width,
      natural_height_px: image.height
    }
  },

  fileExtension(file) {
    const name = String(file.name || "")
    const ext = name.includes(".") ? name.split(".").pop().toLowerCase() : ""
    if (ext) return ext
    const subtype = String(file.type || "").split("/")[1] || "png"
    return subtype.replace(/[^a-z0-9]/gi, "") || "png"
  },

  imageSize(file) {
    return new Promise(resolve => {
      const url = URL.createObjectURL(file)
      const image = new Image()
      const done = (value) => {
        URL.revokeObjectURL(url)
        resolve(value)
      }
      image.onload = () => done({
        width: Math.max(1, Math.round(image.naturalWidth || 1)),
        height: Math.max(1, Math.round(image.naturalHeight || 1))
      })
      image.onerror = () => done({width: 1, height: 1})
      image.src = url
    })
  },

  bytesToBase64(bytes) {
    let binary = ""
    const chunk = 0x8000
    for (let i = 0; i < bytes.length; i += chunk) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk))
    }
    return btoa(binary)
  }
}

const LocalChatRailResizer = {
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

    this.el.addEventListener("pointerdown", this.onPointerDown)
    this.el.addEventListener("click", this.onClick)
    // Capture-phase so we can stop a rapid second submit (e.g. double-Enter while
    // a turn is streaming) BEFORE LiveView's form binding handles it.
    this.el.addEventListener("submit", this.onAgentFormSubmit, true)
    document.addEventListener("click", this.onDocumentClick)
    document.addEventListener("focusin", this.onDocumentFocusIn)
    window.addEventListener("resize", this.onResize)
    window.addEventListener("phx:local_agent_text_append", this.onLocalAgentTextAppend)
    window.addEventListener("phx:local_agent_reasoning_append", this.onLocalAgentReasoningAppend)

    this.handleEvent("local_agent_title_reset", payload => {
      const input = this.el.querySelector("#local-agent-title-label")
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
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("submit", this.onAgentFormSubmit, true)
    document.removeEventListener("click", this.onDocumentClick)
    document.removeEventListener("focusin", this.onDocumentFocusIn)
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener("phx:local_agent_text_append", this.onLocalAgentTextAppend)
    window.removeEventListener("phx:local_agent_reasoning_append", this.onLocalAgentReasoningAppend)
    this.detachDragEvents()
    document.body.removeAttribute("data-chat-rail-dragging")
  },

  // Single-flight guard for the chat composer. Sending a new message while a turn
  // is streaming is allowed (it cancels the in-flight turn and starts a new one),
  // but a SECOND submit fired before the first round-trip is acknowledged would
  // race the server's turn bookkeeping and can leave orphaned empty bubbles. Drop
  // any submit that arrives while one is still pending; `updated()` clears the
  // flag once the server has re-rendered the form.
  guardAgentFormSubmit(event) {
    const form = event.target.closest?.('[data-role="chat-form"]')
    if (!form || !this.el.contains(form)) return

    if (this.agentSubmitPending) {
      event.preventDefault()
      event.stopPropagation()
      return
    }

    this.agentSubmitPending = true
  },

  refreshWorkspaceRefs() {
    this.chatHandle = this.el.querySelector('[data-role="chat-rail-resizer"]')
    this.chatRail = this.el.querySelector('[data-local-chat-rail="true"]')
    this.fileTreeHandle = this.el.querySelector('[data-role="file-tree-resizer"]')
    this.fileTreePanel = this.el.querySelector('[data-local-file-tree-panel="true"]')
    this.fileTreeContent = this.el.querySelector('[data-role="file-tree-content"]')
    this.fileTreeRestore = this.el.querySelector('[data-role="file-tree-restore"]')
    this.fileTreeHide = this.el.querySelector('[data-role="file-tree-hide"]')
    this.fileTreeShow = this.el.querySelector('[data-role="file-tree-show"]')
    this.editorShell = this.el.querySelector('[data-local-editor-shell="true"]')
    this.mobileOpenDocument = this.el.querySelector('[data-role="mobile-open-document"]')
    // Several "back to chat" buttons can exist at once (editor toolbar + the
    // file-tree header shown on the single-pane document view).
    this.mobileOpenChatButtons = [...this.el.querySelectorAll('[data-role="mobile-open-chat"]')]
  },

  handleLayoutClick(event) {
    const fileRow = event.target.closest('a[data-role="repo-browser-row"][data-node-kind="file"][href]')
    if (fileRow && this.el.contains(fileRow) && this.isPlainPrimaryClick(event)) {
      const path = fileRow.dataset.nodePath
      if (!path) return

      event.preventDefault()
      event.stopPropagation()
      this.pushEvent("open_file", {path})
      return
    }

    const openDocument = event.target.closest('[data-role="mobile-open-document"]')
    if (openDocument && this.el.contains(openDocument)) {
      event.preventDefault()
      this.applyMobilePane("document", {focus: true})
      return
    }

    const openChat = event.target.closest('[data-role="mobile-open-chat"]')
    if (openChat && this.el.contains(openChat)) {
      event.preventDefault()
      this.applyMobilePane("chat", {focus: true})
      return
    }

    const hide = event.target.closest('[data-role="file-tree-hide"]')
    if (hide && this.el.contains(hide)) {
      event.preventDefault()
      this.applyFileTreeCollapsed(true)
      this.normalizeLayout()
      return
    }

    const header = event.target.closest('[data-role="repo-browser-header"]')
    if (header && this.el.contains(header) && !this.fileTreeCollapsed) {
      event.preventDefault()
      this.applyFileTreeCollapsed(true)
      this.normalizeLayout()
      return
    }

    const show = event.target.closest('[data-role="file-tree-show"]')
    if (show && this.el.contains(show)) {
      event.preventDefault()
      this.applyFileTreeCollapsed(false)
      this.normalizeLayout()
    }
  },

  isPlainPrimaryClick(event) {
    return event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey
  },

  handleAgentMenuDocumentClick(event) {
    const target = event.target
    if (target.closest?.('[data-role="agent-model-option"], [data-role="provider-reasoning-option"], [data-role="agent-access-option"], [data-role="agent-provider-config-open"]')) {
      this.closeAgentOptionMenus()
      return
    }

    this.closeAgentOptionMenus(target)
  },

  closeAgentOptionMenus(target = null) {
    const activeMenu = target?.closest?.('[data-role="provider-options"] details')
    this.el.querySelectorAll('[data-role="provider-options"] details[open]').forEach(details => {
      if (details !== activeMenu) details.removeAttribute("open")
    })
  },

  appendLocalAgentText(event) {
    const id = event.detail?.message_id
    const piece = event.detail?.piece
    if (!id || !piece) return

    const body = document.querySelector(
      `[data-role="agent-text-body"][data-message-id="${id}"]`
    )
    if (!body) return

    const container = body.closest('[data-role="agent-text"]')
    const indicator = container?.querySelector('[data-role="agent-loading"]')
    if (indicator) indicator.remove()

    body.appendChild(document.createTextNode(piece))
  },

  appendLocalAgentReasoning(event) {
    const id = event.detail?.message_id
    const piece = event.detail?.piece
    if (!id || !piece) return

    const summary = document.querySelector(
      `[data-role="agent-reasoning-text"][data-message-id="${id}"]`
    )
    if (summary) summary.appendChild(document.createTextNode(piece))

    const details = document.querySelector(
      `[data-role="agent-reasoning-details-text"][data-message-id="${id}"]`
    )
    if (details) details.appendChild(document.createTextNode(piece))
  },

  startDragFromEvent(event) {
    const fileTreeHandle = event.target.closest('[data-role="file-tree-resizer"]')
    if (fileTreeHandle && this.el.contains(fileTreeHandle) && !this.fileTreeCollapsed) {
      this.startDrag("fileTree", event)
      return
    }

    const chatHandle = event.target.closest('[data-role="chat-rail-resizer"]')
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
    document.body.setAttribute("data-chat-rail-dragging", "true")
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
    document.body.removeAttribute("data-chat-rail-dragging")

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

// Keeps the chat thread scrolled to the latest message WHILE a turn streams —
// but only when the user is already pinned to the bottom. If they scroll up to
// read earlier messages, new content no longer yanks them back down (the
// `stick` flag, recomputed on every manual scroll, gates the follow).
const liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, DirectR2Upload, LocalEditorToolbar, WasmHwpEditor, WasmOfficeEditor, MarkdownEditor, ObservexPreview, LocalChatRailResizer},
})

window.addEventListener("wheel", event => {
  if (!event.ctrlKey || !event.target || typeof event.target.closest !== "function") return
  const content = event.target.closest("[data-editor-zoomable]")
  if (!content) return

  event.preventDefault()
  const current = Number.parseFloat(content.dataset.editorZoom || "1") || 1
  const step = Math.min(0.24, Math.abs(event.deltaY) * 0.003)
  const factor = 1 + step
  const next = Math.min(4, Math.max(0.5, event.deltaY < 0 ? current * factor : current / factor))
  const scroller = findEditorZoomScroller(content)
  const rect = scroller.getBoundingClientRect()
  const anchorX = scroller.scrollLeft + event.clientX - rect.left
  const anchorY = scroller.scrollTop + event.clientY - rect.top
  const ratio = next / current
  const zoom = String(Number(next.toFixed(4)))
  content.dataset.editorZoom = zoom
  content.style.zoom = ""
  content.style.transformOrigin = "0 0"
  content.style.transform = `scale(${zoom})`
  scroller.scrollLeft = anchorX * ratio - (event.clientX - rect.left)
  scroller.scrollTop = anchorY * ratio - (event.clientY - rect.top)
  content.dispatchEvent(new Event("scroll"))
  content.parentElement?.dispatchEvent(new Event("scroll"))
  window.dispatchEvent(new Event("resize"))
}, {passive: false, capture: true})

function findEditorZoomScroller(content) {
  for (let el = content.parentElement; el; el = el.parentElement) {
    const style = window.getComputedStyle(el)
    if (/(auto|scroll)/.test(`${style.overflow}${style.overflowX}${style.overflowY}`) && (el.scrollHeight > el.clientHeight || el.scrollWidth > el.clientWidth)) return el
  }
  return document.scrollingElement || document.documentElement
}

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
