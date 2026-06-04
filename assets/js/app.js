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
import {WasmHwpEditor} from "./wasm_hwp_editor.js"
import {OfficeEditor} from "./office_editor.js"
import {MarkdownEditor} from "./markdown_editor.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

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

// Office (libreofficex) page virtualization. Mirrors LazyEhwpPage: each page is
// a box-reserving placeholder that asks the server to composite its (heavy
// base64 PNG) tiles only when it scrolls near the viewport, and to release them
// when it scrolls far away — so a 1000-tile deck never holds its full payload in
// the DOM (which would overflow the LiveView socket frame and loop reconnects).
const LazyOfficeTile = {
  mounted() {
    this.page = Number(this.el.dataset.pageNumber)
    this.visible = false
    // Track whether WE have asked the server to hydrate this page, independent of
    // whether its <img> tiles have landed yet. Keying off `querySelector("img")`
    // is wrong while a page is near-viewport but its tiles are still rasterizing
    // (a hydrated-but-tileless slot has no img): it made the observer re-fire
    // `hydrate_page` and never `release_page`. A single explicit `requested` flag
    // means exactly one hydrate on enter and one release on leave.
    this.requested = false
    const root = this.el.closest("[data-role='local-office-viewer']")
    this.io = new IntersectionObserver(
      entries => {
        for (const e of entries) {
          this.visible = e.isIntersecting
          if (e.isIntersecting && !this.requested) {
            this.requested = true
            this.pushEvent("office.local.hydrate_page", { page: this.page })
          } else if (!e.isIntersecting && this.requested) {
            this.requested = false
            this.pushEvent("office.local.release_page", { page: this.page })
          }
        }
      },
      { root, rootMargin: "1200px 0px", threshold: 0 }
    )
    this.io.observe(this.el)
  },

  destroyed() {
    this.io && this.io.disconnect()
  },
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
    this.mobilePane = "chat"
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

    this.el.addEventListener("pointerdown", this.onPointerDown)
    this.el.addEventListener("click", this.onClick)
    document.addEventListener("click", this.onDocumentClick)
    document.addEventListener("focusin", this.onDocumentFocusIn)
    window.addEventListener("resize", this.onResize)
    window.addEventListener("phx:local_agent_text_append", this.onLocalAgentTextAppend)
    window.addEventListener("phx:local_agent_reasoning_append", this.onLocalAgentReasoningAppend)
  },

  updated() {
    this.refreshWorkspaceRefs()
    this.applyFileTreeCollapsed(this.fileTreeCollapsed, {persist: false})
    this.normalizeLayout()
    this.applyMobilePane(this.mobilePane)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onPointerDown)
    this.el.removeEventListener("click", this.onClick)
    document.removeEventListener("click", this.onDocumentClick)
    document.removeEventListener("focusin", this.onDocumentFocusIn)
    window.removeEventListener("resize", this.onResize)
    window.removeEventListener("phx:local_agent_text_append", this.onLocalAgentTextAppend)
    window.removeEventListener("phx:local_agent_reasoning_append", this.onLocalAgentReasoningAppend)
    this.detachDragEvents()
    document.body.removeAttribute("data-chat-rail-dragging")
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
    this.mobileOpenChat = this.el.querySelector('[data-role="mobile-open-chat"]')
  },

  handleLayoutClick(event) {
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
    if (window.innerWidth < this.desktopMinWidth) return

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

  applyMobilePane(pane, {focus = false} = {}) {
    this.mobilePane = pane === "document" ? "document" : "chat"
    this.el.setAttribute("data-mobile-pane", this.mobilePane)

    const showingDocument = this.mobilePane === "document"
    const mobile = window.innerWidth < this.desktopMinWidth

    if (mobile) {
      this.fileTreePanel?.classList.add("max-lg:hidden")
      this.editorShell?.classList.toggle("max-lg:hidden", !showingDocument)
      this.chatRail?.classList.toggle("max-lg:hidden", showingDocument)
    } else {
      this.fileTreePanel?.classList.remove("max-lg:hidden")
      this.editorShell?.classList.remove("max-lg:hidden")
      this.chatRail?.classList.remove("max-lg:hidden")
    }

    this.mobileOpenDocument?.setAttribute("aria-pressed", String(showingDocument))
    this.mobileOpenChat?.setAttribute("aria-pressed", String(!showingDocument))

    if (focus && mobile) {
      const target = showingDocument ? this.mobileOpenChat : this.mobileOpenDocument
      target?.focus({preventScroll: true})
    }
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
    if (window.innerWidth < this.desktopMinWidth) return this.fileTreeMaxWidth

    const layoutMax = window.innerWidth - this.currentChatWidth() - this.editorMinWidth
    return Math.max(this.fileTreeMinWidth, Math.min(this.fileTreeMaxWidth, layoutMax))
  },

  availableChatMaxWidth() {
    if (window.innerWidth < this.desktopMinWidth) return this.chatMaxWidth

    const fileTreeWidth = this.fileTreeCollapsed
      ? this.fileTreeCollapsedWidth
      : this.currentFileTreeWidth()
    const layoutMax = window.innerWidth - fileTreeWidth - this.editorMinWidth
    return Math.max(this.chatMinWidth, Math.min(this.chatMaxWidth, layoutMax))
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, DirectR2Upload, WasmHwpEditor, OfficeEditor, MarkdownEditor, LocalChatRailResizer, LazyOfficeTile},
})

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
