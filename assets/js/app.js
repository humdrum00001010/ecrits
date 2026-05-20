// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
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
import {hooks as colocatedHooks} from "phoenix-colocated/contract"
import topbar from "../vendor/topbar"
import {Rhwp} from "./rhwp"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

const DirectR2Upload = {
  mounted() {
    this.el.addEventListener("change", event => this.upload(event))
  },

  async upload(event) {
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
        method: "PUT",
        headers: {"content-type": file.type || "application/octet-stream"},
        body: file,
      })
      if (!put.ok) throw new Error(`R2 upload failed: HTTP ${put.status}`)

      const sha256 = await this.sha256Hex(file)
      const complete = await this.pushEventReply("document.direct_upload.complete", {
        object_key: prepare.object_key,
        file_name: file.name,
        mime_type: file.type || "application/octet-stream",
        byte_size: file.size,
        sha256,
      })
      if (!complete?.ok) throw new Error(complete?.error || "direct upload completion failed")
    } catch (error) {
      window.alert(error instanceof Error ? error.message : String(error))
    } finally {
      event.target.value = ""
      topbar.hide()
    }
  },

  pushEventReply(event, payload) {
    return new Promise(resolve => this.pushEvent(event, payload, resolve))
  },

  async sha256Hex(file) {
    const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer())
    return Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, "0")).join("")
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, Rhwp, DirectR2Upload},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

window.addEventListener("phx:open-document-upload-picker", () => {
  document.querySelector("[data-role='document-upload-file-input']")?.click()
})

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
