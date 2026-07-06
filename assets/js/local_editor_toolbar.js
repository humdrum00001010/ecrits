// LocalEditorToolbar — the document toolbar hook (B/I/U/S, alignment, image).
// Button clicks and ⌘/Ctrl chords flow through one `ecrits:local-editor-command`
// bus; the editors broadcast caret formatting back on
// `ecrits:local-editor-state` so the buttons reflect the active format.
import {resolveEditorShortcut} from "./local_editor_shortcuts"
import {LOCAL_EDITOR_COMMAND_EVENT, LOCAL_EDITOR_STATE_EVENT} from "./editor_events.ts"
import {SEL} from "./selectors.ts"

export const LocalEditorToolbar = {
  mounted() {
    this.imageInput = this.el.querySelector(SEL.toolbarImageInput)
    this.textColorInput = this.el.querySelector(SEL.textColorInput)
    this.highlightColorInput = this.el.querySelector(SEL.highlightColorInput)
    this.fontSizeInput = this.el.querySelector(SEL.fontSizeInput)
    this.onClick = event => this.handleClick(event)
    this.onImageChange = event => this.handleImageChange(event)
    this.onTextColorChange = () => this.handleColorChange("text-color", this.textColorInput, SEL.textColorBar)
    this.onHighlightChange = () => this.handleColorChange("highlight", this.highlightColorInput, SEL.highlightColorBar)
    this.onFontSizeKey = event => this.handleFontSizeKey(event)
    this.onShortcut = event => this.handleShortcut(event)
    this.onEditorState = event => this.handleEditorState(event.detail || {})
    this.onOutsideClick = event => this.handleOutsideClick(event)

    this.el.addEventListener("click", this.onClick)
    if (this.imageInput) this.imageInput.addEventListener("change", this.onImageChange)
    if (this.textColorInput) this.textColorInput.addEventListener("change", this.onTextColorChange)
    if (this.highlightColorInput) this.highlightColorInput.addEventListener("change", this.onHighlightChange)
    if (this.fontSizeInput) this.fontSizeInput.addEventListener("keydown", this.onFontSizeKey)
    // ⌘/Ctrl chords are the hotkey twin of the toolbar buttons — a document-level
    // listener so they work whether the editor canvas, its IME proxy, or the
    // markdown textarea holds focus (the resolver keeps its hands off inputs
    // outside the editor surface, e.g. the chat composer).
    document.addEventListener("keydown", this.onShortcut)
    // Caret-format reflection: the editor broadcasts the char/para properties at
    // the caret; the toolbar lights up B/I/U/S and the align button face swaps
    // to the caret paragraph's alignment.
    document.addEventListener(LOCAL_EDITOR_STATE_EVENT, this.onEditorState)
    document.addEventListener("click", this.onOutsideClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    if (this.imageInput) this.imageInput.removeEventListener("change", this.onImageChange)
    if (this.textColorInput) this.textColorInput.removeEventListener("change", this.onTextColorChange)
    if (this.highlightColorInput) this.highlightColorInput.removeEventListener("change", this.onHighlightChange)
    if (this.fontSizeInput) this.fontSizeInput.removeEventListener("keydown", this.onFontSizeKey)
    document.removeEventListener("keydown", this.onShortcut)
    document.removeEventListener(LOCAL_EDITOR_STATE_EVENT, this.onEditorState)
    document.removeEventListener("click", this.onOutsideClick)
  },

  // ── Font size + colors ─────────────────────────────────────────────────────
  // The color buttons open native pickers (hidden <input type=color>); a pick
  // dispatches the command with the chosen color and echoes it on the button's
  // underbar. The size input applies on Enter and mirrors the caret size.
  handleColorChange(command, input, barSelector) {
    if (!input || !input.value) return
    const bar = this.el.querySelector(barSelector)
    if (bar) bar.style.backgroundColor = input.value
    this.dispatchCommand(command, { color: input.value })
  },

  handleFontSizeKey(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      event.target.blur()
      return
    }
    if (event.key !== "Enter") return
    event.preventDefault()
    const size = parseFloat(String(event.target.value).replace(",", "."))
    if (!Number.isFinite(size) || size <= 0 || size > 400) return
    this.dispatchCommand("font-size-set", { size })
    event.target.blur()
  },

  // ── Alignment dropdown ─────────────────────────────────────────────────────
  // One toolbar button whose face mirrors the caret paragraph's alignment; the
  // four align commands live in its menu. The menu is position:fixed and
  // anchored at open time — the toolbar scrolls with overflow-x-auto, which
  // would clip an absolutely-positioned child.
  alignMenu() {
    return this.el.querySelector(SEL.alignMenu)
  },

  toggleAlignMenu(button) {
    const menu = this.alignMenu()
    if (!menu) return
    if (menu.hidden) {
      const rect = button.getBoundingClientRect()
      menu.style.left = `${Math.round(rect.left)}px`
      menu.style.top = `${Math.round(rect.bottom + 4)}px`
      menu.hidden = false
      button.setAttribute("aria-expanded", "true")
    } else {
      this.closeAlignMenu()
    }
  },

  closeAlignMenu() {
    const menu = this.alignMenu()
    if (menu && !menu.hidden) menu.hidden = true
    this.el
      .querySelector(SEL.alignMenuButton)
      ?.setAttribute("aria-expanded", "false")
  },

  handleOutsideClick(event) {
    const dropdown = event.target.closest?.(SEL.alignDropdown)
    if (!dropdown || !this.el.contains(dropdown)) this.closeAlignMenu()
  },

  // A LiveView patch (any edit round-trips and re-renders the toolbar) strips
  // client-set data-active attrs — re-apply the last known state after updates.
  // A doc switch re-renders the toolbar for a DIFFERENT document: drop the old
  // doc's state instead of painting it onto the new doc (its editor
  // re-broadcasts right after the patch).
  updated() {
    const documentId = this.el.dataset.localDocumentId || ""
    if (this.lastEditorState && this.lastEditorState.document_id &&
        documentId && String(this.lastEditorState.document_id) !== documentId) {
      this.lastEditorState = null
      if (this.fontSizeInput && document.activeElement !== this.fontSizeInput) {
        this.fontSizeInput.value = ""
      }
      return
    }
    if (this.lastEditorState) this.applyEditorState(this.lastEditorState)
  },

  handleEditorState(detail) {
    const documentId = this.el.dataset.localDocumentId || ""
    if (detail.document_id && documentId && String(detail.document_id) !== documentId) return

    this.lastEditorState = detail
    this.applyEditorState(detail)
  },

  applyEditorState(detail) {
    for (const command of ["bold", "italic", "underline", "strikethrough"]) {
      const button = this.el.querySelector(`[data-command='${command}']`)
      if (button) button.dataset.active = String(detail[command] === true)
    }

    const alignment = String(detail.alignment || "").toLowerCase()
    // Menu items mark the active alignment...
    for (const button of this.el.querySelectorAll(SEL.alignCommandButtons)) {
      button.dataset.active = String(!!alignment && button.dataset.command === `align-${alignment}`)
    }
    // ...and the dropdown button face swaps to the caret paragraph's alignment
    // (falls back to the left glyph for values without a menu entry, e.g. the
    // HWP-only distribute/split).
    const face = ["left", "center", "right", "justify"].includes(alignment) ? alignment : "left"
    for (const icon of this.el.querySelectorAll(SEL.alignIcons)) {
      icon.classList.toggle("flex", icon.dataset.alignIcon === face)
      icon.classList.toggle("hidden", icon.dataset.alignIcon !== face)
    }

    // Font size display follows the caret (HWP emits font_size_pt; office does
    // not yet) — never fight the user while they're typing in the field.
    const sizePt = Number(detail.font_size_pt)
    if (this.fontSizeInput && Number.isFinite(sizePt) && sizePt > 0 &&
        document.activeElement !== this.fontSizeInput) {
      this.fontSizeInput.value = String(Math.round(sizePt * 10) / 10)
    }
  },

  handleShortcut(event) {
    const surface = this.el.closest(SEL.studioSurface)
    const command = resolveEditorShortcut(event, surface, document.activeElement)
    if (!command) return

    event.preventDefault()
    this.dispatchCommand(command)
  },

  handleClick(event) {
    const menuButton = event.target.closest(SEL.alignMenuButton)
    if (menuButton && this.el.contains(menuButton)) {
      event.preventDefault()
      this.toggleAlignMenu(menuButton)
      return
    }

    const button = event.target.closest(SEL.commandButton)
    if (!button || !this.el.contains(button)) return

    event.preventDefault()
    this.closeAlignMenu()
    const command = button.dataset.command
    if (command === "image") {
      if (this.imageInput) this.imageInput.click()
      return
    }
    if (command === "text-color") {
      if (this.textColorInput) this.textColorInput.click()
      return
    }
    if (command === "highlight") {
      if (this.highlightColorInput) this.highlightColorInput.click()
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
      this.el.closest(SEL.localDocumentIdHolder)?.dataset.localDocumentId ||
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
