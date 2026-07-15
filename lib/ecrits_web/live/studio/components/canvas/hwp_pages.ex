defmodule EcritsWeb.Live.Studio.Components.Canvas.HwpPages do
  @moduledoc """
  HWP/HWPX page stack rendered by the in-browser rhwp_core WASM engine.

  The LiveView owns the document state and transmits one encoded
  `DocumentCanvasState`. This component's colocated hook is the browser-engine
  adapter: it loads rhwp_core, renders and hit-tests canvas pages, translates
  browser input, and reports document events back to LiveView.
  """

  use EcritsWeb, :html

  alias Ecrits.DocumentCanvasState

  attr :id, :string, required: true
  attr :pages, :any, required: true
  attr :state, :any, required: true

  def render(%{state: %DocumentCanvasState{}} = assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".WasmHwpEditor"
      role="region"
      tabindex={if(@state.mirror?, do: "-1", else: "0")}
      aria-label={if(@state.mirror?, do: "Document preview", else: "Document pages")}
      class={[
        "relative h-full min-h-0 bg-white",
        @state.mirror? && "overflow-hidden pointer-events-none",
        !@state.mirror? && "overflow-auto"
      ]}
      data-component="canvas-hwp-pages"
      data-renderer="rhwp-wasm"
      data-role="local-hwp-editor"
      data-canvas-state={DocumentCanvasState.encode(@state)}
    >
      <textarea
        id={"#{@id}-ime-proxy"}
        data-role="local-hwp-ime-proxy"
        autocomplete="off"
        autocorrect="off"
        autocapitalize="off"
        spellcheck="false"
        aria-hidden="true"
        tabindex="-1"
        rows="1"
        phx-update="ignore"
        class="fixed m-0 p-0 border-0 outline-none bg-transparent resize-none overflow-hidden"
        style="left:-10000px;top:-10000px;width:1px;height:1px;max-width:1px;max-height:1px;color:transparent;-webkit-text-fill-color:transparent;caret-color:transparent;opacity:0;clip-path:inset(50%);white-space:pre;line-height:1px;font-size:1px;z-index:-1;pointer-events:none"
      ></textarea>
      <div
        id={"#{@id}-pages"}
        data-role="local-hwp-pages"
        data-editor-zoomable
        class="ehwp-document-stack ehwp-document-stack--local flex min-h-full flex-col items-center overflow-auto bg-[#f4f4f5]"
        phx-update="ignore"
      >
      </div>
      <script
        :type={Phoenix.LiveView.ColocatedHook}
        name=".WasmHwpEditor"
        phx-no-curly-interpolation
      >
        // assets/js/selectors.ts
        var SEL = {
          // ── Workspace layout + chat rail colocated hook ─────────────────────────
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
          repoBrowserHeader: '[data-role="repo-browser-header"]',
          repoBrowserFileRow: '[data-role="repo-browser-row"][data-node-kind="file"][data-openable="true"]',
          providerOptionMenus: '[data-role="provider-options"] details',
          providerOptionMenusOpen: '[data-role="provider-options"] details[open]',
          agentOptionControls: '[data-role="agent-model-option"], [data-role="provider-reasoning-option"], [data-role="agent-access-option"], [data-role="agent-provider-config-open"]',
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
          // ── Quick toolbar colocated hook ────────────────────────────────────────
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
          editorZoomable: "[data-editor-zoomable]"
        };

        // assets/js/editor_events.ts
        var EDITOR_COMMAND_EVENT = "ecrits:editor-command";
        var EDITOR_STATE_EVENT = "ecrits:editor-state";
        var DOCUMENT_SEARCH_COMMAND_EVENT = "ecrits:document-search-command";
        var DOCUMENT_SEARCH_RESULT_EVENT = "ecrits:document-search-result";
        var PREVIEW_AUTHORITY_EVENT = "ecrits:editor-preview-authority";
        var PREVIEW_DELTA_EVENT = "ecrits:editor-preview-delta";
        var PICKER_STATE_EVENT = "ecrits:document-element-picker.state";

        // assets/js/document_element_picker.js
        var PICKER_BRIDGE_SELECTOR = '[data-role="document-element-picker-bridge"]';
        var PICK_TOGGLED_EVENT = "ecrits:document-element-picker.pick-toggled";
        var PICKS_CLEARED_EVENT = "ecrits:document-element-picker.picks-cleared";
        function bridge() {
          return document.querySelector(PICKER_BRIDGE_SELECTOR);
        }
        function pickerState() {
          try {
            return JSON.parse(bridge()?.dataset.pickerState || "{}");
          } catch (_error) {
            return {};
          }
        }
        function elementPickerEnabled() {
          return pickerState().enabled === true;
        }
        function pickedElements() {
          const picks = pickerState().picks;
          return Array.isArray(picks) ? picks : [];
        }
        function clearPicks() {
          document.dispatchEvent(new CustomEvent(PICKS_CLEARED_EVENT));
        }
        function togglePickedElement(pick) {
          document.dispatchEvent(new CustomEvent(PICK_TOGGLED_EVENT, { detail: pick || {} }));
        }
        function appendPickedElementToComposer(pick) {
          togglePickedElement(pick);
        }
        function bindElementPickerTarget(target) {
          const apply = (detail) => {
            const enabled = detail?.enabled === true;
            if (target.el) {
              target.el.dataset.elementPicker = String(enabled);
              target.el.classList.toggle("[&_canvas]:cursor-crosshair", enabled);
            }
            if (typeof target.onElementPickerState === "function") {
              target.onElementPickerState(enabled);
            }
            if (typeof target.paintPickedHighlights === "function") {
              target.paintPickedHighlights();
            }
          };
          const onState = (event) => apply(event.detail);
          apply({ enabled: elementPickerEnabled(), picks: pickedElements() });
          document.addEventListener(PICKER_STATE_EVENT, onState);
          return () => document.removeEventListener(PICKER_STATE_EVENT, onState);
        }
        function pickKey(pick) {
          return `${pick.document || ""}|${pick.ref || pick.text || ""}`;
        }
        function implicitAgentPicks() {
          const picks = [];
          for (const el of document.querySelectorAll(SEL.hwpEditor)) {
            let state = {};
            try {
              state = JSON.parse(el.dataset?.canvasState || "{}");
            } catch (_error) {
            }
            if (state.editorMirror === true) continue;
            const editor = el.__wasmHwpEditor;
            if (!editor || editor.mirror || typeof editor.agentSelectionPicks !== "function") continue;
            for (const pick of editor.agentSelectionPicks() || []) picks.push(pick);
          }
          return picks;
        }
        function compactPicks() {
          const seen = /* @__PURE__ */ new Set();
          return [...pickedElements(), ...implicitAgentPicks()].filter((pick) => {
            const key = pickKey(pick);
            if (!key || seen.has(key)) return false;
            seen.add(key);
            return true;
          }).map((pick) => ({
            document: pick.document || "",
            type: pick.type || "unknown",
            ref: pick.ref || "",
            text: (pick.text || "").slice(0, 200),
            hint: (pick.hint || "").slice(0, 300)
          }));
        }

        // assets/js/wasm_ops.ts
        var imageByteDims = (bytes) => {
          if (!bytes || bytes.length < 10) return null;
          if (bytes.length >= 24 && bytes[0] === 137 && bytes[1] === 80 && bytes[2] === 78 && bytes[3] === 71 && bytes[4] === 13 && bytes[5] === 10 && bytes[6] === 26 && bytes[7] === 10 && bytes[12] === 73 && bytes[13] === 72 && bytes[14] === 68 && bytes[15] === 82) {
            return {
              width: (bytes[16] << 24 | bytes[17] << 16 | bytes[18] << 8 | bytes[19]) >>> 0,
              height: (bytes[20] << 24 | bytes[21] << 16 | bytes[22] << 8 | bytes[23]) >>> 0
            };
          }
          if (bytes.length >= 10 && bytes[0] === 71 && bytes[1] === 73 && bytes[2] === 70) {
            return {
              width: bytes[6] | bytes[7] << 8,
              height: bytes[8] | bytes[9] << 8
            };
          }
          if (bytes.length >= 4 && bytes[0] === 255 && bytes[1] === 216) {
            let i = 2;
            while (i + 8 < bytes.length) {
              if (bytes[i] !== 255) {
                i++;
                continue;
              }
              while (i < bytes.length && bytes[i] === 255) i++;
              const marker = bytes[i++];
              if (marker === 217 || marker === 218) break;
              if (marker >= 208 && marker <= 216) continue;
              if (i + 1 >= bytes.length) break;
              const len = bytes[i] << 8 | bytes[i + 1];
              if (len < 2 || i + len > bytes.length) break;
              const sof = marker >= 192 && marker <= 207 && marker !== 196 && marker !== 200 && marker !== 204;
              if (sof && len >= 7) {
                return {
                  height: bytes[i + 3] << 8 | bytes[i + 4],
                  width: bytes[i + 5] << 8 | bytes[i + 6]
                };
              }
              i += len;
            }
          }
          return null;
        };
        var declaredImageDims = (op) => {
          const width = Number.isInteger(op.natural_width_px) ? op.natural_width_px : Number.isInteger(op.naturalWidthPx) ? op.naturalWidthPx : 0;
          const height = Number.isInteger(op.natural_height_px) ? op.natural_height_px : Number.isInteger(op.naturalHeightPx) ? op.naturalHeightPx : 0;
          return width > 0 && height > 0 ? { width, height } : null;
        };
        var validateDeclaredImageDims = (op, bytes) => {
          const actual = imageByteDims(bytes);
          const declared = declaredImageDims(op);
          if (!actual || !declared) return null;
          if (actual.width === declared.width && actual.height === declared.height) return null;
          return `insert_picture image bytes are ${actual.width}x${actual.height}px but natural_width_px/natural_height_px declare ${declared.width}x${declared.height}px; use a real image src/base64 pair`;
        };
        var opReplaceText = (ctx, op, ref, verb) => {
          const query = op.query != null ? String(op.query) : "";
          if (!query) return { error: "replace_text requires a non-empty query" };
          if (op.replacement == null) {
            return { error: "replace_text requires a 'replacement' field (the field is 'replacement', not 'text'/'new'; to delete text use delete_range)" };
          }
          const replacement = ctx.singleParagraphText(op.replacement);
          if (ref && ref.cell) {
            const cl = ref.cell;
            let cellText = "";
            try {
              const len = ctx.cellParagraphLength(ref, cl, cl.cellParaIndex);
              cellText = ctx.getTextInCellRef(ref, cl, cl.cellParaIndex, 0, len) || "";
            } catch (error) {
              return { error: `cell read failed: ${String(error && error.message || error)}` };
            }
            const idx = cellText.indexOf(query);
            if (idx < 0) {
              return { error: `replace_text: query not found in target cell (cell text: ${JSON.stringify(cellText.slice(0, 80))})` };
            }
            try {
              ctx.deleteTextInCellRef(ref, cl, cl.cellParaIndex, idx, query.length);
              ctx.insertTextInCellRef(ref, cl, cl.cellParaIndex, idx, replacement);
            } catch (error) {
              return { error: `cell replace failed: ${String(error && error.message || error)}` };
            }
            ctx.recordOp("AgentReplaceText", { section: ref.section, cell: cl, offset: idx, query, replacement, replaced: 1 });
            return { ok: true, extra: { replaced: 1 } };
          }
          if (ref && ref.note) {
            const nt = ref.note;
            const noteText = ctx.noteParagraphText(ref.section, ref.paragraph, nt);
            const idx = noteText.indexOf(query);
            if (idx < 0) {
              return { error: `replace_text: query not found in target note body (note text: ${JSON.stringify(noteText.slice(0, 80))})` };
            }
            try {
              ctx.doc.deleteTextInFootnote(ref.section, ref.paragraph, nt.controlIndex, nt.subParaIndex, idx, query.length);
              ctx.doc.insertTextInFootnote(ref.section, ref.paragraph, nt.controlIndex, nt.subParaIndex, idx, replacement);
            } catch (error) {
              return { error: `note replace failed: ${String(error && error.message || error)}` };
            }
            ctx.recordOp("AgentReplaceText", { section: ref.section, para: ref.paragraph, note: nt, offset: idx, query, replacement, replaced: 1 });
            return { ok: true, extra: { replaced: 1 } };
          }
          if (ref) {
            let paraText = "";
            try {
              const len = ctx.paragraphLength(ref.section, ref.paragraph);
              paraText = ctx.doc.getTextRange(ref.section, ref.paragraph, 0, len) || "";
            } catch (_) {
              paraText = "";
            }
            const idx = paraText.indexOf(query);
            if (idx >= 0) {
              try {
                ctx.doc.deleteText(ref.section, ref.paragraph, idx, query.length);
                ctx.doc.insertText(ref.section, ref.paragraph, idx, replacement);
              } catch (error) {
                return { error: `scoped replace failed: ${String(error && error.message || error)}` };
              }
              ctx.recordOp("AgentReplaceText", { section: ref.section, para: ref.paragraph, offset: idx, query, replacement, replaced: 1 });
              return { ok: true, extra: { replaced: 1 } };
            }
            console.warn(
              `[wasm-hwp] ref-scoped replace: query not in body paragraph ${ref.section}/${ref.paragraph} (likely in a table cell) \u2014 falling back to global match`
            );
          }
          const all = op.all === true;
          let matchCount = null;
          try {
            const raw = ctx.doc.searchAllText(query, true, true);
            const parsed = raw ? JSON.parse(raw) : [];
            const list = Array.isArray(parsed) ? parsed : parsed.matches || [];
            matchCount = list.length;
          } catch (_) {
            matchCount = null;
          }
          if (matchCount === 0) {
            return { error: `replace_text: no match for query (it must be the document's exact current text)` };
          }
          if (matchCount != null && matchCount > 1 && !all) {
            return { error: `replace_text: query matches ${matchCount} places; pass a ref to target one, use a longer/unique query, or pass all:true to replace every match` };
          }
          let replaced = 0;
          try {
            const raw = ctx.doc.replaceAll(query, replacement, true);
            replaced = ctx.replacedCount(raw);
          } catch (error) {
            return { error: `replaceAll failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentReplaceText", { query, replacement, replaced });
          return { ok: true, extra: { replaced } };
        };
        var opInsertText = (ctx, op, ref, verb) => {
          const at = ref || ctx.resolveEndRef(op.ref);
          if (!at) return { error: 'insert_text requires a ref {section,paragraph,offset} (from doc.find) or "end"' };
          const ref2 = at;
          const text = op.text != null ? String(op.text) : "";
          if (!text) return { error: "insert_text requires non-empty 'text'" };
          const offset = Number.isInteger(ref2.offset) ? ref2.offset : 0;
          if (ref2.note) {
            const nt = ref2.note;
            try {
              ctx.insertTextLinesInFootnote(ref, nt, offset, text);
            } catch (error) {
              return { error: `insertTextInFootnote failed: ${String(error && error.message || error)}` };
            }
            ctx.recordOp("AgentInsertText", { section: ref2.section, para: ref2.paragraph, note: nt, offset, text });
            return { ok: true, extra: { inserted: text.length } };
          }
          if (ref2.cell) {
            const cl = ref2.cell;
            try {
              ctx.insertTextLinesInCell(ref, cl, offset, text);
            } catch (error) {
              return { error: `insertTextInCell failed: ${String(error && error.message || error)}` };
            }
            ctx.recordOp("AgentInsertText", { section: ref2.section, cell: cl, offset, text });
            return { ok: true, extra: { inserted: text.length } };
          }
          try {
            ctx.insertTextLines(ref, offset, text);
          } catch (error) {
            return { error: `insertText failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentInsertText", { section: ref2.section, para: ref2.paragraph, offset, text });
          return { ok: true, extra: { inserted: text.length } };
        };
        var opDeleteRange = (ctx, op, ref, verb) => {
          if (!ref) return { error: "delete_range requires a ref {section,paragraph,offset} (from doc.find)" };
          const offset = Number.isInteger(ref.offset) ? ref.offset : 0;
          const cl = ref.cell;
          const nt = ref.note;
          let count = Number.isInteger(op.count) ? op.count : null;
          if (count == null) {
            let len = 0;
            try {
              if (cl) {
                len = ctx.cellParagraphLength(ref, cl, cl.cellParaIndex);
              } else if (nt) {
                len = ctx.noteParagraphText(ref.section, ref.paragraph, nt).length;
              } else {
                len = ctx.paragraphLength(ref.section, ref.paragraph);
              }
            } catch (_) {
              len = 0;
            }
            count = Math.max(0, len - offset);
          }
          if (count <= 0) return { error: "delete_range: nothing to delete (count must be > 0)" };
          try {
            if (cl) {
              ctx.deleteTextInCellRef(ref, cl, cl.cellParaIndex, offset, count);
            } else if (nt) {
              ctx.doc.deleteTextInFootnote(ref.section, ref.paragraph, nt.controlIndex, nt.subParaIndex, offset, count);
            } else {
              ctx.doc.deleteText(ref.section, ref.paragraph, offset, count);
            }
          } catch (error) {
            return { error: `deleteText failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentDeleteRange", { section: ref.section, cell: cl, note: nt, para: ref.paragraph, offset, count });
          return { ok: true, extra: { deleted: count } };
        };
        var opSetCell = (ctx, op, ref, verb) => {
          if (!ref || !ref.cell) {
            return { error: "set_cell requires a CELL ref (doc.find text inside the cell)" };
          }
          const cl = ref.cell;
          const text = op.text != null ? String(op.text) : "";
          const lines = text.split("\n");
          const { section } = ref;
          try {
            const count = ctx.cellParagraphCount(ref, cl);
            for (let cellPara = Math.min(count - 1, 4095); cellPara >= 1; cellPara--) {
              ctx.mergeParagraphInCellRef(ref, cl, cellPara);
            }
          } catch (_) {
          }
          try {
            const len0 = ctx.cellParagraphLength(ref, cl, 0);
            if (len0 > 0) ctx.deleteTextInCellRef(ref, cl, 0, 0, len0);
            if (lines[0]) ctx.insertTextInCellRef(ref, cl, 0, 0, lines[0]);
            for (let i = 1; i < lines.length; i++) {
              const prevLen = ctx.cellParagraphLength(ref, cl, i - 1);
              ctx.splitParagraphInCellRef(ref, cl, i - 1, prevLen);
              if (lines[i]) ctx.insertTextInCellRef(ref, cl, i, 0, lines[i]);
            }
          } catch (error) {
            return { error: `set_cell failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentSetCell", { section, cell: cl, lines });
          return { ok: true, extra: { cellParaCount: lines.length } };
        };
        var opInsertEquation = (ctx, op, ref, verb) => {
          if (!ref) return { error: "insert_equation requires a ref {section,paragraph,offset} (from doc.find)" };
          const script = op.script != null ? String(op.script) : "";
          if (!script) return { error: "insert_equation requires a non-empty 'script' (HWP equation markup, e.g. 'x^2 + y^2 = z^2')" };
          const offset = Number.isInteger(ref.offset) ? ref.offset : 0;
          const fontSize = Number.isInteger(op.font_size) ? op.font_size : 1e3;
          const color = Number.isInteger(op.color) ? op.color : 0;
          try {
            ctx.doc.insertEquation(ref.section, ref.paragraph, offset, script, fontSize, color);
          } catch (error) {
            return { error: `insertEquation failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentInsertEquation", { section: ref.section, para: ref.paragraph, offset, script, fontSize, color });
          return { ok: true, extra: { script } };
        };
        var opInsertNote = (ctx, op, ref, verb) => {
          if (!ref) return { error: `${verb} requires a ref {section,paragraph,offset} (from doc.find)` };
          const offset = Number.isInteger(ref.offset) ? ref.offset : 0;
          const text = op.text != null ? String(op.text) : "";
          const cell = ref.cell && Number.isInteger(ref.cell.parentParaIndex) ? ref.cell : null;
          let noteInfo = {};
          try {
            if (verb === "insert_footnote" && cell && typeof ctx.doc.insertFootnoteInCell === "function") {
              const res = ctx.doc.insertFootnoteInCell(
                ref.section,
                cell.parentParaIndex,
                cell.controlIndex,
                cell.cellIndex,
                Number.isInteger(cell.cellParaIndex) ? cell.cellParaIndex : 0,
                offset,
                text
              );
              try {
                noteInfo = JSON.parse(res || "{}");
              } catch {
                noteInfo = {};
              }
            } else {
              const res = verb === "insert_footnote" ? ctx.doc.insertFootnote(ref.section, ref.paragraph, offset) : ctx.doc.insertEndnote(ref.section, ref.paragraph, offset);
              try {
                noteInfo = JSON.parse(res || "{}");
              } catch {
                noteInfo = {};
              }
              if (text) {
                if (!Number.isInteger(noteInfo.controlIdx)) {
                  return { error: `${verb}: engine did not report controlIdx \u2014 anchor created but text NOT inserted` };
                }
                const notePara = Number.isInteger(noteInfo.paraIdx) ? noteInfo.paraIdx : ref.paragraph;
                ctx.doc.insertTextInFootnote(ref.section, notePara, noteInfo.controlIdx, 0, 2, text);
              }
            }
          } catch (error) {
            return { error: `${verb} failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp(verb === "insert_footnote" ? "AgentInsertFootnote" : "AgentInsertEndnote", { section: ref.section, para: ref.paragraph, offset, text, cell });
          const number = noteInfo.footnoteNumber != null ? noteInfo.footnoteNumber : noteInfo.endnoteNumber;
          return { ok: true, extra: { text, number, paraIdx: noteInfo.paraIdx, controlIdx: noteInfo.controlIdx } };
        };
        var opInsertShape = (ctx, op, ref, verb) => {
          if (!ref) return { error: "insert_shape requires a ref {section,paragraph,offset} (from doc.find)" };
          const width = Number.isInteger(op.width) ? op.width : null;
          const height = Number.isInteger(op.height) ? op.height : null;
          if (width == null || height == null) {
            return { error: "insert_shape requires integer 'width' and 'height' (HWPUNIT, e.g. 8504 \u2248 3cm)" };
          }
          const offset = Number.isInteger(ref.offset) ? ref.offset : 0;
          const shapeType = op.shape_type != null ? String(op.shape_type) : "rectangle";
          const shapeProps = ctx.shapeStylePropsFromOp(op);
          const shapeJson = JSON.stringify({
            sectionIdx: ref.section,
            paraIdx: ref.paragraph,
            charOffset: offset,
            width,
            height,
            horzOffset: Number.isInteger(op.x) ? op.x : 0,
            vertOffset: Number.isInteger(op.y) ? op.y : 0,
            shapeType,
            treatAsChar: true,
            ...shapeProps
          });
          let created = null;
          try {
            created = ctx.doc.createShapeControl(shapeJson);
            if (Object.keys(shapeProps).length > 0 && created) {
              const info = JSON.parse(created);
              if (Number.isInteger(info.paraIdx) && Number.isInteger(info.controlIdx)) {
                ctx.doc.setShapeProperties(ref.section, info.paraIdx, info.controlIdx, JSON.stringify(shapeProps));
              }
            }
          } catch (error) {
            return { error: `createShapeControl failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentInsertShape", { section: ref.section, para: ref.paragraph, offset, shapeType, width, height, shapeProps });
          return { ok: true, extra: { shapeType, shapeProps } };
        };
        var opSetColumns = (ctx, op, ref, verb) => {
          const section = ref ? ref.section : 0;
          const count = Number.isInteger(op.count) ? op.count : null;
          if (count == null || count <= 0) {
            return { error: "set_columns requires an integer 'count' > 0 (the number of columns)" };
          }
          const columnType = Number.isInteger(op.column_type) ? op.column_type : 0;
          const sameWidth = op.same_width === false ? 0 : 1;
          const spacing = Number.isInteger(op.spacing) ? op.spacing : 0;
          try {
            ctx.doc.setColumnDef(section, count, columnType, sameWidth, spacing);
          } catch (error) {
            return { error: `setColumnDef failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentSetColumns", { section, count, columnType, sameWidth, spacing });
          return { ok: true, extra: { count } };
        };
        var opInsertParagraph = (ctx, op, ref, verb) => {
          const target = ref || ctx.resolveEndRef(op.ref);
          if (!target) return { error: 'insert_paragraph requires a ref {section,paragraph} or "end"' };
          const text = op.text != null ? String(op.text) : "";
          const appending = target.appendIndex != null;
          const idx = appending ? target.appendIndex : target.paragraph;
          try {
            if (appending) {
              ctx.doc.insertParagraph(target.section, idx);
              if (text) ctx.insertTextLines({ section: target.section, paragraph: idx }, 0, text);
            } else if (text) {
              ctx.insertTextLines({ section: target.section, paragraph: idx }, 0, text + "\n");
            } else {
              ctx.doc.insertParagraph(target.section, idx);
            }
          } catch (error) {
            return { error: `insertParagraph failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentInsertParagraph", { section: target.section, para: idx, textLen: text.length });
          return { ok: true, extra: { paragraph: idx, inserted: text.length } };
        };
        var opDeleteParagraph = (ctx, op, ref, verb) => {
          if (!ref) return { error: "delete_paragraph requires a ref {section,paragraph}" };
          try {
            ctx.doc.deleteParagraph(ref.section, ref.paragraph);
          } catch (error) {
            return { error: `deleteParagraph failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentDeleteParagraph", { section: ref.section, para: ref.paragraph });
          return { ok: true, extra: {} };
        };
        var opSplit = (ctx, op, ref, verb) => {
          if (!ref) return { error: "split requires a ref {section,paragraph,offset}" };
          const offset = Number.isInteger(ref.offset) ? ref.offset : 0;
          try {
            if (ref.cell) {
              ctx.splitParagraphInCellRef(ref, ref.cell, ref.cell.cellParaIndex, offset);
            } else {
              ctx.doc.splitParagraph(ref.section, ref.paragraph, offset);
            }
          } catch (error) {
            return { error: `splitParagraph failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentSplit", { section: ref.section, para: ref.paragraph, cell: ref.cell || null, offset });
          return { ok: true, extra: {} };
        };
        var opMerge = (ctx, op, ref, verb) => {
          if (!ref) return { error: "merge requires a ref {section,paragraph}" };
          try {
            if (ref.cell) {
              ctx.mergeParagraphInCellRef(ref, ref.cell, ref.cell.cellParaIndex);
            } else {
              ctx.doc.mergeParagraph(ref.section, ref.paragraph);
            }
          } catch (error) {
            return { error: `mergeParagraph failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentMerge", { section: ref.section, para: ref.paragraph, cell: ref.cell || null });
          return { ok: true, extra: {} };
        };
        var opInsertTable = (ctx, op, ref, verb) => {
          if (!ref) return { error: "insert_table requires a ref {section,paragraph,offset}" };
          const rows = Number.isInteger(op.rows) ? op.rows : null;
          const cols = Number.isInteger(op.cols) ? op.cols : null;
          if (rows == null || cols == null || rows <= 0 || cols <= 0) {
            return { error: "insert_table requires integer 'rows' > 0 and 'cols' > 0" };
          }
          const offset = Number.isInteger(ref.offset) ? ref.offset : 0;
          const treatAsChar = op.treat_as_char === true;
          const colWidths = Array.isArray(op.col_widths) ? op.col_widths.filter(Number.isInteger) : null;
          let rawResult = null;
          try {
            if (treatAsChar || colWidths && colWidths.length) {
              const optionsJson = JSON.stringify({
                sectionIdx: ref.section,
                paraIdx: ref.paragraph,
                charOffset: offset,
                rowCount: rows,
                colCount: cols,
                treatAsChar,
                ...colWidths && colWidths.length ? { colWidths } : {}
              });
              rawResult = ctx.doc.createTableEx(optionsJson);
            } else {
              rawResult = ctx.doc.createTable(ref.section, ref.paragraph, offset, rows, cols);
            }
          } catch (error) {
            return { error: `createTable failed: ${String(error && error.message || error)}` };
          }
          let meta = {};
          try {
            meta = typeof rawResult === "string" ? JSON.parse(rawResult) : rawResult || {};
          } catch (_) {
            meta = {};
          }
          const tablePara = Number.isInteger(meta.paraIdx) ? meta.paraIdx : ref.paragraph;
          const control = Number.isInteger(meta.controlIdx) ? meta.controlIdx : 0;
          const cells = Array.isArray(op.cells) ? op.cells : [];
          let cellsFilled = 0;
          try {
            for (let row = 0; row < Math.min(rows, cells.length); row++) {
              const values = Array.isArray(cells[row]) ? cells[row] : [cells[row]];
              for (let col = 0; col < Math.min(cols, values.length); col++) {
                const text = String(values[col] == null ? "" : values[col]);
                if (text === "") continue;
                const cellIndex = row * cols + col;
                const cell = {
                  parentParaIndex: tablePara,
                  controlIndex: control,
                  cellIndex,
                  cellParaIndex: 0
                };
                const cellRef = {
                  section: ref.section,
                  paragraph: tablePara,
                  offset: 0,
                  cell
                };
                ctx.insertTextLinesInCell(cellRef, cell, 0, text);
                cellsFilled += 1;
              }
            }
            if (op.header === true) {
              const color = ctx.colorValueToBgr(op.header_color || op.headerColor || "#e8e8e8");
              const props = color == null ? null : JSON.stringify({ BackgroundColor: color });
              if (props) {
                for (let col = 0; col < cols; col++) {
                  ctx.doc.setCellProperties(ref.section, tablePara, control, col, props);
                }
              }
            }
          } catch (error) {
            return { error: `createTable cell fill failed: ${String(error && error.message || error)}` };
          }
          ctx.recordOp("AgentInsertTable", { section: ref.section, para: tablePara, control, offset, rows, cols, treatAsChar, cellsFilled });
          return { ok: true, extra: { rows, cols, cells_filled: cellsFilled, paraIdx: tablePara, controlIdx: control } };
        };
        var opTableStructure = (ctx, op, ref, verb) => {
          const target = ctx.resolveTableTarget(ref);
          if (!target) {
            return { error: `${verb} requires a table CELL ref (doc.find a cell in the table; its ref.cell carries the table control)` };
          }
          const { section, paragraph, control } = target;
          const dimsAfter = () => {
            try {
              const d = JSON.parse(ctx.doc.getTableDimensions(section, paragraph, control));
              return { rows_after: d.rowCount, cols_after: d.colCount };
            } catch (_) {
              return {};
            }
          };
          try {
            if (verb === "insert_table_row") {
              const row2 = Number.isInteger(op.row) ? op.row : ctx.cellRowCol(target).row;
              if (!Number.isInteger(row2)) return { error: "insert_table_row needs a 'row' index (or a cell ref to derive it)" };
              const below = op.below === true;
              const count = Number.isInteger(op.count) && op.count > 0 ? Math.min(op.count, 200) : 1;
              for (let i = 0; i < count; i++) {
                ctx.doc.insertTableRow(section, paragraph, control, row2, below);
              }
              ctx.recordOp("AgentInsertTableRow", { section, paragraph, control, row: row2, below, count });
              return { ok: true, extra: { row: row2, below, inserted: count, ...dimsAfter() } };
            }
            if (verb === "delete_table_row") {
              const row2 = Number.isInteger(op.row) ? op.row : ctx.cellRowCol(target).row;
              if (!Number.isInteger(row2)) return { error: "delete_table_row needs a 'row' index (or a cell ref to derive it)" };
              ctx.doc.deleteTableRow(section, paragraph, control, row2);
              ctx.recordOp("AgentDeleteTableRow", { section, paragraph, control, row: row2 });
              return { ok: true, extra: { row: row2, ...dimsAfter() } };
            }
            if (verb === "insert_table_column") {
              const col2 = Number.isInteger(op.col) ? op.col : ctx.cellRowCol(target).col;
              if (!Number.isInteger(col2)) return { error: "insert_table_column needs a 'col' index (or a cell ref to derive it)" };
              const right = op.right === true;
              const count = Number.isInteger(op.count) && op.count > 0 ? Math.min(op.count, 64) : 1;
              for (let i = 0; i < count; i++) {
                ctx.doc.insertTableColumn(section, paragraph, control, col2, right);
              }
              ctx.recordOp("AgentInsertTableColumn", { section, paragraph, control, col: col2, right, count });
              return { ok: true, extra: { col: col2, right, inserted: count, ...dimsAfter() } };
            }
            if (verb === "delete_table_column") {
              const col2 = Number.isInteger(op.col) ? op.col : ctx.cellRowCol(target).col;
              if (!Number.isInteger(col2)) return { error: "delete_table_column needs a 'col' index (or a cell ref to derive it)" };
              ctx.doc.deleteTableColumn(section, paragraph, control, col2);
              ctx.recordOp("AgentDeleteTableColumn", { section, paragraph, control, col: col2 });
              return { ok: true, extra: { col: col2, ...dimsAfter() } };
            }
            if (verb === "merge_cells") {
              const sr = Number.isInteger(op.start_row) ? op.start_row : null;
              const sc = Number.isInteger(op.start_col) ? op.start_col : null;
              const er = Number.isInteger(op.end_row) ? op.end_row : null;
              const ec = Number.isInteger(op.end_col) ? op.end_col : null;
              if ([sr, sc, er, ec].some((v) => v == null)) {
                return { error: "merge_cells requires integer start_row/start_col/end_row/end_col" };
              }
              ctx.doc.mergeTableCells(section, paragraph, control, sr, sc, er, ec);
              ctx.recordOp("AgentMergeCells", { section, paragraph, control, sr, sc, er, ec });
              return { ok: true, extra: { start_row: sr, start_col: sc, end_row: er, end_col: ec } };
            }
            const cellRC = ctx.cellRowCol(target);
            const row = Number.isInteger(op.row) ? op.row : cellRC.row;
            const col = Number.isInteger(op.col) ? op.col : cellRC.col;
            if (!Number.isInteger(row) || !Number.isInteger(col)) {
              return { error: "split_cell needs 'row' and 'col' (or a cell ref to derive them)" };
            }
            const nRows = Number.isInteger(op.rows) ? op.rows : 1;
            const mCols = Number.isInteger(op.cols) ? op.cols : 1;
            if (nRows <= 0 || mCols <= 0 || nRows === 1 && mCols === 1) {
              return { error: "split_cell needs 'rows'/'cols' (the target sub-grid, e.g. rows:2 to split a cell into 2)" };
            }
            ctx.doc.splitTableCellInto(section, paragraph, control, row, col, nRows, mCols, true, false);
            ctx.recordOp("AgentSplitCell", { section, paragraph, control, row, col, nRows, mCols });
            return { ok: true, extra: { row, col, rows: nRows, cols: mCols } };
          } catch (error) {
            return { error: `${verb} failed: ${String(error && error.message || error)}` };
          }
        };
        var opDeleteNode = (ctx, op, ref, verb) => {
          const rawControl = ctx.rawControlIndex(op && op.ref);
          let rawType = null;
          if (op && op.ref && typeof op.ref === "object") {
            rawType = op.ref.type;
          } else if (op && typeof op.ref === "string") {
            try {
              rawType = JSON.parse(op.ref).type;
            } catch (_) {
            }
          }
          if (rawType === "picture" && ref && ref.cell && Number.isInteger(rawControl)) {
            const cellPath = ref.cell.cellPath ? ref.cell.cellPath : [{
              controlIndex: ref.cell.controlIndex ?? 0,
              cellIndex: ref.cell.cellIndex ?? 0,
              cellParaIndex: ref.cell.cellParaIndex ?? 0
            }];
            try {
              const cellPathJson = JSON.stringify(cellPath);
              ctx.doc.deleteCellPictureControlByPath(ref.section, ref.cell.parentParaIndex, cellPathJson, rawControl);
              ctx.recordOp("AgentDeleteNode", { section: ref.section, paragraph: ref.cell.parentParaIndex, control: rawControl, cellPath, removed: "picture" });
              return { ok: true, extra: { removed: "picture" } };
            } catch (error) {
              return { error: `delete_node cell picture failed: ${String(error && error.message || error)}` };
            }
          }
          const target = ctx.resolveTableTarget(ref);
          let section, paragraph, control;
          if (target) {
            ;
            ({ section, paragraph, control } = target);
          } else {
            control = ctx.rawControlIndex(op && op.ref);
            section = ref ? ref.section : 0;
            paragraph = ref ? ref.paragraph : null;
          }
          if (!Number.isInteger(control) || !Number.isInteger(paragraph)) {
            return { error: "delete_node requires a ref to a control (a table cell ref, or an element ref carrying a control index)" };
          }
          const removers = [
            ["table", (s, p, c) => ctx.doc.deleteTableControl(s, p, c)],
            ["picture", (s, p, c) => ctx.doc.deletePictureControl(s, p, c)],
            ["shape", (s, p, c) => ctx.doc.deleteShapeControl(s, p, c)],
            ["equation", (s, p, c) => ctx.doc.deleteEquationControl(s, p, c)],
            ["note", (s, p, c) => ctx.doc.deleteFootnote(s, p, c)]
          ];
          let removed = null;
          let lastErr = null;
          for (const [kind, fn] of removers) {
            try {
              fn(section, paragraph, control);
              removed = kind;
              break;
            } catch (error) {
              lastErr = error;
            }
          }
          if (!removed) {
            return { error: `delete_node failed: control ${control} at p${paragraph} is not a deletable node (${String(lastErr && lastErr.message || lastErr)})` };
          }
          ctx.recordOp("AgentDeleteNode", { section, paragraph, control, removed });
          return { ok: true, extra: { removed } };
        };
        var opInsertPicture = (ctx, op, ref, verb) => {
          if (!ref) return { error: "insert_picture requires a ref {section,paragraph,offset}" };
          const b64 = op.image_base64 || op.imageBase64;
          if (!b64) {
            return { error: "insert_picture on a viewed doc needs inline image bytes ('image_base64'); the server producer must attach them from 'src'" };
          }
          const width = Number.isInteger(op.width) ? op.width : null;
          const height = Number.isInteger(op.height) ? op.height : null;
          if (width == null || height == null) {
            return { error: "insert_picture requires integer 'width' and 'height' (HWPUNIT)" };
          }
          const offset = Number.isInteger(ref.offset) ? ref.offset : 0;
          const extension = op.extension != null ? String(op.extension) : "png";
          const naturalW = Number.isInteger(op.natural_width_px) ? op.natural_width_px : 0;
          const naturalH = Number.isInteger(op.natural_height_px) ? op.natural_height_px : 0;
          const description = op.description != null ? String(op.description) : "";
          let bytes;
          try {
            bytes = ctx.base64ToBytes(b64);
          } catch (error) {
            return { error: `insert_picture: invalid base64 image data (${String(error && error.message || error)})` };
          }
          const dimError = validateDeclaredImageDims(op, bytes);
          if (dimError) return { error: dimError };
          const inlineInCell = op.inline_in_cell === true || op.inlineInCell === true;
          const cellPath = ref.cell && ref.cell.cellPath ? ref.cell.cellPath : ref.cell ? [{
            controlIndex: ref.cell.controlIndex ?? 0,
            cellIndex: ref.cell.cellIndex ?? 0,
            cellParaIndex: ref.cell.cellParaIndex ?? 0
          }] : null;
          const cellPathJson = cellPath ? JSON.stringify(cellPath) : "";
          const priorPictureRefs = new Set();
          try {
            for (const element of ctx.collectElements()) {
              if (element && element.type === "picture" && element.ref) {
                priorPictureRefs.add(JSON.stringify(element.ref));
              }
            }
          } catch (_) {
          }
          try {
            const paperOffsetX = Number.isInteger(op.paper_offset_x_hu) ? op.paper_offset_x_hu : Number.isInteger(op.x) ? op.x : null;
            const paperOffsetY = Number.isInteger(op.paper_offset_y_hu) ? op.paper_offset_y_hu : Number.isInteger(op.y) ? op.y : null;
            const options = {
              sectionIdx: ref.section,
              paraIdx: ref.paragraph,
              charOffset: offset,
              cellPath: cellPathJson,
              width,
              height,
              naturalWidthPx: naturalW,
              naturalHeightPx: naturalH,
              extension,
              description,
              inlineInCell,
              paperOffsetXHu: paperOffsetX,
              paperOffsetYHu: paperOffsetY
            };
            if (typeof ctx.doc.insertPictureBase64 === "function") {
              ctx.doc.insertPictureBase64(JSON.stringify(options), String(b64));
            } else if (typeof ctx.doc.insertPictureEx === "function") {
              ctx.doc.insertPictureEx(JSON.stringify(options), bytes);
            } else {
              ctx.doc.insertPicture(
                ref.section,
                ref.paragraph,
                offset,
                cellPathJson,
                bytes,
                width,
                height,
                naturalW,
                naturalH,
                extension,
                description,
                paperOffsetX,
                paperOffsetY
              );
            }
          } catch (error) {
            return { error: `insertPicture failed: ${String(error && error.message || error)}` };
          }
          ctx._elementsCache = null;
          let inserted = null;
          try {
            inserted = ctx.collectElements().find((element) => {
              if (!element || element.type !== "picture" || !element.ref) return false;
              if (priorPictureRefs.has(JSON.stringify(element.ref))) return false;
              return Number(element.ref.section ?? 0) === Number(ref.section ?? 0);
            }) || null;
          } catch (_) {
          }
          ctx.recordOp("AgentInsertPicture", { section: ref.section, para: ref.paragraph, offset, width, height, extension, inlineInCell });
          const insertedRef = inserted && inserted.ref || {};
          return {
            ok: true,
            extra: {
              width,
              height,
              extension,
              paraIdx: Number.isInteger(insertedRef.paragraph) ? insertedRef.paragraph : ref.paragraph,
              controlIdx: Number.isInteger(insertedRef.control) ? insertedRef.control : insertedRef.controlIndex
            }
          };
        };
        var OpRegistry = class {
          registry = /* @__PURE__ */ Object.create(null);
          define(verb, handler) {
            this.registry[verb] = handler;
            return this;
          }
        };
        var OPS = new OpRegistry().define("replace_text", opReplaceText).define("insert_text", opInsertText).define("delete_range", opDeleteRange).define("set_cell", opSetCell).define("insert_equation", opInsertEquation).define("insert_footnote", opInsertNote).define("insert_endnote", opInsertNote).define("insert_shape", opInsertShape).define("set_columns", opSetColumns).define("insert_paragraph", opInsertParagraph).define("delete_paragraph", opDeleteParagraph).define("split", opSplit).define("merge", opMerge).define("insert_table", opInsertTable).define("insert_table_row", opTableStructure).define("delete_table_row", opTableStructure).define("insert_table_column", opTableStructure).define("delete_table_column", opTableStructure).define("merge_cells", opTableStructure).define("split_cell", opTableStructure).define("delete_node", opDeleteNode).define("insert_picture", opInsertPicture);

        // assets/js/wasm_hwp_keys.ts
        var keyboardSubsystem = {
          bindEditing() {
            if (!this.imeProxy) return;
            this.onBeforeInput = (e) => this.handleBeforeInput(e);
            this.onInput = (e) => this.handleInput(e);
            this.onCompositionStart = (e) => this.handleCompositionStart(e);
            this.onCompositionUpdate = (e) => this.handleCompositionUpdate(e);
            this.onCompositionEnd = (e) => this.handleCompositionEnd(e);
            this.onKeyDown = (e) => this.handleKeyDown(e);
            this.onProxyFocus = () => this.activateKeyboardShortcuts();
            this.onCopy = (e) => this.handleCopy(e);
            this.onPaste = (e) => this.handlePaste(e);
            this.imeProxy.addEventListener("beforeinput", this.onBeforeInput);
            this.imeProxy.addEventListener("input", this.onInput);
            this.imeProxy.addEventListener("compositionstart", this.onCompositionStart);
            this.imeProxy.addEventListener("compositionupdate", this.onCompositionUpdate);
            this.imeProxy.addEventListener("compositionend", this.onCompositionEnd);
            this.imeProxy.addEventListener("keydown", this.onKeyDown);
            this.imeProxy.addEventListener("focus", this.onProxyFocus);
            this.imeProxy.addEventListener("copy", this.onCopy);
            this.imeProxy.addEventListener("paste", this.onPaste);
          },
          unbindEditing() {
            if (!this.imeProxy) return;
            this.imeProxy.removeEventListener("beforeinput", this.onBeforeInput);
            this.imeProxy.removeEventListener("input", this.onInput);
            this.imeProxy.removeEventListener("compositionstart", this.onCompositionStart);
            this.imeProxy.removeEventListener("compositionupdate", this.onCompositionUpdate);
            this.imeProxy.removeEventListener("compositionend", this.onCompositionEnd);
            this.imeProxy.removeEventListener("keydown", this.onKeyDown);
            this.imeProxy.removeEventListener("focus", this.onProxyFocus);
            this.imeProxy.removeEventListener("copy", this.onCopy);
            this.imeProxy.removeEventListener("paste", this.onPaste);
            this.shortcutActive = false;
          },
          activateKeyboardShortcuts() {
            if (!this.mirror) this.shortcutActive = true;
          },
          handleDocumentPointerDown(event) {
            if (this.mirror) return;
            const target = event && event.target;
            if (target && this.el && this.el.contains && this.el.contains(target)) {
              this.activateKeyboardShortcuts();
              return;
            }
            if (target !== this.imeProxy) this.shortcutActive = false;
          },
          handleDocumentKeyDown(event) {
            if (event.defaultPrevented || !this.documentShortcutTarget(event)) return;
            if (this.saveShortcut(event)) {
              event.preventDefault();
              event.stopPropagation();
              this.saveLocalDocument({});
              return;
            }
            this.handleHwpEditShortcut(event);
          },
          documentShortcutTarget(event) {
            if (!this.shortcutActive) return false;
            if (!this.doc) return false;
            const target = event && event.target;
            if (target === this.imeProxy) return false;
            if (this.eventTargetIsEditable(target)) return false;
            if (target && this.el && this.el.contains && this.el.contains(target)) return true;
            const active = document.activeElement;
            if (active && this.el && this.el.contains && this.el.contains(active)) return true;
            return !active || active === document.body || active === document.documentElement;
          },
          eventTargetIsEditable(target) {
            if (!target || target === this.imeProxy || !target.closest) return false;
            return !!target.closest("input, textarea, select, [contenteditable=''], [contenteditable='true']");
          },
          // beforeinput lets us swallow the proxy's own echo (we never want the textarea
          // to accumulate text — the document IS the model). We still let composition
          // events flow through input/composition* handlers.
          handleBeforeInput(_event) {
          },
          hwpNativeImeAvailable() {
            return !!(this.doc && typeof this.doc.beginImeComposition === "function" && typeof this.doc.updateImeComposition === "function" && typeof this.doc.commitImeComposition === "function" && typeof this.doc.cancelImeComposition === "function");
          },
          hwpImeAnchor() {
            const c = this.caret;
            if (!c || c.note) return null;
            if (c.cell) {
              if (Array.isArray(c.cell.cellPath) && c.cell.cellPath.length > 1) {
                return {
                  kind: "cellPath",
                  sectionIdx: c.section,
                  parentParaIdx: c.cell.parentParaIndex,
                  cellPath: c.cell.cellPath,
                  charOffset: c.offset
                };
              }
              return {
                kind: "cell",
                sectionIdx: c.section,
                parentParaIdx: c.cell.parentParaIndex,
                controlIdx: c.cell.controlIndex,
                cellIdx: c.cell.cellIndex,
                cellParaIdx: c.cell.cellParaIndex,
                charOffset: c.offset
              };
            }
            return {
              kind: "body",
              sectionIdx: c.section,
              paraIdx: c.paragraph,
              charOffset: c.offset
            };
          },
          hwpCompositionText(event) {
            const normalize = (text) => {
              const value = String(text || "");
              try {
                return value.normalize("NFC");
              } catch (_) {
                return value;
              }
            };
            if (event && event.data != null) return normalize(event.data);
            return normalize(this.imeProxy ? this.imeProxy.value : "");
          },
          hwpCharCount(text) {
            return [...String(text || "")].length;
          },
          hwpParseNativeJson(raw) {
            if (!raw) return {};
            if (typeof raw === "object") return raw;
            try {
              return JSON.parse(String(raw));
            } catch (_) {
              return {};
            }
          },
          hwpRenderImePages(info, options = {}) {
            const parsed = this.hwpParseNativeJson(info);
            const pages = Array.isArray(parsed.invalidatedPages) ? parsed.invalidatedPages.map(Number).filter(Number.isInteger) : [];
            if (Number.isInteger(Number(parsed.pageIndex))) pages.push(Number(parsed.pageIndex));
            const unique = [...new Set(pages)];
            if (unique.length) {
              unique.forEach((page) => this.renderPage(page));
              return unique;
            }
            if (options.fallbackCaret !== false) this.renderCaretPage();
            return [];
          },
          hwpApplyImeCaret(info) {
            const result = this.hwpParseNativeJson(info);
            const offset = Number(result?.edit?.charOffset ?? result?.charOffset);
            if (!this.caret || !Number.isInteger(offset)) return result;
            this.caret.offset = offset;
            this.caret.preferredX = -1;
            this.refreshCursorRect();
            if (this.caret) this.drawCaret(this.caret);
            this.anchorProxy();
            return result;
          },
          hwpNativeImeInfo() {
            if (!this.hwpNativeImeAvailable() || typeof this.doc.getImeCompositionRenderInfo !== "function") {
              return {};
            }
            try {
              return this.hwpParseNativeJson(this.doc.getImeCompositionRenderInfo());
            } catch (_) {
              return {};
            }
          },
          hwpNativeImeActive() {
            return this.hwpNativeImeInfo().active === true;
          },
          hwpClearNativeIme() {
            if (!this.hwpNativeImeAvailable()) return;
            const before = this.hwpNativeImeInfo();
            if (before.active !== true) return;
            try {
              const raw = this.doc.cancelImeComposition();
              this.hwpApplyImeCaret(raw);
              const rendered = this.hwpRenderImePages(raw, { fallbackCaret: false });
              if (Number.isInteger(Number(before.pageIndex)) && !rendered.includes(Number(before.pageIndex))) {
                this.renderPage(Number(before.pageIndex));
              }
            } catch (error) {
              console.error("[wasm-hwp] cancelImeComposition failed", error);
            }
          },
          hwpCommitNativeIme(text) {
            const before = this.hwpNativeImeInfo();
            const raw = this.doc.commitImeComposition(text);
            this.hwpFinishImeCommit(raw, text, before);
          },
          hwpFinishImeCommit(raw, text, before = null) {
            const result = this.hwpParseNativeJson(raw);
            const c = this.caret;
            if (c && result && result.committed !== false) {
              const edit = result.edit && typeof result.edit === "object" ? result.edit : {};
              const offset = Number(edit.charOffset ?? edit.offset);
              c.offset = Number.isInteger(offset) ? offset : c.offset + this.hwpCharCount(text);
              c.preferredX = -1;
              this.refreshCursorRect();
            }
            const rendered = this.hwpRenderImePages(result);
            if (before && before.active === true && Number.isInteger(Number(before.pageIndex)) && !rendered.includes(Number(before.pageIndex))) {
              this.renderPage(Number(before.pageIndex));
            }
            if (this.caret) this.drawCaret(this.caret);
            this.anchorProxy();
            if (result.committed !== false) {
              this.recordOp("TextInserted", { text });
              this.scheduleSnapshot();
            }
          },
          // Plain text (ASCII / paste) — fires for non-composing input. Korean text is
          // routed to the native IME carrier through composition events and must be
          // skipped here so the browser textarea never becomes the document model.
          handleInput(event) {
            if (!this.doc || !this.caret) return;
            const type = event.inputType || "";
            const compositionInput = type === "insertCompositionText" || type === "insertReplacementText";
            if (compositionInput || event.isComposing) {
              if (this.hwpNativeImeAvailable() && this.hwpNativeImeActive()) {
                const str = this.hwpCompositionText(event);
                try {
                  if (event.isComposing) {
                    const raw = this.doc.updateImeComposition(str, this.hwpCharCount(str));
                    this.hwpApplyImeCaret(raw);
                    this.hwpRenderImePages(raw);
                  } else {
                    this.hwpCommitNativeIme(str);
                  }
                } catch (error) {
                  console.error("[wasm-hwp] composition input fallback failed", error);
                  this.hwpClearNativeIme();
                }
              }
              if (!event.isComposing) this.imeProxy.value = "";
              return;
            }
            if (type === "insertText" || type === "insertFromPaste" || compositionInput) {
              const data = event.data != null ? event.data : this.imeProxy.value;
              if (data) {
                this.pushHwpUndoCheckpoint("input");
                if (this.hasSelection()) this.deleteSelection();
                this.insertPlainTextAtCaret(data);
              }
            }
            this.imeProxy.value = "";
          },
          // Korean IME — composition events are routed to rhwp_core. JS owns neither
          // the live composition text nor its document position; it only forwards the
          // event text and follows the native edit cursor.
          handleCompositionStart(_event) {
            if (!this.doc || !this.caret) return;
            if (!this.hwpNativeImeAvailable()) return;
            this.hwpClearNativeIme();
            const anchor = this.hwpImeAnchor();
            if (!anchor) return;
            this.pushHwpUndoCheckpoint("composition");
            if (this.hasSelection()) this.deleteSelection();
            try {
              const raw = this.doc.beginImeComposition(JSON.stringify(this.hwpImeAnchor() || anchor));
              this.hwpRenderImePages(raw, { fallbackCaret: false });
            } catch (error) {
              console.error("[wasm-hwp] beginImeComposition failed", error);
            }
          },
          handleCompositionUpdate(event) {
            if (!this.doc || !this.caret || !this.hwpNativeImeAvailable()) return;
            const str = this.hwpCompositionText(event);
            try {
              const raw = this.doc.updateImeComposition(str, this.hwpCharCount(str));
              this.hwpApplyImeCaret(raw);
              this.hwpRenderImePages(raw);
            } catch (error) {
              console.error("[wasm-hwp] updateImeComposition failed", error);
            }
          },
          handleCompositionEnd(event) {
            if (!this.doc || !this.caret) return;
            const str = this.hwpCompositionText(event);
            if (this.hwpNativeImeAvailable()) {
              try {
                this.hwpCommitNativeIme(str);
              } catch (error) {
                console.error("[wasm-hwp] commitImeComposition failed", error);
                this.hwpClearNativeIme();
              }
              this.imeProxy.value = "";
              return;
            }
            if (str) {
              this.pushHwpUndoCheckpoint("composition");
              if (this.hasSelection()) this.deleteSelection();
              this.insertPlainTextAtCaret(str);
            }
            this.imeProxy.value = "";
          },
          // Insert plain text at the caret, route to cell when inside a table cell.
          insertAtCaret(text) {
            const c = this.caret;
            this.applyInsert(c.section, c.paragraph, c.offset, text);
            c.offset += [...text].length;
            c.preferredX = -1;
            this.refreshCursorRect();
            this.renderCaretPage();
            this.drawCaret(c);
            this.anchorProxy();
            this.scheduleSnapshot();
          },
          // ─── Low-level apply helpers (body vs cell routing) ──────────────────────
          applyInsert(section, paragraph, offset, text) {
            const c = this.caret;
            try {
              if (c.note) {
                this.doc.insertTextInFootnote(
                  section,
                  paragraph,
                  c.note.controlIndex,
                  c.note.innerParaIndex,
                  offset,
                  text
                );
              } else if (c.cell) {
                this.doc.insertTextInCell(
                  section,
                  c.cell.parentParaIndex,
                  c.cell.controlIndex,
                  c.cell.cellIndex,
                  c.cell.cellParaIndex,
                  offset,
                  text
                );
              } else {
                this.doc.insertText(section, paragraph, offset, text);
              }
              this.recordOp("TextInserted", { section, para: paragraph, offset, text });
            } catch (error) {
              console.error("[wasm-hwp] insertText failed", error);
            }
          },
          applyDelete(section, paragraph, offset, count) {
            const c = this.caret;
            try {
              if (c.note) {
                this.doc.deleteTextInFootnote(
                  section,
                  paragraph,
                  c.note.controlIndex,
                  c.note.innerParaIndex,
                  offset,
                  count
                );
              } else if (c.cell) {
                this.doc.deleteTextInCell(
                  section,
                  c.cell.parentParaIndex,
                  c.cell.controlIndex,
                  c.cell.cellIndex,
                  c.cell.cellParaIndex,
                  offset,
                  count
                );
              } else {
                this.doc.deleteText(section, paragraph, offset, count);
              }
              this.recordOp("TextDeleted", { section, para: paragraph, offset, count });
            } catch (error) {
              console.error("[wasm-hwp] deleteText failed", error);
            }
          },
          // ─── Editing keys (keydown, non-composing) ───────────────────────────────
          handleKeyDown(event) {
            if (this.saveShortcut(event)) {
              event.preventDefault();
              event.stopPropagation();
              this.saveLocalDocument({});
              return;
            }
            if (!this.doc) return;
            if (event.isComposing) return;
            if (this.hwpClearNativeIme) this.hwpClearNativeIme();
            if (this.handleHwpEditShortcut(event)) return;
            if (this.handleSelectedImageDeleteKey(event)) return;
            if (!this.caret) return;
            if (event.metaKey || event.ctrlKey || event.altKey) return;
            if (event.key === "Tab") {
              event.preventDefault();
              event.stopPropagation();
              if (this.imeProxy) this.imeProxy.focus({ preventScroll: true });
              this.anchorProxy();
              return;
            }
            if (this.hasSelection() && (event.key === "Backspace" || event.key === "Delete" || event.key === "Enter")) {
              event.preventDefault();
              this.pushHwpUndoCheckpoint(event.key === "Enter" ? "selection-enter" : "selection-delete");
              this.deleteSelection();
              if (event.key === "Enter") this.splitAtCaret();
              return;
            }
            switch (event.key) {
              case "Backspace":
                event.preventDefault();
                this.pushHwpUndoCheckpoint("backspace");
                this.deleteBackward();
                break;
              case "Delete":
                event.preventDefault();
                this.pushHwpUndoCheckpoint("delete");
                this.deleteForward();
                break;
              case "Enter":
                event.preventDefault();
                this.pushHwpUndoCheckpoint("enter");
                this.splitAtCaret();
                break;
              case "ArrowLeft":
                event.preventDefault();
                this.collapseSelection();
                this.moveHorizontal(-1);
                break;
              case "ArrowRight":
                event.preventDefault();
                this.collapseSelection();
                this.moveHorizontal(1);
                break;
              case "ArrowUp":
                event.preventDefault();
                this.collapseSelection();
                this.moveVertical(-1);
                break;
              case "ArrowDown":
                event.preventDefault();
                this.collapseSelection();
                this.moveVertical(1);
                break;
              default:
                break;
            }
          },
          handleSelectedImageDeleteKey(event) {
            if (event.metaKey || event.ctrlKey || event.altKey) return false;
            if (event.key !== "Backspace" && event.key !== "Delete") return false;
            if (!this.localImagePick || !/image|picture/i.test(this.localImagePick.type || "")) return false;
            event.preventDefault();
            event.stopPropagation();
            if (this.deleteSelectedImage()) {
              if (this.imeProxy) this.imeProxy.value = "";
            }
            return true;
          },
          selectedImageTarget() {
            if (!this.localImagePick || !/image|picture/i.test(this.localImagePick.type || "")) return null;
            let ref = this.localImagePick.ref;
            if (typeof ref === "string") {
              try {
                ref = JSON.parse(ref);
              } catch (_) {
                return null;
              }
            }
            if (!ref || typeof ref !== "object") return null;
            const section = Number(ref.section ?? ref.sectionIndex ?? 0);
            const paragraph = Number(ref.paragraph ?? ref.paragraphIndex);
            const control = Number(ref.control ?? ref.controlIndex);
            if (![section, paragraph, control].every(Number.isInteger)) return null;
            return { section, paragraph, control };
          },
          deleteSelectedImage() {
            const target = this.selectedImageTarget();
            if (!target || !this.doc) return false;
            this.pushHwpUndoCheckpoint("image-delete");
            try {
              this.doc.deletePictureControl(target.section, target.paragraph, target.control);
            } catch (error) {
              console.error("[wasm-hwp] deletePictureControl failed", error);
              return false;
            }
            this.localImagePick = null;
            this.clearSelection();
            this.clearSelectionOverlays();
            this.recordOp("PictureDeleted", {
              section: target.section,
              paragraph: target.paragraph,
              control: target.control
            });
            this.finishAgentEdit({});
            return true;
          },
          handleCopy(event) {
            const text = this.selectedText ? this.selectedText() : "";
            if (!text || !event.clipboardData) return;
            event.preventDefault();
            event.clipboardData.setData("text/plain", text);
            if (this.imeProxy) this.imeProxy.value = "";
          },
          handlePaste(event) {
            if (!this.doc || !this.caret) return;
            const html = event.clipboardData && event.clipboardData.getData("text/html");
            const text = event.clipboardData && event.clipboardData.getData("text/plain");
            if (!html && !text) return;
            event.preventDefault();
            this.pushHwpUndoCheckpoint("paste");
            if (this.hasSelection()) this.deleteSelection();
            if (html && html.length <= 2e6 && this.pasteRichHtmlAtCaret(html)) return;
            this.insertPlainTextAtCaret(text);
          },
          pasteRichHtmlAtCaret(html) {
            const c = this.caret;
            if (!c || !this.doc) return false;
            try {
              let raw;
              if (c.cell && Array.isArray(c.cell.cellPath) && c.cell.cellPath.length > 1 && typeof this.doc.pasteHtmlInCellByPath === "function") {
                raw = this.doc.pasteHtmlInCellByPath(
                  c.section,
                  c.cell.parentParaIndex,
                  JSON.stringify(c.cell.cellPath),
                  c.offset,
                  html
                );
              } else if (c.cell && typeof this.doc.pasteHtmlInCell === "function") {
                raw = this.doc.pasteHtmlInCell(
                  c.section,
                  c.cell.parentParaIndex,
                  c.cell.controlIndex,
                  c.cell.cellIndex,
                  c.cell.cellParaIndex,
                  c.offset,
                  html
                );
              } else if (!c.cell && typeof this.doc.pasteHtml === "function") {
                raw = this.doc.pasteHtml(c.section, c.paragraph, c.offset, html);
              } else {
                return false;
              }
              const result = typeof raw === "string" ? JSON.parse(raw || "{}") : raw || {};
              if (result.ok === false) return false;
              if (c.cell) {
                c.cell.cellParaIndex = Number.isInteger(result.cellParaIdx) ? result.cellParaIdx : c.cell.cellParaIndex;
              } else {
                c.paragraph = Number.isInteger(result.paraIdx) ? result.paraIdx : c.paragraph;
              }
              c.offset = Number.isInteger(result.charOffset) ? result.charOffset : c.offset;
              c.preferredX = -1;
              this.recordOp("RichHtmlPasted", { section: c.section, bytes: html.length });
              this.finishAgentEdit({});
              this.refreshCursorRect();
              this.scheduleToolbarStateSync();
              return true;
            } catch (error) {
              console.warn("[wasm-hwp] rich paste failed; falling back to plain text", error);
              return false;
            }
          },
          insertPlainTextAtCaret(text) {
            const value = String(text || "").replace(/\r\n?/g, "\n");
            if (!value) return;
            const parts = value.split("\n");
            parts.forEach((part, index) => {
              if (part) this.insertAtCaret(part);
              if (index < parts.length - 1) this.splitAtCaret();
            });
          },
          deleteBackward() {
            const c = this.caret;
            if (c.offset > 0) {
              const newOffset = c.offset - 1;
              this.applyDelete(c.section, c.paragraph, newOffset, 1);
              c.offset = newOffset;
              c.preferredX = -1;
              this.refreshCursorRect();
              this.renderCaretPage();
              this.drawCaret(c);
              this.anchorProxy();
              this.scheduleSnapshot();
            } else {
              this.mergeBackward();
            }
          },
          deleteForward() {
            const c = this.caret;
            this.applyDelete(c.section, c.paragraph, c.offset, 1);
            c.preferredX = -1;
            this.refreshCursorRect();
            this.renderCaretPage();
            this.drawCaret(c);
            this.anchorProxy();
            this.scheduleSnapshot();
          },
          // Backspace at offset 0: merge this paragraph into the previous one. The
          // engine returns the merge point so the caret lands at the join.
          mergeBackward() {
            const c = this.caret;
            if (c.cell) {
              if (c.cell.cellParaIndex <= 0) return;
              try {
                const raw = this.doc.mergeParagraphInCell(
                  c.section,
                  c.cell.parentParaIndex,
                  c.cell.controlIndex,
                  c.cell.cellIndex,
                  c.cell.cellParaIndex
                );
                const r = JSON.parse(raw);
                c.cell.cellParaIndex = r.cellParaIndex;
                c.offset = r.charOffset;
                this.recordOp("ParagraphMerged", { section: c.section, para: c.cell.cellParaIndex });
              } catch (error) {
                console.error("[wasm-hwp] mergeParagraphInCell failed", error);
                return;
              }
            } else {
              if (c.paragraph <= 0) return;
              try {
                const raw = this.doc.mergeParagraph(c.section, c.paragraph);
                const r = JSON.parse(raw);
                c.paragraph = r.paraIdx;
                c.offset = r.charOffset;
                this.recordOp("ParagraphMerged", { section: c.section, para: c.paragraph });
              } catch (error) {
                console.error("[wasm-hwp] mergeParagraph failed", error);
                return;
              }
            }
            c.preferredX = -1;
            this.refreshCursorRect();
            this.renderCaretPage({ refreshVisible: true });
            this.drawCaret(c);
            this.anchorProxy();
            this.scheduleSnapshot();
          },
          splitAtCaret() {
            const c = this.caret;
            try {
              if (c.cell) {
                const raw = this.doc.splitParagraphInCell(
                  c.section,
                  c.cell.parentParaIndex,
                  c.cell.controlIndex,
                  c.cell.cellIndex,
                  c.cell.cellParaIndex,
                  c.offset
                );
                const r = JSON.parse(raw);
                c.cell.cellParaIndex = r.cellParaIndex;
                c.offset = r.charOffset;
              } else {
                const raw = this.doc.splitParagraph(c.section, c.paragraph, c.offset);
                const r = JSON.parse(raw);
                c.paragraph = r.paraIdx;
                c.offset = r.charOffset;
              }
              this.recordOp("ParagraphSplit", { section: c.section, para: c.paragraph, offset: c.offset });
            } catch (error) {
              console.error("[wasm-hwp] splitParagraph failed", error);
              return;
            }
            c.preferredX = -1;
            this.refreshCursorRect();
            this.renderCaretPage({ refreshVisible: true });
            this.drawCaret(c);
            this.anchorProxy();
            this.scheduleSnapshot();
          },
          saveShortcut(event) {
            return (event.metaKey || event.ctrlKey) && this.shortcutKey(event) === "s";
          },
          shortcutKey(event) {
            const key = String(event && event.key || "").toLowerCase();
            if (/^[a-z]$/.test(key)) return key;
            const code = String(event && event.code || "");
            const match = /^Key([A-Z])$/.exec(code);
            return match ? match[1].toLowerCase() : key;
          },
          handleHwpEditShortcut(event) {
            if (event.altKey || !(event.metaKey || event.ctrlKey)) return false;
            const key = this.shortcutKey(event);
            const undo = key === "z" && !event.shiftKey;
            const redo = key === "z" && event.shiftKey || key === "y" && event.ctrlKey && !event.metaKey;
            if (!undo && !redo) return false;
            event.preventDefault();
            event.stopPropagation();
            if (undo) this.runHwpUndo();
            else this.runHwpRedo();
            return true;
          }
        };

        // assets/js/wasm_hwp_editor.ts
        var RHWP_ASSET_VERSION = "20260713-engine-find-r20";
        var WASM_URL = `/assets/rhwp/rhwp_bg.wasm?v=${RHWP_ASSET_VERSION}`;
        var RHWP_JS_URL = `/assets/rhwp/rhwp.js?v=${RHWP_ASSET_VERSION}`;
        var HWP_IMAGE_DEFAULT_MAX_UNIT = 22e3;
        var HWP_PICK_POINT_RECT_SIZE = 48;
        var HWP_RENDER_MAX_PX = 4e6;
        var HWP_LOW_MEMORY_RENDER_MAX_PX = 2e6;
        var HWP_MIRROR_RENDER_MAX_PX = 15e5;
        var HWP_RENDERED_PAGE_SOFT_LIMIT = 10;
        var HWP_RETAINED_PAGE_MARGIN = 1;
        var HWP_HISTORY_LIMIT = 64;
        var HWP_SAVED_EDIT_MIN_TEXT_RECT_WIDTH = 8;
        var HWP_SAVED_EDIT_MIN_TEXT_RECT_HEIGHT = 8;
        var HWP_SAVED_EDIT_CJK_CHAR_WIDTH = 13.5;
        var HWP_SAVED_EDIT_LATIN_CHAR_WIDTH = 7;
        var HWP_SAVED_EDIT_SPACE_WIDTH = 6;
        var HWP_SAVED_EDIT_TEXT_HEIGHT = 17;
        var SNAPSHOT_IDLE_MS = 1500;
        var wasmReady = null;
        var HwpDocument = null;
        function ensureWasm() {
          if (!wasmReady) {
            wasmReady = import(RHWP_JS_URL).then((module) => {
              HwpDocument = module.HwpDocument;
              return module.default(WASM_URL).then(() => {
                window.__rhwpWasmReady = true;
                return true;
              });
            });
          }
          return wasmReady;
        }
        var CHAR_PROP_SPEC = {
          // Office UNO → engine
          CharWeight: ["bold", "weightThreshold"],
          FontWeight: ["bold", "fontWeight"],
          CharPosture: ["italic", "positive"],
          CharUnderline: ["underline", "positive"],
          CharColor: ["textColor", "verbatim"],
          CharHeight: ["fontSize", "fontSize"],
          // HWP PascalCase → engine
          Bold: ["bold", "bool"],
          Italic: ["italic", "bool"],
          Underline: ["underline", "bool"],
          Strikethrough: ["strikethrough", "bool"],
          TextColor: ["textColor", "verbatim"],
          FontSize: ["fontSize", "fontSize"],
          fontSize: ["fontSize", "fontSize"],
          FontFamily: ["fontFamily", "verbatim"],
          FontId: ["fontId", "int"]
        };
        var castCharProp = (type, v) => {
          switch (type) {
            case "bool":
              return !!v;
            case "weightThreshold":
              return Number(v) >= 150;
            case "fontWeight":
              return v === "bold" || Number(v) >= 600;
            case "positive":
              return Number(v) > 0;
            case "int":
              return Math.round(Number(v));
            case "verbatim":
              return v;
            // fontSize is 1/100 pt (10pt = 1000); a point-scale value (<=200) means
            // POINTS → x100, else it's already 1/100pt. Mirrors rhwp.ex font_size_hu.
            case "fontSize": {
              const n = Number(v);
              return n <= 0 ? 1e3 : n <= 200 ? Math.round(n * 100) : Math.round(n);
            }
            default:
              return v;
          }
        };
        var translateCharProps = (props) => {
          const out = {};
          for (const [k, v] of Object.entries(props)) {
            const spec = CHAR_PROP_SPEC[k];
            if (spec) out[spec[0]] = castCharProp(spec[1], v);
            else out[k] = v;
          }
          return out;
        };
        var PARA_PROP_SPEC = {
          Alignment: ["alignment", "verbatim"],
          alignment: ["alignment", "verbatim"],
          LineSpacing: ["lineSpacing", "int"],
          lineSpacing: ["lineSpacing", "int"],
          LineSpacingType: ["lineSpacingType", "verbatim"],
          HeadType: ["headType", "verbatim"],
          headType: ["headType", "verbatim"],
          ParaLevel: ["paraLevel", "int"],
          paraLevel: ["paraLevel", "int"],
          NumberingId: ["numberingId", "int"],
          numberingId: ["numberingId", "int"]
        };
        var translateParaProps = (props) => {
          const out = {};
          for (const [k, v] of Object.entries(props)) {
            const spec = PARA_PROP_SPEC[k];
            if (spec) out[spec[0]] = spec[1] === "int" ? Math.round(Number(v)) : v;
            else out[k] = v;
          }
          return out;
        };
        var PICTURE_PROP_SPEC = {
          Width: ["width", "int"],
          Height: ["height", "int"],
          PosX: ["horzOffset", "int"],
          PosY: ["vertOffset", "int"],
          TreatAsChar: ["treatAsChar", "bool"],
          Caption: ["caption", "verbatim"],
          width: ["width", "int"],
          height: ["height", "int"],
          x: ["horzOffset", "int"],
          y: ["vertOffset", "int"],
          horzOffset: ["horzOffset", "int"],
          vertOffset: ["vertOffset", "int"],
          treatAsChar: ["treatAsChar", "bool"]
        };
        var castPictureProp = (type, v) => {
          switch (type) {
            case "bool":
              return !!v;
            case "int":
              return Math.round(Number(v));
            default:
              return v;
          }
        };
        var translatePictureProps = (props) => {
          const out = {};
          for (const [k, v] of Object.entries(props)) {
            const spec = PICTURE_PROP_SPEC[k];
            if (spec) out[spec[0]] = castPictureProp(spec[1], v);
            else out[k] = v;
          }
          const moving = "PosX" in props || "PosY" in props || "x" in props || "y" in props || "horzOffset" in props || "vertOffset" in props;
          if (moving) {
            if (out.treatAsChar === void 0) out.treatAsChar = false;
            if (out.horzRelTo === void 0) out.horzRelTo = "Paper";
            if (out.vertRelTo === void 0) out.vertRelTo = "Paper";
            if (out.horzAlign === void 0) out.horzAlign = "Left";
            if (out.vertAlign === void 0) out.vertAlign = "Top";
          }
          return out;
        };
        var HWP_VIEW_STATE_KEYS = [
          "canvasState",
          "doc",
          "pageCount",
          "scale",
          "rendered",
          "renderedPageOrder",
          "pageScales",
          "renderSeq",
          "visible",
          "caret",
          "sel",
          "hwpFind",
          "localImagePick",
          "imageDrag",
          "dragSelect",
          "lamport",
          "snapshotTimer",
          "snapshotSeq",
          "undoStack",
          "redoStack",
          "caretBlinkOn",
          "pickerHover",
          "pickerHoverEvent",
          "pickerHoverRaf",
          "textCursorEvent",
          "textCursorRaf",
          "textCursorCanvas",
          "agentOpQueue",
          "agentOpProcessing",
          "pendingVfsWrites",
          "vfsPreviewObjectUrls",
          "previewPlaybackGeneration",
          "previewPlaybackFrame",
          "previewPlaybackSignature",
          "previewPatchText",
          "previewPatchCursor",
          "previewPatchAnchor",
          "previewPatchTarget",
          "previewPatchCount",
          "previewPatchHighlight",
          "previewSavedHighlights",
          "previewSavedHighlight",
          "previewPageFilter",
          "previewPatchTurnId",
          "previewHookEventCount",
          "previewAuthorityPublishCount",
          "previewAuthorityRequestCount",
          "previewAuthorityEventCount",
          "previewAuthorityReloadCount",
          "previewAuthorityDeferredCount",
          "previewAuthorityLastPayload",
          "authoritativePreviewObjectUrl",
          "scrollPersistTimer",
          "pendingScrollPosition",
          "scrollPositions",
          "shortcutActive",
          "imeProxy",
          "pageStack",
          "documentId",
          "format",
          "mirror",
          "unbindElementPicker",
          "onScroll",
          "onPreviewAuthority",
          "onResize",
          "onMouseDown",
          "onMouseMove",
          "onMouseUp",
          "onDoubleClick",
          "onToolbarCommand",
          "onFindCommand",
          "onDocumentKeyDown",
          "onDocumentPointerDown",
          "blink",
          "io",
          "_loadingUrl",
          "_loadInFlight",
          "loadedUrl",
          "toolbarStateSyncQueued",
          "_elementsCache",
          "onBeforeInput",
          "onInput",
          "onCompositionStart",
          "onCompositionUpdate",
          "onCompositionEnd",
          "onKeyDown",
          "onProxyFocus",
          "onCopy",
          "onPaste"
        ];
        function installHwpViewState(editor) {
          if (editor.view_state) return;
          Object.defineProperty(editor, "view_state", {
            value: /* @__PURE__ */ Object.create(null),
            writable: false,
            enumerable: true,
            configurable: false
          });
          for (const key of HWP_VIEW_STATE_KEYS) {
            Object.defineProperty(editor, key, {
              get() {
                return this.view_state[key];
              },
              set(value) {
                this.view_state[key] = value;
              },
              enumerable: false,
              configurable: true
            });
          }
        }
        function unexpectedHwpLooseOwnStateKeys(editor, allowedOwnKeys = []) {
          const allowedDataKeys = /* @__PURE__ */ new Set(["view_state", ...allowedOwnKeys]);
          const viewStateKeys = new Set(HWP_VIEW_STATE_KEYS);
          const unexpected = [];
          for (const [key, descriptor] of Object.entries(Object.getOwnPropertyDescriptors(editor))) {
            if (viewStateKeys.has(key)) {
              if ("value" in descriptor) unexpected.push(key);
              continue;
            }
            if (allowedDataKeys.has(key)) continue;
            if ("value" in descriptor) unexpected.push(key);
          }
          return unexpected.sort();
        }
        var WasmHwpEditor = {
          // Keyboard / IME / text-input methods (bindEditing, handleKeyDown, composition
          // input, delete/merge/split at caret, editor shortcuts) live in
          // wasm_hwp_keys.ts and are mixed in here — they run as hook methods with
          // `this` = this editor instance.
          ...keyboardSubsystem,
          readCanvasState() {
            try {
              const state = JSON.parse(this.el?.dataset?.canvasState || "{}");
              return state && typeof state === "object" ? state : {};
            } catch (_error) {
              return {};
            }
          },
          mounted() {
            installHwpViewState(this);
            this.canvasState = this.readCanvasState();
            this.doc = null;
            this._loadingUrl = null;
            this._loadInFlight = null;
            this.pageCount = 0;
            this.scale = 1;
            this.rendered = /* @__PURE__ */ new Map();
            this.renderedPageOrder = /* @__PURE__ */ new Map();
            this.pageScales = /* @__PURE__ */ new Map();
            this.renderSeq = 0;
            this.visible = /* @__PURE__ */ new Set();
            this.caret = null;
            this.sel = null;
            this.hwpFind = null;
            this.localImagePick = null;
            this.imageDrag = null;
            this.dragSelect = null;
            this.lamport = 0;
            this.snapshotTimer = null;
            this.snapshotSeq = 0;
            this.undoStack = [];
            this.redoStack = [];
            this.caretBlinkOn = true;
            this.pickerHover = null;
            this.pickerHoverEvent = null;
            this.pickerHoverRaf = null;
            this.agentOpQueue = [];
            this.agentOpProcessing = false;
            this.pendingVfsWrites = new Map();
            this.vfsPreviewObjectUrls = new Map();
            this.previewPlaybackGeneration = 0;
            this.previewPlaybackFrame = null;
            this.previewPlaybackSignature = null;
            this.previewPatchText = "";
            this.previewPatchCursor = null;
            this.previewPatchAnchor = null;
            this.previewPatchTarget = "";
            this.previewPatchCount = 0;
            this.previewPatchHighlight = null;
            this.previewSavedHighlights = [];
            this.previewSavedHighlight = null;
            this.previewPageFilter = null;
            this.previewPatchTurnId = null;
            this.previewHookEventCount = 0;
            this.previewAuthorityPublishCount = 0;
            this.previewAuthorityRequestCount = 0;
            this.previewAuthorityEventCount = 0;
            this.previewAuthorityReloadCount = 0;
            this.previewAuthorityDeferredCount = 0;
            this.previewAuthorityLastPayload = null;
            this.authoritativePreviewObjectUrl = null;
            this.scrollPersistTimer = null;
            this.pendingScrollPosition = null;
            this.scrollPositions = /* @__PURE__ */ new Map();
            this.shortcutActive = false;
            this.imeProxy = this.el.querySelector(SEL.hwpImeProxy);
            this.pageStack = this.el.querySelector(SEL.hwpPages);
            this.documentId = this.canvasState.documentId || this.canvasState.localDocumentId;
            this.format = this.canvasState.localDocumentFormat || "hwp";
            this.mirror = this.canvasState.editorMirror === true;
            this.unbindElementPicker = null;
            if (!this.mirror) this.el.__wasmHwpEditor = this;
            this.onScroll = () => this.rememberScrollPosition();
            this.el.addEventListener("scroll", this.onScroll, { passive: true });
            ensureWasm().catch((error) => console.error("[wasm-hwp] init failed", error));
            this.handleEvent("document.hwp.load_command", (payload) => {
              if (this.eventMatchesDocument(payload)) this.loadDocument(payload);
            });
            this.handleEvent("document.engine.operation.command", (payload) => {
              if (!this.mirror && this.eventMatchesDocument(payload)) this.handleAgentOp(payload);
            });
            this.handleEvent("document.save.command", (payload) => {
              if (!this.mirror && this.eventMatchesDocument(payload)) this.saveLocalDocument(payload);
            });
            this.handleEvent("document.preview.delta_received", (payload) => {
              this.previewHookEventCount += 1;
              this.el.dataset.previewHookEventCount = String(this.previewHookEventCount);
              if (this.eventMatchesDocument(payload)) {
                if (this.mirror) {
                  this.el.dataset.previewAuthorityState = "waiting";
                  window.setTimeout(() => this.requestAuthoritativePreview(payload), 0);
                } else {
                  this.recordPreviewTarget(payload);
                  this.publishAuthoritativePreview(payload);
                }
              }
            });
            this.onPreviewAuthority = (event) => {
              const payload = event && event.detail ? event.detail : {};
              if (payload.source_editor_id === this.el.id) return;
              if (this.mirror && this.eventMatchesDocument(payload)) this.applyAuthoritativePreviewState(payload);
            };
            window.addEventListener(PREVIEW_AUTHORITY_EVENT, this.onPreviewAuthority);
            const bytesUrl = this.canvasState.bytesUrl;
            if (bytesUrl) this.loadDocument({ url: bytesUrl, document_id: this.documentId });
            this.onResize = () => {
              if (this.onResize.frame != null) return;
              const schedule = typeof window.requestAnimationFrame === "function" ? window.requestAnimationFrame.bind(window) : (callback) => window.setTimeout(callback, 16);
              this.onResize.cancel = typeof window.cancelAnimationFrame === "function" ? window.cancelAnimationFrame.bind(window) : window.clearTimeout.bind(window);
              this.onResize.frame = schedule(() => {
                this.onResize.frame = null;
                const rects = this.previewSavedHighlight && this.previewSavedHighlight.rects;
                if (this.mirror && Array.isArray(rects) && rects.length > 0) {
                  this.frameSavedEditHighlights(rects);
                }
              });
              if (this.onResize.renderTimer != null) window.clearTimeout(this.onResize.renderTimer);
              this.onResize.renderTimer = window.setTimeout(() => {
                this.onResize.renderTimer = null;
                this.renderVisiblePages();
              }, 120);
            };
            window.addEventListener("resize", this.onResize);
            if (typeof ResizeObserver === "function") {
              this.onResize.observer = new ResizeObserver(this.onResize);
              this.onResize.observer.observe(this.el);
            }
            this.onMouseDown = (event) => this.onCanvasMouseDown(event);
            this.onMouseMove = (event) => this.onCanvasMouseMove(event);
            this.onMouseUp = (event) => this.onCanvasMouseUp(event);
            this.onDoubleClick = (event) => this.onCanvasDoubleClick(event);
            this.onToolbarCommand = (event) => this.handleToolbarCommand(event.detail || {});
            this.onFindCommand = (event) => this.handleFindCommand(event.detail || {});
            this.onDocumentKeyDown = (event) => this.handleDocumentKeyDown(event);
            this.onDocumentPointerDown = (event) => this.handleDocumentPointerDown(event);
            this.el.addEventListener("mousedown", this.onMouseDown);
            this.el.addEventListener("dblclick", this.onDoubleClick);
            document.addEventListener("keydown", this.onDocumentKeyDown, true);
            document.addEventListener("mousedown", this.onDocumentPointerDown, true);
            document.addEventListener("mousemove", this.onMouseMove);
            document.addEventListener("mouseup", this.onMouseUp);
            document.addEventListener(EDITOR_COMMAND_EVENT, this.onToolbarCommand);
            document.addEventListener(DOCUMENT_SEARCH_COMMAND_EVENT, this.onFindCommand);
            this.bindEditing();
            this.blink = setInterval(() => {
              this.caretBlinkOn = !this.caretBlinkOn;
              if (this.caret) this.drawCaret(this.caret);
            }, 530);
            this.io = new IntersectionObserver(
              (entries) => {
                for (const e of entries) {
                  const idx = Number(e.target.dataset.pageIndex);
                  if (e.isIntersecting) {
                    this.visible.add(idx);
                    this.renderPage(idx);
                  } else {
                    this.visible.delete(idx);
                    this.releasePageCanvas(idx);
                    this.enforcePageMemoryBudget();
                  }
                }
              },
              { root: this.el, rootMargin: "1200px 0px", threshold: 0 }
            );
            if (!this.mirror) this.unbindElementPicker = bindElementPickerTarget(this);
          },
          destroyed() {
            this.rememberScrollPosition();
            this.flushScrollPosition();
            if (this.io) this.io.disconnect();
            if (this.blink) clearInterval(this.blink);
            if (this.snapshotTimer) {
              clearTimeout(this.snapshotTimer);
              this.snapshotTimer = null;
              try {
                this.pushSnapshot();
              } catch (_) {
              }
            }
            if (this.pickerHoverRaf) cancelAnimationFrame(this.pickerHoverRaf);
            if (this.textCursorRaf) cancelAnimationFrame(this.textCursorRaf);
            this.setTextCursorCanvas(null);
            if (this.authoritativePreviewObjectUrl) {
              try {
                URL.revokeObjectURL(this.authoritativePreviewObjectUrl);
              } catch (_) {
              }
              this.authoritativePreviewObjectUrl = null;
            }
            this.previewPlaybackGeneration += 1;
            if (this.previewPlaybackFrame && typeof window.cancelAnimationFrame === "function") {
              window.cancelAnimationFrame(this.previewPlaybackFrame);
            }
            this.previewPlaybackFrame = null;
            for (const entry of this.vfsPreviewObjectUrls.values()) {
              if (entry.timer) clearTimeout(entry.timer);
              try {
                URL.revokeObjectURL(entry.url);
              } catch (_) {
              }
            }
            this.vfsPreviewObjectUrls.clear();
            window.removeEventListener("resize", this.onResize);
            if (this.onResize && this.onResize.observer) this.onResize.observer.disconnect();
            if (this.onResize && this.onResize.frame != null && this.onResize.cancel) {
              this.onResize.cancel(this.onResize.frame);
              this.onResize.frame = null;
            }
            if (this.onResize && this.onResize.renderTimer != null) {
              window.clearTimeout(this.onResize.renderTimer);
              this.onResize.renderTimer = null;
            }
            window.removeEventListener(PREVIEW_AUTHORITY_EVENT, this.onPreviewAuthority);
            this.el.removeEventListener("scroll", this.onScroll);
            this.el.removeEventListener("mousedown", this.onMouseDown);
            this.el.removeEventListener("dblclick", this.onDoubleClick);
            document.removeEventListener("keydown", this.onDocumentKeyDown, true);
            document.removeEventListener("mousedown", this.onDocumentPointerDown, true);
            document.removeEventListener("mousemove", this.onMouseMove);
            document.removeEventListener("mouseup", this.onMouseUp);
            document.removeEventListener(EDITOR_COMMAND_EVENT, this.onToolbarCommand);
            document.removeEventListener(DOCUMENT_SEARCH_COMMAND_EVENT, this.onFindCommand);
            if (this.unbindElementPicker) this.unbindElementPicker();
            this.unbindEditing();
            if (this.el.__wasmHwpEditor === this) delete this.el.__wasmHwpEditor;
            this.releaseAllPageCanvases();
            if (this.doc) {
              this.clearHwpHistory();
              try {
                this.doc.free();
              } catch (_) {
              }
              this.doc = null;
            }
          },
          updated() {
            this.canvasState = this.readCanvasState();
            if (this.mirror) {
              const playbackSteps = this.previewPlaybackSteps();
              if (playbackSteps.length > 0) {
                if (this.doc) this.startVfsPreviewPlayback(playbackSteps);
                return;
              }
              const payload = {
                document_id: this.documentId,
                turn_id: this.canvasState.previewTurnId,
                text: this.canvasState.previewText || "",
                delta_count: Number(this.canvasState.previewDeltaCount || 0)
              };
              if (this.handleLoadedPreviewHighlights(false, payload)) return;
              this.el.dataset.previewAuthorityState = "waiting";
              this.requestAuthoritativePreview(payload);
              return;
            }
            this.scheduleToolbarStateSync();
          },
          scrollPositionKey(url = null) {
            return [
              this.documentId,
              this.canvasState?.documentPath,
              url,
              this.loadedUrl,
              this.canvasState?.bytesUrl
            ].find((value) => typeof value === "string" && value.length > 0) || null;
          },
          rememberScrollPosition(url = null) {
            if (this.mirror || !this.el) return;
            const key = this.scrollPositionKey(url);
            if (!key) return;
            const position = {
              top: Math.max(0, Math.round(this.el.scrollTop || 0)),
              left: Math.max(0, Math.round(this.el.scrollLeft || 0))
            };
            this.scrollPositions.set(key, position);
            if (this.scrollPositions.size > 100) {
              const oldest = this.scrollPositions.keys().next().value;
              if (oldest) this.scrollPositions.delete(oldest);
            }
            this.queueScrollPositionPersist(position);
          },
          restoreScrollPosition(url = null) {
            if (this.mirror || !this.el) return;
            const key = this.scrollPositionKey(url);
            const position = key && this.scrollPositions.get(key) || this.serverScrollPosition();
            if (!position) return;
            const raf = window.requestAnimationFrame || ((fn) => setTimeout(fn, 16));
            raf(() => {
              raf(() => {
                if (!this.el || this.el.isConnected === false) return;
                this.el.scrollTop = position.top;
                this.el.scrollLeft = position.left;
                this.renderVisiblePages();
              });
            });
          },
          serverScrollPosition() {
            if (!this.el) return null;
            const top = Number(this.canvasState.scrollTop);
            const left = Number(this.canvasState.scrollLeft);
            const hasTop = Number.isFinite(top) && top >= 0;
            const hasLeft = Number.isFinite(left) && left >= 0;
            if (!hasTop && !hasLeft) return null;
            return {
              top: hasTop ? Math.round(top) : 0,
              left: hasLeft ? Math.round(left) : 0
            };
          },
          queueScrollPositionPersist(position) {
            if (this.mirror || !this.el || typeof this.pushEvent !== "function") return;
            if (!this.canvasState.documentPath) return;
            this.pendingScrollPosition = position;
            if (this.scrollPersistTimer) clearTimeout(this.scrollPersistTimer);
            this.scrollPersistTimer = setTimeout(() => this.flushScrollPosition(), 150);
          },
          flushScrollPosition() {
            if (this.scrollPersistTimer) {
              clearTimeout(this.scrollPersistTimer);
              this.scrollPersistTimer = null;
            }
            const position = this.pendingScrollPosition;
            this.pendingScrollPosition = null;
            if (this.mirror || !this.el || !position || typeof this.pushEvent !== "function") return;
            const documentPath = this.canvasState.documentPath;
            if (!documentPath) return;
            this.pushEvent("document.viewport.changed", {
              document_path: documentPath,
              document_id: this.documentId,
              top: position.top,
              left: position.left
            });
          },
          handleLoadedPreviewHighlights(authorityPreviewLoad = false, payload = {}) {
            this.previewSavedHighlights = this.parsePreviewHighlights();
            if (this.previewSavedHighlights.length === 0) return false;
            if (this.mirror && !authorityPreviewLoad) {
              this.el.dataset.previewAuthorityState = "waiting";
              const requested = this.requestAuthoritativePreview({
                ...payload,
                authority_bytes: true,
                preview_highlights: this.previewSavedHighlights
              });
              if (!requested) this.renderSavedEditHighlights();
            } else {
              this.renderSavedEditHighlights();
            }
            return true;
          },
          eventMatchesDocument(payload = {}) {
            const id = payload.document_id || payload.documentId;
            if (this.mirror) return !!id && !!this.documentId && String(id) === String(this.documentId);
            return !id || !this.documentId || String(id) === String(this.documentId);
          },
          handlePreviewDelta(payload = {}) {
            this.ensurePreviewPatchTurn(payload);
            const delta = payload.delta == null ? "" : String(payload.delta);
            const current = this.previewPatchText || this.canvasState.previewText || "";
            const target = typeof payload.text === "string" ? payload.text : current + delta;
            this.patchPreviewToMountedDoc(target, payload);
          },
          recordPreviewTarget(payload = {}) {
            this.ensurePreviewPatchTurn(payload);
            const delta = payload.delta == null ? "" : String(payload.delta);
            const current = this.previewPatchTarget || this.canvasState.previewText || "";
            const target = typeof payload.text === "string" ? payload.text : current + delta;
            this.previewPatchTarget = target;
            this.canvasState.previewText = target;
            const count = Number(payload.delta_count || payload.preview_patch_count || this.previewPatchCount || 0);
            if (Number.isFinite(count) && count > 0) {
              this.previewPatchCount = count;
              this.canvasState.previewDeltaCount = String(count);
              this.el.dataset.previewPatchCount = String(count);
            }
            this.el.dataset.previewPatchMode = "authority-only";
            this.el.dataset.previewPatchPending = "false";
          },
          requestAuthoritativePreview(payload = {}) {
            if (!this.mirror) return;
            this.previewAuthorityRequestCount += 1;
            this.el.dataset.previewAuthorityRequestCount = String(this.previewAuthorityRequestCount);
            let targetCount = 0;
            let targetHookCount = 0;
            const targetIds = [];
            for (const target of document.querySelectorAll(SEL.hwpEditor)) {
              let targetState = {};
              try {
                targetState = JSON.parse(target.dataset.canvasState || "{}");
              } catch (_error) {
              }
              const id = targetState.documentId || targetState.localDocumentId;
              if (targetState.editorMirror !== true && id === this.documentId) {
                targetCount += 1;
                targetIds.push(target.id);
                if (target.__wasmHwpEditor && typeof target.__wasmHwpEditor.publishAuthoritativePreview === "function") {
                  targetHookCount += 1;
                  target.__wasmHwpEditor.publishAuthoritativePreview(payload);
                }
              }
            }
            this.el.dataset.previewAuthorityTargetCount = String(targetCount);
            this.el.dataset.previewAuthorityTargetHookCount = String(targetHookCount);
            this.el.dataset.previewAuthorityTargetIds = targetIds.join(",");
            if (targetHookCount === 0) this.el.dataset.previewAuthorityState = targetCount === 0 ? "missing" : "waiting";
            return targetHookCount > 0;
          },
          applyAuthoritativePreviewState(payload = {}) {
            if (!this.mirror) return;
            this.previewAuthorityEventCount += 1;
            this.el.dataset.previewAuthorityEventCount = String(this.previewAuthorityEventCount);
            this.el.dataset.previewAuthorityState = "received";
            this.el.dataset.previewAuthoritySourceId = payload.source_editor_id || "";
            if (typeof payload.bytes_url === "string" && payload.bytes_url) {
              this.el.dataset.previewAuthorityBytesUrl = payload.bytes_url;
              if (payload.delta_count != null) this.canvasState.previewDeltaCount = String(payload.delta_count);
              this.el.dataset.previewAuthorityState = "loading-bytes";
              this.loadDocument({
                url: payload.bytes_url,
                document_id: this.documentId,
                force: true,
                authority_preview: true
              }).then(() => {
                this.renderSavedEditHighlights();
                this.el.dataset.previewAuthorityState = "applied";
              }).catch((error) => {
                this.el.dataset.previewAuthorityState = "error";
                this.el.dataset.previewAuthorityError = String(error && error.message || error);
              });
              return;
            }
            const text = typeof payload.model_text === "string" ? payload.model_text : typeof payload.text === "string" ? payload.text : "";
            this.handlePreviewDelta({
              ...payload,
              authoritative: true,
              text,
              delta_count: payload.delta_count || payload.preview_patch_count
            });
            this.el.dataset.previewAuthorityState = "applied";
          },
          publishAuthoritativePreview(payload = {}) {
            if (this.mirror) return;
            this.previewAuthorityLastPayload = payload;
            const detail = this.buildAuthoritativePreviewState(payload);
            if (!detail) return;
            this.previewAuthorityPublishCount += 1;
            this.el.dataset.previewAuthorityPublishCount = String(this.previewAuthorityPublishCount);
            window.dispatchEvent(new CustomEvent(PREVIEW_AUTHORITY_EVENT, { detail }));
          },
          buildAuthoritativePreviewState(payload = {}) {
            if (!this.doc) return null;
            const modelText = this.readPreviewModelText();
            const text = typeof payload.text === "string" ? payload.text : this.previewPatchTarget || this.previewPatchText || modelText || "";
            const count = Number(payload.delta_count || payload.preview_patch_count || this.previewPatchCount || 0);
            const bytesUrl = payload.authority_bytes === true ? this.authoritativePreviewBytesUrl() : null;
            return {
              ...payload,
              authoritative: true,
              document_id: this.documentId,
              turn_id: payload.turn_id || payload.turnId || this.previewPatchTurnId,
              text,
              model_text: modelText,
              target_text: text,
              delta_count: Number.isFinite(count) ? count : 0,
              preview_patch_count: Number.isFinite(count) ? count : 0,
              model_matches: this.el.dataset.previewModelMatches === "true",
              source_editor_id: this.el.id,
              source_editor_mirror: false,
              ...bytesUrl ? { bytes_url: bytesUrl } : {},
              anchor: this.previewPatchAnchor,
              cursor: this.previewPatchCursor
            };
          },
          authoritativePreviewBytesUrl() {
            if (!this.doc) return null;
            try {
              const bytes = this.exportDocumentBytes();
              if (this.authoritativePreviewObjectUrl) {
                try {
                  URL.revokeObjectURL(this.authoritativePreviewObjectUrl);
                } catch (_) {
                }
              }
              const blob = new Blob([bytes], {
                type: this.format === "hwpx" ? "application/vnd.hancom.hwpx" : "application/x-hwp"
              });
              this.authoritativePreviewObjectUrl = URL.createObjectURL(blob);
              return this.authoritativePreviewObjectUrl;
            } catch (error) {
              console.error("[wasm-hwp] authoritative preview export failed", error);
              return null;
            }
          },
          ensurePreviewPatchTurn(payload = {}) {
            const turnId = payload.turn_id || payload.turnId || null;
            if (!turnId || this.previewPatchTurnId === turnId) return;
            if (!this.previewPatchTurnId) {
              this.previewPatchTurnId = turnId;
              return;
            }
            this.resetPreviewPatchState(turnId);
          },
          resetPreviewPatchState(turnId = null) {
            this.previewPatchText = "";
            this.previewPatchCursor = null;
            this.previewPatchAnchor = null;
            this.previewPatchTarget = "";
            this.previewPatchCount = 0;
            this.previewPatchHighlight = null;
            this.previewPatchTurnId = turnId;
            this.canvasState.previewText = "";
            this.canvasState.previewDeltaCount = "0";
            this.el.dataset.previewPatchPending = "false";
            this.el.dataset.previewPatchMismatch = "false";
            this.el.dataset.previewPatchMode = "";
            this.el.dataset.previewPatchCount = "0";
            this.el.dataset.previewModelLength = "0";
            this.el.dataset.previewModelTail = "";
            this.el.dataset.previewModelMatches = "false";
            this.el.dataset.previewHighlightMode = "";
            this.el.dataset.previewHighlightCount = "0";
            this.el.dataset.previewHighlightPages = "";
            this.el.dataset.previewHighlightError = "";
          },
          patchPreviewToMountedDoc(target, payload = {}) {
            const text = typeof target === "string" ? target : "";
            this.previewPatchTarget = text;
            this.canvasState.previewText = text;
            if (payload.delta_count != null) this.canvasState.previewDeltaCount = String(payload.delta_count);
            if (!this.doc) {
              this.el.dataset.previewPatchPending = "true";
              return;
            }
            if (!this.mirror) {
              this.recordPreviewTarget({ ...payload, text });
              this.publishAuthoritativePreview({ ...payload, text });
              return;
            }
            this.el.dataset.previewPatchPending = "false";
            if (!text.startsWith(this.previewPatchText)) {
              this.el.dataset.previewPatchMismatch = "true";
              if (payload.authoritative && this.mirror) this.reloadPreviewMirrorFromAuthority(text, payload);
              return;
            }
            const suffix = text.slice(this.previewPatchText.length);
            if (suffix) {
              this.patchPreviewSuffixIntoDoc(suffix);
              this.previewPatchText = text;
            }
            const count = Number(payload.delta_count || this.canvasState.previewDeltaCount || this.previewPatchCount || 0);
            if (Number.isFinite(count) && count > 0) this.previewPatchCount = count;
            this.el.dataset.previewPatchMode = "direct-doc";
            this.el.dataset.previewPatchCount = String(this.previewPatchCount);
            this.updatePreviewPatchInspection();
            this.renderPreviewPatchHighlight();
            if (!this.mirror) this.publishAuthoritativePreview(payload);
            this.el.dispatchEvent(new CustomEvent(PREVIEW_DELTA_EVENT, {
              bubbles: true,
              detail: {
                document_id: this.documentId,
                turn_id: payload.turn_id,
                patch_mode: "direct-doc",
                delta_count: this.previewPatchCount,
                model_matches: this.el.dataset.previewModelMatches === "true"
              }
            }));
          },
          patchPreviewSuffixIntoDoc(text) {
            if (!this.mirror) return;
            const cursor = this.ensurePreviewPatchCursor();
            if (!cursor) return;
            for (const [index, line] of String(text).split("\n").entries()) {
              if (index > 0) {
                this.doc.splitParagraph(cursor.section, cursor.paragraph, cursor.offset);
                cursor.paragraph += 1;
                cursor.offset = 0;
              }
              if (line) {
                this.doc.insertText(cursor.section, cursor.paragraph, cursor.offset, line);
                cursor.offset += line.length;
              }
            }
            this._elementsCache = null;
            this.rendered.clear();
            this.renderVisiblePages();
            this.renderPreviewPatchHighlight();
          },
          reloadPreviewMirrorFromAuthority(text, payload = {}) {
            if (!this.mirror) return;
            const url = this.loadedUrl || this.canvasState.bytesUrl;
            if (!url) return;
            this.previewAuthorityReloadCount += 1;
            this.el.dataset.previewAuthorityReloadCount = String(this.previewAuthorityReloadCount);
            this.el.dataset.previewAuthorityState = "reloading";
            const turnId = payload.turn_id || payload.turnId || this.previewPatchTurnId;
            this.resetPreviewPatchState(turnId);
            this.previewPatchTarget = text;
            this.canvasState.previewText = text;
            if (payload.delta_count != null) this.canvasState.previewDeltaCount = String(payload.delta_count);
            this.el.dataset.previewPatchPending = "true";
            this.loadDocument({ url, document_id: this.documentId, force: true });
          },
          scrollPreviewPatchIntoView() {
            const cursor = this.previewPatchCursor;
            if (!cursor || !this.doc) return;
            this.caret = { section: cursor.section, paragraph: cursor.paragraph, offset: cursor.offset, cell: null };
            this.refreshCursorRect();
            const pageIndex = this.caret && this.caret.cursorRect && this.caret.cursorRect.pageIndex;
            if (!Number.isInteger(pageIndex)) return;
            const section = this.pageSection(pageIndex);
            if (!section) return;
            this.el.scrollTop = Math.max(0, section.offsetTop - 12);
            this.renderPage(pageIndex);
            this.drawCaret(this.caret);
            this.anchorProxy();
          },
          ensurePreviewPatchCursor() {
            if (this.previewPatchCursor) return this.previewPatchCursor;
            let ref = { section: 0, paragraph: 0, offset: 0 };
            try {
              const bodyParagraphs = this.collectElements().filter((el) => {
                const r = el && el.ref;
                return el.type === "paragraph" && r && Number.isInteger(r.section) && Number.isInteger(r.paragraph) && !r.cell && !r.note;
              });
              const body = bodyParagraphs.find((el) => String(el.text || "").trim() !== "") || bodyParagraphs[0];
              if (body && body.ref) ref = { section: body.ref.section, paragraph: body.ref.paragraph, offset: 0 };
            } catch (_) {
            }
            this.previewPatchAnchor = { ...ref };
            this.previewPatchCursor = { ...ref };
            return this.previewPatchCursor;
          },
          updatePreviewPatchInspection() {
            const modelText = this.readPreviewModelText();
            this.el.dataset.previewModelLength = String(modelText.length);
            this.el.dataset.previewModelTail = modelText.slice(-80);
            this.el.dataset.previewModelMatches = String(modelText === this.previewPatchText);
          },
          readPreviewModelText() {
            const anchor = this.previewPatchAnchor;
            if (!anchor || !this.doc) return "";
            let modelText = "";
            try {
              modelText = this.doc.getTextRange(
                anchor.section,
                anchor.paragraph,
                anchor.offset,
                this.previewPatchText.length
              ) || "";
            } catch (_) {
              modelText = "";
            }
            return modelText;
          },
          renderPreviewPatchHighlight() {
            if (!this.mirror || !this.doc) return;
            const anchor = this.previewPatchAnchor;
            const cursor = this.previewPatchCursor;
            if (!anchor || !cursor) return;
            if (anchor.section !== cursor.section || anchor.paragraph === cursor.paragraph && anchor.offset === cursor.offset) {
              this.previewPatchHighlight = null;
              this.el.dataset.previewHighlightMode = "";
              this.el.dataset.previewHighlightCount = "0";
              this.el.dataset.previewHighlightPages = "";
              return;
            }
            let raw;
            try {
              raw = this.doc.getSelectionRects(
                anchor.section,
                anchor.paragraph,
                anchor.offset,
                cursor.paragraph,
                cursor.offset
              );
            } catch (error) {
              this.previewPatchHighlight = null;
              this.el.dataset.previewHighlightMode = "agent-edit-range";
              this.el.dataset.previewHighlightCount = "0";
              this.el.dataset.previewHighlightPages = "";
              this.el.dataset.previewHighlightError = String(error && error.message ? error.message : error);
              return;
            }
            let rects = [];
            try {
              const parsed = raw ? JSON.parse(raw) : [];
              rects = Array.isArray(parsed) ? parsed : [];
            } catch (_) {
              rects = [];
            }
            this.previewPatchHighlight = {
              section: anchor.section,
              start: { paragraph: anchor.paragraph, offset: anchor.offset },
              end: { paragraph: cursor.paragraph, offset: cursor.offset },
              rects
            };
            const pages = [...new Set(rects.map((r) => r.pageIndex).filter(Number.isInteger))];
            this.el.dataset.previewHighlightMode = "agent-edit-range";
            this.el.dataset.previewHighlightCount = String(rects.length);
            this.el.dataset.previewHighlightPages = pages.join(",");
            this.el.dataset.previewHighlightError = "";
            for (const page of pages) this.paintPreviewPatchHighlightOnPage(page);
          },
          paintPreviewPatchHighlightOnPage(pageIndex) {
            const highlight = this.previewPatchHighlight;
            if (!highlight || !Array.isArray(highlight.rects) || highlight.rects.length === 0) return;
            const overlay = this.pageOverlay(pageIndex);
            if (!overlay) return;
            const ctx = overlay.getContext("2d");
            if (!ctx) return;
            const s = this.pageScale(pageIndex);
            for (const r of highlight.rects) {
              if (r.pageIndex !== pageIndex) continue;
              this.paintEditHighlightRect(ctx, overlay, r, s);
            }
          },
          previewPlaybackSteps() {
            const raw = this.canvasState && this.canvasState.previewSteps;
            if (!raw) return [];
            try {
              const parsed = typeof raw === "string" ? JSON.parse(raw) : raw;
              return Array.isArray(parsed) ? parsed : [];
            } catch (_) {
              return [];
            }
          },
          startVfsPreviewPlayback(steps = this.previewPlaybackSteps()) {
            if (!this.mirror || !this.doc || !Array.isArray(steps) || steps.length === 0) return;
            const signature = `${this.canvasState.previewTurnId || ""}:${steps.length}:${JSON.stringify(steps[steps.length - 1] || {}).length}`;
            if (this.previewPlaybackSignature === signature) return;
            this.previewPlaybackSignature = signature;
            this.previewPlaybackGeneration += 1;
            const generation = this.previewPlaybackGeneration;
            let index = 0;
            this.el.dataset.previewPlaybackState = "running";
            this.el.dataset.previewPlaybackTotal = String(steps.length);
            const schedule = (callback) => {
              if (typeof window.requestAnimationFrame === "function" && document.visibilityState !== "hidden") {
                this.previewPlaybackFrame = window.requestAnimationFrame(callback);
              } else {
                this.previewPlaybackFrame = setTimeout(callback, 16);
              }
            };
            const advance = () => {
              if (generation !== this.previewPlaybackGeneration || !this.doc) return;
              const step = steps[index];
              const result = this.applyVfsPreviewStep(step, index + 1, steps.length);
              if (result.error) {
                this.el.dataset.previewPlaybackState = "error";
                this.el.dataset.previewPlaybackError = result.error;
                return;
              }
              index += 1;
              if (index >= steps.length) {
                this.previewPlaybackFrame = null;
                this.el.dataset.previewPlaybackState = "complete";
                return;
              }
              schedule(advance);
            };
            schedule(advance);
          },
          applyVfsPreviewStep(step = {}, index, total) {
            const ops = Array.isArray(step.ops) ? step.ops : [];
            const sets = Array.isArray(step.sets) ? step.sets : [];
            const appliedOps = [];
            for (const op of ops) {
              let result;
              try {
                result = this.applyOneOp(op);
              } catch (error) {
                return { error: String(error && error.message || error) };
              }
              if (!result || result.error) return { error: result && result.error || "preview edit failed" };
              appliedOps.push({ op, result });
            }
            for (const entry of sets) {
              let result;
              try {
                result = this.applySetOne(entry && entry.ref, entry && entry.props);
              } catch (error) {
                return { error: String(error && error.message || error) };
              }
              if (!result || result.error) return { error: result && result.error || "preview set failed" };
            }
            this._elementsCache = null;
            const materialized = this.materializeVfsPreviewModel(appliedOps);
            if (materialized.error) return materialized;
            const nextPageCount = this.doc.pageCount();
            if (materialized.ok || nextPageCount !== this.pageCount) {
              this.pageCount = nextPageCount;
              this.buildPageStack();
            } else {
              this.rendered.clear();
              this.renderVisiblePages();
            }
            const highlights = this.remapVfsPreviewHighlights(step.highlights, appliedOps);
            this.canvasState.previewHighlights = JSON.stringify(highlights);
            this.canvasState.previewDeltaCount = String(index);
            this.el.dataset.previewPlaybackIndex = String(index);
            const card = this.el.closest('[data-role="editor-preview-card"]');
            const counter = card && card.querySelector('[data-role="editor-preview-delta-count"]');
            if (counter) counter.textContent = String(index);
            const summary = card && card.querySelector('[data-role="editor-preview-summary"]');
            if (summary) {
              const doc = this.canvasState.documentName || this.canvasState.documentPath || "document";
              const verb = ops[0] && ops[0].op || sets[0] && "set" || "edit";
              summary.textContent = `${doc}: ${index} ${index === 1 ? "token" : "tokens"} · ${index}/${total} — ${verb}`;
            }
            if (card) card.dataset.previewPlaybackState = index >= total ? "complete" : "running";
            this.renderSavedEditHighlights();
            this.refreshSavedEditHighlightsOnNextFrame(index);
            this.el.dispatchEvent(new CustomEvent(PREVIEW_DELTA_EVENT, {
              bubbles: true,
              detail: {
                document_id: this.documentId,
                turn_id: this.canvasState.previewTurnId,
                delta_count: index,
                delta_total: total,
                patch_mode: "vfs-op-playback"
              }
            }));
            return { ok: true };
          },
          materializeVfsPreviewModel(appliedOps) {
            const needsMaterialization = (Array.isArray(appliedOps) ? appliedOps : []).some(({ op }) => op && op.op === "insert_picture");
            if (!needsMaterialization) return { ok: false };
            let replacement = null;
            try {
              const bytes = this.exportDocumentBytes();
              replacement = new HwpDocument(bytes);
              try {
                replacement.convertToEditable();
              } catch (_) {
              }
              const previous = this.doc;
              this.releaseAllPageCanvases();
              this.doc = replacement;
              replacement = null;
              try {
                previous.free();
              } catch (_) {
              }
              this.clearHwpHistory();
              this.hwpFind = null;
              this._elementsCache = null;
              return { ok: true };
            } catch (error) {
              if (replacement) {
                try {
                  replacement.free();
                } catch (_) {
                }
              }
              return { error: `preview picture materialization failed: ${String(error && error.message || error)}` };
            }
          },
          remapVfsPreviewHighlights(highlights, appliedOps) {
            const source = Array.isArray(highlights) ? highlights : [];
            const pictureResults = (Array.isArray(appliedOps) ? appliedOps : []).filter(({ op, result }) => op && op.op === "insert_picture" && result && result.extra);
            let pictureIndex = 0;
            return source.map((highlight) => {
              if (!highlight || highlight.op !== "insert_picture") return highlight;
              const applied = pictureResults[pictureIndex++];
              if (!applied) return highlight;
              const extra = applied.result.extra || {};
              if (!Number.isInteger(extra.paraIdx) || !Number.isInteger(extra.controlIdx)) return highlight;
              let ref = highlight.ref;
              if (typeof ref === "string") {
                try {
                  ref = JSON.parse(ref);
                } catch (_) {
                  ref = {};
                }
              }
              ref = ref && typeof ref === "object" ? { ...ref } : {};
              const opRef = this.parseRef(applied.op.ref) || {};
              ref.section = Number(opRef.section ?? ref.section ?? 0);
              ref.paragraph = extra.paraIdx;
              ref.control = extra.controlIdx;
              ref.type = ref.type || "picture";
              return { ...highlight, ref };
            });
          },
          refreshSavedEditHighlightsOnNextFrame(index) {
            requestAnimationFrame(() => {
              if (!this.el || !this.el.isConnected) return;
              if (this.el.dataset.previewPlaybackIndex !== String(index)) return;
              this.renderVisiblePages();
              this.renderSavedEditHighlights();
            });
          },
          parsePreviewHighlights() {
            const raw = this.el && this.el.dataset ? this.canvasState.previewHighlights : "";
            if (!raw) return [];
            try {
              const parsed = JSON.parse(raw);
              return Array.isArray(parsed) ? parsed : [];
            } catch (_) {
              return [];
            }
          },
          savedEditHighlightRects() {
            const highlights = this.parsePreviewHighlights();
            this.previewSavedHighlights = highlights;
            let rects = [];
            const errors = [];
            for (const [index, highlight] of highlights.entries()) {
              try {
                const hasCell = !!(this.parseRef(highlight && (highlight.ref || highlight.op && highlight.op.ref)) || {}).cell;
                const next = this.rectsForSavedEditHighlight(highlight).map((r) => ({
                  ...r,
                  savedHighlightIndex: index,
                  savedHighlightHasCell: hasCell
                }));
                rects = rects.concat(next);
              } catch (error) {
                errors.push(String(error && error.message ? error.message : error));
              }
            }
            return { highlights, rects, errors };
          },
          previewPageIndexesForSavedHighlights() {
            if (!this.mirror || !this.doc) return null;
            const { highlights, rects } = this.savedEditHighlightRects();
            if (!Array.isArray(highlights) || highlights.length === 0) return null;
            const pages = [...new Set(rects.map((r) => r.pageIndex).filter(Number.isInteger))];
            return pages.length > 0 ? pages : [0];
          },
          renderSavedEditHighlights() {
            if (!this.mirror || !this.doc) return;
            const { highlights, rects, errors } = this.savedEditHighlightRects();
            if (highlights.length === 0) {
              this.previewSavedHighlight = null;
              if (!this.previewPatchHighlight) {
                this.el.dataset.previewHighlightMode = "";
                this.el.dataset.previewHighlightCount = "0";
                this.el.dataset.previewHighlightPages = "";
                this.el.dataset.previewHighlightError = "";
                this.el.dataset.previewHighlightAuthority = "";
                this.el.dataset.previewHighlightFallbackCount = "0";
              }
              return;
            }
            this.previewSavedHighlight = { rects };
            const pages = [...new Set(rects.map((r) => r.pageIndex).filter(Number.isInteger))];
            const authorityCounts = rects.reduce((counts, rect) => {
              const authority = String(rect && rect.savedHighlightAuthority || "unknown");
              counts[authority] = (counts[authority] || 0) + 1;
              return counts;
            }, {});
            const fallbackAuthorities = new Set(["cell-bbox", "cursor", "element-estimate"]);
            const fallbackCount = rects.reduce((count, rect) => {
              return count + (fallbackAuthorities.has(String(rect && rect.savedHighlightAuthority || "")) ? 1 : 0);
            }, 0);
            this.el.dataset.previewHighlightMode = "saved-edit-regions";
            this.el.dataset.previewHighlightCount = String(rects.length);
            this.el.dataset.previewHighlightPages = pages.join(",");
            this.el.dataset.previewHighlightError = errors.slice(0, 3).join(";");
            this.el.dataset.previewHighlightAuthority = Object.keys(authorityCounts).sort().map((authority) => `${authority}:${authorityCounts[authority]}`).join(",");
            this.el.dataset.previewHighlightFallbackCount = String(fallbackCount);
            this.frameSavedEditHighlights(rects);
            for (const page of pages) {
              if (this.rendered && !this.rendered.get(page)) this.renderPage(page);
              this.paintSavedEditHighlightsOnPage(page);
            }
          },
          frameSavedEditHighlights(rects) {
            if (!this.mirror || !Array.isArray(rects) || rects.length === 0) return;
            const target = rects.find((r) => r.savedHighlightHasCell && Number.isInteger(r.pageIndex)) || rects.find((r) => Number.isInteger(r.pageIndex));
            if (!target) return;
            const section = this.pageSection(target.pageIndex);
            if (!section) return;
            let ratio = 1;
            try {
              const info = this.pageInfo(target.pageIndex);
              const rect = section.getBoundingClientRect();
              if (info && info.h > 0 && rect && rect.height > 0) ratio = rect.height / info.h;
            } catch (_) {
              ratio = 1;
            }
            const top = Number(section.offsetTop || 0) + Number(target.y || 0) * ratio - 24;
            this.el.scrollTop = Math.max(0, top);
            this.el.dataset.previewFrameMode = target.savedHighlightHasCell ? "saved-cell" : "saved-text";
            this.el.dataset.previewFramePage = String(target.pageIndex);
            this.el.dataset.previewFrameScrollTop = String(Math.round(this.el.scrollTop || 0));
          },
          rectsForSavedEditHighlight(highlight) {
            const rawRef = highlight && (highlight.ref || highlight.op && highlight.op.ref);
            const ref = this.parseRef(rawRef);
            if (!ref || !this.doc) return [];
            const nativeRects = this.nativeSavedEditHighlightRects(highlight);
            if (nativeRects.length > 0) return nativeRects;
            const controlRect = this.savedEditControlHighlightRect(rawRef, highlight);
            if (controlRect) return [controlRect];
            let raw = null;
            if (ref.cell) {
              const cell = ref.cell;
              const paragraph = Number.isInteger(cell.cellParaIndex) ? cell.cellParaIndex : 0;
              const range = this.savedEditCellHighlightRange(ref, cell, paragraph, highlight);
              if (!range) return [];
              raw = this.doc.getSelectionRectsInCell(
                ref.section,
                cell.parentParaIndex,
                cell.controlIndex,
                cell.cellIndex,
                range.startParagraph,
                range.startOffset,
                range.endParagraph,
                range.endOffset
              );
            } else {
              const start = this.savedEditParagraphStart(ref, highlight);
              const end = this.savedEditParagraphEnd(ref, highlight, start);
              if (end <= start) return [];
              raw = this.doc.getSelectionRects(ref.section, ref.paragraph, start, ref.paragraph, end);
            }
            let rects = [];
            try {
              const parsed = raw ? JSON.parse(raw) : [];
              rects = Array.isArray(parsed) ? parsed : [];
            } catch (_) {
              rects = [];
            }
            if (rects.length > 0) {
              const authority = ref.cell ? "selection-cell" : "selection";
              rects = rects.map((rect) => ({ ...rect, savedHighlightNative: true, savedHighlightAuthority: authority }));
              if (!ref.cell || this.savedEditRectsUsable(rects)) return rects;
              const cellRect = this.fallbackSavedEditCellRect(ref, ref.cell, rects, highlight);
              if (cellRect) return [{ ...cellRect, savedHighlightAuthority: "cell-bbox" }];
              return rects;
            }
            if (ref.cell) {
              const cellRect = this.fallbackSavedEditCellRect(ref, ref.cell, rects, highlight);
              if (cellRect) return [{ ...cellRect, savedHighlightAuthority: "cell-bbox" }];
            }
            const cursorRect = this.fallbackSavedEditCursorRect(ref, highlight);
            if (cursorRect) return [{ ...cursorRect, savedHighlightAuthority: "cursor" }];
            const estimatedRect = this.fallbackSavedEditElementRect(ref);
            return estimatedRect ? [{ ...estimatedRect, savedHighlightAuthority: "element-estimate" }] : [];
          },
          nativeSavedEditHighlightRects(highlight) {
            if (!this.doc || typeof this.doc.getSavedEditHighlightRects !== "function") return [];
            try {
              const raw = this.doc.getSavedEditHighlightRects(JSON.stringify(highlight || {}));
              const rects = raw ? JSON.parse(raw) : [];
              return Array.isArray(rects) ? rects.filter((rect) => rect && typeof rect === "object").map((rect) => ({ ...rect, savedHighlightNative: true, savedHighlightAuthority: "saved-edit-api" })) : [];
            } catch (_) {
              return [];
            }
          },
          savedEditControlHighlightRect(rawRef, highlight) {
            const refType = rawRef && typeof rawRef === "object" ? rawRef.type : "";
            const kind = String(highlight && (highlight.kind || highlight.op) || refType || "").toLowerCase();
            const type = String(highlight && highlight.type || refType || "").toLowerCase();
            if (!kind.includes("picture") && !type.includes("picture") && !type.includes("image")) return null;
            if (!this.doc || typeof this.doc.getPageControlLayout !== "function") return null;
            let pickRef;
            try {
              pickRef = typeof rawRef === "string" ? rawRef : JSON.stringify(rawRef || {});
            } catch (_) {
              return null;
            }
            const pick = { type: "picture", ref: pickRef };
            const pages = Math.max(1, Number(this.pageCount || 1));
            for (let pageIndex = 0; pageIndex < pages; pageIndex++) {
              let controls = [];
              try {
                controls = (JSON.parse(this.doc.getPageControlLayout(pageIndex) || "{}") || {}).controls || [];
              } catch (_) {
                controls = [];
              }
              const rect = this.pictureLiveRect(pick, pageIndex, controls);
              if (rect) {
                const normalized = this.normalizeSavedEditRect(rect, pageIndex);
                return normalized ? { ...normalized, savedHighlightNative: true, savedHighlightAuthority: "control-layout" } : null;
              }
            }
            return null;
          },
          savedEditRectsUsable(rects) {
            if (!Array.isArray(rects) || rects.length === 0) return false;
            return rects.some((rect) => {
              const width = Number(rect && (rect.width ?? rect.w));
              const height = Number(rect && (rect.height ?? rect.h));
              return width >= HWP_SAVED_EDIT_MIN_TEXT_RECT_WIDTH && height >= HWP_SAVED_EDIT_MIN_TEXT_RECT_HEIGHT;
            });
          },
          fallbackSavedEditCellRect(ref, cell, rects = [], highlight = null) {
            if (!ref || !cell || !this.doc || typeof this.doc.getTableCellBboxes !== "function") return null;
            const pageHint = this.savedEditRectPageHint(rects);
            let boxes = [];
            try {
              const raw = this.doc.getTableCellBboxes(
                ref.section,
                cell.parentParaIndex,
                cell.controlIndex,
                Number.isInteger(pageHint) ? pageHint : void 0
              );
              boxes = JSON.parse(raw || "[]");
            } catch (_) {
              boxes = [];
            }
            if (!Array.isArray(boxes) || boxes.length === 0) return null;
            const target = boxes.find((box) => Number(box.cellIdx ?? box.cellIndex) === Number(cell.cellIndex));
            if (!target) return null;
            const normalized = this.normalizeSavedEditRect(target, target.pageIndex ?? pageHint);
            if (!normalized) return null;
            if (this.savedEditRectsUsable([normalized])) return normalized;
            const row = Number(target.row);
            const pageIndex = Number(target.pageIndex ?? normalized.pageIndex);
            if (!Number.isInteger(row) || !Number.isInteger(pageIndex)) {
              return this.estimatedSavedEditCellTextRect(normalized, null, highlight);
            }
            const rowRects = boxes.filter((box) => Number(box.row) === row && Number(box.pageIndex ?? pageIndex) === pageIndex).map((box) => this.normalizeSavedEditRect(box, pageIndex)).filter(Boolean);
            return this.estimatedSavedEditCellTextRect(normalized, rowRects, highlight);
          },
          savedEditRectPageHint(rects) {
            if (!Array.isArray(rects)) return null;
            const page = rects.find((rect) => Number.isInteger(Number(rect && (rect.pageIndex ?? rect.page))));
            if (!page) return null;
            const pageIndex = Number(page.pageIndex ?? page.page);
            return Number.isInteger(pageIndex) ? pageIndex : null;
          },
          normalizeSavedEditRect(rect, fallbackPageIndex = 0) {
            if (!rect || typeof rect !== "object") return null;
            const pageIndex = Number(rect.pageIndex ?? rect.page ?? fallbackPageIndex);
            const x = Number(rect.x ?? rect.left);
            const y = Number(rect.y ?? rect.top);
            const width = Number(rect.width ?? rect.w);
            const height = Number(rect.height ?? rect.h);
            if (![pageIndex, x, y, width, height].every(Number.isFinite)) return null;
            if (!(width > 0 && height > 0)) return null;
            return {
              pageIndex: Math.max(0, Math.round(pageIndex)),
              x,
              y,
              width,
              height
            };
          },
          estimatedSavedEditCellTextRect(anchor, rowRects, highlight) {
            if (!anchor) return null;
            const text = highlight && typeof highlight.text === "string" ? highlight.text : "";
            const estimatedWidth = this.estimatedSavedEditTextWidth(text);
            const rowRight = Array.isArray(rowRects) && rowRects.length > 0 ? rowRects.reduce((max, rect) => Math.max(max, rect.x + rect.width), anchor.x + anchor.width) : null;
            const maxWidth = Number.isFinite(rowRight) ? Math.max(1, rowRight - anchor.x) : Infinity;
            const width = Math.min(Math.max(anchor.width, estimatedWidth), maxWidth);
            return {
              pageIndex: anchor.pageIndex,
              x: anchor.x,
              y: anchor.y,
              width: Math.max(1, width),
              height: Math.max(anchor.height, HWP_SAVED_EDIT_TEXT_HEIGHT)
            };
          },
          estimatedSavedEditTextWidth(text) {
            if (typeof text !== "string" || text.length === 0) return 40;
            return Array.from(text).reduce((width, char) => {
              if (/\s/.test(char)) return width + HWP_SAVED_EDIT_SPACE_WIDTH;
              if (/[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af\u3040-\u30ff\u3400-\u9fff]/.test(char)) {
                return width + HWP_SAVED_EDIT_CJK_CHAR_WIDTH;
              }
              return width + HWP_SAVED_EDIT_LATIN_CHAR_WIDTH;
            }, 0);
          },
          fallbackSavedEditCursorRect(ref, highlight) {
            if (!ref || !this.doc) return null;
            try {
              let raw = null;
              if (ref.cell) {
                const cell = ref.cell;
                const paragraph = Number.isInteger(cell.cellParaIndex) ? cell.cellParaIndex : 0;
                const length = this.cellParagraphLength(ref, cell, paragraph);
                const start = Math.min(Math.max(0, length), this.savedEditCellHighlightStart(ref, highlight));
                raw = this.doc.getCursorRectInCell(
                  ref.section,
                  cell.parentParaIndex,
                  cell.controlIndex,
                  cell.cellIndex,
                  paragraph,
                  start
                );
              } else {
                const length = this.paragraphLength(ref.section, ref.paragraph);
                const start = Math.min(Math.max(0, length), this.savedEditParagraphStart(ref, highlight));
                raw = this.doc.getCursorRect(ref.section, ref.paragraph, start);
              }
              const parsed = raw ? JSON.parse(raw) : null;
              return this.normalizeSavedEditCursorRect(parsed, highlight);
            } catch (_) {
              return null;
            }
          },
          normalizeSavedEditCursorRect(rect, highlight) {
            if (!rect || typeof rect !== "object") return null;
            const pageIndex = Number(rect.pageIndex ?? rect.page ?? 0);
            if (!Number.isInteger(pageIndex) || pageIndex < 0) return null;
            const info = this.pageInfo(pageIndex);
            let x = Number(rect.x ?? rect.left);
            let y = Number(rect.y ?? rect.top);
            let width = Number(rect.width ?? rect.w);
            let height = Number(rect.height ?? rect.h);
            if (!Number.isFinite(x)) x = Math.round((info.w || 794) * 0.14);
            if (!Number.isFinite(y)) return null;
            if (!Number.isFinite(height) || height <= 0) height = 22;
            if (!Number.isFinite(width) || width <= 0) {
              const text = highlight && typeof highlight.text === "string" ? highlight.text : "";
              width = Math.max(40, Math.min(Math.round((info.w || 794) * 0.72), text.length * 9));
            }
            const maxWidth = Math.max(1, (info.w || 794) - x - 8);
            return {
              pageIndex,
              x: Math.max(0, Math.round(x)),
              y: Math.max(0, Math.round(y)),
              width: Math.max(1, Math.min(Math.round(width), maxWidth)),
              height: Math.max(1, Math.round(height))
            };
          },
          fallbackSavedEditElementRect(ref) {
            if (!ref || !this.doc) return null;
            const pageCount = Math.max(1, this.pageCount || 1);
            let elements = [];
            try {
              elements = this.collectElements().filter((el) => el && el.ref);
            } catch (_) {
              elements = [];
            }
            const index = elements.findIndex((el) => this.sameHwpElementRef(el.ref, ref));
            const pageIndex = this.estimatedSavedEditPage(ref, elements, index, pageCount);
            const info = this.pageInfo(pageIndex);
            const perPage = Math.max(1, Math.ceil(Math.max(elements.length, 1) / pageCount));
            const indexInPage = index >= 0 ? index % perPage : Math.max(0, Number(ref.paragraph || 0) % perPage);
            const y = Math.max(32, Math.round(info.h * (indexInPage + 1) / (perPage + 1)));
            return {
              pageIndex,
              x: Math.round(info.w * 0.14),
              y,
              width: Math.round(info.w * 0.72),
              height: 26
            };
          },
          estimatedSavedEditPage(ref, elements, index, pageCount) {
            if (index >= 0 && elements.length > 0) {
              return Math.min(pageCount - 1, Math.max(0, Math.floor(index / elements.length * pageCount)));
            }
            const section = Number(ref.section ?? 0);
            const paragraph = Number(ref.paragraph ?? ref.cell?.parentParaIndex);
            if (Number.isInteger(paragraph)) {
              let paragraphCount = 0;
              try {
                paragraphCount = this.paragraphCount(section);
              } catch (_) {
                paragraphCount = 0;
              }
              if (paragraphCount > 0) {
                return Math.min(pageCount - 1, Math.max(0, Math.floor(paragraph / paragraphCount * pageCount)));
              }
            }
            return 0;
          },
          savedEditCellHighlightLength(ref, cell, paragraph, highlight) {
            const explicit = this.savedEditNumericField(highlight, null, ["length", "len"]);
            if (explicit !== null) return Math.max(0, explicit);
            let length = 0;
            try {
              length = this.cellParagraphLength(ref, cell, paragraph);
            } catch (_) {
              length = 0;
            }
            if (length > 0) return length;
            const text = highlight && typeof highlight.text === "string" ? highlight.text : "";
            return text.length;
          },
          savedEditCellHighlightRange(ref, cell, paragraph, highlight) {
            const start = this.savedEditCellHighlightStart(ref, highlight);
            const op = String(highlight && (highlight.op || highlight.kind) || "");
            const text = highlight && typeof highlight.text === "string" ? highlight.text : "";
            if ((op === "set_cell" || op === "insert_text") && /\r?\n/.test(text)) {
              const lines = text.split(/\r?\n/);
              return {
                startParagraph: paragraph,
                startOffset: start,
                endParagraph: paragraph + lines.length - 1,
                endOffset: lines[lines.length - 1].length
              };
            }
            const length = this.savedEditCellHighlightLength(ref, cell, paragraph, highlight);
            if (length <= 0) return null;
            return {
              startParagraph: paragraph,
              startOffset: start,
              endParagraph: paragraph,
              endOffset: start + length
            };
          },
          savedEditCellHighlightStart(ref, highlight) {
            const explicit = this.savedEditNumericField(highlight, null, [
              "offset",
              "start",
              "startOffset",
              "start_offset"
            ]);
            return explicit !== null ? Math.max(0, explicit) : 0;
          },
          savedEditParagraphStart(ref, highlight) {
            const op = highlight && (highlight.op || highlight.kind);
            const explicit = this.savedEditNumericField(highlight, null, [
              "offset",
              "start",
              "startOffset",
              "start_offset"
            ]);
            if (explicit !== null) return Math.max(0, explicit);
            if (op === "insert_text" || op === "set_char") return Math.max(0, Number(ref.offset || 0));
            return 0;
          },
          savedEditParagraphEnd(ref, highlight, start) {
            const paragraphLength = this.paragraphLength(ref.section, ref.paragraph);
            const op = highlight && (highlight.op || highlight.kind);
            const explicit = this.savedEditNumericField(highlight, null, ["length", "len"]);
            if (explicit !== null) return Math.min(paragraphLength, start + Math.max(0, explicit));
            const refExplicit = Number(ref.length || ref.len);
            if ((op === "insert_text" || op === "set_char") && Number.isFinite(refExplicit) && refExplicit > 0) {
              return Math.min(paragraphLength, start + refExplicit);
            }
            const text = highlight && typeof highlight.text === "string" ? highlight.text : "";
            if (op === "insert_text" && text.length > 0) return Math.min(paragraphLength, start + text.length);
            return paragraphLength;
          },
          savedEditNumericField(highlight, ref, keys) {
            for (const source of [highlight, ref]) {
              if (!source || typeof source !== "object") continue;
              for (const key of keys) {
                if (!Object.prototype.hasOwnProperty.call(source, key)) continue;
                const value = Number(source[key]);
                if (Number.isFinite(value)) return value;
              }
            }
            return null;
          },
          paintSavedEditHighlightsOnPage(pageIndex) {
            const highlight = this.previewSavedHighlight;
            if (!highlight || !Array.isArray(highlight.rects) || highlight.rects.length === 0) return;
            const overlay = this.pageOverlay(pageIndex);
            if (!overlay) return;
            const ctx = overlay.getContext("2d");
            if (!ctx) return;
            const s = this.pageScale(pageIndex);
            for (const r of highlight.rects) {
              if (r.pageIndex !== pageIndex) continue;
              this.paintEditHighlightRect(ctx, overlay, r, s);
            }
          },
          paintEditHighlightRect(ctx, overlay, rect, scale) {
            if (!ctx || !overlay || !rect) return;
            const css = typeof overlay.getBoundingClientRect === "function" ? overlay.getBoundingClientRect() : { width: overlay.width || 1, height: overlay.height || 1 };
            const overlayWidth = Number.isFinite(Number(overlay.width)) && Number(overlay.width) > 0 ? Number(overlay.width) : Number(css && css.width) || 1;
            const overlayHeight = Number.isFinite(Number(overlay.height)) && Number(overlay.height) > 0 ? Number(overlay.height) : Number(css && css.height) || 1;
            const backingPerCssX = css && css.width > 0 ? overlayWidth / css.width : 1;
            const backingPerCssY = css && css.height > 0 ? overlayHeight / css.height : backingPerCssX;
            const preciseNativeRect = rect.savedHighlightNative === true;
            const minWidth = preciseNativeRect ? 1 : Math.max(1, 28 * backingPerCssX);
            const minHeight = preciseNativeRect ? 1 : Math.max(1, 14 * backingPerCssY);
            const rawX = Number(rect.x || 0) * scale;
            const rawY = Number(rect.y || 0) * scale;
            const rawW = Math.max(1, Number(rect.width || rect.w || 1) * scale);
            const rawH = Math.max(1, Number(rect.height || rect.h || 1) * scale);
            const width = Math.max(rawW, minWidth);
            const height = Math.max(rawH, minHeight);
            const canvasWidth = Math.max(overlayWidth, rawX + width);
            const canvasHeight = Math.max(overlayHeight, rawY + height);
            const x = Math.max(0, Math.min(canvasWidth - width, rawX - Math.max(0, width - rawW) / 2));
            const y = Math.max(0, Math.min(canvasHeight - height, rawY - Math.max(0, height - rawH) / 2));
            ctx.fillStyle = "rgba(245, 158, 11, 0.30)";
            ctx.fillRect(x, y, width, height);
            if (typeof ctx.strokeRect === "function") {
              ctx.strokeStyle = "rgba(180, 83, 9, 0.78)";
              ctx.lineWidth = Math.max(1, Math.min(backingPerCssX, backingPerCssY));
              ctx.strokeRect(x + 0.5, y + 0.5, Math.max(1, width - 1), Math.max(1, height - 1));
            }
          },
          async loadDocument({ url, force = false, authority_preview = false, authorityPreview = false }) {
            if (!url) return;
            if (this.doc && this.loadedUrl === url && !force) return;
            if (this._loadInFlight) {
              if (this._loadingUrl === url && !force) return this._loadInFlight;
              try {
                await this._loadInFlight;
              } catch (_) {
              }
              if (this.doc && this.loadedUrl === url && !force) return;
            }
            if (this.loadedUrl && this.loadedUrl !== url) this.rememberScrollPosition(this.loadedUrl);
            this._loadingUrl = url;
            const load = (async () => {
              try {
              await ensureWasm();
              const response = await fetch(url, { credentials: "same-origin" });
              if (!response.ok) throw new Error(`document bytes HTTP ${response.status}`);
              const bytes = new Uint8Array(await response.arrayBuffer());
              if (this.doc) {
                if (this.snapshotTimer) {
                  clearTimeout(this.snapshotTimer);
                  this.snapshotTimer = null;
                  try {
                    this.pushSnapshot();
                  } catch (_) {
                  }
                }
                this.releaseAllPageCanvases();
                this.clearHwpHistory();
                try {
                  this.doc.free();
                } catch (_) {
                }
                this.doc = null;
              }
              this.doc = new HwpDocument(bytes);
              this.loadedUrl = url;
              try {
                this.doc.convertToEditable();
              } catch (_) {
              }
              try {
                this.format = this.doc.getSourceFormat() || this.format;
              } catch (_) {
              }
              this.pageCount = this.doc.pageCount();
              this.caret = null;
              this.sel = null;
              this.hwpFind = null;
              this.localImagePick = null;
              this.clearHwpHistory();
              this.previewPatchHighlight = null;
              const playbackSteps = this.previewPlaybackSteps();
              this.previewPageFilter = playbackSteps.length > 0 ? null : this.previewPageIndexesForSavedHighlights();
              if (!this.mirror) window.__rhwpDoc = this.doc;
              this.buildPageStack();
              this.restoreScrollPosition(url);
              this.renderVisiblePages();
              const authorityPreviewLoad = authority_preview === true || authorityPreview === true;
              if (playbackSteps.length > 0 && this.mirror) {
                this.startVfsPreviewPlayback(playbackSteps);
              } else {
                const handledHighlights = this.handleLoadedPreviewHighlights(authorityPreviewLoad, {
                  document_id: this.documentId,
                  turn_id: this.canvasState.previewTurnId,
                  text: this.canvasState.previewText || "",
                  delta_count: Number(this.canvasState.previewDeltaCount || "0")
                });
                if (!handledHighlights && (this.previewPatchTarget || this.canvasState.previewText)) this.patchPreviewToMountedDoc(this.previewPatchTarget || this.canvasState.previewText || "", {
                  authoritative: this.mirror,
                  turn_id: this.previewPatchTurnId || this.canvasState.previewTurnId,
                  delta_count: Number(this.canvasState.previewDeltaCount || "0")
                });
              }
              this.notifyViewerState(true);
              this.scheduleToolbarStateSync();
              } catch (error) {
                console.error("[wasm-hwp] load failed", error);
                this.notifyViewerState(false);
              }
            })();
            this._loadInFlight = load;
            try {
              return await load;
            } finally {
              if (this._loadInFlight === load) {
                this._loadInFlight = null;
                this._loadingUrl = null;
              }
            }
          },
          notifyViewerState(ready) {
            if (this.mirror) return;
            const id = this.documentId;
            if (!id) return;
            try {
              this.pushEvent(
                ready ? "document.viewer.ready" : "document.viewer.failed",
                { document_id: id }
              );
            } catch (_) {
            }
          },
          // Build one box-reserving <section> per page with a render <canvas> and a
          // caret-overlay <canvas>. `phx-update="ignore"` on the stack means the hook
          // owns this DOM (LiveView won't patch it), so we create the page nodes here.
          buildPageStack() {
            if (!this.pageStack) return;
            this.releaseAllPageCanvases();
            this.rendered.clear();
            if (this.renderedPageOrder) this.renderedPageOrder.clear();
            if (this.pageScales) this.pageScales.clear();
            this.visible.clear();
            this.pageStack.replaceChildren();
            if (this.io) this.io.disconnect();
            const pageIndexes = this.pageStackIndexes();
            if (this.el && this.el.dataset) {
              this.el.dataset.previewPageFilter = this.mirror && this.previewPageFilter ? this.previewPageFilter.join(",") : "";
            }
            for (const i of pageIndexes) {
              const { w, h } = this.pageInfo(i);
              const section = document.createElement("section");
              section.className = "ehwp-svg-page relative border border-black/10 bg-white shadow-[0_2px_8px_rgba(15,23,42,0.08)]";
              section.dataset.role = "local-hwp-page";
              section.dataset.pageIndex = String(i);
              section.dataset.pageNumber = String(i + 1);
              section.style.cssText = `width:${w}px;max-width:100%;aspect-ratio:${w} / ${h};position:relative`;
              const canvas = document.createElement("canvas");
              canvas.dataset.role = "ehwp-canvas";
              canvas.width = 1;
              canvas.height = 1;
              canvas.className = "block h-full w-full";
              const ctx = canvas.getContext("2d");
              if (ctx) {
                ctx.fillStyle = "#ffffff";
                ctx.fillRect(0, 0, 1, 1);
              }
              const overlay = document.createElement("canvas");
              overlay.dataset.role = "ehwp-caret-overlay";
              overlay.width = 1;
              overlay.height = 1;
              overlay.className = "pointer-events-none absolute left-0 top-0 h-full w-full";
              section.appendChild(canvas);
              section.appendChild(overlay);
              this.pageStack.appendChild(section);
              this.io.observe(section);
            }
          },
          pageStackIndexes() {
            if (this.mirror && Array.isArray(this.previewPageFilter) && this.previewPageFilter.length > 0) {
              return this.previewPageFilter.filter((index) => Number.isInteger(index) && index >= 0 && index < this.pageCount);
            }
            return Array.from({ length: this.pageCount }, (_value, index) => index);
          },
          pageInfo(index) {
            try {
              const info = JSON.parse(this.doc.getPageInfo(index));
              const w = Math.max(1, Math.round(info.width || 794));
              const h = Math.max(1, Math.round(info.height || 1123));
              return { w, h };
            } catch (_) {
              return { w: 794, h: 1123 };
            }
          },
          renderVisiblePages() {
            for (const idx of this.visible) this.renderPage(idx);
            if (this.visible.size === 0) {
              const first = this.pageStackIndexes()[0];
              if (Number.isInteger(first)) this.renderPage(first);
            }
            this.enforcePageMemoryBudget();
          },
          currentDeviceScale() {
            return window.devicePixelRatio || 1;
          },
          lowMemoryDevice() {
            const memory = typeof navigator !== "undefined" ? Number(navigator.deviceMemory) : NaN;
            return Number.isFinite(memory) && memory > 0 && memory <= 8;
          },
          renderPixelBudget() {
            if (this.mirror) return HWP_MIRROR_RENDER_MAX_PX;
            return this.lowMemoryDevice() ? HWP_LOW_MEMORY_RENDER_MAX_PX : HWP_RENDER_MAX_PX;
          },
          renderScaleFor(logical) {
            const baseScale = this.currentDeviceScale();
            const width = Math.max(1, Number(logical && logical.w) || Number(logical && logical.width) || 794);
            const height = Math.max(1, Number(logical && logical.h) || Number(logical && logical.height) || 1123);
            const wantPx = width * height * baseScale * baseScale;
            const maxPx = this.renderPixelBudget();
            if (wantPx <= maxPx) return baseScale;
            return baseScale * Math.sqrt(maxPx / wantPx);
          },
          pageScale(index = null) {
            if (Number.isInteger(index) && this.pageScales && this.pageScales.has(index)) {
              return this.pageScales.get(index);
            }
            return Number.isFinite(this.scale) && this.scale > 0 ? this.scale : this.currentDeviceScale();
          },
          releaseAllPageCanvases() {
            if (!this.pageStack) return;
            const sections = this.pageStack.querySelectorAll ? this.pageStack.querySelectorAll(SEL.hwpPage) : [];
            for (const section of sections) {
              const index = Number(section.dataset && section.dataset.pageIndex);
              if (Number.isInteger(index)) this.releasePageCanvas(index, { force: true });
            }
          },
          releasePageCanvas(index, { force = false } = {}) {
            if (!force && this.protectedPageIndexes().has(index)) return false;
            const section = this.pageSection(index);
            if (!section) return false;
            const canvas = section.querySelector(SEL.ehwpCanvas);
            const overlay = section.querySelector(SEL.ehwpCaretOverlay);
            if (canvas && (canvas.width !== 1 || canvas.height !== 1)) {
              canvas.width = 1;
              canvas.height = 1;
              const ctx = canvas.getContext("2d");
              if (ctx) {
                ctx.fillStyle = "#ffffff";
                ctx.fillRect(0, 0, 1, 1);
              }
            }
            if (overlay && (overlay.width !== 1 || overlay.height !== 1)) {
              overlay.width = 1;
              overlay.height = 1;
            }
            if (this.rendered && typeof this.rendered.delete === "function") this.rendered.delete(index);
            if (this.renderedPageOrder && typeof this.renderedPageOrder.delete === "function") this.renderedPageOrder.delete(index);
            if (this.pageScales && typeof this.pageScales.delete === "function") this.pageScales.delete(index);
            return true;
          },
          protectedPageIndexes() {
            const pages = /* @__PURE__ */ new Set();
            for (const page of this.visible || []) this.addPageWithMargin(pages, page);
            if (pages.size === 0 && this.pageCount > 0) this.addPageIndex(pages, 0);
            const caretPage = this.caret && this.caret.cursorRect && this.caret.cursorRect.pageIndex;
            this.addPageIndex(pages, caretPage);
            const dragPage = this.dragSelect && this.dragSelect.pageIndex;
            this.addPageIndex(pages, dragPage);
            const imageDragPage = this.imageDrag && this.imageDrag.pageIndex;
            this.addPageIndex(pages, imageDragPage);
            for (const rect of this.previewPatchHighlight && this.previewPatchHighlight.rects || []) {
              this.addPageIndex(pages, rect && rect.pageIndex);
            }
            for (const rect of this.previewSavedHighlight && this.previewSavedHighlight.rects || []) {
              this.addPageIndex(pages, rect && rect.pageIndex);
            }
            for (const pick of this.el && this.documentAdornmentPicks ? this.documentAdornmentPicks() : []) {
              for (const rect of pick.rects || []) this.addPageIndex(pages, rect && (rect.pageIndex ?? 0));
            }
            if (this.pickerHover && Array.isArray(this.pickerHover.rects)) {
              for (const rect of this.pickerHover.rects) this.addPageIndex(pages, rect && (rect.pageIndex ?? 0));
            }
            return pages;
          },
          addPageWithMargin(pages, page) {
            const index = Number(page);
            if (!Number.isInteger(index)) return;
            for (let offset = -HWP_RETAINED_PAGE_MARGIN; offset <= HWP_RETAINED_PAGE_MARGIN; offset++) {
              this.addPageIndex(pages, index + offset);
            }
          },
          addPageIndex(pages, page) {
            const index = Number(page);
            if (!Number.isInteger(index)) return;
            if (index < 0 || this.pageCount && index >= this.pageCount) return;
            pages.add(index);
          },
          enforcePageMemoryBudget() {
            if (!this.rendered || typeof this.rendered.keys !== "function") return;
            const protectedPages = this.protectedPageIndexes();
            for (const index of Array.from(this.rendered.keys())) {
              if (!protectedPages.has(index)) this.releasePageCanvas(index, { force: true });
            }
            if (this.rendered.size <= HWP_RENDERED_PAGE_SOFT_LIMIT) return;
            const ordered = this.renderedPageOrder && typeof this.renderedPageOrder.entries === "function" ? Array.from(this.renderedPageOrder.entries()).sort((a, b) => a[1] - b[1]).map(([index]) => index) : Array.from(this.rendered.keys());
            for (const index of ordered) {
              if (this.rendered.size <= HWP_RENDERED_PAGE_SOFT_LIMIT) break;
              if (!protectedPages.has(index)) this.releasePageCanvas(index, { force: true });
            }
          },
          renderPage(index) {
            if (!this.doc) return;
            const section = this.pageSection(index);
            if (!section) return;
            const canvas = section.querySelector(SEL.ehwpCanvas);
            if (!canvas) return;
            const logical = this.pageInfo(index);
            const dpr = this.renderScaleFor(logical);
            this.scale = dpr;
            try {
              this.doc.renderPageToCanvas(index, canvas, dpr);
              const overlay = section.querySelector(SEL.ehwpCaretOverlay);
              if (overlay) {
                overlay.width = canvas.width;
                overlay.height = canvas.height;
              }
              this.rendered.set(index, true);
              if (this.pageScales) this.pageScales.set(index, dpr);
              if (this.renderedPageOrder) {
                this.renderSeq = (this.renderSeq || 0) + 1;
                this.renderedPageOrder.set(index, this.renderSeq);
              }
              this.paintPreviewPatchHighlightOnPage(index);
              this.paintSavedEditHighlightsOnPage(index);
              if (this.caret && this.caret.cursorRect && this.caret.cursorRect.pageIndex === index) {
                this.drawCaret(this.caret);
              }
              this.enforcePageMemoryBudget();
            } catch (error) {
              console.error(`[wasm-hwp] renderPage(${index}) failed`, error);
            }
          },
          pageSection(index) {
            return this.pageStack && this.pageStack.querySelector(`${SEL.hwpPage}[data-page-index='${index}']`);
          },
          // Render whatever page the caret currently sits on. Plain typing must stay
          // single-page; structural edits can opt into refreshing the visible window.
          renderCaretPage(options = {}) {
            const idx = this.caret && this.caret.cursorRect && this.caret.cursorRect.pageIndex;
            if (typeof idx === "number") this.renderPage(idx);
            if (options.refreshVisible) {
              for (const v of this.visible) if (v !== idx) this.renderPage(v);
            }
          },
          // mousedown on a page canvas -> map canvas-rect coords to PAGE coords -> hitTest.
          //
          // Page coord = (clientX - rect.left) * (canvas.width / rect.width) / scale.
          // `canvas.width / rect.width` is the CSS-px -> backing-px ratio (includes the
          // devicePixelRatio supersampling); dividing by `scale` (== dpr) yields page
          // units, which is the coordinate space renderPageToCanvas/hitTest use.
          onCanvasMouseDown(event) {
            if (event.button !== 0 || !this.doc) return;
            const hitInfo = this.hitTestEvent(event);
            if (!hitInfo) return;
            const { hit, pageIndex } = hitInfo;
            window.__rhwpLastHit = hit;
            if (this.sel) {
              this.clearSelection();
              this.clearSelectionOverlays();
            }
            if (this.pickerEnabled()) {
              event.preventDefault();
              event.stopPropagation();
              this.localImagePick = null;
              const pick = this.hwpPickFromHit(hit, pageIndex);
              if (pick) appendPickedElementToComposer(pick);
              return;
            }
            const handle = this.pictureResizeHandleAtHit(hit);
            if (handle) {
              event.preventDefault();
              if (this.imeProxy) this.imeProxy.focus({ preventScroll: true });
              this.beginImageResize(handle, hit, pageIndex);
              return;
            }
            const pressPick = this.hwpPick(hit, pageIndex);
            if (pressPick && /image|picture/i.test(pressPick.type || "")) {
              event.preventDefault();
              if (this.imeProxy) this.imeProxy.focus({ preventScroll: true });
              this.beginImageDrag(
                {
                  section: pressPick.ref.section,
                  paragraph: pressPick.ref.paragraph,
                  controlIndex: pressPick.controlIndex,
                  type: pressPick.type,
                  bbox: (pressPick.rects || [])[0]
                },
                hit,
                pageIndex,
                this.hwpPickEnvelope(pressPick, pageIndex, hit)
              );
              return;
            }
            this.localImagePick = null;
            this.setCaretFromHit(hit, pageIndex);
            const c = this.caret;
            this.dragSelect = {
              pageIndex,
              section: c.section,
              cell: c.cell,
              anchor: { paragraph: c.paragraph, offset: c.offset },
              moved: false
            };
            this.clearSelection();
            if (this.imeProxy) {
              event.preventDefault();
              this.imeProxy.focus({ preventScroll: true });
              this.anchorProxy();
            }
          },
          // mousemove while the button is held: hit-test the current point and extend
          // the selection from the drag anchor to the current (focus) offset.
          // Picker mode stays visually quiet until the user actually selects an element.
          onCanvasMouseMove(event) {
            if (!this.doc) return;
            if (this.imageDrag) {
              if ((event.buttons & 1) === 0) {
                this.onCanvasMouseUp(event);
                return;
              }
              this.updateImageDrag(event);
              return;
            }
            if (!this.dragSelect) {
              if (this.pickerEnabled()) {
                this.setTextCursorCanvas(null);
                this.queuePickerHover(event);
              } else {
                this.queueTextCursorHover(event);
              }
              return;
            }
            if ((event.buttons & 1) === 0) {
              this.onCanvasMouseUp(event);
              return;
            }
            const hitInfo = this.hitTestEvent(event, this.dragSelect.pageIndex);
            if (!hitInfo) return;
            const { hit } = hitInfo;
            if (hit.sectionIndex !== void 0 && hit.sectionIndex !== this.dragSelect.section) return;
            if (this.updateCellBlockFromHit(hit)) {
              if (this.caret) this.drawCaret(this.caret);
              this.anchorProxy();
              if (event.cancelable) event.preventDefault();
              return;
            }
            const focus = {
              paragraph: hit.paragraphIndex !== void 0 ? hit.paragraphIndex : 0,
              offset: hit.charOffset !== void 0 ? hit.charOffset : 0
            };
            const ds = this.dragSelect;
            const sameSpot = focus.paragraph === ds.anchor.paragraph && focus.offset === ds.anchor.offset;
            if (!sameSpot) ds.moved = true;
            this.setCaretFromHit(hit, ds.pageIndex);
            if (ds.moved) {
              this.sel = {
                kind: "text",
                section: ds.section,
                cell: ds.cell,
                anchor: { ...ds.anchor },
                focus
              };
            } else {
              this.clearSelection();
            }
            this.renderSelection();
            if (this.caret) this.drawCaret(this.caret);
            this.anchorProxy();
            if (event.cancelable) event.preventDefault();
          },
          // mouseup: finalize (or discard) the drag-select gesture.
          onCanvasMouseUp(_event) {
            if (this.imageDrag) {
              this.endImageDrag();
              return;
            }
            if (!this.dragSelect) return;
            const ds = this.dragSelect;
            this.dragSelect = null;
            if (this.cellSel()) {
              if (this.documentAdornmentPicks().length > 0) this.paintPickedHighlights();
              return;
            }
            if (!ds.moved) {
              this.clearSelection();
              this.renderSelection();
              if (this.caret) this.drawCaret(this.caret);
            }
            if (this.documentAdornmentPicks().length > 0) this.paintPickedHighlights();
          },
          onCanvasDoubleClick(event) {
            if (!this.doc) return;
            const hitInfo = this.hitTestEvent(event);
            if (!hitInfo) return;
            const { hit, pageIndex } = hitInfo;
            event.preventDefault();
            event.stopPropagation();
            this.dragSelect = null;
            this.clearSelection();
            this.renderSelection();
            this.setCaretFromHit(hit, pageIndex);
            if (this.imeProxy) {
              this.imeProxy.focus({ preventScroll: true });
              this.anchorProxy();
            }
          },
          // Map a pointer event to { hit, pageIndex } via the engine's hitTest. When the
          // pointer is over a page canvas we use that page; otherwise (drag left the
          // canvas) we fall back to `preferPage` and clamp coords into its box so the
          // selection still extends to the nearest in-page offset.
          hitTestEvent(event, preferPage) {
            let section = event.target && event.target.closest ? event.target.closest(SEL.hwpPage) : null;
            let pageIndex = section ? Number(section.dataset.pageIndex) : preferPage;
            if (section == null && preferPage != null) section = this.pageSection(preferPage);
            if (!section && typeof pageIndex === "number") section = this.pageSection(pageIndex);
            if (!section) return null;
            if (typeof pageIndex !== "number" || Number.isNaN(pageIndex)) {
              pageIndex = Number(section.dataset.pageIndex);
            }
            const canvas = section.querySelector(SEL.ehwpCanvas);
            if (!canvas) return null;
            if ((!this.rendered || !this.rendered.get(pageIndex)) && this.doc) this.renderPage(pageIndex);
            if (!canvas.width || canvas.width <= 1) return null;
            const rect = canvas.getBoundingClientRect();
            const backingRatio = canvas.width / rect.width;
            const scale = this.pageScale(pageIndex);
            const clientX = Math.min(Math.max(event.clientX, rect.left), rect.right);
            const clientY = Math.min(Math.max(event.clientY, rect.top), rect.bottom);
            const x = (clientX - rect.left) * backingRatio / scale;
            const y = (clientY - rect.top) * backingRatio / scale;
            try {
              const raw = this.doc.hitTest(pageIndex, x, y);
              if (!raw) return null;
              const hit = JSON.parse(raw);
              hit.x = x;
              hit.y = y;
              return { hit, pageIndex };
            } catch (error) {
              console.error("[wasm-hwp] hitTest failed", error);
              return null;
            }
          },
          // rAF-throttle ordinary hover hit-testing. The engine's cursorRect describes
          // the nearest real text insertion point; requiring the pointer to remain near
          // that rect prevents page whitespace from receiving an I-beam cursor.
          queueTextCursorHover(event) {
            this.textCursorEvent = event;
            if (this.textCursorRaf) return;
            this.textCursorRaf = requestAnimationFrame(() => {
              this.textCursorRaf = null;
              this.updateTextCursorHover(this.textCursorEvent);
            });
          },
          updateTextCursorHover(event) {
            if (this.pickerEnabled() || !this.doc || !event) {
              this.setTextCursorCanvas(null);
              return;
            }
            const page = event.target && event.target.closest ? event.target.closest(SEL.hwpPage) : null;
            const canvas = page ? page.querySelector(SEL.ehwpCanvas) : null;
            if (!canvas) {
              this.setTextCursorCanvas(null);
              return;
            }
            const hitInfo = this.hitTestEvent(event);
            this.setTextCursorCanvas(hitInfo && this.hitIsText(hitInfo.hit) ? canvas : null);
          },
          hitIsText(hit) {
            const pointX = Number(hit && hit.x);
            const pointY = Number(hit && hit.y);
            const rect = hit && hit.cursorRect;
            const x = Number(rect && rect.x);
            const y = Number(rect && rect.y);
            const height = Number(rect && rect.height);
            if (![pointX, pointY, x, y, height].every(Number.isFinite) || height <= 0) return false;
            const horizontalTolerance = Math.max(3, height * 0.65);
            const verticalTolerance = Math.max(2, height * 0.15);
            return Math.abs(pointX - x) <= horizontalTolerance && pointY >= y - verticalTolerance && pointY <= y + height + verticalTolerance;
          },
          setTextCursorCanvas(canvas) {
            if (this.textCursorCanvas === canvas) return;
            if (this.textCursorCanvas) this.textCursorCanvas.style.cursor = "";
            this.textCursorCanvas = canvas;
            if (canvas) canvas.style.cursor = "text";
          },
          // ─── Selection rendering ─────────────────────────────────────────────────
          // Drop the active selection (any kind) — state only; caller re-renders.
          clearSelection() {
            this.sel = null;
            window.__rhwpSelection = null;
            window.__rhwpCellSelection = null;
          },
          // Typed views of the single `this.sel` value (null unless that kind is live).
          textSel() {
            return this.sel && this.sel.kind === "text" ? this.sel : null;
          },
          cellSel() {
            return this.sel && this.sel.kind === "cells" ? this.sel : null;
          },
          // ─── Table cell-block selection ──────────────────────────────────────────
          // A drag that crosses cell boundaries selects a rectangular range of CELLS
          // (the rhwp-studio model). The engine owns the geometry: hitTest resolves the
          // cell under the pointer, getCellInfo maps it to {row, col}, and
          // getTableCellBboxes gives every cell rect to paint. We only keep the
          // anchor/focus row-col and paint the union — no front-end hit-testing.
          // Nested tables (cellPath length > 1) are out of scope for block selection;
          // such drags fall back to normal in-cell text selection.
          isNestedCell(cellPath) {
            return Array.isArray(cellPath) && cellPath.length > 1;
          },
          // The {row, col} of a top-level table cell, or null when the engine can't
          // resolve it. Wraps the existing cellRowCol(target) lookup (which yields
          // {row, col} with null fields on miss) into a strict integer pair.
          cellGridPos(section, parentParaIndex, controlIndex, cellIndex) {
            if (!Number.isInteger(cellIndex)) return null;
            const rc = this.cellRowCol({
              section,
              paragraph: parentParaIndex,
              control: controlIndex,
              cellIndex
            });
            return rc && Number.isInteger(rc.row) && Number.isInteger(rc.col) ? rc : null;
          },
          // Drive the cell-block selection from a drag hit. Returns true once the drag
          // is a cell-block gesture (promoted on first cross-cell move and sticky for
          // the rest of the drag); false leaves the move to text drag-select.
          updateCellBlockFromHit(hit) {
            const ds = this.dragSelect;
            const anchorCell = ds && ds.cell;
            if (!anchorCell || this.isNestedCell(anchorCell.cellPath)) return false;
            const inSameTable = hit.parentParaIndex !== void 0 && Number.isInteger(hit.cellIndex) && hit.sectionIndex === ds.section && hit.parentParaIndex === anchorCell.parentParaIndex && hit.controlIndex === anchorCell.controlIndex && !this.isNestedCell(hit.cellPath);
            const cs = this.cellSel();
            if (!cs) {
              if (!inSameTable || hit.cellIndex === anchorCell.cellIndex) return false;
              const anchorRC = this.cellGridPos(
                ds.section,
                anchorCell.parentParaIndex,
                anchorCell.controlIndex,
                anchorCell.cellIndex
              );
              const focusRC = this.cellGridPos(
                ds.section,
                anchorCell.parentParaIndex,
                anchorCell.controlIndex,
                hit.cellIndex
              );
              if (!anchorRC || !focusRC) return false;
              this.sel = {
                kind: "cells",
                section: ds.section,
                parentParaIndex: anchorCell.parentParaIndex,
                controlIndex: anchorCell.controlIndex,
                anchor: anchorRC,
                focus: focusRC,
                bboxes: this.tableCellBboxes(ds.section, anchorCell.parentParaIndex, anchorCell.controlIndex)
              };
            } else if (inSameTable) {
              const focusRC = this.cellGridPos(
                ds.section,
                cs.parentParaIndex,
                cs.controlIndex,
                hit.cellIndex
              );
              if (focusRC) cs.focus = focusRC;
            }
            this.renderSelection();
            return true;
          },
          tableCellBboxes(section, parentParaIndex, controlIndex) {
            try {
              const arr = JSON.parse(
                this.doc.getTableCellBboxes(section, parentParaIndex, controlIndex) || "[]"
              );
              return Array.isArray(arr) ? arr : [];
            } catch (error) {
              console.error("[wasm-hwp] getTableCellBboxes failed", error);
              return [];
            }
          },
          // The sorted row/col rectangle currently covered by anchor..focus.
          cellSelectRange() {
            const { anchor, focus } = this.cellSel();
            return {
              startRow: Math.min(anchor.row, focus.row),
              endRow: Math.max(anchor.row, focus.row),
              startCol: Math.min(anchor.col, focus.col),
              endCol: Math.max(anchor.col, focus.col)
            };
          },
          // A cell (with its merge spans) overlaps the selected rectangle.
          cellBboxInRange(b, range) {
            const endRow = b.row + (b.rowSpan || 1) - 1;
            const endCol = b.col + (b.colSpan || 1) - 1;
            return b.row <= range.endRow && endRow >= range.startRow && b.col <= range.endCol && endCol >= range.startCol;
          },
          // Paint the cell-block rects that fall on one page (the cells arm of
          // paintSelectionOnPage; also used by drawCaret's blink-frame restore).
          paintCellsOnPage(pageIndex) {
            const cs = this.cellSel();
            if (!cs || !Array.isArray(cs.bboxes)) return;
            const overlay = this.pageOverlay(pageIndex);
            if (!overlay) return;
            const ctx = overlay.getContext("2d");
            if (!ctx) return;
            const range = this.cellSelectRange();
            const s = this.pageScale(pageIndex);
            ctx.fillStyle = "rgba(29, 78, 216, 0.28)";
            for (const b of cs.bboxes) {
              if (b.pageIndex !== pageIndex || !this.cellBboxInRange(b, range)) continue;
              ctx.fillRect(b.x * s, b.y * s, Math.max(1, b.w) * s, Math.max(1, b.h) * s);
            }
          },
          // Ask the engine for the line-by-line rects of the current selection and paint
          // a translucent highlight on each affected page's overlay canvas (the same
          // overlay the caret uses). getSelectionRects returns page-coordinate rects
          // `[{pageIndex, x, y, width, height}, ...]`; we scale them to the overlay
          // backing store exactly like drawCaret does.
          // Engine line-rects for a text selection: `[{pageIndex, x, y, width, height}]`,
          // or [] when collapsed / unavailable. Body and in-cell selections both route
          // here (the cell case uses getSelectionRectsInCell).
          textSelectionRects(sel) {
            if (sel.anchor.paragraph === sel.focus.paragraph && sel.anchor.offset === sel.focus.offset) return [];
            const [start, end] = this.orderedSelection(sel);
            try {
              const raw = sel.cell ? this.doc.getSelectionRectsInCell(
                sel.section,
                sel.cell.parentParaIndex,
                sel.cell.controlIndex,
                sel.cell.cellIndex,
                start.paragraph,
                start.offset,
                end.paragraph,
                end.offset
              ) : this.doc.getSelectionRects(
                sel.section,
                start.paragraph,
                start.offset,
                end.paragraph,
                end.offset
              );
              const rects = raw ? JSON.parse(raw) : [];
              return Array.isArray(rects) ? rects : [];
            } catch (error) {
              console.error("[wasm-hwp] getSelectionRects failed", error);
              return [];
            }
          },
          // Repaint the active selection — text OR cell-block — across every page it
          // touches, publish the matching window.__rhwp* globals, then restore the agent
          // preview-patch highlight. Per-page painting is delegated to
          // paintSelectionOnPage so the caret-blink restore shares one implementation.
          renderSelection() {
            this.clearSelectionOverlays();
            window.__rhwpSelection = null;
            window.__rhwpCellSelection = null;
            window.__rhwpSelectionRects = null;
            const pages = /* @__PURE__ */ new Set();
            const cs = this.cellSel();
            const ts = this.textSel();
            if (cs) {
              const range = this.cellSelectRange();
              window.__rhwpCellSelection = {
                section: cs.section,
                parentParaIndex: cs.parentParaIndex,
                controlIndex: cs.controlIndex,
                range
              };
              for (const b of cs.bboxes || []) if (this.cellBboxInRange(b, range)) pages.add(b.pageIndex);
            } else if (ts) {
              const rects = this.textSelectionRects(ts);
              if (rects.length) {
                const [start, end] = this.orderedSelection(ts);
                window.__rhwpSelection = { section: ts.section, start, end, cell: ts.cell || null };
                window.__rhwpSelectionRects = rects;
                for (const r of rects) pages.add(r.pageIndex);
              }
            }
            for (const page of pages) this.paintSelectionOnPage(page);
            if (this.previewPatchHighlight) this.paintPreviewPatchHighlightPages();
          },
          // Clear all overlay canvases (selection highlight + any stale caret) across the
          // page stack so a moving selection doesn't leave streaks behind.
          clearSelectionOverlays() {
            if (!this.pageStack) return;
            const overlays = this.pageStack.querySelectorAll(SEL.ehwpCaretOverlay);
            for (const overlay of overlays) {
              const ctx = overlay.getContext("2d");
              if (ctx) ctx.clearRect(0, 0, overlay.width, overlay.height);
            }
          },
          pageOverlay(index) {
            const section = this.pageSection(index);
            return section ? section.querySelector(SEL.ehwpCaretOverlay) : null;
          },
          paintPreviewPatchHighlightPages() {
            const highlight = this.previewPatchHighlight;
            if (!highlight || !Array.isArray(highlight.rects)) return;
            const pages = [...new Set(highlight.rects.map((r) => r.pageIndex).filter(Number.isInteger))];
            for (const page of pages) this.paintPreviewPatchHighlightOnPage(page);
          },
          // Order a selection's anchor/focus into [start, end] in document order.
          orderedSelection(sel) {
            const a = sel.anchor;
            const f = sel.focus;
            const before = a.paragraph < f.paragraph || a.paragraph === f.paragraph && a.offset <= f.offset;
            return before ? [a, f] : [f, a];
          },
          // True when a non-collapsed TEXT selection is active (cell-block selections
          // are not "text" for copy/delete/format purposes — same as before the merge).
          hasSelection() {
            const sel = this.textSel();
            return !!sel && !(sel.anchor.paragraph === sel.focus.paragraph && sel.anchor.offset === sel.focus.offset);
          },
          // Drop the selection highlight and repaint the overlays (keeps the caret).
          collapseSelection() {
            if (!this.sel) return;
            this.clearSelection();
            this.clearSelectionOverlays();
            if (this.caret) this.drawCaret(this.caret);
          },
          selectedText() {
            if (!this.hasSelection() || !this.doc) return "";
            const sel = this.textSel();
            const [start, end] = this.orderedSelection(sel);
            const chunks = [];
            for (let paragraph = start.paragraph; paragraph <= end.paragraph; paragraph++) {
              const startOffset = paragraph === start.paragraph ? start.offset : 0;
              const endOffset = paragraph === end.paragraph ? end.offset : this.hwpToolbarParagraphLength(sel.section, paragraph, sel.cell);
              if (endOffset < startOffset) continue;
              try {
                if (sel.cell) {
                  const ref = this.hwpToolbarRef(sel.section, paragraph, 0, sel.cell);
                  chunks.push(this.getTextInCellRef(ref, ref.cell, paragraph, startOffset, endOffset - startOffset) || "");
                } else {
                  chunks.push(this.doc.getTextRange(sel.section, paragraph, startOffset, endOffset - startOffset) || "");
                }
              } catch (_) {
                chunks.push("");
              }
            }
            return chunks.join("\n");
          },
          cloneEditorPoint(point) {
            return point ? JSON.parse(JSON.stringify(point)) : null;
          },
          handleToolbarCommand(detail) {
            if (!this.activeToolbarTarget() || !this.doc || !this.toolbarCommandMatchesDocument(detail)) return;
            switch (detail.command) {
              case "bold":
                this.hwpToolbarToggleCharProp("Bold", "bold");
                break;
              case "italic":
                this.hwpToolbarToggleCharProp("Italic", "italic");
                break;
              case "underline":
                this.hwpToolbarToggleCharProp("Underline", "underline");
                break;
              case "strikethrough":
                this.hwpToolbarToggleCharProp("Strikethrough", "strikethrough");
                break;
              case "bullets":
                this.hwpToolbarToggleList("Bullet");
                break;
              case "numbering":
                this.hwpToolbarToggleList("Number");
                break;
              case "font-size-set":
                if (Number.isFinite(Number(detail.size)) && Number(detail.size) > 0) {
                  this.hwpToolbarApplyProps({ FontSize: Number(detail.size) });
                }
                break;
              case "font-family-set":
                if (detail.family && typeof this.doc.findOrCreateFontId === "function") {
                  const fontId = this.doc.findOrCreateFontId(detail.family);
                  if (Number.isInteger(fontId) && fontId >= 0) {
                    this.hwpToolbarApplyProps({ FontId: fontId });
                  }
                }
                break;
              case "line-spacing-set":
                if (Number.isFinite(Number(detail.spacing))) {
                  this.hwpToolbarApplyParaProps({
                    LineSpacing: Math.round(Number(detail.spacing) * 100),
                    LineSpacingType: "Percent"
                  }, "toolbar-line-spacing");
                }
                break;
              case "named-style-set":
                this.hwpToolbarApplyNamedStyle(detail.style);
                break;
              case "indent-decrease":
                this.hwpToolbarAdjustIndent(-1e3);
                break;
              case "indent-increase":
                this.hwpToolbarAdjustIndent(1e3);
                break;
              case "table-insert":
              case "table-row-before":
              case "table-row-after":
              case "table-row-delete":
              case "table-column-before":
              case "table-column-after":
              case "table-column-delete":
              case "table-merge":
              case "table-split":
                this.hwpToolbarTableCommand(detail);
                break;
              case "text-color":
                if (detail.color) this.hwpToolbarApplyProps({ TextColor: detail.color });
                break;
              case "highlight":
                if (detail.color) this.hwpToolbarApplyProps({ shadeColor: detail.color });
                break;
              case "align-left":
              case "align-center":
              case "align-right":
              case "align-justify":
                this.hwpToolbarAlign(detail.command.slice("align-".length));
                break;
              case "image":
                this.hwpToolbarImage(detail);
                break;
              default:
                break;
            }
          },
          // ── Find bar (⌘F) ──────────────────────────────────────────────────────────
          // The find bar broadcasts search/next/prev/close on the find bus. RHWP owns
          // match ordering, directional stepping, wrap-around, and counts through its
          // `find` API; this hook only supplies the current anchor and paints the hit
          // with the editor's native text selection.
          handleFindCommand(detail) {
            if (this.mirror) return;
            if (!this.activeToolbarTarget() || !this.doc || !this.toolbarCommandMatchesDocument(detail)) return;
            const query = String(detail.query || "");
            switch (detail.action) {
              case "search":
                this.hwpFindSearch(query);
                break;
              case "next":
                this.hwpFindStep(query, 1);
                break;
              case "prev":
                this.hwpFindStep(query, -1);
                break;
              case "close":
                this.hwpFind = null;
                if (this.imeProxy) this.imeProxy.focus({ preventScroll: true });
                break;
              default:
                break;
            }
          },
          hwpFindAnchor(position = this.caret) {
            if (!position) return null;
            const anchor = {
              sec: position.section ?? 0,
              para: position.cell ? position.cell.parentParaIndex : position.paragraph ?? 0,
              charOffset: position.offset ?? 0
            };
            if (position.cell) {
              anchor.cellContext = {
                parentPara: position.cell.parentParaIndex,
                ctrlIdx: position.cell.controlIndex ?? 0,
                cellIdx: position.cell.cellIndex ?? 0,
                cellPara: position.cell.cellParaIndex ?? 0
              };
            }
            return anchor;
          },
          hwpFindResult(query, direction, skipCurrent, anchor) {
            try {
              const raw = this.doc.find(query, JSON.stringify({
                direction,
                caseSensitive: false,
                includeCells: true,
                includeNotes: false,
                skipCurrent,
                anchor
              }));
              return raw ? JSON.parse(raw) : { found: false, total: 0, index: null };
            } catch (error) {
              console.error("[wasm-hwp] find failed", error);
              return { found: false, total: 0, index: null };
            }
          },
          hwpFindMatch(hit, query) {
            const cc = hit && hit.cellContext;
            const cell = cc && cc.parentPara != null ? {
              parentParaIndex: cc.parentPara,
              controlIndex: cc.ctrlIdx ?? 0,
              cellIndex: cc.cellIdx ?? 0,
              cellParaIndex: cc.cellPara ?? 0
            } : null;
            return {
              section: hit?.sec ?? 0,
              paragraph: cell ? cell.cellParaIndex : hit?.para ?? 0,
              offset: hit?.charOffset ?? 0,
              length: Math.max(1, Number(hit?.length) || String(query).length),
              cell
            };
          },
          hwpFindSearch(query) {
            if (!query) {
              this.hwpFind = null;
              if (this.hasSelection()) this.collapseSelection();
              this.emitHwpFindState("", null, null);
              return;
            }
            this.hwpFindApply(query, "forward", false, this.hwpFindAnchor());
          },
          hwpFindStep(query, dir) {
            if (!query) {
              this.hwpFindSearch(query);
              return;
            }
            const current = this.hwpFind && this.hwpFind.query === query ? this.hwpFind : null;
            const anchor = current ? current.hit : this.hwpFindAnchor();
            this.hwpFindApply(query, dir < 0 ? "backward" : "forward", !!current, anchor);
          },
          hwpFindApply(query, direction, skipCurrent, anchor) {
            const result = this.hwpFindResult(query, direction, skipCurrent, anchor);
            if (result.found && result.hit) {
              this.hwpFind = { query, hit: result.hit };
              this.hwpFindSelect(this.hwpFindMatch(result.hit, query));
              this.emitHwpFindState(query, Number(result.total) || 0, result.index ?? null);
              return;
            }
            this.hwpFind = { query, hit: null };
            if (this.hasSelection()) this.collapseSelection();
            this.emitHwpFindState(query, Number(result.total) || 0, null);
          },
          // Select the match with the editor's native text selection (the same
          // `this.sel` a drag produces — renderSelection paints it and publishes the
          // window.__rhwpSelection globals), park the caret at the match end, and
          // scroll the match's page-rect into view.
          hwpFindSelect(match) {
            const cell = match.cell ? { ...match.cell } : null;
            this.sel = {
              kind: "text",
              section: match.section,
              cell,
              anchor: { paragraph: match.paragraph, offset: match.offset },
              focus: { paragraph: match.paragraph, offset: match.offset + match.length }
            };
            this.caret = {
              section: match.section,
              paragraph: match.paragraph,
              offset: match.offset + match.length,
              cell,
              note: null,
              cursorRect: null,
              preferredX: -1
            };
            this.refreshCursorRect();
            this.hwpFindScrollIntoView();
            this.renderSelection();
            this.caretBlinkOn = true;
            if (this.caret && this.caret.cursorRect) this.drawCaret(this.caret);
          },
          // Scroll the current find selection into view (top third of the viewport)
          // unless it is already visible. Uses the engine selection rects; falls back
          // to the caret rect when the rects are empty (zero-width matches).
          hwpFindScrollIntoView() {
            const ts = this.textSel();
            const rects = ts ? this.textSelectionRects(ts) : [];
            const rect = rects.find((r) => Number.isInteger(r.pageIndex)) || this.caret && this.caret.cursorRect || null;
            if (!rect) return;
            const section = this.pageSection(rect.pageIndex);
            if (!section) return;
            let ratio = 1;
            try {
              const info = this.pageInfo(rect.pageIndex);
              const bounds = section.getBoundingClientRect();
              if (info && info.h > 0 && bounds && bounds.height > 0) ratio = bounds.height / info.h;
            } catch (_) {
              ratio = 1;
            }
            const top = Number(section.offsetTop || 0) + Number(rect.y || 0) * ratio;
            const viewTop = Number(this.el.scrollTop || 0);
            const viewHeight = Number(this.el.clientHeight || 0);
            if (viewHeight > 0 && top >= viewTop + 24 && top <= viewTop + viewHeight - 48) return;
            this.el.scrollTop = Math.max(0, top - Math.max(48, viewHeight * 0.33));
          },
          emitHwpFindState(query, total, index) {
            document.dispatchEvent(new CustomEvent(DOCUMENT_SEARCH_RESULT_EVENT, {
              detail: {
                document_id: this.documentId,
                query,
                total,
                index
              }
            }));
          },
          // Paragraph alignment over the selection's paragraphs (or the caret
          // paragraph). Char refs double as para refs — the para branch of applySetOne
          // only reads section/paragraph/cell — but must be DEDUPED per paragraph
          // (a multi-run selection yields one char ref per paragraph already).
          hwpToolbarAlign(alignment) {
            const refs = this.hwpToolbarParaRefs();
            if (!refs.length) return;
            this.pushHwpUndoCheckpoint("toolbar-align");
            let applied = 0;
            for (const ref of refs) {
              const result = this.applySetOne(ref, { kind: "para", Alignment: alignment });
              if (result && result.error) {
                console.warn("[wasm-hwp] toolbar align failed", result.error);
              } else {
                applied++;
              }
            }
            if (applied > 0) {
              this.finishAgentEdit({});
              this.scheduleToolbarStateSync();
            }
          },
          hwpToolbarParaRefs() {
            const seen = /* @__PURE__ */ new Set();
            return this.hwpToolbarCharRefs().filter((ref) => {
              const key = JSON.stringify([ref.section, ref.paragraph, ref.cell || null]);
              if (seen.has(key)) return false;
              seen.add(key);
              return true;
            });
          },
          hwpToolbarParaProps(ref) {
            const parsed = this.parseRef(ref);
            if (!parsed) return {};
            try {
              const cl = parsed.cell;
              const raw = cl && typeof this.doc.getCellParaPropertiesAt === "function"
                ? this.doc.getCellParaPropertiesAt(
                    parsed.section,
                    cl.parentParaIndex,
                    cl.controlIndex,
                    cl.cellIndex,
                    cl.cellParaIndex
                  )
                : !cl && typeof this.doc.getParaPropertiesAt === "function"
                  ? this.doc.getParaPropertiesAt(parsed.section, parsed.paragraph)
                  : null;
              return typeof raw === "string" ? JSON.parse(raw || "{}") : raw || {};
            } catch (_) {
              return {};
            }
          },
          hwpToolbarListActive(ref, headType) {
            const current = String(this.hwpToolbarParaProps(ref).headType || "").toLowerCase();
            if (headType === "Bullet") return current === "bullet";
            return current === "number" || current === "outline";
          },
          hwpToolbarToggleList(headType) {
            const refs = this.hwpToolbarParaRefs();
            if (!refs.length) return;
            const enabled = refs.every((ref) => this.hwpToolbarListActive(ref, headType));
            let numberingId = 0;
            if (!enabled) {
              try {
                numberingId = headType === "Bullet"
                  ? Number(this.doc.ensureDefaultBullet("•"))
                  : Number(this.doc.ensureDefaultNumbering());
              } catch (error) {
                console.warn("[wasm-hwp] toolbar list definition failed", error);
                return;
              }
              if (!Number.isInteger(numberingId) || numberingId <= 0) return;
            }
            this.pushHwpUndoCheckpoint("toolbar-list");
            let applied = 0;
            for (const ref of refs) {
              const result = this.applySetOne(ref, {
                kind: "para",
                HeadType: enabled ? "None" : headType,
                NumberingId: enabled ? 0 : numberingId,
                ParaLevel: 0
              });
              if (result && result.error) {
                console.warn("[wasm-hwp] toolbar list failed", result.error);
              } else {
                applied++;
              }
            }
            if (applied > 0) {
              this.finishAgentEdit({});
              this.scheduleToolbarStateSync();
            }
          },
          hwpToolbarApplyParaProps(props, checkpoint = "toolbar-paragraph") {
            const refs = this.hwpToolbarParaRefs();
            if (!refs.length) return;
            this.pushHwpUndoCheckpoint(checkpoint);
            let applied = 0;
            for (const ref of refs) {
              const result = this.applySetOne(ref, { kind: "para", ...props });
              if (result && result.error) console.warn("[wasm-hwp] toolbar paragraph failed", result.error);
              else applied++;
            }
            if (applied > 0) {
              this.finishAgentEdit({});
              this.scheduleToolbarStateSync();
            }
          },
          hwpToolbarAdjustIndent(delta) {
            const refs = this.hwpToolbarParaRefs();
            if (!refs.length) return;
            this.pushHwpUndoCheckpoint("toolbar-indent");
            let applied = 0;
            for (const ref of refs) {
              const current = Number(this.hwpToolbarParaProps(ref).marginLeft || 0);
              const result = this.applySetOne(ref, {
                kind: "para",
                marginLeft: Math.max(0, Math.min(5e4, current + delta))
              });
              if (result && result.error) console.warn("[wasm-hwp] toolbar indent failed", result.error);
              else applied++;
            }
            if (applied > 0) {
              this.finishAgentEdit({});
              this.scheduleToolbarStateSync();
            }
          },
          hwpToolbarApplyNamedStyle(style) {
            if (!style || typeof this.doc.getStyleList !== "function" || typeof this.doc.applyStyle !== "function") return;
            const refs = this.hwpToolbarParaRefs().filter(ref => !ref.cell);
            if (!refs.length) return;
            let styles = [];
            try {
              const raw = this.doc.getStyleList();
              styles = typeof raw === "string" ? JSON.parse(raw || "[]") : raw || [];
            } catch (_) {
              return;
            }
            const aliases = {
              body: ["normal", "body text", "default", "바탕글", "본문"],
              title: ["title", "제목"],
              subtitle: ["subtitle", "부제"],
              "heading-1": ["heading 1", "heading1", "개요 1", "제목 1"],
              "heading-2": ["heading 2", "heading2", "개요 2", "제목 2"],
              "heading-3": ["heading 3", "heading3", "개요 3", "제목 3"],
              quote: ["quote", "quotation", "인용"],
              preformatted: ["preformatted text", "preformatted", "code", "고정폭"]
            };
            const wanted = aliases[style] || [String(style)];
            const normalize = value => String(value || "").trim().toLowerCase();
            let match = styles.find(item => wanted.includes(normalize(item.englishName)) || wanted.includes(normalize(item.name)));
            if (!match && style === "body") match = styles.find(item => Number(item.id) === 0) || styles[0];
            this.pushHwpUndoCheckpoint("toolbar-style");
            if (!match) match = this.hwpToolbarCreateNamedStyle(style);
            const styleId = Number(match && match.id);
            if (!Number.isInteger(styleId) || styleId < 0) return;
            let applied = 0;
            for (const ref of refs) {
              try {
                const raw = this.doc.applyStyle(ref.section, ref.paragraph, styleId);
                const result = typeof raw === "string" ? JSON.parse(raw || "{}") : raw || {};
                if (result.error) console.warn("[wasm-hwp] toolbar style failed", result.error);
                else applied++;
              } catch (error) {
                console.warn("[wasm-hwp] toolbar style failed", error);
              }
            }
            if (applied > 0) {
              this.finishAgentEdit({});
              this.scheduleToolbarStateSync();
            }
          },
          hwpToolbarCreateNamedStyle(style) {
            if (typeof this.doc.createStyle !== "function") return null;
            const presets = {
              title: {
                name: "제목",
                englishName: "Title",
                char: { fontSize: 2200, bold: true },
                para: { alignment: "center", spacingBefore: 400, spacingAfter: 300, keepWithNext: true }
              },
              subtitle: {
                name: "부제",
                englishName: "Subtitle",
                char: { fontSize: 1500, italic: true },
                para: { alignment: "center", spacingAfter: 250, keepWithNext: true }
              },
              "heading-1": {
                name: "제목 1",
                englishName: "Heading 1",
                char: { fontSize: 1800, bold: true },
                para: { spacingBefore: 300, spacingAfter: 150, keepWithNext: true }
              },
              "heading-2": {
                name: "제목 2",
                englishName: "Heading 2",
                char: { fontSize: 1600, bold: true },
                para: { spacingBefore: 250, spacingAfter: 120, keepWithNext: true }
              },
              "heading-3": {
                name: "제목 3",
                englishName: "Heading 3",
                char: { fontSize: 1400, bold: true },
                para: { spacingBefore: 200, spacingAfter: 100, keepWithNext: true }
              },
              quote: {
                name: "인용",
                englishName: "Quote",
                char: { italic: true },
                para: { marginLeft: 2000, marginRight: 2000, spacingBefore: 100, spacingAfter: 100 }
              },
              preformatted: {
                name: "고정폭",
                englishName: "Preformatted",
                char: { fontSize: 1000 },
                para: { marginLeft: 1000, marginRight: 1000 }
              }
            };
            const preset = presets[style];
            if (!preset) return null;
            const charMods = { ...preset.char };
            if (style === "preformatted" && typeof this.doc.findOrCreateFontId === "function") {
              const fontId = Number(this.doc.findOrCreateFontId("Liberation Mono"));
              if (Number.isInteger(fontId) && fontId >= 0) charMods.fontId = fontId;
            }
            try {
              const id = Number(this.doc.createStyle(JSON.stringify({
                name: preset.name,
                englishName: preset.englishName,
                type: 0,
                nextStyleId: 0
              })));
              if (!Number.isInteger(id) || id < 0) return null;
              if (typeof this.doc.updateStyleShapes === "function") {
                const updated = this.doc.updateStyleShapes(
                  id,
                  JSON.stringify(charMods),
                  JSON.stringify(preset.para)
                );
                if (updated === false) {
                  if (typeof this.doc.deleteStyle === "function") this.doc.deleteStyle(id);
                  return null;
                }
              }
              return { id, name: preset.name, englishName: preset.englishName };
            } catch (error) {
              console.warn("[wasm-hwp] toolbar style creation failed", error);
              return null;
            }
          },
          hwpToolbarTableTarget() {
            const c = this.caret;
            if (!c || !c.cell || this.isNestedCell(c.cell.cellPath)) return null;
            const rc = this.cellGridPos(c.section, c.cell.parentParaIndex, c.cell.controlIndex, c.cell.cellIndex);
            return rc ? {
              section: c.section,
              paragraph: c.cell.parentParaIndex,
              control: c.cell.controlIndex,
              ...rc
            } : null;
          },
          hwpToolbarTableCommand(detail) {
            if (detail.command === "table-insert") {
              const ref = this.hwpToolbarCaretRef() || this.hwpToolbarViewportRef();
              const rows = Number(detail.rows);
              const cols = Number(detail.cols);
              if (!ref || ref.cell || !Number.isInteger(rows) || !Number.isInteger(cols)) return;
              this.pushHwpUndoCheckpoint("toolbar-table-insert");
              try {
                const raw = this.doc.createTable(ref.section, ref.paragraph, ref.offset || 0, rows, cols);
                const result = typeof raw === "string" ? JSON.parse(raw || "{}") : raw || {};
                if (result.error || result.ok === false) return;
                this.recordOp("ToolbarInsertTable", { section: ref.section, paragraph: ref.paragraph, rows, cols });
                this.finishAgentEdit({});
              } catch (error) {
                console.warn("[wasm-hwp] toolbar table insert failed", error);
              }
              return;
            }
            const target = this.hwpToolbarTableTarget();
            if (!target) return;
            const selection = this.cellSel();
            this.pushHwpUndoCheckpoint("toolbar-table-edit");
            try {
              switch (detail.command) {
                case "table-row-before":
                  this.doc.insertTableRow(target.section, target.paragraph, target.control, target.row, false);
                  break;
                case "table-row-after":
                  this.doc.insertTableRow(target.section, target.paragraph, target.control, target.row, true);
                  break;
                case "table-row-delete":
                  this.doc.deleteTableRow(target.section, target.paragraph, target.control, target.row);
                  break;
                case "table-column-before":
                  this.doc.insertTableColumn(target.section, target.paragraph, target.control, target.col, false);
                  break;
                case "table-column-after":
                  this.doc.insertTableColumn(target.section, target.paragraph, target.control, target.col, true);
                  break;
                case "table-column-delete":
                  this.doc.deleteTableColumn(target.section, target.paragraph, target.control, target.col);
                  break;
                case "table-merge": {
                  if (!selection) return;
                  const startRow = Math.min(selection.anchor.row, selection.focus.row);
                  const startCol = Math.min(selection.anchor.col, selection.focus.col);
                  const endRow = Math.max(selection.anchor.row, selection.focus.row);
                  const endCol = Math.max(selection.anchor.col, selection.focus.col);
                  this.doc.mergeTableCells(target.section, target.paragraph, target.control, startRow, startCol, endRow, endCol);
                  break;
                }
                case "table-split":
                  this.doc.splitTableCell(target.section, target.paragraph, target.control, target.row, target.col);
                  break;
                default:
                  return;
              }
              this.recordOp("ToolbarTableEdit", { command: detail.command, ...target });
              this.clearSelection();
              this.finishAgentEdit({});
              this.scheduleToolbarStateSync();
            } catch (error) {
              console.warn("[wasm-hwp] toolbar table edit failed", error);
            }
          },
          activeToolbarTarget() {
            return !!(this.el && this.el.isConnected && /^(hwp|hwpx)$/i.test(this.format || ""));
          },
          toolbarCommandMatchesDocument(detail) {
            const commandDocumentId = detail && (detail.document_id || detail.documentId);
            if (!commandDocumentId) return true;
            return !!(this.documentId && String(commandDocumentId) === String(this.documentId));
          },
          hwpToolbarApplyProps(props) {
            const refs = this.hwpToolbarCharRefs();
            return this.hwpToolbarApplyPropsToRefs(refs, props);
          },
          hwpToolbarToggleCharProp(prop, engineKey) {
            const refs = this.hwpToolbarCharRefs();
            if (!refs.length) return;
            const enabled = refs.every((ref) => this.hwpToolbarCharPropEnabled(ref, engineKey));
            this.hwpToolbarApplyPropsToRefs(refs, { [prop]: !enabled });
          },
          hwpToolbarApplyPropsToRefs(refs, props) {
            if (!refs.length) return;
            this.pushHwpUndoCheckpoint("toolbar-format");
            let applied = 0;
            for (const ref of refs) {
              const result = this.applySetOne(ref, { kind: "char", ...props });
              if (result && result.error) {
                console.warn("[wasm-hwp] toolbar format failed", result.error);
              } else {
                applied++;
              }
            }
            if (applied > 0) {
              this.finishAgentEdit({});
              this.scheduleToolbarStateSync();
            }
          },
          hwpToolbarCharPropEnabled(ref, engineKey) {
            const parsed = this.parseRef(ref);
            if (!parsed) return false;
            const offset = this.hwpToolbarCharPropProbeOffset(parsed);
            try {
              let raw;
              const cl = parsed.cell;
              if (cl) {
                raw = this.doc.getCellCharPropertiesAt(
                  parsed.section,
                  cl.parentParaIndex,
                  cl.controlIndex,
                  cl.cellIndex,
                  cl.cellParaIndex,
                  offset
                );
              } else {
                raw = this.doc.getCharPropertiesAt(parsed.section, parsed.paragraph, offset);
              }
              const props = typeof raw === "string" ? JSON.parse(raw || "{}") : raw || {};
              return props && props[engineKey] === true;
            } catch (_) {
              return false;
            }
          },
          hwpToolbarCharPropProbeOffset(parsed) {
            let offset = Number.isInteger(parsed.offset) ? parsed.offset : 0;
            const span = Number(parsed.length ?? parsed.len ?? 0);
            if (!(Number.isFinite(span) && span > 0) && offset > 0) offset -= 1;
            return Math.max(0, offset);
          },
          hwpToolbarImage(detail) {
            if (!detail || !detail.image_base64) return;
            const ref = this.hwpToolbarCaretRef() || this.hwpToolbarViewportRef() || this.resolveEndRef("end");
            if (!ref) return;
            const size = this.hwpToolbarImageSize(detail, HWP_IMAGE_DEFAULT_MAX_UNIT);
            this.pushHwpUndoCheckpoint("toolbar-image");
            const result = this.applyOneOp({
              op: "insert_picture",
              ref,
              image_base64: detail.image_base64,
              extension: detail.extension || "png",
              natural_width_px: detail.natural_width_px || 0,
              natural_height_px: detail.natural_height_px || 0,
              width: size.width,
              height: size.height,
              description: detail.file_name || "image"
            });
            if (result && result.error) {
              console.warn("[wasm-hwp] toolbar image failed", result.error);
              return;
            }
            this.finishAgentEdit(result && result.extra ? result.extra : {});
          },
          hwpToolbarCharRefs() {
            if (this.hasSelection()) {
              const sel = this.textSel();
              const [start, end] = this.orderedSelection(sel);
              const refs = [];
              for (let paragraph = start.paragraph; paragraph <= end.paragraph; paragraph++) {
                const startOffset = paragraph === start.paragraph ? start.offset : 0;
                const endOffset = paragraph === end.paragraph ? end.offset : this.hwpToolbarParagraphLength(sel.section, paragraph, sel.cell);
                if (endOffset <= startOffset) continue;
                const ref = this.hwpToolbarRef(sel.section, paragraph, startOffset, sel.cell);
                ref.length = endOffset - startOffset;
                refs.push(ref);
              }
              if (refs.length) return refs;
            }
            const caretRef = this.hwpToolbarCaretRef();
            return caretRef ? [caretRef] : this.hwpToolbarDefaultRefs();
          },
          hwpToolbarDefaultRefs() {
            if (!this.doc) return [];
            let sections = 1;
            try {
              if (typeof this.doc.sectionCount === "function") {
                sections = Math.max(1, Number(this.doc.sectionCount()) || 1);
              }
            } catch (_) {
            }
            for (let section = 0; section < sections; section++) {
              let paragraphs = 0;
              try {
                paragraphs = this.doc.getParagraphCount(section);
              } catch (_) {
              }
              if (Number.isFinite(paragraphs) && paragraphs > 0) {
                return [this.hwpToolbarRef(section, 0, 0, null)];
              }
            }
            return [];
          },
          hwpToolbarCaretRef() {
            const c = this.caret;
            if (!c) return null;
            return this.hwpToolbarRef(c.section, c.paragraph, c.offset, c.cell);
          },
          // The paragraph ref at the top of the current viewport, so a toolbar insert
          // lands on the screen the user is looking at rather than the document end.
          // Resolved by the engine hit-test (pickAtPoint, via hwpPick) at the top-centre
          // of the first page intersecting the scroll viewport. Null if nothing visible.
          hwpToolbarViewportRef() {
            if (!this.doc) return null;
            const hostRect = this.el.getBoundingClientRect();
            for (const node of Array.from(this.el.querySelectorAll(SEL.hwpPage))) {
              const pageEl = node;
              const r = pageEl.getBoundingClientRect();
              if (r.bottom <= hostRect.top + 8 || r.top >= hostRect.bottom) continue;
              const canvas = pageEl.querySelector(SEL.ehwpCanvas);
              if (!canvas) continue;
              const pageIndex = Number(pageEl.dataset.pageIndex);
              if (!Number.isFinite(pageIndex)) continue;
              if ((!this.rendered || !this.rendered.get(pageIndex)) && this.doc) this.renderPage(pageIndex);
              if (!canvas.width || canvas.width <= 1) continue;
              const rect = canvas.getBoundingClientRect();
              if (!rect.width || !rect.height) continue;
              const backingRatio = canvas.width / rect.width;
              const scale = this.pageScale(pageIndex);
              const clientX = rect.left + rect.width / 2;
              const clientY = Math.min(Math.max(hostRect.top + 12, rect.top), rect.bottom);
              const x = (clientX - rect.left) * backingRatio / scale;
              const y = (clientY - rect.top) * backingRatio / scale;
              const pick = this.hwpPick({ x, y }, pageIndex);
              if (pick && pick.ref) {
                if (/picture|image/i.test(pick.type || "")) {
                  return this.hwpToolbarRef(Number(pick.ref.section ?? 0), Number(pick.ref.paragraph ?? 0), 0, null);
                }
                return pick.ref;
              }
            }
            return null;
          },
          hwpToolbarRef(section, paragraph, offset, cell) {
            const ref = { section, paragraph, offset };
            if (cell) {
              ref.cell = {
                parentParaIndex: cell.parentParaIndex,
                controlIndex: cell.controlIndex,
                cellIndex: cell.cellIndex,
                cellParaIndex: paragraph
              };
              if (Array.isArray(cell.cellPath) && cell.cellPath.length > 1) {
                const last = { ...cell.cellPath[cell.cellPath.length - 1], cellParaIndex: paragraph };
                ref.cellPath = [...cell.cellPath.slice(0, -1), last];
                ref.cell.cellPath = ref.cellPath;
                ref.paragraph = cell.parentParaIndex;
              }
            }
            return ref;
          },
          hwpToolbarParagraphLength(section, paragraph, cell) {
            if (cell) {
              const ref = this.hwpToolbarRef(section, paragraph, 0, cell);
              return this.cellParagraphLength(ref, ref.cell, paragraph);
            }
            return this.paragraphLength(section, paragraph);
          },
          hwpToolbarImageSize(detail, maxUnit) {
            const widthPx = Math.max(1, Number(detail.natural_width_px || 1));
            const heightPx = Math.max(1, Number(detail.natural_height_px || 1));
            const aspect = widthPx / heightPx;
            if (aspect >= 1) {
              return {
                width: maxUnit,
                height: Math.max(1, Math.round(maxUnit / aspect))
              };
            }
            return {
              width: Math.max(1, Math.round(maxUnit * aspect)),
              height: maxUnit
            };
          },
          // Delete the active selection from the document and collapse the caret to the
          // start of the deleted range. Used when typing / Backspace / Delete replaces a
          // selection. The engine returns the collapse point `{paraIdx, charOffset}`.
          deleteSelection() {
            if (!this.hasSelection()) return;
            const sel = this.textSel();
            const [start, end] = this.orderedSelection(sel);
            const c = this.caret;
            try {
              let raw;
              if (sel.cell && c.cell) {
                raw = this.doc.deleteRangeInCell(
                  sel.section,
                  c.cell.parentParaIndex,
                  c.cell.controlIndex,
                  c.cell.cellIndex,
                  start.paragraph,
                  start.offset,
                  end.paragraph,
                  end.offset
                );
                const r = JSON.parse(raw);
                c.cell.cellParaIndex = r.paraIdx !== void 0 ? r.paraIdx : start.paragraph;
                c.offset = r.charOffset !== void 0 ? r.charOffset : start.offset;
              } else {
                raw = this.doc.deleteRange(
                  sel.section,
                  start.paragraph,
                  start.offset,
                  end.paragraph,
                  end.offset
                );
                const r = JSON.parse(raw);
                c.paragraph = r.paraIdx !== void 0 ? r.paraIdx : start.paragraph;
                c.offset = r.charOffset !== void 0 ? r.charOffset : start.offset;
              }
              this.recordOp("RangeDeleted", {
                section: sel.section,
                startPara: start.paragraph,
                startOffset: start.offset,
                endPara: end.paragraph,
                endOffset: end.offset
              });
            } catch (error) {
              console.error("[wasm-hwp] deleteRange failed", error);
              return;
            }
            c.preferredX = -1;
            this.clearSelection();
            this.refreshCursorRect();
            this.renderCaretPage({ refreshVisible: true });
            this.clearSelectionOverlays();
            this.drawCaret(c);
            this.anchorProxy();
            this.scheduleSnapshot();
          },
          // Normalize a hitTest / moveVertical result into caret state.
          setCaretFromHit(hit, fallbackPage) {
            if (this.hwpClearNativeIme) this.hwpClearNativeIme();
            const cell = hit.parentParaIndex !== void 0 ? {
              parentParaIndex: hit.parentParaIndex,
              controlIndex: hit.controlIndex,
              cellIndex: hit.cellIndex,
              cellParaIndex: hit.cellParaIndex,
              cellPath: hit.cellPath || null,
              isTextBox: !!hit.isTextBox
            } : null;
            const cursorRect = hit.cursorRect || (hit.x !== void 0 ? {
              pageIndex: hit.pageIndex !== void 0 ? hit.pageIndex : fallbackPage,
              x: hit.x,
              y: hit.y,
              height: hit.height
            } : null);
            this.caret = {
              section: hit.sectionIndex !== void 0 ? hit.sectionIndex : this.caret ? this.caret.section : 0,
              // For cell carets the editable paragraph index is cellParaIndex; for body
              // it's paragraphIndex.
              paragraph: hit.paragraphIndex !== void 0 ? hit.paragraphIndex : 0,
              offset: hit.charOffset !== void 0 ? hit.charOffset : 0,
              cell,
              // The native caret hit carries `note` when the click landed on a footnote
              // marker (engine resolved the caret INTO the note). The editor stores it
              // so the caret stays in the footnote on refresh + routes typing there —
              // it just consumes the engine's note caret, no front-end footnote logic.
              note: cell ? null : hit.note || null,
              cursorRect,
              preferredX: -1
            };
            this.caretBlinkOn = true;
            this.drawCaret(this.caret);
            this.anchorProxy();
            this.scheduleToolbarStateSync();
          },
          // One engine call resolves the WHOLE hit: footnote-marker → containing control
          // → cell/paragraph, with engine-computed highlight rects (cell bbox, column-
          // banded line union). The editor does NOT hit-test — that lives in rhwp_core
          // (`pickAtPoint`). Returns the engine pick {type, ref, rects, footnoteNumber?,
          // controlIndex?}; the cell ref is reshaped to the nested {…,cell:{…}} grammar
          // the doc.* tools + text/element helpers consume. Null only if unresolvable.
          hwpPick(hit, pageIndex) {
            if (!this.doc || hit.x === void 0 || hit.y === void 0) return null;
            let pick;
            if (typeof this.doc.pickAtPoint === "function") {
              try {
                pick = JSON.parse(this.doc.pickAtPoint(pageIndex, hit.x, hit.y));
              } catch (_) {
                pick = null;
              }
            }
            const picturePick = this.hwpPicturePickFromLayout(hit, pageIndex);
            if (picturePick) return picturePick;
            if (!pick) pick = this.hwpPickFromHitTest(hit, pageIndex);
            if (!pick) return null;
            if (pick.type === "cell") {
              const r = pick.ref;
              pick.ref = {
                section: r.section,
                paragraph: r.parentParaIndex,
                offset: 0,
                cell: {
                  parentParaIndex: r.parentParaIndex,
                  controlIndex: r.controlIndex,
                  cellIndex: r.cellIndex,
                  cellParaIndex: r.cellParaIndex,
                  cellPath: r.cellPath || null
                }
              };
            }
            return pick;
          },
          hwpPickFromHitTest(hit, pageIndex) {
            const section = Number(hit.sectionIndex ?? hit.section ?? 0);
            const paragraph = Number(hit.paragraphIndex ?? hit.paragraph);
            if (!Number.isInteger(section) || !Number.isInteger(paragraph)) return null;
            if (hit.cellIndex !== void 0) {
              const parentParaIndex = Number(hit.parentParaIndex);
              const controlIndex = Number(hit.controlIndex);
              const cellIndex = Number(hit.cellIndex);
              const cellParaIndex = Number(hit.cellParaIndex ?? 0);
              if (![parentParaIndex, controlIndex, cellIndex, cellParaIndex].every(Number.isInteger)) return null;
              const cellPath = this.normalizeCellPath(hit.cellPath) || null;
              return {
                type: "cell",
                ref: {
                  section,
                  parentParaIndex,
                  controlIndex,
                  cellIndex,
                  cellParaIndex,
                  cellPath
                },
                rects: this.hwpCellPickRects(section, parentParaIndex, controlIndex, cellIndex, pageIndex)
              };
            }
            const rects = this.hwpParagraphPickRects(section, paragraph, pageIndex);
            return {
              type: "paragraph",
              ref: {
                section,
                paragraph,
                offset: Number.isInteger(Number(hit.charOffset)) ? Number(hit.charOffset) : 0
              },
              rects: rects.length > 0 ? rects : this.hwpPointPickRect(hit, pageIndex)
            };
          },
          hwpPointPickRect(hit, pageIndex) {
            const x = Number(hit && hit.x);
            const y = Number(hit && hit.y);
            if (!Number.isFinite(x) || !Number.isFinite(y)) return [];
            const size = HWP_PICK_POINT_RECT_SIZE;
            return [{
              pageIndex,
              x: Math.max(0, x - size / 2),
              y: Math.max(0, y - size / 2),
              width: size,
              height: size,
              fallbackPoint: true
            }];
          },
          hwpParagraphPickRects(section, paragraph, pageIndex) {
            let len = 0;
            try {
              len = this.paragraphLength(section, paragraph);
            } catch (_) {
              len = 0;
            }
            if (!(len > 0) || !this.doc || typeof this.doc.getSelectionRects !== "function") return [];
            try {
              const raw = JSON.parse(this.doc.getSelectionRects(section, paragraph, 0, paragraph, len) || "[]");
              if (!Array.isArray(raw)) return [];
              return raw.map((rect) => this.normalizeHwpPickRect(rect, pageIndex)).filter(Boolean);
            } catch (_) {
              return [];
            }
          },
          hwpCellPickRects(section, parentParaIndex, controlIndex, cellIndex, pageIndex) {
            if (!this.doc || typeof this.doc.getTableCellBboxes !== "function") return [];
            try {
              const raw = JSON.parse(this.doc.getTableCellBboxes(section, parentParaIndex, controlIndex, pageIndex) || "[]");
              if (!Array.isArray(raw)) return [];
              const box = raw.find((rect) => Number(rect.cellIdx ?? rect.cellIndex) === Number(cellIndex));
              const normalized = box ? this.normalizeHwpPickRect(box, pageIndex) : null;
              return normalized ? [normalized] : [];
            } catch (_) {
              return [];
            }
          },
          normalizeHwpPickRect(rect, pageIndex) {
            if (!rect) return null;
            const x = Number(rect.x ?? 0);
            const y = Number(rect.y ?? 0);
            const width = Number(rect.width ?? rect.w ?? 0);
            const height = Number(rect.height ?? rect.h ?? 0);
            if (!(width > 0 && height > 0)) return null;
            const page = Number(rect.pageIndex ?? pageIndex);
            return {
              pageIndex: Number.isInteger(page) ? page : pageIndex,
              x,
              y,
              width,
              height
            };
          },
          hwpPicturePickFromLayout(hit, pageIndex) {
            const control = this.pictureLayoutControlAtHit(hit, pageIndex);
            if (!control) return null;
            return this.hwpPicturePickFromControl(control, pageIndex);
          },
          pictureLayoutControlAtHit(hit, pageIndex) {
            if (!this.doc || !hit || hit.x === void 0 || hit.y === void 0) return null;
            let controls = [];
            try {
              controls = (JSON.parse(this.doc.getPageControlLayout(pageIndex)) || {}).controls || [];
            } catch (_) {
              return null;
            }
            for (let i = controls.length - 1; i >= 0; i--) {
              const c = controls[i];
              const x = Number(c.x ?? 0);
              const y = Number(c.y ?? 0);
              const w = Number(c.w ?? c.width ?? 0);
              const h = Number(c.h ?? c.height ?? 0);
              if (!(w > 0 && h > 0)) continue;
              if (hit.x < x || hit.x > x + w || hit.y < y || hit.y > y + h) continue;
              const section = Number(c.secIdx ?? c.section ?? 0);
              const paragraph = Number(c.paraIdx ?? c.paragraph);
              const controlIndex = Number(c.controlIdx ?? c.controlIndex ?? c.control);
              if (![section, paragraph, controlIndex].every(Number.isInteger)) continue;
              const cellPath = this.normalizeCellPath(c.cellPath ?? c.cell_path);
              const cellPathJson = cellPath ? JSON.stringify(cellPath) : null;
              try {
                if (cellPathJson) {
                  this.doc.getCellPicturePropertiesByPath(section, paragraph, cellPathJson, controlIndex);
                } else {
                  this.doc.getPictureProperties(section, paragraph, controlIndex);
                }
              } catch (_) {
                continue;
              }
              return {
                section,
                paragraph,
                controlIndex,
                cellPath,
                bbox: { pageIndex, x, y, width: w, height: h }
              };
            }
            return null;
          },
          hwpPicturePickFromControl(control, pageIndex) {
            if (!control) return null;
            const section = Number(control.section ?? 0);
            const paragraph = Number(control.paragraph ?? control.paraIdx);
            const controlIndex = Number(control.controlIndex ?? control.controlIdx ?? control.control);
            if (![section, paragraph, controlIndex].every(Number.isInteger)) return null;
            const element = this.findHwpControlElement(section, paragraph, controlIndex);
            const ref = element && element.ref ? element.ref : control.cellPath ? this.pictureCellRef(section, paragraph, controlIndex, control.cellPath) : { section, paragraph, control: controlIndex, type: "picture" };
            const type = element && element.type || "picture";
            const bbox = control.bbox || {};
            const rect = {
              pageIndex,
              x: Number(bbox.x ?? control.x ?? 0),
              y: Number(bbox.y ?? control.y ?? 0),
              width: Number(bbox.width ?? control.w ?? control.width ?? 0),
              height: Number(bbox.height ?? control.h ?? control.height ?? 0)
            };
            return {
              type,
              ref,
              rects: rect.width > 0 && rect.height > 0 ? [rect] : [],
              controlIndex
            };
          },
          pictureCellRef(section, paragraph, controlIndex, cellPath) {
            const path = this.normalizeCellPath(cellPath);
            if (!path) return { section, paragraph, control: controlIndex, type: "picture" };
            const last = path[path.length - 1];
            return {
              section,
              paragraph,
              control: controlIndex,
              type: "picture",
              cellPath: path,
              cell: {
                parentParaIndex: paragraph,
                controlIndex: path[0].controlIndex,
                cellIndex: last.cellIndex,
                cellParaIndex: last.cellParaIndex,
                cellPath: path
              }
            };
          },
          // The composer pick envelope. Hit resolution + rects are the engine's
          // (`hwpPick`); here we only attach document identity and the element TEXT (a
          // ref→text lookup, not hit-testing).
          hwpPickFromHit(hit, pageIndex) {
            const pick = this.hwpPick(hit, pageIndex);
            if (!pick) return null;
            return this.hwpPickEnvelope(pick, pageIndex, hit);
          },
          hwpPickEnvelope(pick, pageIndex, hit) {
            return {
              document: this.el && this.el.dataset && this.canvasState.documentPath || "",
              backend: "hwp",
              format: this.format || "hwp",
              type: pick.type,
              ref: JSON.stringify(pick.ref),
              text: this.hwpTextForPick(pick),
              rects: pick.rects || [],
              ir: {
                page: pageIndex + 1,
                ref: pick.ref,
                hit,
                footnoteNumber: pick.footnoteNumber,
                controlIndex: pick.controlIndex
              }
            };
          },
          // ref→text for a resolved pick (NOT hit-testing): the note's first paragraph
          // for a footnote; the element text for a paragraph/cell; controls carry none.
          hwpTextForPick(pick) {
            if (pick.type === "footnote") {
              try {
                const info = JSON.parse(
                  this.doc.getFootnoteInfo(pick.ref.section, pick.ref.paragraph, pick.ref.control) || "{}"
                );
                if (Array.isArray(info.texts) && info.texts.length) return String(info.texts[0] || "").trim();
              } catch (_) {
              }
              return "";
            }
            if (pick.type === "paragraph" || pick.type === "cell") {
              const element = this.findHwpElement(pick.ref);
              return element ? element.text || "" : this.hwpTextForRef(pick.ref);
            }
            return "";
          },
          // ─── Image gesture: click = select, drag = move ──────────────────────────
          // Pressing a picture arms a gesture. If released without dragging it's a CLICK
          // → select (pick) the image. If dragged it's a MOVE → one Paper-anchored float
          // committed on release (a ghost box previews; per-mousemove engine calls would
          // corrupt the bin).
          beginImageDrag(control, hit, pageIndex, pick = null) {
            const { bbox } = control;
            const props = JSON.parse(
              this.doc.getPictureProperties(control.section, control.paragraph, control.controlIndex)
            );
            this.imageDrag = {
              mode: "move",
              control,
              hit,
              section: control.section,
              paraIdx: control.paragraph,
              controlIdx: control.controlIndex,
              pageIndex,
              startX: bbox.x,
              startY: bbox.y,
              curX: bbox.x,
              curY: bbox.y,
              w: bbox.width,
              h: bbox.height,
              // px↔HWPUNIT is the engine's job: the move commits through
              // `this.doc.pxToHwpUnit` (authoritative, DPI-based). No hand-rolled scale.
              startMouseX: hit.x,
              startMouseY: hit.y,
              props,
              pick,
              moved: false
            };
            this.dragSelect = null;
          },
          // Resize the SELECTED picture by dragging its corner handle: scales uniformly
          // (keeps aspect) via the engine's setPictureProperties{width,height}. The
          // top-left (inline anchor) stays fixed; the engine reflows around the new size.
          beginImageResize(handle, hit, pageIndex) {
            const props = JSON.parse(
              this.doc.getPictureProperties(handle.section, handle.paraIdx, handle.controlIdx)
            );
            const w = handle.bbox.width;
            const h = handle.bbox.height;
            this.imageDrag = {
              mode: "resize",
              section: handle.section,
              paraIdx: handle.paraIdx,
              controlIdx: handle.controlIdx,
              pageIndex,
              x: handle.bbox.x,
              y: handle.bbox.y,
              curW: w,
              curH: h,
              aspect: w / h,
              // Size commits through `this.doc.pxToHwpUnit` — the engine owns px↔HWPUNIT.
              props,
              moved: false
            };
            this.dragSelect = null;
          },
          updateImageDrag(event) {
            const drag = this.imageDrag;
            if (!drag) return;
            const hitInfo = this.hitTestEvent(event, drag.pageIndex);
            if (!hitInfo || hitInfo.hit.x === void 0) return;
            if (drag.mode === "resize") {
              const newW = Math.max(20, hitInfo.hit.x - drag.x);
              const newH = newW / drag.aspect;
              if (Math.abs(newW - drag.curW) > 1) drag.moved = true;
              drag.curW = newW;
              drag.curH = newH;
              this.clearSelection();
              this.drawImageDragGhost({ pageIndex: drag.pageIndex, curX: drag.x, curY: drag.y, w: newW, h: newH });
              if (event.cancelable) event.preventDefault();
              return;
            }
            const nx = Math.max(0, drag.startX + (hitInfo.hit.x - drag.startMouseX));
            const ny = Math.max(0, drag.startY + (hitInfo.hit.y - drag.startMouseY));
            if (!drag.moved && Math.hypot(nx - drag.startX, ny - drag.startY) < 4) return;
            drag.moved = true;
            drag.curX = nx;
            drag.curY = ny;
            this.clearSelection();
            this.drawImageDragGhost(drag);
            if (event.cancelable) event.preventDefault();
          },
          endImageDrag() {
            const drag = this.imageDrag;
            this.imageDrag = null;
            if (!drag) return;
            this.clearImageDragGhost(drag.pageIndex);
            if (drag.mode === "resize") {
              if (!drag.moved) {
                this.paintPickedHighlights();
                return;
              }
              const next = this.pictureGeometryProps(drag.props, {
                width: this.doc.pxToHwpUnit(drag.curW),
                height: this.doc.pxToHwpUnit(drag.curH)
              });
              this.pushHwpUndoCheckpoint("image-resize");
              try {
                this.doc.setPictureProperties(drag.section, drag.paraIdx, drag.controlIdx, JSON.stringify(next));
              } catch (_) {
                return;
              }
              this.renderPage(drag.pageIndex);
              this.scheduleSnapshot();
              this.localImagePick = this.hwpPicturePickFromControl({
                section: drag.section,
                paragraph: drag.paraIdx,
                controlIndex: drag.controlIdx,
                bbox: { pageIndex: drag.pageIndex, x: drag.x, y: drag.y, width: drag.curW, height: drag.curH }
              }, drag.pageIndex);
              if (this.localImagePick) {
                this.localImagePick = this.hwpPickEnvelope(
                  this.localImagePick,
                  drag.pageIndex,
                  { x: drag.x + drag.curW / 2, y: drag.y + drag.curH / 2 }
                );
              }
              this.paintPickedHighlights();
              return;
            }
            if (!drag.moved) {
              this.localImagePick = drag.pick || this.hwpPickFromHit(drag.hit, drag.pageIndex);
              this.clearSelection();
              this.paintPickedHighlights();
              return;
            }
            const floatProps = this.pictureGeometryProps(drag.props, {
              treatAsChar: false,
              horzRelTo: "Paper",
              vertRelTo: "Paper",
              horzAlign: "Left",
              vertAlign: "Top",
              horzOffset: this.doc.pxToHwpUnit(drag.curX),
              vertOffset: this.doc.pxToHwpUnit(drag.curY)
            });
            this.pushHwpUndoCheckpoint("image-move");
            try {
              this.doc.setPictureProperties(drag.section, drag.paraIdx, drag.controlIdx, JSON.stringify(floatProps));
            } catch (_) {
              return;
            }
            this.renderPage(drag.pageIndex);
            this.scheduleSnapshot();
            const movedPick = this.hwpPicturePickFromControl(
              {
                section: drag.section,
                paragraph: drag.paraIdx,
                controlIndex: drag.controlIdx,
                bbox: { pageIndex: drag.pageIndex, x: drag.curX, y: drag.curY, width: drag.w, height: drag.h }
              },
              drag.pageIndex
            );
            this.localImagePick = movedPick ? this.hwpPickEnvelope(movedPick, drag.pageIndex, { x: drag.curX + drag.w / 2, y: drag.curY + drag.h / 2 }) : drag.pick || this.hwpPickFromHit(drag.hit, drag.pageIndex);
            this.paintPickedHighlights();
          },
          // Dashed ghost box (page overlay) showing where a dragged picture will land.
          drawImageDragGhost(drag) {
            const overlay = this.pageOverlay(drag.pageIndex);
            const ctx = overlay && overlay.getContext("2d");
            if (!ctx) return;
            const s = this.pageScale(drag.pageIndex);
            ctx.clearRect(0, 0, overlay.width, overlay.height);
            ctx.save();
            ctx.fillStyle = "rgba(29, 78, 216, 0.10)";
            ctx.strokeStyle = "#1d4ed8";
            ctx.lineWidth = Math.max(1, 1.5 * s);
            ctx.setLineDash([6 * s, 4 * s]);
            ctx.fillRect(drag.curX * s, drag.curY * s, drag.w * s, drag.h * s);
            ctx.strokeRect(drag.curX * s, drag.curY * s, drag.w * s, drag.h * s);
            ctx.restore();
          },
          clearImageDragGhost(pageIndex) {
            const overlay = this.pageOverlay(pageIndex);
            const ctx = overlay && overlay.getContext("2d");
            if (ctx) ctx.clearRect(0, 0, overlay.width, overlay.height);
          },
          pictureGeometryProps(props, overrides = {}) {
            const out = {};
            for (const key of [
              "width",
              "height",
              "treatAsChar",
              "horzRelTo",
              "vertRelTo",
              "horzAlign",
              "vertAlign",
              "horzOffset",
              "vertOffset",
              "textWrap"
            ]) {
              if (props && props[key] !== void 0) out[key] = props[key];
            }
            return Object.assign(out, overrides);
          },
          // Half-size (doc px) of the square resize handle drawn at a selected picture's
          // bottom-right corner.
          IMAGE_HANDLE_HALF: 7,
          // The picture pick's LIVE bbox on `pageIndex`, read from rhwp's control layout
          // (passed in to avoid re-querying). The single source of truth for a picture's
          // selection box + handle — so it always tracks the engine's current geometry.
          pictureLiveRect(pick, pageIndex, layout) {
            if (!/picture|image/i.test(pick.type || "")) return null;
            let ref = {};
            try {
              ref = JSON.parse(pick.ref);
            } catch (_) {
              return null;
            }
            if (ref.control === void 0) return null;
            const c = (layout || []).find(
              (cc) => Number(cc.secIdx ?? 0) === Number(ref.section ?? 0) && Number(cc.paraIdx) === Number(ref.paragraph) && Number(cc.controlIdx) === Number(ref.control)
            );
            return c ? { pageIndex, x: c.x, y: c.y, width: c.w, height: c.h } : null;
          },
          // If the press is on the bottom-right resize handle of a SELECTED picture,
          // return that picture's ref + LIVE bbox (from rhwp's layout); else null.
          pictureResizeHandleAtHit(hit) {
            if (!hit || hit.x === void 0 || hit.y === void 0) return null;
            const H = this.IMAGE_HANDLE_HALF + 2;
            for (const pick of this.documentAdornmentPicks()) {
              if (!/picture|image/i.test(pick.type || "")) continue;
              const pageIndex = ((pick.rects || [])[0] || {}).pageIndex ?? 0;
              let layout = [];
              try {
                layout = (JSON.parse(this.doc.getPageControlLayout(pageIndex)) || {}).controls || [];
              } catch (_) {
                continue;
              }
              const r = this.pictureLiveRect(pick, pageIndex, layout);
              if (!r) continue;
              const hx = r.x + r.width;
              const hy = r.y + r.height;
              if (Math.abs(hit.x - hx) <= H && Math.abs(hit.y - hy) <= H) {
                const ref = JSON.parse(pick.ref);
                return {
                  section: Number(ref.section ?? 0),
                  paraIdx: Number(ref.paragraph),
                  controlIdx: Number(ref.control),
                  bbox: r
                };
              }
            }
            return null;
          },
          findHwpControlElement(section, paragraph, controlIndex) {
            try {
              return this.collectElements().find((el) => {
                const r = el.ref || {};
                return Number(r.section ?? 0) === Number(section) && Number(r.paragraph ?? 0) === Number(paragraph) && Number(r.control ?? -1) === Number(controlIndex);
              }) || null;
            } catch (_) {
              return null;
            }
          },
          findHwpElement(ref) {
            try {
              return this.collectElements().find((el) => this.sameHwpElementRef(el.ref, ref)) || null;
            } catch (_) {
              return null;
            }
          },
          sameHwpElementRef(a, b) {
            if (!a || !b) return false;
            if (Number(a.section ?? 0) !== Number(b.section ?? 0)) return false;
            if (Number(a.paragraph ?? 0) !== Number(b.paragraph ?? 0)) return false;
            if (!!a.cell !== !!b.cell) return false;
            if (!a.cell) return true;
            return Number(a.cell.parentParaIndex ?? a.paragraph) === Number(b.cell.parentParaIndex ?? b.paragraph) && Number(a.cell.controlIndex ?? 0) === Number(b.cell.controlIndex ?? 0) && Number(a.cell.cellIndex ?? 0) === Number(b.cell.cellIndex ?? 0);
          },
          hwpTextForRef(ref) {
            try {
              if (ref.cell) {
                const c = ref.cell;
                const para = c.cellParaIndex ?? 0;
                const len2 = this.doc.getCellParagraphLength(ref.section, c.parentParaIndex, c.controlIndex, c.cellIndex, para);
                return this.doc.getTextInCell(ref.section, c.parentParaIndex, c.controlIndex, c.cellIndex, para, 0, len2) || "";
              }
              const len = this.paragraphLength(ref.section, ref.paragraph);
              return this.doc.getTextRange(ref.section, ref.paragraph, 0, len) || "";
            } catch (_) {
              return "";
            }
          },
          // Repaint EVERY current pick's highlight (multi-select) plus the live hover
          // preview. Clears + repaints the overlays through the normal selection pass
          // so picks, hover, text selection and caret coexist.
          paintPickedHighlights() {
            this.renderSelection();
            const caretPage = this.caret && this.caret.cursorRect ? this.caret.cursorRect.pageIndex : null;
            if (this.caret) this.drawCaret(this.caret);
            const pages = /* @__PURE__ */ new Set();
            for (const pick of this.documentAdornmentPicks()) {
              for (const rect of pick.rects || []) pages.add(rect.pageIndex ?? 0);
            }
            if (this.pickerEnabled() && this.pickerHover) {
              for (const rect of this.pickerHover.rects || []) pages.add(rect.pageIndex ?? 0);
            }
            if (caretPage != null) pages.delete(caretPage);
            for (const page of pages) this.paintAdornmentsOnPage(page);
          },
          currentDocumentPicks() {
            if (this.mirror) return [];
            const picks = pickedElements();
            const docPath = this.canvasState.documentPath || "";
            return picks.filter((p) => p.document === docPath);
          },
          agentSelectionPicks() {
            if (this.mirror) return [];
            const docPath = this.canvasState.documentPath || "";
            const pick = this.localImagePick;
            if (!pick || pick.document !== docPath) return [];
            return [
              {
                document: pick.document || docPath,
                type: pick.type || "image",
                ref: pick.ref || "",
                text: pick.text || "",
                hint: this.agentSelectionHint(pick)
              }
            ];
          },
          agentSelectionHint(pick) {
            let ref = null;
            try {
              ref = JSON.parse(pick.ref || "{}");
            } catch (_error) {
              ref = null;
            }
            const section = Number(ref && ref.section);
            const paragraph = Number(ref && ref.paragraph);
            const control = Number(ref && (ref.control ?? ref.controlIndex));
            if (Number.isInteger(section) && Number.isInteger(paragraph)) {
              const controlPart = Number.isInteger(control) ? `; picture-control order=${control}` : "";
              return `active HWP image selection; VFS nested target section=${section}; paragraph=${paragraph}${controlPart}`;
            }
            return "active HWP image selection";
          },
          documentAdornmentPicks() {
            const picks = this.currentDocumentPicks().slice();
            const docPath = this.canvasState.documentPath || "";
            if (this.localImagePick && this.localImagePick.document === docPath) {
              const key = this.localImagePick.ref || "";
              if (!picks.some((p) => (p.ref || "") === key)) picks.push(this.localImagePick);
            }
            return picks;
          },
          // Paint the selected pick highlights that fall on ONE page's overlay,
          // without clearing it (the caller owns the clear).
          paintAdornmentsOnPage(pageIndex) {
            const overlay = this.pageOverlay(pageIndex);
            if (!overlay) return;
            const ctx = overlay.getContext("2d");
            if (!ctx) return;
            const s = this.pageScale(pageIndex);
            let layout;
            for (const pick of this.documentAdornmentPicks()) {
              const isPicture = /picture|image/i.test(pick.type || "");
              let rects = pick.rects || [];
              if (isPicture) {
                if (layout === void 0) {
                  try {
                    layout = (JSON.parse(this.doc.getPageControlLayout(pageIndex)) || {}).controls || [];
                  } catch (_) {
                    layout = [];
                  }
                }
                const r = this.pictureLiveRect(pick, pageIndex, layout);
                rects = r ? [r] : [];
              }
              for (const rect of rects) {
                if ((rect.pageIndex ?? 0) !== pageIndex) continue;
                ctx.save();
                ctx.fillStyle = "rgba(99, 102, 241, 0.16)";
                ctx.strokeStyle = "rgba(79, 70, 229, 0.95)";
                ctx.lineWidth = Math.max(2, 1.5 * s);
                ctx.fillRect(rect.x * s, rect.y * s, rect.width * s, rect.height * s);
                ctx.strokeRect(rect.x * s, rect.y * s, rect.width * s, rect.height * s);
                if (isPicture) {
                  const hh = this.IMAGE_HANDLE_HALF * s;
                  const hx = (rect.x + (rect.width || 0)) * s;
                  const hy = (rect.y + (rect.height || 0)) * s;
                  ctx.fillStyle = "#4f46e5";
                  ctx.strokeStyle = "#ffffff";
                  ctx.lineWidth = Math.max(1, s);
                  ctx.fillRect(hx - hh, hy - hh, hh * 2, hh * 2);
                  ctx.strokeRect(hx - hh, hy - hh, hh * 2, hh * 2);
                }
                ctx.restore();
              }
            }
            const hover = this.pickerEnabled() ? this.pickerHover : null;
            if (hover) {
              let x1 = Infinity, y1 = Infinity, x2 = -Infinity, y2 = -Infinity;
              for (const rect of hover.rects || []) {
                if ((rect.pageIndex ?? 0) !== pageIndex) continue;
                x1 = Math.min(x1, rect.x);
                y1 = Math.min(y1, rect.y);
                x2 = Math.max(x2, rect.x + (rect.width || 0));
                y2 = Math.max(y2, rect.y + (rect.height || 0));
              }
              if (x2 > x1 && y2 > y1) {
                const pad = 2;
                const bx = (x1 - pad) * s, by = (y1 - pad) * s;
                const bw = (x2 - x1 + pad * 2) * s, bh = (y2 - y1 + pad * 2) * s;
                ctx.save();
                ctx.fillStyle = "rgba(99, 102, 241, 0.18)";
                ctx.strokeStyle = "rgba(79, 70, 229, 0.95)";
                ctx.lineWidth = Math.max(2, 1.5 * s);
                ctx.setLineDash([6 * s, 4 * s]);
                ctx.fillRect(bx, by, bw, bh);
                ctx.strokeRect(bx, by, bw, bh);
                ctx.restore();
              }
            }
          },
          // ─── Picker hover preview (DOM-inspector style) ─────────────────────────
          // rAF-throttle the document-level mousemove: hit-testing every move would
          // hammer the WASM engine while the pointer sweeps across a page.
          queuePickerHover(event) {
            this.pickerHoverEvent = event;
            if (this.pickerHoverRaf) return;
            this.pickerHoverRaf = requestAnimationFrame(() => {
              this.pickerHoverRaf = null;
              this.updatePickerHover(this.pickerHoverEvent);
            });
          },
          updatePickerHover(event) {
            if (!this.pickerEnabled() || !this.doc || !event) {
              this.setPickerHover(null);
              return;
            }
            const overPage = event.target && event.target.closest ? event.target.closest(SEL.hwpPage) : null;
            if (!overPage) {
              this.setPickerHover(null);
              return;
            }
            const hitInfo = this.hitTestEvent(event);
            if (!hitInfo) {
              this.setPickerHover(null);
              return;
            }
            const { hit, pageIndex } = hitInfo;
            const pick = this.hwpPick(hit, pageIndex);
            if (!pick) {
              this.setPickerHover(null);
              return;
            }
            const rects = (pick.rects || []).filter((rect) => rect && !rect.fallbackPoint).map((rect) => ({ ...rect, pageIndex: rect.pageIndex ?? pageIndex }));
            if (rects.length === 0) {
              this.setPickerHover(null);
              return;
            }
            const key = JSON.stringify({ type: pick.type, ref: pick.ref, control: pick.controlIndex });
            if (this.pickerHover && this.pickerHover.key === key) return;
            this.setPickerHover({ key, rects });
          },
          setPickerHover(hover) {
            if (!hover && !this.pickerHover) return;
            this.pickerHover = hover;
            this.paintPickedHighlights();
          },
          pickerEnabled() {
            return elementPickerEnabled();
          },
          // bindElementPickerTarget calls this on picker mode changes: every transition
          // starts with a blank hover preview. Picks persist independently.
          onElementPickerState(enabled) {
            if (this.textCursorRaf) {
              cancelAnimationFrame(this.textCursorRaf);
              this.textCursorRaf = null;
            }
            this.textCursorEvent = null;
            this.setTextCursorCanvas(null);
            if (this.pickerHoverRaf) {
              cancelAnimationFrame(this.pickerHoverRaf);
              this.pickerHoverRaf = null;
            }
            this.pickerHoverEvent = null;
            if (enabled) this.localImagePick = null;
            this.setPickerHover(null);
          },
          // Refresh `cursorRect` from the engine for the current caret position. Used
          // after edits whose result JSON gives us the new offset but not coordinates.
          refreshCursorRect() {
            if (!this.caret || !this.doc) return;
            const c = this.caret;
            try {
              let raw;
              if (c.note) {
                raw = this.doc.getCursorRectInFootnote(
                  c.cursorRect ? c.cursorRect.pageIndex : 0,
                  c.note.footnoteIndex,
                  c.note.innerParaIndex,
                  c.offset
                );
              } else if (c.cell) {
                const path = Array.isArray(c.cell.cellPath) && c.cell.cellPath.length > 0 ? c.cell.cellPath.map((step) => ({
                  controlIndex: step.controlIndex,
                  cellIndex: step.cellIndex,
                  cellParaIndex: step.cellParaIndex
                })) : [{
                  controlIndex: c.cell.controlIndex,
                  cellIndex: c.cell.cellIndex,
                  cellParaIndex: c.cell.cellParaIndex
                }];
                path[path.length - 1].cellParaIndex = c.cell.cellParaIndex;
                const pathJson = JSON.stringify(path);
                const hintPage = Number(c.cursorRect && c.cursorRect.pageIndex);
                if (typeof this.doc.getCursorRectByPathNear === "function" && Number.isInteger(hintPage)) {
                  raw = this.doc.getCursorRectByPathNear(
                    c.section,
                    c.cell.parentParaIndex,
                    pathJson,
                    c.offset,
                    hintPage
                  );
                } else if (typeof this.doc.getCursorRectByPath === "function") {
                  raw = this.doc.getCursorRectByPath(
                    c.section,
                    c.cell.parentParaIndex,
                    pathJson,
                    c.offset
                  );
                } else {
                  raw = this.doc.getCursorRectInCell(
                    c.section,
                    c.cell.parentParaIndex,
                    c.cell.controlIndex,
                    c.cell.cellIndex,
                    c.cell.cellParaIndex,
                    c.offset
                  );
                }
              } else {
                raw = this.doc.getCursorRect(c.section, c.paragraph, c.offset);
              }
              if (raw) c.cursorRect = JSON.parse(raw);
            } catch (error) {
              console.error("[wasm-hwp] getCursorRect failed", error);
            }
            this.scheduleToolbarStateSync();
          },
          // ── Toolbar state reflection (the rhwp-studio 'cursor-format-changed' UX) ──
          // After the caret settles, read the char + para properties AT the caret and
          // broadcast them so the quick toolbar can light up B/I/U/S and the active
          // alignment. rAF-coalesced: a burst of caret moves reads the engine once.
          scheduleToolbarStateSync() {
            if (this.mirror || this.toolbarStateSyncQueued) return;
            this.toolbarStateSyncQueued = true;
            const run = () => {
              if (!this.toolbarStateSyncQueued) return;
              this.toolbarStateSyncQueued = false;
              this.emitToolbarState();
            };
            if (typeof window !== "undefined" && typeof window.requestAnimationFrame === "function") {
              window.requestAnimationFrame(run);
              setTimeout(run, 120);
            } else {
              setTimeout(run, 0);
            }
          },
          emitToolbarState() {
            if (!this.doc) return;
            const c = this.caret || { section: 0, paragraph: 0, offset: 0, cell: null, note: null };
            const offset = Math.max(0, c.offset > 0 ? c.offset - 1 : 0);
            let charProps = {};
            let paraProps = {};
            try {
              const raw = c.cell ? this.doc.getCellCharPropertiesAt(
                c.section,
                c.cell.parentParaIndex,
                c.cell.controlIndex,
                c.cell.cellIndex,
                c.cell.cellParaIndex,
                offset
              ) : this.doc.getCharPropertiesAt(c.section, c.paragraph, offset);
              charProps = typeof raw === "string" ? JSON.parse(raw || "{}") : raw || {};
            } catch (_) {
            }
            try {
              let raw = null;
              if (c.cell && typeof this.doc.getCellParaPropertiesAt === "function") {
                raw = this.doc.getCellParaPropertiesAt(
                  c.section,
                  c.cell.parentParaIndex,
                  c.cell.controlIndex,
                  c.cell.cellIndex,
                  c.cell.cellParaIndex
                );
              } else if (!c.cell && typeof this.doc.getParaPropertiesAt === "function") {
                raw = this.doc.getParaPropertiesAt(c.section, c.paragraph);
              }
              if (raw != null) {
                paraProps = typeof raw === "string" ? JSON.parse(raw || "{}") : raw || {};
              }
            } catch (_) {
            }
            document.dispatchEvent(new CustomEvent(EDITOR_STATE_EVENT, {
              detail: {
                document_id: this.documentId,
                bold: charProps.bold === true,
                italic: charProps.italic === true,
                underline: charProps.underline === true,
                strikethrough: charProps.strikethrough === true,
                bullets: String(paraProps.headType || "").toLowerCase() === "bullet",
                numbering: ["number", "outline"].includes(String(paraProps.headType || "").toLowerCase()),
                alignment: paraProps.alignment || null,
                // Engine stores 1/100pt; the toolbar size field displays points.
                font_size_pt: Number.isFinite(Number(charProps.fontSize)) && Number(charProps.fontSize) > 0 ? Number(charProps.fontSize) / 100 : null,
                font_family: charProps.fontFamily || null,
                line_spacing: Number.isFinite(Number(paraProps.lineSpacing)) && Number(paraProps.lineSpacing) > 0 ? Number(paraProps.lineSpacing) / 100 : null,
                named_style: !c.cell && typeof this.doc.getStyleAt === "function" ? (() => {
                  try {
                    const raw = this.doc.getStyleAt(c.section, c.paragraph);
                    const style = typeof raw === "string" ? JSON.parse(raw || "{}") : raw || {};
                    return style.name || style.englishName || null;
                  } catch (_) {
                    return null;
                  }
                })() : null,
                table_context: !!c.cell
              }
            }));
          },
          // Draw the blinking caret on the page's overlay canvas, in page coords scaled
          // to the overlay backing store (overlay.width == page canvas.width == w*scale).
          drawCaret(caret) {
            const rect = caret && caret.cursorRect;
            if (!rect) return;
            const section = this.pageSection(rect.pageIndex);
            if (!section) return;
            if ((!this.rendered || !this.rendered.get(rect.pageIndex)) && this.doc) this.renderPage(rect.pageIndex);
            const overlay = section.querySelector(SEL.ehwpCaretOverlay);
            if (!overlay) return;
            const ctx = overlay.getContext("2d");
            if (!ctx) return;
            ctx.clearRect(0, 0, overlay.width, overlay.height);
            if (this.sel) this.paintSelectionOnPage(rect.pageIndex);
            this.paintPreviewPatchHighlightOnPage(rect.pageIndex);
            this.paintSavedEditHighlightsOnPage(rect.pageIndex);
            this.paintAdornmentsOnPage(rect.pageIndex);
            if (this.cellSel()) return;
            if (!this.caretBlinkOn) return;
            const s = this.pageScale(rect.pageIndex);
            ctx.fillStyle = "#1d4ed8";
            ctx.fillRect(rect.x * s, rect.y * s, 1.5 * s, (rect.height || 16) * s);
          },
          // Paint just the selection rects that fall on `pageIndex` (used by drawCaret to
          // restore the highlight after it clears the shared overlay for a blink frame).
          paintSelectionOnPage(pageIndex) {
            const cs = this.cellSel();
            if (cs) {
              this.paintCellsOnPage(pageIndex);
              return;
            }
            const ts = this.textSel();
            if (!ts) return;
            const rects = this.textSelectionRects(ts);
            if (!rects.length) return;
            const overlay = this.pageOverlay(pageIndex);
            if (!overlay) return;
            const ctx = overlay.getContext("2d");
            if (!ctx) return;
            const s = this.pageScale(pageIndex);
            ctx.fillStyle = "rgba(29, 78, 216, 0.28)";
            for (const r of rects) {
              if (r.pageIndex !== pageIndex) continue;
              ctx.fillRect(r.x * s, r.y * s, Math.max(1, r.width) * s, Math.max(1, r.height) * s);
            }
          },
          // Keep the browser-owned editable proxy away from the document. The visible
          // composition is ordinary document text rendered by rhwp_core; letting the
          // textarea sit at the caret lets Chromium/macOS paint cached marked text over
          // glyphs.
          anchorProxy() {
            if (!this.imeProxy) return;
            this.imeProxy.style.position = "fixed";
            this.imeProxy.style.left = "-10000px";
            this.imeProxy.style.top = "-10000px";
            this.imeProxy.style.width = "1px";
            this.imeProxy.style.height = "1px";
            this.imeProxy.style.maxWidth = "1px";
            this.imeProxy.style.maxHeight = "1px";
            this.imeProxy.style.fontSize = "1px";
            this.imeProxy.style.lineHeight = "1px";
            this.imeProxy.style.opacity = "0";
            this.imeProxy.style.color = "transparent";
            this.imeProxy.style.webkitTextFillColor = "transparent";
            this.imeProxy.style.caretColor = "transparent";
            this.imeProxy.style.clipPath = "inset(50%)";
            this.imeProxy.style.zIndex = "-1";
          },
          // Left/Right: move the caret offset by ±1. The engine's getCursorRect gives
          // us the new coordinates; paragraph/line boundary crossing is handled by
          // clamping at 0 / paragraph length and stepping to the adjacent paragraph.
          moveHorizontal(dir) {
            const c = this.caret;
            const len = this.caretParagraphLength();
            let offset = c.offset + dir;
            if (offset < 0) {
              if (!c.cell && c.paragraph > 0) {
                c.paragraph -= 1;
                c.offset = this.paragraphLength(c.section, c.paragraph);
              } else {
                c.offset = 0;
              }
            } else if (offset > len) {
              if (!c.cell && c.paragraph + 1 < this.paragraphCount(c.section)) {
                c.paragraph += 1;
                c.offset = 0;
              } else {
                c.offset = len;
              }
            } else {
              c.offset = offset;
            }
            c.preferredX = -1;
            this.refreshCursorRect();
            this.drawCaret(c);
            this.anchorProxy();
          },
          // Up/Down: ask the engine to move vertically, keeping a sticky preferred x so
          // the caret tracks a column down a ragged-right paragraph. moveVertical
          // returns the new position + cursor coords + the preferredX to carry forward.
          moveVertical(dir) {
            const c = this.caret;
            const cell = c.cell;
            const SENTINEL = 4294967295;
            try {
              const raw = this.doc.moveVertical(
                c.section,
                c.paragraph,
                c.offset,
                dir,
                c.preferredX,
                cell ? cell.parentParaIndex : SENTINEL,
                cell ? cell.controlIndex : 0,
                cell ? cell.cellIndex : 0,
                cell ? cell.cellParaIndex : 0
              );
              const r = JSON.parse(raw);
              const preferredX = r.preferredX;
              this.setCaretFromHit(r, c.cursorRect ? c.cursorRect.pageIndex : 0);
              if (typeof preferredX === "number") this.caret.preferredX = preferredX;
            } catch (error) {
              console.error("[wasm-hwp] moveVertical failed", error);
            }
          },
          caretParagraphLength() {
            const c = this.caret;
            try {
              if (c.cell) {
                return this.doc.getCellParagraphLength(
                  c.section,
                  c.cell.parentParaIndex,
                  c.cell.controlIndex,
                  c.cell.cellIndex,
                  c.cell.cellParaIndex
                );
              }
              return this.doc.getParagraphLength(c.section, c.paragraph);
            } catch (_) {
              return c.offset;
            }
          },
          paragraphLength(section, paragraph) {
            try {
              return this.doc.getParagraphLength(section, paragraph);
            } catch (_) {
              return 0;
            }
          },
          // Read a note (footnote/endnote) body sub-paragraph's text via getFootnoteInfo,
          // which returns {ok, paraCount, totalTextLen, number, texts:[...]} for BOTH
          // footnotes and endnotes (the native impl is control-type agnostic). `note`
          // carries {controlIndex, subParaIndex}; returns the sub-paragraph text or ""
          // (so an empty note reads as "" rather than throwing).
          noteParagraphText(section, paragraph, note) {
            try {
              const info = JSON.parse(this.doc.getFootnoteInfo(section, paragraph, note.controlIndex) || "{}");
              const texts = Array.isArray(info.texts) ? info.texts : [];
              const t = texts[note.subParaIndex];
              return typeof t === "string" ? t : "";
            } catch (_) {
              return "";
            }
          },
          paragraphCount(section) {
            try {
              return this.doc.getParagraphCount(section);
            } catch (_) {
              return 1;
            }
          },
          // ─── Agent ops (server -> browser, design §6.2) ──────────────────────────
          // Apply an agent-routed op to the authoritative WASM doc and reply with the
          // result. `verb` is read | find | edit. The reply is always sent (even on
          // error) so the blocked MCP caller never hangs to its timeout.
          handleAgentOp(request) {
            this.agentOpQueue.push(request);
            this.processAgentOpQueue();
          },
          processAgentOpQueue() {
            if (this.agentOpProcessing) return;
            const request = this.agentOpQueue.shift();
            if (!request) return;
            this.agentOpProcessing = true;
            const { request_id, verb, payload } = request;
            const finishMirrorOp = () => {
              this.agentOpProcessing = false;
              this.processAgentOpQueue();
            };
            if (this.mirror && verb !== "edit" && verb !== "set") {
              finishMirrorOp();
              return;
            }
            const replyNow = (body) => {
              if (!this.mirror) this.pushEvent("document.engine.operation.replied", { request_id, ...body });
            };
            const reply = (body, waitForPaint = false) => {
              const send = () => {
                replyNow(body);
                this.agentOpProcessing = false;
                this.processAgentOpQueue();
              };
              if (waitForPaint) {
                this.afterNextPaint(send);
              } else {
                setTimeout(send, 0);
              }
            };
            if (!this.doc) {
              reply({ error: "document_not_loaded" });
              return;
            }
            try {
              switch (verb) {
                case "edit":
                  reply(
                    Array.isArray(payload && payload.ops) ? this.applyAgentEditBatch(payload) : this.applyAgentEdit(payload),
                    true
                  );
                  break;
                case "set":
                  reply(
                    Array.isArray(payload && payload.sets) ? this.applyAgentSetBatch(payload) : this.applyAgentSet(payload),
                    true
                  );
                  break;
                case "find":
                  reply({ result: this.applyAgentFind(payload) });
                  break;
                case "read":
                  reply({ result: this.applyAgentRead(payload) });
                  break;
                case "save":
                  this.exportForSave().then((saved) => reply({ result: saved })).catch((error) => {
                    console.error("[wasm-hwp] save export failed", error);
                    reply({ error: String(error && error.message || error) });
                  });
                  break;
                case "vfs_write":
                  this.applyAgentVfsWrite(payload).then((saved) => reply({ result: saved }, true)).catch((error) => {
                    console.error("[wasm-hwp] VFS write failed", error);
                    reply({ error: String(error && error.message || error) });
                  });
                  break;
                case "vfs_commit":
                  reply({ result: this.commitAgentVfsWrite(payload) });
                  break;
                case "vfs_rollback":
                  reply({ result: this.rollbackAgentVfsWrite(payload) }, true);
                  break;
                default:
                  reply({ error: `unsupported_verb:${verb}` });
              }
            } catch (error) {
              console.error("[wasm-hwp] agent op failed", verb, error);
              reply({ error: String(error && error.message || error) });
            }
          },
          afterNextPaint(callback) {
            if (typeof window.requestAnimationFrame !== "function" || document.visibilityState === "hidden") {
              setTimeout(callback, 0);
              return;
            }
            window.requestAnimationFrame(() => setTimeout(callback, 0));
          },
          // Structural edit verbs over the viewed WASM model: `replace_text`,
          // `insert_text`, `delete_range`. Each addresses text positionally via a `ref`
          // ({section, paragraph, offset} from doc.find) so the agent can target ONE
          // paragraph instead of the whole document. `replace_text` may also run without
          // a ref (global), but only replaces >1 match when `all:true` is set.
          //
          // Single-op entry point: apply the MUTATION (applyOneOp, no render) then run
          // the shared finish (re-render/snapshot) ONCE. The mutation and the
          // finish are deliberately split so the BATCH path (applyAgentEditBatch) can
          // mutate many ops and finish a single time.
          applyAgentEdit({ op }) {
            let r;
            try {
              this.pushHwpUndoCheckpoint("agent-edit");
              r = this.applyOneOp(op);
            } catch (error) {
              return { error: String(error && error.message || error) };
            }
            if (r.error) return { error: r.error };
            return this.finishAgentEdit(r.extra || {});
          },
          // Apply ONE structural edit op to the WASM model and return either
          // `{ ok: true, extra }` (the per-verb result fields the finish should echo) or
          // `{ error }`. This function NEVER renders — that is the
          // caller's job via finishAgentEdit, so a batch can mutate N ops and finish once.
          colorValueToBgr(value) {
            if (Number.isInteger(value)) return value;
            if (typeof value !== "string") return null;
            const match = value.trim().match(/^#?([0-9a-fA-F]{6})$/);
            if (!match) return null;
            const hex = match[1];
            const r = parseInt(hex.slice(0, 2), 16);
            const g = parseInt(hex.slice(2, 4), 16);
            const b = parseInt(hex.slice(4, 6), 16);
            return b << 16 | g << 8 | r;
          },
          colorPropFromOp(op, keys) {
            for (const key of keys) {
              if (op && Object.prototype.hasOwnProperty.call(op, key)) {
                const color = this.colorValueToBgr(op[key]);
                if (color != null) return color;
              }
            }
            return null;
          },
          intPropFromOp(op, keys) {
            for (const key of keys) {
              if (op && Number.isInteger(op[key])) return op[key];
            }
            return null;
          },
          shapeStylePropsFromOp(op) {
            const props = {};
            const fillColor = this.colorPropFromOp(op, [
              "fillBgColor",
              "fillColor",
              "BackgroundColor",
              "backgroundColor",
              "fill_color",
              "background_color"
            ]);
            const fillType = op && (op.fillType != null ? op.fillType : op.fill_type);
            if (fillColor != null) {
              props.fillType = fillType != null ? String(fillType) : "solid";
              props.fillBgColor = fillColor;
              props.fillPatType = -1;
            } else if (fillType != null) {
              props.fillType = String(fillType);
            }
            for (const [target, keys] of [
              ["fillPatColor", ["fillPatColor", "fill_pat_color"]],
              ["fillPatType", ["fillPatType", "fill_pat_type"]],
              ["fillAlpha", ["fillAlpha", "fill_alpha"]],
              ["borderWidth", ["borderWidth", "border_width"]],
              ["lineType", ["lineType", "line_type"]],
              ["roundRate", ["roundRate", "round_rate"]],
              ["rotationAngle", ["rotationAngle", "rotation_angle"]]
            ]) {
              const value = this.intPropFromOp(op, keys);
              if (value != null) props[target] = value;
            }
            const borderColor = this.colorPropFromOp(op, ["borderColor", "border_color", "lineColor", "line_color"]);
            if (borderColor != null) props.borderColor = borderColor;
            return props;
          },
          // ── Doc-edit dispatch ───────────────────────────────────────────
          // Parse the verb + ref ONCE, then dispatch through the chained, typed op
          // registry (assets/js/wasm_ops.ts). Each verb is a standalone handler taking
          // the editor instance as `ctx`; add/override one via WasmHwpEditor.define.
          applyOneOp(op) {
            const verb = op && op.op;
            const ref = this.parseRef(op && op.ref);
            const handler = OPS.registry[verb];
            if (!handler) return { error: `unsupported_op:${verb}` };
            return handler(this, op, ref, verb);
          },
          // "end" -> an appendable position at the document tail: the LAST section's
          // last paragraph (offset = its length) plus appendIndex (= paragraph count)
          // for insert_paragraph's append-after semantics. This is the ref shape the
          // docx authoring guide teaches; agents reuse it on hwp, and rejecting it
          // turned "append 3 sonnets" into a failed batch (live 2026-06-13).
          resolveEndRef(rawRef) {
            if (rawRef !== "end") return null;
            let section = 0;
            try {
              for (const el of this.collectElements()) {
                const s = el.ref && el.ref.section;
                if (Number.isInteger(s) && s > section) section = s;
              }
            } catch (_) {
            }
            let count = 0;
            try {
              count = this.doc.getParagraphCount(section);
            } catch (_) {
            }
            const paragraph = Math.max(0, count - 1);
            let offset = 0;
            try {
              offset = this.paragraphLength(section, paragraph);
            } catch (_) {
            }
            return { section, paragraph, offset, appendIndex: count };
          },
          // Resolve a table edit target from a ref. Table row/col/merge/split ops need the
          // paragraph that HOLDS the table control + the control index; a cell ref carries
          // both (parentParaIndex + controlIndex). Returns null if the ref is not a cell.
          resolveTableTarget(ref) {
            if (ref && ref.cell && Number.isInteger(ref.cell.parentParaIndex) && Number.isInteger(ref.cell.controlIndex)) {
              return {
                section: ref.section,
                paragraph: ref.cell.parentParaIndex,
                control: ref.cell.controlIndex,
                cellIndex: ref.cell.cellIndex
              };
            }
            return null;
          },
          // (row, col) of the picked cell, read from the engine (getCellInfo returns
          // {row,col,rowSpan,colSpan}). Lets "insert a row below THIS cell" work without
          // the agent separately computing the row index.
          cellRowCol(target) {
            try {
              const info = JSON.parse(
                this.doc.getCellInfo(target.section, target.paragraph, target.control, target.cellIndex) || "{}"
              );
              return {
                row: Number.isInteger(info.row) ? info.row : null,
                col: Number.isInteger(info.col) ? info.col : null
              };
            } catch (_) {
              return { row: null, col: null };
            }
          },
          // Extract a bare control index from a raw ref (object or {control}/{controlIndex}).
          // parseRef only keeps a control when it pairs with a note sub-paragraph; a
          // picture/shape control ref carries `control` alone, which delete_node needs.
          rawControlIndex(rawRef) {
            let r = rawRef;
            if (typeof r === "string") {
              try {
                r = JSON.parse(r);
              } catch (_) {
                return null;
              }
            }
            if (r && typeof r === "object") {
              const c = Number(r.control ?? r.controlIndex);
              if (Number.isInteger(c)) return c;
            }
            return null;
          },
          // base64 → Uint8Array (the inverse of bytesToBase64), for inline image bytes.
          base64ToBytes(b64) {
            const binary = atob(String(b64 || ""));
            const bytes = new Uint8Array(binary.length);
            for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
            return bytes;
          },
          singleParagraphText(value) {
            return String(value == null ? "" : value).replace(/\r\n|\r|\n/g, " ").replace(/[ \t]{2,}/g, " ").trim();
          },
          splitTextLines(value) {
            return String(value == null ? "" : value).split(/\r\n|\r|\n/);
          },
          normalizeCellPath(raw) {
            let list = Array.isArray(raw) ? raw : null;
            if (!list && typeof raw === "string" && raw.trim() !== "") {
              try {
                const parsed = JSON.parse(raw);
                if (Array.isArray(parsed)) list = parsed;
              } catch (_) {
                return null;
              }
            }
            if (!list || list.length === 0) return null;
            const path = [];
            for (const step of list) {
              if (!step || typeof step !== "object") return null;
              const controlIndex = Number(step.controlIndex ?? step.control ?? step.ctrlIdx);
              const cellIndex = Number(step.cellIndex ?? step.cell ?? step.cellIdx);
              const cellParaIndex = Number(step.cellParaIndex ?? step.cellPara ?? step.cell_para);
              if (!Number.isInteger(controlIndex) || !Number.isInteger(cellIndex) || !Number.isInteger(cellParaIndex)) {
                return null;
              }
              path.push({ controlIndex, cellIndex, cellParaIndex });
            }
            return path;
          },
          cellPathForPara(ref, cellParaIndex) {
            if (!ref || !Array.isArray(ref.cellPath) || ref.cellPath.length === 0) return null;
            const path = ref.cellPath.map((step) => ({
              controlIndex: step.controlIndex,
              cellIndex: step.cellIndex,
              cellParaIndex: step.cellParaIndex
            }));
            if (Number.isInteger(cellParaIndex)) {
              path[path.length - 1].cellParaIndex = cellParaIndex;
            }
            return path;
          },
          cellPathJson(ref, cellParaIndex) {
            const path = this.cellPathForPara(ref, cellParaIndex);
            return path ? JSON.stringify(path) : null;
          },
          cellParagraphCount(ref, cell) {
            const pathJson = this.cellPathJson(ref, 0);
            if (pathJson && typeof this.doc.getCellParagraphCountByPath === "function") {
              return this.doc.getCellParagraphCountByPath(ref.section, cell.parentParaIndex, pathJson);
            }
            return this.doc.getCellParagraphCount(ref.section, cell.parentParaIndex, cell.controlIndex, cell.cellIndex);
          },
          cellParagraphLength(ref, cell, cellParaIndex) {
            const pathJson = this.cellPathJson(ref, cellParaIndex);
            if (pathJson && typeof this.doc.getCellParagraphLengthByPath === "function") {
              return this.doc.getCellParagraphLengthByPath(ref.section, cell.parentParaIndex, pathJson);
            }
            return this.doc.getCellParagraphLength(
              ref.section,
              cell.parentParaIndex,
              cell.controlIndex,
              cell.cellIndex,
              cellParaIndex
            );
          },
          getTextInCellRef(ref, cell, cellParaIndex, offset, count) {
            const pathJson = this.cellPathJson(ref, cellParaIndex);
            if (pathJson && typeof this.doc.getTextInCellByPath === "function") {
              return this.doc.getTextInCellByPath(ref.section, cell.parentParaIndex, pathJson, offset, count);
            }
            return this.doc.getTextInCell(
              ref.section,
              cell.parentParaIndex,
              cell.controlIndex,
              cell.cellIndex,
              cellParaIndex,
              offset,
              count
            );
          },
          insertTextInCellRef(ref, cell, cellParaIndex, offset, text) {
            const pathJson = this.cellPathJson(ref, cellParaIndex);
            if (pathJson && typeof this.doc.insertTextInCellByPath === "function") {
              return this.doc.insertTextInCellByPath(ref.section, cell.parentParaIndex, pathJson, offset, text);
            }
            return this.doc.insertTextInCell(
              ref.section,
              cell.parentParaIndex,
              cell.controlIndex,
              cell.cellIndex,
              cellParaIndex,
              offset,
              text
            );
          },
          deleteTextInCellRef(ref, cell, cellParaIndex, offset, count) {
            const pathJson = this.cellPathJson(ref, cellParaIndex);
            if (pathJson && typeof this.doc.deleteTextInCellByPath === "function") {
              return this.doc.deleteTextInCellByPath(ref.section, cell.parentParaIndex, pathJson, offset, count);
            }
            return this.doc.deleteTextInCell(
              ref.section,
              cell.parentParaIndex,
              cell.controlIndex,
              cell.cellIndex,
              cellParaIndex,
              offset,
              count
            );
          },
          splitParagraphInCellRef(ref, cell, cellParaIndex, offset) {
            const pathJson = this.cellPathJson(ref, cellParaIndex);
            if (pathJson && typeof this.doc.splitParagraphInCellByPath === "function") {
              return this.doc.splitParagraphInCellByPath(ref.section, cell.parentParaIndex, pathJson, offset);
            }
            return this.doc.splitParagraphInCell(
              ref.section,
              cell.parentParaIndex,
              cell.controlIndex,
              cell.cellIndex,
              cellParaIndex,
              offset
            );
          },
          mergeParagraphInCellRef(ref, cell, cellParaIndex) {
            const pathJson = this.cellPathJson(ref, cellParaIndex);
            if (pathJson && typeof this.doc.mergeParagraphInCellByPath === "function") {
              return this.doc.mergeParagraphInCellByPath(ref.section, cell.parentParaIndex, pathJson);
            }
            return this.doc.mergeParagraphInCell(
              ref.section,
              cell.parentParaIndex,
              cell.controlIndex,
              cell.cellIndex,
              cellParaIndex
            );
          },
          insertTextLines(ref, offset, text) {
            const lines = this.splitTextLines(text);
            this.doc.insertText(ref.section, ref.paragraph, offset, lines[0] || "");
            let para = ref.paragraph;
            let splitOffset = offset + (lines[0] || "").length;
            for (let i = 1; i < lines.length; i++) {
              this.doc.splitParagraph(ref.section, para, splitOffset);
              para += 1;
              const line = lines[i] || "";
              this.doc.insertText(ref.section, para, 0, line);
              splitOffset = line.length;
            }
          },
          insertTextLinesInCell(ref, cell, offset, text) {
            const lines = this.splitTextLines(text);
            let cellPara = cell.cellParaIndex;
            this.insertTextInCellRef(ref, cell, cellPara, offset, lines[0] || "");
            let splitOffset = offset + (lines[0] || "").length;
            for (let i = 1; i < lines.length; i++) {
              this.splitParagraphInCellRef(ref, cell, cellPara, splitOffset);
              cellPara += 1;
              const line = lines[i] || "";
              this.insertTextInCellRef(ref, cell, cellPara, 0, line);
              splitOffset = line.length;
            }
          },
          insertTextLinesInFootnote(ref, note, offset, text) {
            const lines = this.splitTextLines(text);
            let subPara = note.subParaIndex;
            this.doc.insertTextInFootnote(ref.section, ref.paragraph, note.controlIndex, subPara, offset, lines[0] || "");
            let splitOffset = offset + (lines[0] || "").length;
            for (let i = 1; i < lines.length; i++) {
              this.doc.splitParagraphInFootnote(ref.section, ref.paragraph, note.controlIndex, subPara, splitOffset);
              subPara += 1;
              const line = lines[i] || "";
              this.doc.insertTextInFootnote(ref.section, ref.paragraph, note.controlIndex, subPara, 0, line);
              splitOffset = line.length;
            }
          },
          // Batch structural edit (doc.edit {ops:[...]}). Apply every op to the WASM
          // model with ONE re-render/snapshot at the end (finishAgentEdit). This is
          // best-effort: each op is applied independently, a bad ref does NOT abort the
          // rest, and the result carries a per-op `results` array.
          //
          // ORDERING — index-shifting body ops vs. order-independent cell ops:
          // a verb that inserts/removes BODY paragraphs (insert_text whose text has a
          // newline, insert_paragraph, delete_paragraph, split, merge) shifts the
          // paragraph indices AFTER it, invalidating other
          // body refs the agent computed against the pre-edit document. So body
          // index-shifting ops run in REVERSE document order (section desc, then
          // paragraph desc): editing the LAST paragraph first leaves every earlier ref
          // still valid. Cell-targeted ops (ref carries `.cell`) and pure in-place ops
          // address a fixed cell/offset and never move another op's target, so they are
          // order-independent and run first (in their given order).
          applyAgentEditBatch({ ops }) {
            const list = Array.isArray(ops) ? ops : [];
            if (list.length === 0) return { error: "edit batch requires a non-empty 'ops' array" };
            this.pushHwpUndoCheckpoint("agent-edit-batch");
            const tagged = list.map((op, idx) => ({ op, idx, shift: this.opShiftsBodyIndices(op) }));
            const stable = tagged.filter((t) => !t.shift);
            const shifting = tagged.filter((t) => t.shift).sort((a, b) => {
              const ra = this.parseRef(a.op && a.op.ref) || { section: 0, paragraph: 0 };
              const rb = this.parseRef(b.op && b.op.ref) || { section: 0, paragraph: 0 };
              if ((rb.section || 0) !== (ra.section || 0)) return (rb.section || 0) - (ra.section || 0);
              return (rb.paragraph || 0) - (ra.paragraph || 0);
            });
            const ordered = stable.concat(shifting);
            const results = new Array(list.length);
            let applied = 0;
            let failed = 0;
            for (const { op, idx } of ordered) {
              const refStr = op && op.ref != null ? typeof op.ref === "string" ? op.ref : JSON.stringify(op.ref) : null;
              let r;
              try {
                r = this.applyOneOp(op);
              } catch (error) {
                r = { error: String(error && error.message || error) };
              }
              if (r && r.ok) {
                applied++;
                results[idx] = Object.assign({ ref: refStr, ok: true }, r.extra || {});
              } else {
                failed++;
                results[idx] = { ref: refStr, error: r && r.error || "unknown_error" };
              }
            }
            this.finishAgentEdit({});
            return {
              ok: true,
              result: { ok: true, applied, failed, results }
            };
          },
          async applyAgentVfsWrite({ edit_id, editId, ops = [], sets = [] } = {}) {
            const id = String(edit_id || editId || "");
            if (!id) throw new Error("vfs_write requires edit_id");
            if (this.pendingVfsWrites.has(id)) throw new Error(`vfs_write already pending: ${id}`);
            const snapshot = this.saveHwpHistorySnapshot(`vfs-write:${id}`);
            if (!snapshot) throw new Error("vfs_write could not create rollback snapshot");
            const undoLength = Array.isArray(this.undoStack) ? this.undoStack.length : 0;
            const redoLength = Array.isArray(this.redoStack) ? this.redoStack.length : 0;
            const previewBaseUrl = this.createVfsPreviewObjectUrl(id);
            try {
              const editReply = Array.isArray(ops) && ops.length > 0 ? this.applyAgentEditBatch({ ops }) : { ok: true, result: { ok: true, applied: 0, failed: 0, results: [] } };
              if (!editReply || !editReply.ok || !editReply.result || Number(editReply.result.failed || 0) > 0) {
                throw new Error(this.vfsBatchError("edit", editReply));
              }
              const setReply = Array.isArray(sets) && sets.length > 0 ? this.applyAgentSetBatch({ sets }) : { ok: true, result: { ok: true, applied: 0, failed: 0, results: [] } };
              if (!setReply || !setReply.ok || !setReply.result || Number(setReply.result.failed || 0) > 0) {
                throw new Error(this.vfsBatchError("set", setReply));
              }
              const saved = await this.exportForSave();
              this.pendingVfsWrites.set(id, {
                snapshot,
                undoLength,
                redoLength,
                previewBaseUrl
              });
              return {
                ...saved,
                edit_id: id,
                preview_base_url: previewBaseUrl,
                edit: editReply.result,
                set: setReply.result
              };
            } catch (error) {
              this.restoreAgentVfsSnapshot({ snapshot, undoLength, redoLength });
              this.releaseVfsPreviewObjectUrl(id);
              throw error;
            }
          },
          commitAgentVfsWrite({ edit_id, editId } = {}) {
            const id = String(edit_id || editId || "");
            const pending = this.pendingVfsWrites.get(id);
            if (!pending) return { ok: true, edit_id: id, already_finalized: true };
            this.pendingVfsWrites.delete(id);
            this.discardHwpHistorySnapshot(pending.snapshot);
            return { ok: true, edit_id: id };
          },
          rollbackAgentVfsWrite({ edit_id, editId } = {}) {
            const id = String(edit_id || editId || "");
            const pending = this.pendingVfsWrites.get(id);
            if (!pending) return { ok: true, edit_id: id, already_finalized: true };
            this.pendingVfsWrites.delete(id);
            this.restoreAgentVfsSnapshot(pending);
            this.releaseVfsPreviewObjectUrl(id);
            return { ok: true, edit_id: id, rolled_back: true };
          },
          restoreAgentVfsSnapshot({ snapshot, undoLength = 0, redoLength = 0 }) {
            if (snapshot) {
              this.restoreHwpHistorySnapshot(snapshot, "vfs-rollback");
              this.discardHwpHistorySnapshot(snapshot);
            }
            this.trimHwpHistoryTo(this.undoStack, undoLength);
            this.trimHwpHistoryTo(this.redoStack, redoLength);
          },
          trimHwpHistoryTo(stack, length) {
            if (!Array.isArray(stack)) return;
            while (stack.length > length) this.discardHwpHistorySnapshot(stack.pop());
          },
          vfsBatchError(kind, reply) {
            if (reply && reply.error) return `${kind}: ${reply.error}`;
            const results = reply && reply.result && Array.isArray(reply.result.results) ? reply.result.results : [];
            const failed = results.filter((result) => result && result.error).slice(0, 3).map((result) => result.error);
            return `${kind}: ${failed.join("; ") || "batch failed"}`;
          },
          createVfsPreviewObjectUrl(editId) {
            const bytes = this.exportDocumentBytes();
            const blob = new Blob([bytes], {
              type: this.format === "hwpx" ? "application/vnd.hancom.hwpx" : "application/x-hwp"
            });
            const url = URL.createObjectURL(blob);
            const timer = setTimeout(() => this.releaseVfsPreviewObjectUrl(editId), 120000);
            this.vfsPreviewObjectUrls.set(editId, { url, timer });
            return url;
          },
          releaseVfsPreviewObjectUrl(editId) {
            const entry = this.vfsPreviewObjectUrls.get(editId);
            if (!entry) return;
            this.vfsPreviewObjectUrls.delete(editId);
            if (entry.timer) clearTimeout(entry.timer);
            try {
              URL.revokeObjectURL(entry.url);
            } catch (_) {
            }
          },
          // Does this op shift BODY paragraph indices after its target? insert_paragraph,
          // delete_paragraph, split and merge always restructure the body; insert_text
          // only when it authors >1 paragraph (its text contains a newline).
          // delete_range calls deleteText within one paragraph and does not move body
          // paragraph indices, so it must remain in input order with a following
          // insert_text that materializes one replacement. Cell-targeted ops (ref has
          // `.cell`) never move another op's body target, so they are order-independent.
          // Used only to ORDER a batch — never to reject an op.
          opShiftsBodyIndices(op) {
            if (!op || typeof op !== "object") return false;
            const ref = this.parseRef(op.ref);
            if (ref && ref.cell) return false;
            if (ref && ref.note) return false;
            switch (op.op) {
              case "insert_paragraph":
              case "delete_paragraph":
              case "split":
              case "merge":
                return true;
              case "insert_text":
                return typeof op.text === "string" && op.text.includes("\n");
              case "delete_range":
                return false;
              default:
                return false;
            }
          },
          // Universal property set (doc.set) over the viewed WASM model, so a property
          // change RENDERS in the viewer — the server NIF copy is NOT what the user sees,
          // which is why server-side doc.set was invisible for an open doc. `props` is the
          // agent's property map; a `kind` discriminator (if present) is stripped — the
          // engine reads the property KEYS (BackgroundColor/fillColor for a cell;
          // Bold/TextColor/FontSize for a char run). `ref` is doc.find's positional ref; a
          // cell ref carries {parentParaIndex,controlIndex,cellIndex,cellParaIndex}.
          applyAgentSet({ ref, props }) {
            this.pushHwpUndoCheckpoint("agent-set");
            const r = this.applySetOne(ref, props);
            if (r.error) return { error: r.error };
            return this.finishAgentEdit({});
          },
          // Apply ONE property set to the WASM model and return `{ ok: true }` or
          // `{ error }`. Mutate-only — no render (the caller finishes
          // once), so a batch of sets renders a single time.
          applySetOne(ref, props) {
            const parsed = this.parseRef(ref);
            if (!parsed) return { error: "set requires a ref {section,paragraph,offset[,cell]} (from doc.find)" };
            if (props == null || typeof props !== "object") return { error: "set requires a 'props' object" };
            const { kind: rawKind, ...rest } = props;
            if (Object.keys(rest).length === 0) return { error: "set requires at least one property in 'props'" };
            const propJson = JSON.stringify(rest);
            const kind = rawKind || (parsed.cell ? "cell" : "char");
            if (kind === "cell") {
              const cl = parsed.cell;
              if (!cl) return { error: "set kind:cell needs a cell ref (doc.find a cell, then set its BackgroundColor)" };
              try {
                this.doc.setCellProperties(parsed.section, cl.parentParaIndex, cl.controlIndex, cl.cellIndex, propJson);
              } catch (error) {
                return { error: `setCellProperties failed: ${String(error && error.message || error)}` };
              }
              this.recordOp("AgentSetCell", { section: parsed.section, cell: cl, props: rest });
              return { ok: true };
            }
            if (kind === "picture") {
              const control = this.rawControlIndex(ref);
              if (!Number.isInteger(control)) {
                return { error: "set kind:picture needs a picture ref carrying a control index (doc.find a picture/image element first)" };
              }
              const pictureJson = JSON.stringify(translatePictureProps(rest));
              try {
                if (parsed.cell) {
                  const cellPath = parsed.cell.cellPath ? parsed.cell.cellPath : [{
                    controlIndex: parsed.cell.controlIndex ?? 0,
                    cellIndex: parsed.cell.cellIndex ?? 0,
                    cellParaIndex: parsed.cell.cellParaIndex ?? 0
                  }];
                  const cellPathJson = JSON.stringify(cellPath);
                  this.doc.setCellPicturePropertiesByPath(
                    parsed.section,
                    parsed.cell.parentParaIndex,
                    cellPathJson,
                    control,
                    pictureJson
                  );
                } else {
                  this.doc.setPictureProperties(parsed.section, parsed.paragraph, control, pictureJson);
                }
              } catch (error) {
                return { error: `setPictureProperties failed: ${String(error && error.message || error)}` };
              }
              this.recordOp("AgentSetPicture", { section: parsed.section, para: parsed.paragraph, control, cell: parsed.cell || null, props: rest });
              return { ok: true };
            }
            if (kind === "char") {
              const charJson = JSON.stringify(translateCharProps(rest));
              const start = Number.isInteger(parsed.offset) ? parsed.offset : 0;
              const span = Number(parsed.length ?? parsed.len ?? 0);
              let end = start + (Number.isFinite(span) && span > 0 ? span : 0);
              const cl = parsed.cell;
              if (end <= start) {
                try {
                  end = cl ? this.cellParagraphLength(parsed, cl, cl.cellParaIndex) : this.paragraphLength(parsed.section, parsed.paragraph);
                } catch (_) {
                  end = start;
                }
              }
              try {
                if (cl) {
                  this.doc.applyCharFormatInCell(
                    parsed.section,
                    cl.parentParaIndex,
                    cl.controlIndex,
                    cl.cellIndex,
                    cl.cellParaIndex,
                    start,
                    end,
                    charJson
                  );
                } else {
                  this.doc.applyCharFormat(parsed.section, parsed.paragraph, start, end, charJson);
                }
              } catch (error) {
                return { error: `applyCharFormat failed: ${String(error && error.message || error)}` };
              }
              this.recordOp("AgentSetChar", { section: parsed.section, para: parsed.paragraph, cell: cl, start, end, props: rest });
              return { ok: true };
            }
            if (kind === "para") {
              const paraJson = JSON.stringify(translateParaProps(rest));
              const cl = parsed.cell;
              try {
                if (cl) {
                  this.doc.applyParaFormatInCell(
                    parsed.section,
                    cl.parentParaIndex,
                    cl.controlIndex,
                    cl.cellIndex,
                    cl.cellParaIndex,
                    paraJson
                  );
                } else {
                  this.doc.applyParaFormat(parsed.section, parsed.paragraph, paraJson);
                }
              } catch (error) {
                return { error: `applyParaFormat failed: ${String(error && error.message || error)}` };
              }
              this.recordOp("AgentSetPara", { section: parsed.section, para: parsed.paragraph, cell: cl, props: rest });
              return { ok: true };
            }
            return { error: `set: unsupported kind '${kind}' in the browser editor (supported: cell, char, para, picture)` };
          },
          // Batch property set (doc.set {sets:[{ref,props}, ...]}). Apply every set to
          // the WASM model with ONE re-render/snapshot at the end. Best-effort: a
          // bad ref does NOT abort the rest; the result carries a per-set `results`
          // array. Sets address fixed cells/runs and never move another set's target, so
          // order is irrelevant (applied in the given order).
          applyAgentSetBatch({ sets }) {
            const list = Array.isArray(sets) ? sets : [];
            if (list.length === 0) return { error: "set batch requires a non-empty 'sets' array" };
            this.pushHwpUndoCheckpoint("agent-set-batch");
            const results = [];
            let applied = 0;
            let failed = 0;
            for (const entry of list) {
              const ref = entry && entry.ref;
              const refStr = ref != null ? typeof ref === "string" ? ref : JSON.stringify(ref) : null;
              let r;
              try {
                r = this.applySetOne(ref, entry && entry.props);
              } catch (error) {
                r = { error: String(error && error.message || error) };
              }
              if (r && r.ok) {
                applied++;
                results.push({ ref: refStr, ok: true });
              } else {
                failed++;
                results.push({ ref: refStr, error: r && r.error || "unknown_error" });
              }
            }
            this.finishAgentEdit({});
            return {
              ok: true,
              result: { ok: true, applied, failed, results }
            };
          },
          // A ref is the positional index doc.find returns (a JSON string
          // {section,paragraph,offset}); accept the parsed object too. null when absent.
          parseRef(ref) {
            if (ref == null) return null;
            let r = ref;
            if (typeof ref === "string") {
              try {
                r = JSON.parse(ref);
              } catch (_) {
                const text = ref.trim();
                let match = /^hwp:s(\d+)\/p(\d+)(?:@(\d+))?$/.exec(text);
                if (match) {
                  return {
                    section: Number(match[1]),
                    paragraph: Number(match[2]),
                    offset: Number(match[3] || 0)
                  };
                }
                match = /^hwp:s(\d+)\/p(\d+)\/c(\d+)\+\d+$/.exec(text);
                if (match) {
                  return {
                    section: Number(match[1]),
                    paragraph: Number(match[2]),
                    offset: Number(match[3])
                  };
                }
                return null;
              }
            }
            if (typeof r !== "object") return null;
            const section = Number(r.section ?? r.sectionIndex ?? 0);
            const paragraph = Number(r.paragraph ?? r.paragraphIndex);
            if (!Number.isInteger(paragraph)) return null;
            const offset = Number(r.offset ?? r.charOffset ?? 0);
            const out = { section: Number.isInteger(section) ? section : 0, paragraph, offset: Number.isInteger(offset) ? offset : 0 };
            const length = Number(r.length ?? r.len);
            if (Number.isFinite(length) && length > 0) out.length = length;
            const cellPath = this.normalizeCellPath(r.cellPath ?? r.cell_path);
            if (cellPath) {
              const last = cellPath[cellPath.length - 1];
              out.cellPath = cellPath;
              out.cell = {
                parentParaIndex: paragraph,
                controlIndex: cellPath[0].controlIndex,
                cellIndex: last.cellIndex,
                cellParaIndex: last.cellParaIndex,
                cellPath
              };
              return out;
            }
            const cell = r.cell;
            if (cell && typeof cell === "object") {
              const ppi = Number(cell.parentParaIndex ?? cell.parentPara);
              if (Number.isInteger(ppi)) {
                out.cell = {
                  parentParaIndex: ppi,
                  controlIndex: Number(cell.controlIndex ?? cell.ctrlIdx ?? 0),
                  cellIndex: Number(cell.cellIndex ?? cell.cellIdx ?? 0),
                  cellParaIndex: Number(cell.cellParaIndex ?? cell.cellPara ?? 0)
                };
              }
            }
            const control = Number(r.control ?? r.controlIndex);
            const subPara = Number(r.subParagraph ?? r.subParagraphIndex ?? r.sub_paragraph);
            if (Number.isInteger(control) && Number.isInteger(subPara)) {
              out.note = { controlIndex: control, subParaIndex: subPara };
            }
            return out;
          },
          // Shared post-edit step: re-render the visible window (an edit can reflow any
          // page), redraw the caret, and persist the edited bytes so it survives reload.
          finishAgentEdit(extra) {
            this._elementsCache = null;
            this.hwpFind = null;
            this.rendered.clear();
            this.renderVisiblePages();
            if (this.caret) this.drawCaret(this.caret);
            if (!this.mirror) {
              this.scheduleSnapshot();
              if (this.previewAuthorityLastPayload) {
                window.setTimeout(() => this.publishAuthoritativePreview({
                  ...this.previewAuthorityLastPayload,
                  authority_after_edit: true
                }), 0);
              }
            }
            return { ok: true, result: { ok: true, ...extra } };
          },
          // Best-effort match count from replaceAll's JSON return (shape varies across
          // rhwp builds: {replaced}/{count}/{matches}); default to 1 when it applied.
          replacedCount(raw) {
            if (raw == null) return 1;
            try {
              const j = typeof raw === "string" ? JSON.parse(raw) : raw;
              if (typeof j === "number") return j;
              const n = j.replaced ?? j.count ?? j.matches ?? j.replacedCount;
              return typeof n === "number" ? n : 1;
            } catch (_) {
              const n = Number(raw);
              return Number.isFinite(n) ? n : 1;
            }
          },
          // Literal search over the viewed model -> [{ref, text}] (ref carries the
          // section/paragraph/offset so the agent can target a replace).
          //
          // `all` (or `regex`) flips to discovery mode: enumerate EVERY addressable
          // element — body paragraphs AND table cells (empty ones included, which the
          // literal searchAllText can never surface) — and filter by `pattern` as a
          // regex. This is what lets the agent see the blank boxes in a form template.
          applyAgentFind({ pattern, patterns, case_sensitive, all, regex, type, limit }) {
            if (Array.isArray(patterns)) {
              return {
                results: patterns.map(
                  (p) => this.applyAgentFind({ pattern: p, case_sensitive, all, regex, type, limit })
                )
              };
            }
            if (all || regex || type) return this.applyAgentFindAll(pattern, !!case_sensitive, type, limit);
            const matches = [];
            try {
              const raw = this.doc.searchAllText(String(pattern || ""), !!case_sensitive, true);
              const parsed = raw ? JSON.parse(raw) : [];
              const list = Array.isArray(parsed) ? parsed : parsed.matches || [];
              for (const m of list) {
                const refObj = {
                  section: m.sec ?? m.section ?? m.sectionIndex ?? 0,
                  paragraph: m.para ?? m.paragraph ?? m.paragraphIndex ?? 0,
                  offset: m.charOffset ?? m.offset ?? 0
                };
                const cc = m.cellContext;
                if (cc && cc.parentPara != null) {
                  refObj.cell = {
                    parentParaIndex: cc.parentPara,
                    controlIndex: cc.ctrlIdx ?? 0,
                    cellIndex: cc.cellIdx ?? 0,
                    cellParaIndex: cc.cellPara ?? 0
                  };
                }
                matches.push({ ref: JSON.stringify(refObj), text: m.text ?? pattern });
              }
            } catch (error) {
              console.error("[wasm-hwp] searchAllText failed", error);
            }
            return { pattern, matches: this.limitAgentMatches(matches, limit) };
          },
          // Discovery search: enumerate every element (collectElements) and keep those
          // whose text matches `pattern` as a regex. An empty/missing pattern becomes
          // [\s\S]* so {all:true} lists the WHOLE structure, including empty cells.
          applyAgentFindAll(pattern, caseSensitive, type, limit) {
            const src = pattern == null || pattern === "" ? "[\\s\\S]*" : String(pattern);
            let re;
            try {
              re = new RegExp(src, caseSensitive ? "" : "i");
            } catch (error) {
              return { pattern, error: String(error && error.message ? error.message : error), matches: [] };
            }
            const t = String(type || "").toLowerCase();
            const typeOk = (el) => {
              if (!t) return true;
              const isCell = !!(el.ref && el.ref.cell);
              const isEmpty = !el.text || el.text.trim() === "";
              const isFormField = !!(el.context && String(el.context).trim());
              const kind = el.type || (isCell ? "cell" : "paragraph");
              switch (t) {
                case "fillable":
                  return !!this.fillableKind(el);
                case "cell":
                  return isCell;
                case "empty_cell":
                case "blank_cell":
                  return isCell && isEmpty && isFormField;
                case "filled_cell":
                  return isCell && !isEmpty;
                case "paragraph":
                  return kind === "paragraph";
                case "empty":
                case "blank":
                  return isEmpty;
                // Any IR kind: field, form, picture, shape, table, equation, header, …
                default:
                  return kind === t;
              }
            };
            const MATCH_CAP = Math.min(2e3, Math.max(1, Number(limit || 2e3)));
            const matches = [];
            let truncated = false;
            for (const el of this.collectElements()) {
              if (typeOk(el) && re.test(el.text)) {
                if (matches.length >= MATCH_CAP) {
                  truncated = true;
                  break;
                }
                const m = { ref: JSON.stringify(el.ref), text: el.text, table_cell: !!(el.ref && el.ref.cell) };
                if (el.type) m.type = el.type;
                if (el.context) m.context = el.context;
                if (el.row != null) m.row = el.row;
                if (el.col != null) m.col = el.col;
                const fillableKind = this.fillableKind(el);
                if (fillableKind) m.fillable_kind = fillableKind;
                matches.push(m);
              }
            }
            const out = { pattern, matches };
            if (truncated) out.truncated = true;
            return out;
          },
          isPlaceholderText(text) {
            return !!this.placeholderKind(text);
          },
          placeholderKind(text) {
            const s = String(text || "").trim();
            if (!s || s.startsWith("\u203B")) return null;
            if (s.includes("____")) return "underscore";
            if (s.includes("[]") || /^[□☐]\s*/u.test(s)) return "checkbox";
            if (/[-‐‑‒–—―－─]{4,}.*\(이하/u.test(s)) return "signature_line";
            if (/\(\s{2,}\)/u.test(s)) return "paren_blank";
            if (/[:：]\s{2,}[회년월일원%]/u.test(s)) return "inline_gap";
            if (/[년월일]\s{2,}/u.test(s)) return "date_gap";
            if (s.endsWith(":") && s.length <= 80) return "trailing_label";
            return null;
          },
          fillableKind(el) {
            const isCell = !!(el && el.ref && el.ref.cell);
            const text = String(el && el.text || "").trim();
            const kind = el && el.type || (isCell ? "cell" : "paragraph");
            const hasContext = !!(el && el.context && String(el.context).trim());
            if (kind === "cell" && text === "" && hasContext) return "empty_cell";
            if (kind === "field" || kind === "form") return kind;
            if (kind === "paragraph" || kind === "cell") return this.placeholderKind(text);
            return null;
          },
          limitAgentMatches(matches, limit) {
            const n = Number(limit || 0);
            return n > 0 ? matches.slice(0, Math.min(2e3, n)) : matches;
          },
          // Enumerate EVERY addressable element of the viewed model -> [{ref, text}]:
          // every body paragraph plus every table cell (empty cells included). Empty
          // cells are invisible to searchAllText/collectParagraphs but are real edit
          // targets, so this is what powers {all:true} template discovery.
          //
          // Tables are anchored at a body paragraph (s,p); we probe controls c and cells
          // i positionally via getCellParagraphLength, which THROWS once we walk past the
          // last control/cell — that throw is the loop bound. If c===0&&i===0 throws there
          // is no table at (s,p), so we stop probing this paragraph entirely (cheap).
          collectElements() {
            if (this._elementsCache) return this._elementsCache;
            let out = null;
            try {
              out = this.collectElementsViaEngine();
            } catch (e) {
              console.warn("[wasm-hwp] enumerateElements failed; falling back to probe", e);
              out = null;
            }
            if (!out || out.length === 0) out = this.collectElementsProbe();
            this._elementsCache = out;
            return out;
          },
          // Engine-native enumeration: the rhwp_core `enumerateElements()` WASM export
          // walks the FULL IR (every Control kind — table/picture/shape/equation/field/
          // form/header/footer/… plus paragraph/cell) and returns typed nodes. We attach
          // per-cell `context` ("<table title> › <column header> / <row label>") so a
          // blank cell self-describes, and skip pure-layout controls that aren't agent
          // targets. Returns null when the export is absent (older wasm) so collectElements
          // can fall back to the positional probe.
          collectElementsViaEngine() {
            if (!this.doc || typeof this.doc.enumerateElements !== "function") return null;
            let raw;
            try {
              raw = JSON.parse(this.doc.enumerateElements() || "[]");
            } catch (_) {
              return null;
            }
            if (!Array.isArray(raw) || raw.length === 0) return null;
            const SKIP = /* @__PURE__ */ new Set([
              "section_def",
              "column_def",
              "page_number_pos",
              "auto_number",
              "new_number",
              "char_overlap",
              "page_hide"
            ]);
            const grids = {};
            let lastHeading = "";
            for (const el of raw) {
              const isCell = !!(el.ref && el.ref.cell);
              if (el.type === "paragraph" && !isCell) {
                const t = (el.text || "").trim();
                if (t) lastHeading = t;
              } else if (el.type === "cell" && isCell && el.row != null && el.col != null) {
                const key = el.ref.cell.parentParaIndex + ":" + el.ref.cell.controlIndex;
                if (!grids[key]) grids[key] = { byRC: {}, caption: lastHeading };
                grids[key].byRC[el.row + "," + el.col] = el.text || "";
              }
            }
            const out = [];
            for (const el of raw) {
              if (SKIP.has(el.type)) continue;
              const isCell = !!(el.ref && el.ref.cell);
              const o = { ref: el.ref, text: el.text || "", type: el.type };
              if (isCell && el.row != null && el.col != null) {
                o.row = el.row;
                o.col = el.col;
                const g = grids[el.ref.cell.parentParaIndex + ":" + el.ref.cell.controlIndex];
                if (g) {
                  const header = el.row > 0 ? g.byRC["0," + el.col] || "" : "";
                  const rowLabel = el.col > 0 ? g.byRC[el.row + ",0"] || "" : "";
                  const hr = [header, rowLabel].map((x) => (x || "").trim()).filter(Boolean).join(" / ");
                  const parts = [];
                  if (g.caption) parts.push(g.caption);
                  if (hr) parts.push(hr);
                  if (parts.length) o.context = parts.join(" \u203A ");
                }
              }
              out.push(o);
            }
            return out;
          },
          // Fallback positional probe (paragraphs + table cells only) for builds whose
          // wasm predates enumerateElements.
          collectElementsProbe() {
            const ELEM_CAP = 5e3;
            const out = [];
            let sectionCount = 1;
            try {
              sectionCount = this.doc.getSectionCount();
            } catch (_) {
            }
            for (let s = 0; s < sectionCount; s++) {
              let paraCount = 0;
              try {
                paraCount = this.doc.getParagraphCount(s);
              } catch (_) {
                paraCount = 0;
              }
              for (let p = 0; p < paraCount; p++) {
                if (out.length >= ELEM_CAP) break;
                let len = 0;
                try {
                  len = this.doc.getParagraphLength(s, p);
                } catch (_) {
                  len = 0;
                }
                let text = "";
                try {
                  text = this.doc.getTextRange(s, p, 0, len) || "";
                } catch (_) {
                  text = "";
                }
                out.push({ ref: { section: s, paragraph: p, offset: 0 }, text });
                for (let c = 0; c < 8; c++) {
                  let dims = null;
                  try {
                    dims = JSON.parse(this.doc.getTableDimensions(s, p, c));
                  } catch (_) {
                    dims = null;
                  }
                  if (!dims || !(Number(dims.cellCount) > 0)) break;
                  const cellCount = Math.min(Number(dims.cellCount), 512);
                  const cells = [];
                  const byRC = {};
                  for (let i = 0; i < cellCount; i++) {
                    let ctext = "";
                    try {
                      const clen = this.doc.getCellParagraphLength(s, p, c, i, 0);
                      ctext = this.doc.getTextInCell(s, p, c, i, 0, 0, clen) || "";
                    } catch (_) {
                      ctext = "";
                    }
                    let row = null, col = null;
                    try {
                      const ci = JSON.parse(this.doc.getCellInfo(s, p, c, i));
                      row = ci.row;
                      col = ci.col;
                    } catch (_) {
                    }
                    cells.push({ i, text: ctext, row, col });
                    if (row != null && col != null) byRC[row + "," + col] = ctext;
                  }
                  for (const cell of cells) {
                    if (out.length >= ELEM_CAP) break;
                    const el = {
                      ref: {
                        section: s,
                        paragraph: p,
                        offset: 0,
                        cell: { parentParaIndex: p, controlIndex: c, cellIndex: cell.i, cellParaIndex: 0 }
                      },
                      text: cell.text
                    };
                    if (cell.row != null && cell.col != null) {
                      el.row = cell.row;
                      el.col = cell.col;
                      const header = cell.row > 0 ? byRC["0," + cell.col] || "" : "";
                      const rowLabel = cell.col > 0 ? byRC[cell.row + ",0"] || "" : "";
                      const ctx = [header, rowLabel].map((x) => (x || "").trim()).filter(Boolean).join(" / ");
                      if (ctx) el.context = ctx;
                    }
                    out.push(el);
                  }
                }
                if (out.length >= ELEM_CAP) break;
              }
            }
            this._elementsCache = out;
            return out;
          },
          // Clarify a single anchor ref from doc.find. No paging/full-document read.
          applyAgentRead({ opts }) {
            const o = opts || {};
            if (!o.ref) return { error: "doc.read requires ref from doc.find" };
            return this.applyAgentReadNearby(o);
          },
          applyAgentReadNearby(o) {
            const ref = String(o.ref || "");
            const nearby = this.normalizeAgentNearby(o.nearby);
            const elements = this.collectElements();
            const matches = elements.map((el) => this.agentElementMatch(el));
            const candidates = this.agentReadRefCandidates(ref);
            const hit = this.findAgentReadMatch(matches, candidates);
            if (!hit) {
              const table = this.compactAgentTableRead(candidates, nearby);
              return table && !table.error ? { ref, ...table } : { ref, error: "ref not found" };
            }
            const idx = hit.idx;
            const resolvedRef = hit.ref;
            const start = Math.max(0, idx - nearby.before);
            const window2 = matches.slice(start, idx + nearby.after + 1);
            const target = matches[idx];
            const out = {
              ref,
              target,
              elements: window2,
              text: window2.map((m) => m.text || "").join("\n")
            };
            if (resolvedRef !== ref) out.resolved_ref = resolvedRef;
            if (target.type === "cell" || this.tableKeyFromRefString(resolvedRef)) {
              Object.assign(out, this.tableNearby(matches, target, nearby));
            }
            return out;
          },
          findAgentReadMatch(matches, refs) {
            for (const ref of refs) {
              const idx = matches.findIndex((m) => m.ref === ref);
              if (idx >= 0) return { ref, idx };
            }
            return null;
          },
          agentReadRefCandidates(ref) {
            const refs = [String(ref || "")];
            let obj = null;
            try {
              obj = JSON.parse(String(ref || ""));
            } catch (_) {
              obj = null;
            }
            if (obj && typeof obj === "object") {
              if (obj.cell && typeof obj.cell === "object") {
                const sec = Number(obj.section ?? obj.sectionIndex ?? 0);
                const parentPara = Number(obj.cell.parentParaIndex ?? obj.cell.parentPara ?? obj.paragraph);
                const control = Number(obj.cell.controlIndex ?? obj.cell.ctrlIdx);
                const cell = Number(obj.cell.cellIndex ?? obj.cell.cellIdx);
                const cellPara = Number(obj.cell.cellParaIndex ?? obj.cell.cellPara ?? 0);
                if ([sec, parentPara, control, cell, cellPara].every(Number.isInteger)) {
                  refs.push(JSON.stringify({
                    section: sec,
                    paragraph: parentPara,
                    offset: 0,
                    cell: { parentParaIndex: parentPara, controlIndex: control, cellIndex: cell, cellParaIndex: cellPara }
                  }));
                  refs.push(JSON.stringify({ section: sec, paragraph: parentPara, control }));
                }
              } else if (obj.paragraph != null || obj.paragraphIndex != null) {
                const sec = Number(obj.section ?? obj.sectionIndex ?? 0);
                const para = Number(obj.paragraph ?? obj.paragraphIndex);
                if (Number.isInteger(sec) && Number.isInteger(para)) {
                  refs.push(JSON.stringify({ section: sec, paragraph: para, offset: 0 }));
                  refs.push(`hwp:s${sec}/p${para}`);
                }
              }
            }
            const s = String(ref || "");
            let m = /^hwp:s(\d+)\/p(\d+)\/tbl(\d+)\/cell(\d+)\/cp(\d+)\/c\d+\+\d+$/.exec(s);
            if (m) {
              const sec = Number(m[1]);
              const para = Number(m[2]);
              const control = Number(m[3]);
              const cell = Number(m[4]);
              const cellPara = Number(m[5]);
              refs.push(JSON.stringify({
                section: sec,
                paragraph: para,
                offset: 0,
                cell: { parentParaIndex: para, controlIndex: control, cellIndex: cell, cellParaIndex: cellPara }
              }));
            }
            m = /^hwp:s(\d+)\/p(\d+)\/c\d+\+\d+$/.exec(s);
            if (m) {
              const sec = Number(m[1]);
              const para = Number(m[2]);
              refs.push(JSON.stringify({ section: sec, paragraph: para, offset: 0 }));
              refs.push(`hwp:s${sec}/p${para}`);
            }
            return Array.from(new Set(refs.filter(Boolean)));
          },
          normalizeAgentNearby(input) {
            const n = input && typeof input === "object" ? input : {};
            const clamp = (value, fallback) => {
              const x = Number(value);
              return Number.isFinite(x) ? Math.max(0, Math.min(10, Math.floor(x))) : fallback;
            };
            return {
              before: clamp(n.before, 2),
              after: clamp(n.after, 2),
              row: n.row !== false,
              column: n.column === true,
              headers: n.headers !== false
            };
          },
          agentElementMatch(el) {
            const m = {
              ref: JSON.stringify(el.ref),
              text: el.text || "",
              type: el.type || (el.ref && el.ref.cell ? "cell" : "paragraph")
            };
            if (el.context) m.context = el.context;
            if (el.row != null) m.row = el.row;
            if (el.col != null) m.col = el.col;
            return m;
          },
          compactAgentTableRead(ref, nearby) {
            const refs = Array.isArray(ref) ? ref.map((r) => String(r || "")) : [String(ref || "")];
            const refString = refs[0] || "";
            const matches = this.collectElements().map((el) => this.agentElementMatch(el));
            const key = refs.map((r) => this.tableKeyFromRefString(r)).find(Boolean) || (() => {
              const hit = matches.find((m) => refs.includes(m.ref));
              return hit ? this.tableKeyFromRefString(hit.ref) : null;
            })();
            if (!key) return { ref: refString, error: "ref is not a table/cell ref" };
            const cells = matches.filter((m) => m.type === "cell" && this.tableKeyFromRefString(m.ref) === key);
            if (!cells.length) return { ref: refString, error: "no cells for table ref" };
            return this.compactTablePayload(refString, key, cells, null, nearby);
          },
          tableNearby(matches, target, nearby) {
            const key = this.tableKeyFromRefString(target.ref);
            const cells = matches.filter((m) => m.type === "cell" && this.tableKeyFromRefString(m.ref) === key);
            return cells.length ? this.compactTablePayload(target.ref, key, cells, target, nearby) : {};
          },
          compactTablePayload(ref, key, cells, target, nearby) {
            const sorted = cells.slice().sort((a, b) => (a.row || 0) - (b.row || 0) || (a.col || 0) - (b.col || 0));
            const targetRow = target && Number.isInteger(target.row) ? target.row : null;
            const targetCol = target && Number.isInteger(target.col) ? target.col : null;
            const out = {
              table: {
                key,
                anchor: this.tableAnchor(key),
                row_count: new Set(sorted.map((c) => c.row).filter((v) => Number.isInteger(v))).size,
                col_count: new Set(sorted.map((c) => c.col).filter((v) => Number.isInteger(v))).size
              }
            };
            if (nearby.headers) {
              out.table_headers = sorted.filter((c) => c.row === 0).map((c) => ({ col: c.col, text: c.text || "" }));
              out.row_labels = sorted.filter((c) => (c.col || 0) === 0 && (c.row || 0) > 0).filter((c) => String(c.text || "").trim() || c.row === targetRow).map((c) => ({ row: c.row, text: c.text || "" }));
            }
            if (nearby.row && targetRow !== null) {
              out.row = sorted.filter((c) => c.row === targetRow).map((c) => this.compactTableCell(c, ref));
            }
            if (nearby.column && targetCol !== null) {
              out.column = sorted.filter((c) => c.col === targetCol).map((c) => this.compactTableCell(c, ref));
            }
            return out;
          },
          compactTableCell(cell, targetRef) {
            const out = {
              row: cell.row,
              col: cell.col,
              text: cell.text || "",
              type: cell.type || "cell"
            };
            if (cell.context) out.context = cell.context;
            const writable = this.writableCell(cell);
            if (writable) out.writable = true;
            if (writable || cell.ref === targetRef) out.ref = cell.ref;
            return out;
          },
          tableAnchor(key) {
            const m = /^hwp:s(\d+):p(\d+):c(\d+)$/.exec(String(key || ""));
            return m ? { section: Number(m[1]), paragraph: Number(m[2]), control: Number(m[3]) } : { key };
          },
          writableCell(cell) {
            return cell.type === "cell" && String(cell.text || "").trim() === "" && (!!(cell.context && String(cell.context).trim()) || Number.isInteger(cell.row) && Number.isInteger(cell.col) && cell.row > 0 && cell.col > 0);
          },
          tableKeyFromRefString(ref) {
            let obj = null;
            try {
              obj = JSON.parse(String(ref || ""));
            } catch (_) {
              obj = null;
            }
            if (obj && typeof obj === "object") {
              if (obj.cell && typeof obj.cell === "object") {
                const sec2 = Number(obj.section ?? obj.sectionIndex ?? 0);
                const para2 = Number(obj.cell.parentParaIndex ?? obj.cell.parentPara ?? obj.paragraph);
                const control2 = Number(obj.cell.controlIndex ?? obj.cell.ctrlIdx ?? 0);
                if (Number.isInteger(para2) && Number.isInteger(control2)) return `hwp:s${Number.isInteger(sec2) ? sec2 : 0}:p${para2}:c${control2}`;
              }
              const control = Number(obj.control ?? obj.controlIndex);
              const para = Number(obj.paragraph ?? obj.paragraphIndex);
              const sec = Number(obj.section ?? obj.sectionIndex ?? 0);
              if (Number.isInteger(control) && Number.isInteger(para)) return `hwp:s${Number.isInteger(sec) ? sec : 0}:p${para}:c${control}`;
            }
            const m = /^hwp:s(\d+)\/p(\d+)\/tbl(\d+)/.exec(String(ref || ""));
            return m ? `hwp:s${m[1]}:p${m[2]}:c${m[3]}` : null;
          },
          // Flatten body paragraph text across sections via the WASM accessors.
          collectParagraphs() {
            const out = [];
            let sectionCount = 1;
            try {
              sectionCount = this.doc.getSectionCount();
            } catch (_) {
            }
            for (let s = 0; s < sectionCount; s++) {
              let paraCount = 0;
              try {
                paraCount = this.doc.getParagraphCount(s);
              } catch (_) {
                paraCount = 0;
              }
              for (let p = 0; p < paraCount; p++) {
                let len = 0;
                try {
                  len = this.doc.getParagraphLength(s, p);
                } catch (_) {
                  len = 0;
                }
                let text = "";
                try {
                  text = this.doc.getTextRange(s, p, 0, len) || "";
                } catch (_) {
                  text = "";
                }
                out.push(text);
              }
            }
            return out;
          },
          // ─── Op-log + snapshot persistence ───────────────────────────────────────
          hwpHistoryAvailable() {
            return !!(this.doc && !this.mirror && typeof this.doc.saveSnapshot === "function" && typeof this.doc.restoreSnapshot === "function");
          },
          saveHwpHistorySnapshot(reason = "") {
            if (!this.hwpHistoryAvailable()) return null;
            try {
              const id = this.doc.saveSnapshot();
              return Number.isInteger(id) ? { id, reason: String(reason || ""), at: Date.now() } : null;
            } catch (error) {
              console.warn("[wasm-hwp] saveSnapshot failed", error);
              return null;
            }
          },
          discardHwpHistorySnapshot(snapshot) {
            if (!snapshot || !this.doc || typeof this.doc.discardSnapshot !== "function") return;
            const id = Number(snapshot.id ?? snapshot);
            if (!Number.isInteger(id)) return;
            try {
              this.doc.discardSnapshot(id);
            } catch (_) {
            }
          },
          discardHwpHistoryStack(stack) {
            if (!Array.isArray(stack)) return;
            for (const snapshot of stack) this.discardHwpHistorySnapshot(snapshot);
            stack.length = 0;
          },
          clearHwpHistory() {
            this.discardHwpHistoryStack(this.undoStack);
            this.discardHwpHistoryStack(this.redoStack);
            this.undoStack = [];
            this.redoStack = [];
          },
          pushHwpHistoryStack(name, snapshot) {
            if (!snapshot) return false;
            const stack = name === "redo" ? this.redoStack : this.undoStack;
            if (!Array.isArray(stack)) return false;
            stack.push(snapshot);
            while (stack.length > HWP_HISTORY_LIMIT) {
              this.discardHwpHistorySnapshot(stack.shift());
            }
            return true;
          },
          clearHwpRedoHistory() {
            this.discardHwpHistoryStack(this.redoStack);
            this.redoStack = [];
          },
          pushHwpUndoCheckpoint(reason = "") {
            const snapshot = this.saveHwpHistorySnapshot(reason);
            if (!snapshot) return false;
            if (!Array.isArray(this.undoStack)) this.undoStack = [];
            if (!Array.isArray(this.redoStack)) this.redoStack = [];
            this.pushHwpHistoryStack("undo", snapshot);
            this.clearHwpRedoHistory();
            if (this.activateKeyboardShortcuts) this.activateKeyboardShortcuts();
            return true;
          },
          runHwpUndo() {
            return this.restoreHwpHistoryDirection("undo");
          },
          runHwpRedo() {
            return this.restoreHwpHistoryDirection("redo");
          },
          restoreHwpHistoryDirection(direction) {
            if (!this.hwpHistoryAvailable()) return false;
            if (!Array.isArray(this.undoStack)) this.undoStack = [];
            if (!Array.isArray(this.redoStack)) this.redoStack = [];
            const source = direction === "redo" ? this.redoStack : this.undoStack;
            if (!source.length) return false;
            const current = this.saveHwpHistorySnapshot(direction === "redo" ? "undo-current" : "redo-current");
            const target = source.pop();
            const destination = direction === "redo" ? "undo" : "redo";
            if (current) this.pushHwpHistoryStack(destination, current);
            const restored = this.restoreHwpHistorySnapshot(target, direction);
            if (restored) {
              this.discardHwpHistorySnapshot(target);
              return true;
            }
            if (current) {
              const stack = destination === "redo" ? this.redoStack : this.undoStack;
              const last = stack && stack[stack.length - 1];
              if (last && last.id === current.id) stack.pop();
              this.discardHwpHistorySnapshot(current);
            }
            if (target) source.push(target);
            return false;
          },
          restoreHwpHistorySnapshot(snapshot, direction) {
            if (!snapshot || !this.hwpHistoryAvailable()) return false;
            const id = Number(snapshot.id ?? snapshot);
            if (!Number.isInteger(id)) return false;
            try {
              this.doc.restoreSnapshot(id);
            } catch (error) {
              console.warn("[wasm-hwp] restoreSnapshot failed", error);
              return false;
            }
            this.caret = null;
            this.sel = null;
            this.hwpFind = null;
            this.localImagePick = null;
            if (this.imeProxy) this.imeProxy.value = "";
            if (this.clearSelectionOverlays) this.clearSelectionOverlays();
            this._elementsCache = null;
            let nextPageCount = this.pageCount;
            try {
              nextPageCount = this.doc.pageCount();
            } catch (_) {
            }
            if (Number.isInteger(nextPageCount) && nextPageCount !== this.pageCount) {
              this.pageCount = nextPageCount;
              this.buildPageStack();
            }
            this.finishAgentEdit({ history_direction: direction });
            if (this.scheduleToolbarStateSync) this.scheduleToolbarStateSync();
            return true;
          },
          // Push a single edit op to the server's op-log so edits are recoverable even
          // before the next byte snapshot lands. Body mirrors the rhwp DocumentEvent
          // shape the server's `rhwp.text.mutated` handler expects.
          recordOp(type, fields) {
            if (this.mirror) return;
            if (!this.documentId) return;
            this.lamport += 1;
            const eventId = `${this.documentId}:${Date.now()}:${this.lamport}`;
            const body = { type, ...fields };
            if (this.caret && this.caret.cell) {
              body.parentParaIndex = this.caret.cell.parentParaIndex;
              body.controlIndex = this.caret.cell.controlIndex;
              body.cellPath = this.caret.cell.cellPath;
            }
            this.pushEvent("document.content.changed", {
              documentId: this.documentId,
              document_id: this.documentId,
              siteId: window.__rhwpSiteId || "local",
              lamport: this.lamport,
              eventId,
              body
            });
          },
          // Debounced full-document snapshot: serialize the edited doc to its native
          // format and push the bytes so a browser close doesn't lose work. The engine
          // exposes exportHwp/exportHwpx, so this is a real save (not just an op-log).
          scheduleSnapshot() {
            if (this.mirror) return;
            this.hwpFind = null;
            if (this.snapshotTimer) clearTimeout(this.snapshotTimer);
            this.snapshotTimer = setTimeout(() => {
              this.snapshotTimer = null;
              this.pushSnapshot();
            }, SNAPSHOT_IDLE_MS);
          },
          // Export the open doc's current edited bytes for doc.save (the server writes
          // them to disk). Same serializer as the snapshot, but returned synchronously
          // to the doc.save round-trip rather than pushed as a checkpoint.
          exportDocumentBytes() {
            return this.format === "hwpx" ? this.doc.exportHwpx() : this.doc.exportHwp();
          },
          async exportForSave() {
            const bytes = this.exportDocumentBytes();
            return { format: this.format, ...await this.uploadLocalDocumentBytes(bytes) };
          },
          async saveLocalDocument(payload = {}) {
            if (this.mirror) return;
            const requestId = payload.request_id || `local-save:${++this.snapshotSeq}`;
            const documentId = payload.document_id || this.documentId;
            if (!this.doc || !documentId) {
              this.pushEvent("document.viewer.save_requested", {
                request_id: requestId,
                document_id: documentId,
                error: "document_not_loaded"
              });
              return;
            }
            try {
              const saved = await this.exportForSave();
              this.pushEvent("document.viewer.save_requested", {
                request_id: requestId,
                document_id: documentId,
                ...saved
              });
            } catch (error) {
              console.error("[wasm-hwp] save failed", error);
              this.pushEvent("document.viewer.save_requested", {
                request_id: requestId,
                document_id: documentId,
                error: String(error && error.message || error)
              });
            }
          },
          async pushSnapshot() {
            if (this.mirror) return;
            if (!this.doc || !this.documentId) return;
            let bytes;
            try {
              bytes = this.exportDocumentBytes();
            } catch (error) {
              console.error("[wasm-hwp] export failed", error);
              return;
            }
            const requestId = `${this.documentId}:snap:${++this.snapshotSeq}`;
            try {
              const uploaded = await this.uploadLocalDocumentBytes(bytes);
              this.pushEvent("document.snapshot.checkpoint", {
                document_id: this.documentId,
                request_id: requestId,
                format: this.format,
                ...uploaded
              });
            } catch (error) {
              console.error("[wasm-hwp] snapshot upload failed", error);
              this.pushEvent("document.snapshot.checkpoint", {
                document_id: this.documentId,
                request_id: requestId,
                error: String(error && error.message || error)
              });
            }
          },
          async uploadLocalDocumentBytes(bytes) {
            const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
            const headers = { "content-type": "application/octet-stream" };
            const csrf = this.localCsrfToken();
            if (csrf) headers["x-csrf-token"] = csrf;
            const response = await fetch("/local/document-bytes", {
              method: "POST",
              credentials: "same-origin",
              headers,
              body: u8
            });
            if (!response.ok) throw new Error(await this.uploadErrorFromResponse(response));
            const body = await response.json();
            if (!body || !body.bytes_token) throw new Error("document bytes upload returned no token");
            return { bytes_token: body.bytes_token, bytes: body.bytes || u8.length };
          },
          localCsrfToken() {
            return document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || "";
          },
          async uploadErrorFromResponse(response) {
            try {
              const body = await response.json();
              return body?.error || `document bytes upload failed: HTTP ${response.status}`;
            } catch (_) {
              return `document bytes upload failed: HTTP ${response.status}`;
            }
          },
          bytesToBase64(bytes) {
            let binary = "";
            const chunk = 32768;
            for (let i = 0; i < bytes.length; i += chunk) {
              binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
            }
            return btoa(binary);
          }
        };
        WasmHwpEditor.define = (verb, handler) => OPS.define(verb, handler);

        // assets/.hwp_colocated_entry.ts
        var hwp_colocated_entry_default = WasmHwpEditor;
        export {
          HWP_VIEW_STATE_KEYS,
          OPS,
          WasmHwpEditor,
          clearPicks,
          compactPicks,
          hwp_colocated_entry_default as default,
          installHwpViewState,
          keyboardSubsystem,
          pickedElements,
          unexpectedHwpLooseOwnStateKeys
        };
      </script>
    </div>
    """
  end
end
