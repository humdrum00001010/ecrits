import {WasmHwpEditor} from "./wasm_hwp_editor"
import {WasmOfficeEditor} from "./wasm_office_editor.js"
import {MarkdownEditor} from "./markdown_editor.js"
import {ObservexPreview} from "./observex_preview.js"
import {LocalEditorToolbar} from "./local_editor_toolbar.js"
import {LocalChatRailResizer} from "./local_chat_rail_resizer.js"
import {installEditorZoom} from "./editor_zoom.js"

export const hooks = {
  LocalEditorToolbar,
  WasmHwpEditor,
  WasmOfficeEditor,
  MarkdownEditor,
  ObservexPreview,
  LocalChatRailResizer,
}

export function installEcritsClientBehavior() {
  installEditorZoom()
}
