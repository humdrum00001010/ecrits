defmodule EcritsWeb.Live.Studio.Components.EditorSurface do
  @moduledoc """
  Studio editor chrome reused by local document sessions.
  """

  use EcritsWeb, :html

  alias Ecrits.DocumentCanvasState
  alias Ecrits.DocumentElementPicker
  alias Ecrits.DocumentSearch
  alias Ecrits.EditorPreviewState
  alias Ecrits.EditorSurfaceState
  alias EcritsWeb.Live.Studio.Components.Canvas.HwpPages
  alias EcritsWeb.Live.Studio.Components.Canvas.MarkdownEditor
  alias EcritsWeb.Live.Studio.Components.Canvas.OfficeWasm

  attr :id, :string, default: "studio-root"
  attr :shell_id, :string, required: true
  attr :toolbar_id, :string, required: true
  attr :frame_id, :string, required: true
  attr :state, :any, required: true
  attr :hwp_pages, :any, required: true

  def local_document(%{state: %EditorSurfaceState{}} = assigns) do
    state = assigns.state

    assigns =
      assigns
      |> assign(:canvas_state, DocumentCanvasState.from_editor_surface(state))
      |> assign(
        :document_search_form,
        to_form(%{"query" => state.document_search.query}, as: :document_search)
      )
      |> assign(
        :editor_toolbar_form,
        to_form(
          %{
            "size" =>
              state.editor_toolbar.font_size_pt &&
                to_string(state.editor_toolbar.font_size_pt)
          },
          as: :editor_toolbar
        )
      )
      |> assign(
        :text_color_form,
        to_form(
          %{"command" => "text-color", "color" => state.editor_toolbar.text_color},
          as: :editor_toolbar
        )
      )
      |> assign(
        :highlight_color_form,
        to_form(
          %{"command" => "highlight", "color" => state.editor_toolbar.highlight_color},
          as: :editor_toolbar
        )
      )

    ~H"""
    <div
      id={@shell_id}
      data-component="studio-local-document-surface"
      data-search-state={DocumentSearch.encode(@state.document_search, @state.document)}
      phx-hook=".DocumentSearchBridge"
      phx-window-keydown="document.save.requested"
      phx-key="s"
      class="h-[calc(100vh-60px)] min-h-[calc(100vh-60px)] w-full overflow-hidden"
    >
      <div
        id="document-element-picker-bridge"
        phx-hook=".DocumentElementPickerBridge"
        data-role="document-element-picker-bridge"
        data-picker-state={DocumentElementPicker.encode(@state.document_element_picker)}
        hidden
      >
      </div>
      <div
        id={@id}
        data-component="studio-document-surface"
        class="h-full min-h-0 w-full overflow-hidden"
      >
        <section class="flex h-full min-h-0 min-w-0 flex-col overflow-hidden bg-transparent">
          <div id={@toolbar_id} class="contents">
            <header
              id="studio-document-header"
              class="flex min-h-9 items-stretch justify-between border-b border-base-300 bg-base-100"
            >
              <div
                id="studio-document-tabs"
                role="group"
                aria-label="Open documents"
                data-role="document-tabs"
                class="flex min-w-0 flex-1 items-stretch overflow-hidden"
              >
                <div
                  :for={tab <- @state.open_documents}
                  id={"studio-document-tab-#{tab.id}"}
                  role="presentation"
                  data-role="document-tab"
                  data-tab-id={tab.id}
                  data-active={to_string(tab.id == @state.active_document_id)}
                  title={tab.path}
                  class={[
                    "group flex min-w-0 shrink items-stretch border-r border-base-300 max-w-[15rem] text-[13px] leading-none transition-colors border-b-2",
                    if(tab.id == @state.active_document_id,
                      do: "bg-base-100 text-base-content font-medium border-b-primary",
                      else:
                        "bg-base-200/50 text-base-content/70 border-b-transparent hover:bg-base-100/70 hover:text-base-content"
                    )
                  ]}
                >
                  <button
                    type="button"
                    aria-pressed={to_string(tab.id == @state.active_document_id)}
                    tabindex={if(tab.id == @state.active_document_id, do: "0", else: "-1")}
                    phx-click="workspace.document.activate"
                    phx-value-id={tab.id}
                    data-role="document-tab-switch"
                    class="inline-flex h-full min-w-0 flex-1 items-center gap-1 px-3 text-left outline-none"
                    title={tab.path}
                  >
                    <span
                      :if={tab.id in @state.dirty_document_ids}
                      data-role="document-dirty-icon"
                      class="inline-flex size-4 shrink-0 items-center justify-center text-amber-500"
                      title="Unsaved changes"
                      aria-label="Unsaved changes"
                    >
                      <.icon name="hero-pencil" class="size-3" />
                    </span>
                    <span class="min-w-0 truncate">{tab.name}</span>
                  </button>
                  <button
                    type="button"
                    phx-click="workspace.document.close"
                    phx-value-id={tab.id}
                    data-role="document-tab-close"
                    aria-label={"Close #{tab.name}"}
                    class="my-auto mr-1.5 inline-flex size-6 shrink-0 items-center justify-center rounded text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </div>
              </div>

              <div class="ml-auto inline-flex min-w-0 shrink-0 items-center justify-end gap-1.5 pl-2 pr-3">
                <span
                  id="local-rhwp-save-state"
                  class="hidden max-w-48 truncate text-xs text-base-content/55 2xl:inline"
                  title={@state.save_state}
                >
                  {@state.save_state}
                </span>

                <button
                  id="local-document-element-picker"
                  type="button"
                  phx-click="document.element_picker.toggle"
                  class="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-transparent text-base-content/60 transition-colors hover:border-base-content/15 hover:bg-base-200 hover:text-base-content focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--cs-blue)] data-[active=true]:border-[var(--cs-blue)] data-[active=true]:bg-[color-mix(in_oklab,var(--cs-blue)_12%,transparent)] data-[active=true]:text-[var(--cs-blue)]"
                  aria-label="Pick document element"
                  aria-controls="local-editor-shell local-agent-input"
                  aria-pressed={to_string(@state.document_element_picker.enabled?)}
                  data-active={to_string(@state.document_element_picker.enabled?)}
                  data-role="document-element-picker-toggle"
                  title="Pick document element"
                >
                  <.icon name="hero-cursor-arrow-rays" class="size-4" />
                </button>

                <button
                  id="local-rhwp-fullscreen"
                  type="button"
                  phx-click="workspace.editor_fullscreen.toggle"
                  class="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content"
                  aria-label="Toggle fullscreen"
                  aria-controls="local-editor-shell local-file-tree-panel local-agent-sidebar"
                  aria-pressed={to_string(@state.workspace_layout.editor_fullscreen?)}
                  data-role="editor-fullscreen-toggle"
                  title="Toggle fullscreen"
                >
                  <span
                    data-role="enter-fullscreen"
                    class={
                      if(@state.workspace_layout.editor_fullscreen?,
                        do: "hidden",
                        else: "inline-flex"
                      )
                    }
                  >
                    <.icon name="hero-arrows-pointing-out" class="size-4" />
                  </span>
                  <span
                    data-role="exit-fullscreen"
                    class={
                      if(@state.workspace_layout.editor_fullscreen?,
                        do: "inline-flex",
                        else: "hidden"
                      )
                    }
                  >
                    <.icon name="hero-arrows-pointing-in" class="size-4" />
                  </span>
                </button>
              </div>
            </header>
            <div
              :if={@state.document}
              id="local-document-quick-toolbar"
              phx-hook=".EditorToolbarBridge"
              data-role="local-editor-toolbar"
              class="flex h-9 items-center gap-0.5 overflow-x-auto border-b border-base-300 bg-base-100 px-2"
            >
              <button
                type="button"
                data-command="bold"
                data-active={to_string(@state.editor_toolbar.bold)}
                phx-click="document.toolbar.command"
                phx-value-command="bold"
                aria-label="Bold"
                title="Bold (⌘B)"
                class={quick_toolbar_button_class()}
              >
                <.quick_toolbar_bold_icon />
              </button>
              <button
                type="button"
                data-command="italic"
                data-active={to_string(@state.editor_toolbar.italic)}
                phx-click="document.toolbar.command"
                phx-value-command="italic"
                aria-label="Italic"
                title="Italic (⌘I)"
                class={quick_toolbar_button_class()}
              >
                <.quick_toolbar_italic_icon />
              </button>
              <button
                :if={not markdown_format?(@state.document.format)}
                type="button"
                data-command="underline"
                data-active={to_string(@state.editor_toolbar.underline)}
                phx-click="document.toolbar.command"
                phx-value-command="underline"
                aria-label="Underline"
                title="Underline (⌘U)"
                class={quick_toolbar_button_class()}
              >
                <.quick_toolbar_underline_icon />
              </button>
              <button
                type="button"
                data-command="strikethrough"
                data-active={to_string(@state.editor_toolbar.strikethrough)}
                phx-click="document.toolbar.command"
                phx-value-command="strikethrough"
                aria-label="Strikethrough"
                title="Strikethrough (⌘⇧X)"
                class={quick_toolbar_button_class()}
              >
                <.quick_toolbar_strikethrough_icon />
              </button>
              <span
                :if={not markdown_format?(@state.document.format)}
                aria-hidden="true"
                class="mx-1 h-4 w-px shrink-0 self-center bg-base-300"
              >
              </span>
              <.form
                :if={not markdown_format?(@state.document.format)}
                for={@editor_toolbar_form}
                id="editor-toolbar-font-size-form"
                phx-submit="document.toolbar.font_size_changed"
                class="contents"
              >
                <.input
                  field={@editor_toolbar_form[:size]}
                  id="editor-toolbar-font-size"
                  type="text"
                  inputmode="decimal"
                  data-role="font-size-input"
                  aria-label="Font size (pt)"
                  title="Font size (pt) — Enter to apply"
                  wrapper_class="contents"
                  label_class="contents"
                  class="h-7 w-9 shrink-0 rounded-md border border-base-300 bg-base-100 text-center text-[12px] text-base-content/80 focus:border-[var(--cs-blue)] focus:outline-none"
                />
              </.form>
              <.form
                :if={not markdown_format?(@state.document.format)}
                for={@text_color_form}
                id="editor-toolbar-text-color-form"
                phx-change="document.toolbar.color_changed"
                class="contents"
              >
                <.input
                  field={@text_color_form[:command]}
                  id="editor-toolbar-text-color-command"
                  type="hidden"
                />
                <label
                  for="editor-toolbar-text-color"
                  data-command="text-color"
                  aria-label="Text color"
                  title="Text color"
                  class={[quick_toolbar_button_class(), "relative cursor-pointer"]}
                >
                  <span class="text-[13px] font-semibold leading-none">A</span>
                  <span
                    data-role="text-color-bar"
                    class="absolute bottom-1 left-1.5 right-1.5 h-[3px] rounded-sm"
                    style={"background-color: #{@state.editor_toolbar.text_color}"}
                  >
                  </span>
                </label>
                <.input
                  field={@text_color_form[:color]}
                  id="editor-toolbar-text-color"
                  type="color"
                  data-role="text-color-input"
                  aria-label="Text color picker"
                  wrapper_class="contents"
                  label_class="contents"
                  class="pointer-events-none absolute h-0 w-0 opacity-0"
                  tabindex="-1"
                />
              </.form>
              <.form
                :if={not markdown_format?(@state.document.format)}
                for={@highlight_color_form}
                id="editor-toolbar-highlight-form"
                phx-change="document.toolbar.color_changed"
                class="contents"
              >
                <.input
                  field={@highlight_color_form[:command]}
                  id="editor-toolbar-highlight-command"
                  type="hidden"
                />
                <label
                  for="editor-toolbar-highlight-color"
                  data-command="highlight"
                  aria-label="Highlight color"
                  title="Highlight color"
                  class={[quick_toolbar_button_class(), "relative cursor-pointer"]}
                >
                  <.quick_toolbar_highlight_icon />
                  <span
                    data-role="highlight-color-bar"
                    class="absolute bottom-1 left-1.5 right-1.5 h-[3px] rounded-sm"
                    style={"background-color: #{@state.editor_toolbar.highlight_color}"}
                  >
                  </span>
                </label>
                <.input
                  field={@highlight_color_form[:color]}
                  id="editor-toolbar-highlight-color"
                  type="color"
                  data-role="highlight-color-input"
                  aria-label="Highlight color picker"
                  wrapper_class="contents"
                  label_class="contents"
                  class="pointer-events-none absolute h-0 w-0 opacity-0"
                  tabindex="-1"
                />
              </.form>
              <span
                :if={not markdown_format?(@state.document.format)}
                aria-hidden="true"
                class="mx-1 h-4 w-px shrink-0 self-center bg-base-300"
              >
              </span>
              <details
                :if={not markdown_format?(@state.document.format)}
                data-role="align-dropdown"
                class="relative flex shrink-0"
              >
                <summary
                  data-role="align-menu-button"
                  aria-label="Paragraph alignment"
                  title="Paragraph alignment"
                  class={[
                    "inline-flex h-7 shrink-0 items-center justify-center gap-0.5 rounded-md border border-transparent px-1",
                    "text-base-content/65 transition-colors duration-150",
                    "hover:border-base-content/15 hover:bg-base-200 hover:text-base-content",
                    "focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--cs-blue)]"
                  ]}
                >
                  <span
                    :for={align <- ~w(left center right justify)}
                    data-align-icon={align}
                    class={[
                      "items-center justify-center",
                      if(align == @state.editor_toolbar.alignment, do: "flex", else: "hidden")
                    ]}
                  >
                    <.quick_toolbar_align_icon align={align} />
                  </span>
                  <.icon name="hero-chevron-down" class="size-3 shrink-0 opacity-60" />
                </summary>
                <div
                  data-role="align-menu"
                  role="menu"
                  aria-label="Paragraph alignment"
                  class="absolute left-0 top-8 z-40 min-w-44 rounded-md border border-base-300 bg-base-100 p-1 shadow-lg"
                >
                  <button
                    :for={
                      {align, label, hint} <- [
                        {"left", "Align left", "⌘⇧L"},
                        {"center", "Align center", "⌘⇧E"},
                        {"right", "Align right", "⌘⇧R"},
                        {"justify", "Justify", "⌘⇧J"}
                      ]
                    }
                    type="button"
                    role="menuitem"
                    data-command={"align-#{align}"}
                    data-active={to_string(@state.editor_toolbar.alignment == align)}
                    phx-click="document.toolbar.command"
                    phx-value-command={"align-#{align}"}
                    aria-label={label}
                    class={[
                      "flex w-full items-center gap-2 rounded px-2 py-1.5 text-left text-[13px]",
                      "text-base-content/80 transition-colors hover:bg-base-200",
                      "data-[active=true]:bg-[color-mix(in_oklab,var(--cs-blue)_12%,transparent)]",
                      "data-[active=true]:text-[var(--cs-blue)]"
                    ]}
                  >
                    <.quick_toolbar_align_icon align={align} />
                    <span class="flex-1">{label}</span>
                    <span class="font-mono text-[10px] text-base-content/45">{hint}</span>
                  </button>
                </div>
              </details>
              <span
                :if={not markdown_format?(@state.document.format)}
                aria-hidden="true"
                class="mx-1 h-4 w-px shrink-0 self-center bg-base-300"
              >
              </span>
              <label
                :if={not markdown_format?(@state.document.format)}
                for="editor-toolbar-image-input"
                data-command="image"
                aria-label="Insert image"
                title="Insert image"
                class={[quick_toolbar_button_class(), "cursor-pointer"]}
              >
                <span class="flex size-4 items-center justify-center">
                  <.icon name="hero-photo" class="size-4" />
                </span>
              </label>
              <input
                id="editor-toolbar-image-input"
                type="file"
                accept="image/*"
                data-role="local-editor-toolbar-image-input"
                class="hidden"
              />
              <%!-- Markdown PREVIEW <-> SOURCE toggle, folded in from the old
                   markdown-editor header. LiveView transitions the embedded
                   markdown state consumed by the canvas. --%>
              <button
                :if={markdown_format?(@state.document.format)}
                type="button"
                data-role="markdown-editor-toggle"
                phx-click="document.markdown.view_toggled"
                aria-label="Toggle source and preview"
                title="Toggle source / preview"
                class={["ml-auto", quick_toolbar_button_class()]}
              >
                <span
                  data-toggle-label="preview"
                  class={
                    if(@state.markdown_editor.view == :preview,
                      do: "inline-flex",
                      else: "hidden"
                    )
                  }
                  title="Edit source"
                >
                  <.icon name="hero-code-bracket" class="size-4" />
                </span>
                <span
                  data-toggle-label="source"
                  class={
                    if(@state.markdown_editor.view == :source,
                      do: "inline-flex",
                      else: "hidden"
                    )
                  }
                  title="Show preview"
                >
                  <.icon name="hero-eye" class="size-4" />
                </span>
              </button>
            </div>
          </div>

          <article class="relative m-0 flex min-h-0 flex-1 overflow-hidden border-0 bg-transparent p-0 font-sans text-[15px] leading-[1.78] text-base-content shadow-none">
            <div class="relative h-full min-h-0 w-full">
              <.document_search_bar
                :if={@state.document && not markdown_format?(@state.document.format)}
                state={@state}
                document_search_form={@document_search_form}
              />
              <div :if={@state.document} id={@frame_id} class="contents">
                <HwpPages.render
                  :if={ehwp_format?(@state.document.format)}
                  id={@state.canvas_id}
                  pages={@hwp_pages}
                  state={@canvas_state}
                />
                <MarkdownEditor.render
                  :if={markdown_format?(@state.document.format)}
                  id={@state.canvas_id}
                  state={@canvas_state}
                />
                <OfficeWasm.render
                  :if={
                    not ehwp_format?(@state.document.format) and
                      not markdown_format?(@state.document.format)
                  }
                  id={@state.canvas_id}
                  state={@canvas_state}
                />
              </div>

              <div
                :if={!@state.document && @state.document_loading?}
                id="studio-document-loading-body"
                data-role="document-loading"
                class="flex h-full min-h-0 w-full items-start justify-center gap-2 px-5 py-6 text-sm text-base-content/60"
              >
                <.icon name="hero-arrow-path" class="mt-0.5 size-4 animate-spin" />
                <span class="truncate">
                  Opening {Path.basename(@state.document_path || "document")}
                </span>
              </div>

              <div
                :if={!@state.document && !@state.document_loading?}
                id="studio-document-empty-body"
                class="flex h-full min-h-0 w-full items-start justify-center px-5 py-6 text-sm text-base-content/60"
              >
                This file type can't be rendered in the editor.
              </div>
            </div>
          </article>
        </section>
      </div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DocumentSearchBridge">
        export default {
          searchState() {
            try { return JSON.parse(this.el.dataset.searchState || "{}") }
            catch (_error) { return {} }
          },
          mounted() {
            document.addEventListener("keydown", event => {
              if (event.isComposing || event.altKey || event.repeat) return

              const key = String(event.key || "").toLowerCase()
              const input = event.target?.closest?.("#document-search-input")

              if (key === "enter" && event.shiftKey && input) {
                event.preventDefault()
                this.pushEvent("document.search.previous", {})
                return
              }

              if (key !== "f" || event.shiftKey || !(event.metaKey || event.ctrlKey)) return
              const state = this.searchState()
              if (state.enabled !== true) return

              const editableSelector =
                "input, textarea, select, [contenteditable=''], [contenteditable='true']"
              const targetEditable = event.target?.closest?.(editableSelector)
              const activeEditable = document.activeElement?.closest?.(editableSelector)
              if (targetEditable && !this.el.contains(targetEditable)) return
              if (activeEditable && !this.el.contains(activeEditable)) return

              event.preventDefault()
              this.pushEvent("document.search.open", {
                document_id: state.documentId || ""
              })
            })

            document.addEventListener("ecrits:document-search-result", event => {
              const detail = event.detail || {}
              const documentId = this.searchState().documentId || ""
              if (!documentId || String(detail.document_id || "") !== documentId) return
              this.pushEvent("document.search.result_received", detail)
            })

            this.handleEvent("document.search.command", detail => {
              document.dispatchEvent(
                new CustomEvent("ecrits:document-search-command", {detail})
              )
            })

            if (this.searchState().open === true) {
              const input = this.el.querySelector("#document-search-input")
              if (input) {
                input.focus({preventScroll: true})
                input.select()
              }
            }
          },

          updated() {
            if (this.searchState().open !== true) return
            const input = this.el.querySelector("#document-search-input")
            if (input && document.activeElement !== input) {
              input.focus({preventScroll: true})
            }
          }
        }
      </script>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".DocumentElementPickerBridge">
        let activeHook = null
        const onDomEvent = event => activeHook?.handleDomEvent(event)

        export default {
          pickerState() {
            try { return JSON.parse(this.el.dataset.pickerState || "{}") }
            catch (_error) { return {} }
          },
          mounted() {
            activeHook = this
            document.addEventListener("ecrits:document-element-picker.pick-toggled", onDomEvent)
            document.addEventListener("ecrits:document-element-picker.picks-cleared", onDomEvent)
            document.addEventListener("keydown", onDomEvent)
            this.broadcast()
          },
          updated() {
            this.broadcast()
          },
          destroyed() {
            document.removeEventListener("ecrits:document-element-picker.pick-toggled", onDomEvent)
            document.removeEventListener("ecrits:document-element-picker.picks-cleared", onDomEvent)
            document.removeEventListener("keydown", onDomEvent)
            if (activeHook === this) activeHook = null
          },
          handleDomEvent(event) {
            if (event.type === "ecrits:document-element-picker.pick-toggled") {
              this.pushEvent("document.element_picker.pick.toggle", event.detail || {})
              return
            }
            if (event.type === "ecrits:document-element-picker.picks-cleared") {
              this.pushEvent("document.element_picker.picks.clear", {})
              return
            }
            if (event.key !== "Escape" || this.pickerState().enabled !== true) return
            const picks = this.picks()
            this.pushEvent(
              picks.length > 0
                ? "document.element_picker.picks.clear"
                : "document.element_picker.toggle",
              {}
            )
          },
          picks() {
            const picks = this.pickerState().picks
            return Array.isArray(picks) ? picks : []
          },
          broadcast() {
            const detail = {enabled: this.pickerState().enabled === true, picks: this.picks()}
            this.el.dataset.enabled = String(detail.enabled)
            this.el.dataset.picks = JSON.stringify(detail.picks)
            document.dispatchEvent(
              new CustomEvent("ecrits:document-element-picker.state", {detail})
            )
          }
        }
      </script>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".EditorToolbarBridge">
        const EDITOR_COMMAND_EVENT = "ecrits:editor-command"
        const EDITOR_STATE_EVENT = "ecrits:editor-state"

        export default {
          mounted() {
            this.handleEvent("document.toolbar.command", detail => {
              document.dispatchEvent(new CustomEvent(EDITOR_COMMAND_EVENT, {detail}))
            })

            document.addEventListener(EDITOR_STATE_EVENT, event => {
              this.pushEvent("document.toolbar.state_received", event.detail || {})
            })

            document.addEventListener("keydown", event => {
              if (event.isComposing || event.repeat) return
              const primary = event.metaKey !== event.ctrlKey
              const key = String(event.key || "").toLowerCase()
              const mappedKey =
                (!event.shiftKey && ["b", "i", "u"].includes(key)) ||
                (event.shiftKey && ["x", "l", "e", "r", "j"].includes(key))
              if (!primary || event.altKey || !mappedKey) return

              const surface = this.el.closest("[data-component='studio-document-surface']")
              const editable =
                event.target?.closest?.("input, textarea, select, [contenteditable=''], [contenteditable='true']")
              if (editable && !surface?.contains(editable)) return

              event.preventDefault()
              this.pushEvent("document.toolbar.shortcut_pressed", {
                key,
                meta_key: event.metaKey,
                ctrl_key: event.ctrlKey,
                shift_key: event.shiftKey,
                alt_key: event.altKey
              })
            })

            this.el.addEventListener("change", async event => {
              const input = event.target?.closest?.("[data-role='local-editor-toolbar-image-input']")
              const file = input?.files?.[0]
              if (!file) return
              input.value = ""

              const bytes = new Uint8Array(await file.arrayBuffer())
              let binary = ""
              const chunk = 0x8000
              for (let index = 0; index < bytes.length; index += chunk) {
                binary += String.fromCharCode.apply(null, bytes.subarray(index, index + chunk))
              }

              const size = await new Promise(resolve => {
                const url = URL.createObjectURL(file)
                const image = new Image()
                const done = value => {
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

              this.pushEvent("document.toolbar.image_selected", {
                file_name: file.name || "image",
                mime_type: file.type || "application/octet-stream",
                extension: String(file.name || "").split(".").pop() || "",
                image_base64: btoa(binary),
                natural_width_px: size.width,
                natural_height_px: size.height
              })
            })
          }
        }
      </script>
    </div>
    """
  end

  attr :state, :map, required: true
  attr :document_search_form, :any, required: true

  defp document_search_bar(%{state: %EditorSurfaceState{}} = assigns) do
    ~H"""
    <.form
      for={@document_search_form}
      id="document-search-bar"
      role="search"
      aria-label="Find in document"
      phx-change="document.search.query_changed"
      phx-submit="document.search.next"
      phx-window-keydown="document.search.close"
      phx-key="Escape"
      data-role="document-search-bar"
      hidden={not @state.document_search.open?}
      class="absolute right-4 top-0 z-30 flex items-center gap-1 rounded-b-md border-x border-b border-base-content/20 bg-base-100 py-1 pl-3 pr-2 shadow-lg"
    >
      <.input
        field={@document_search_form[:query]}
        id="document-search-input"
        type="search"
        data-role="find-input"
        aria-label="Find in document"
        placeholder="Find in document"
        autocomplete="off"
        spellcheck="false"
        phx-debounce="150"
        wrapper_class="contents"
        label_class="contents"
        class="h-7 w-44 border-none bg-transparent text-[13px] text-base-content placeholder:text-base-content/40 focus:outline-none"
      />
      <span
        id="document-search-counter"
        data-role="find-counter"
        aria-live="polite"
        class="min-w-14 shrink-0 whitespace-nowrap text-right text-[11px] tabular-nums text-base-content/50"
      >
        {document_search_counter(@state.document_search)}
      </span>
      <button
        id="document-search-prev"
        type="button"
        data-role="find-prev"
        phx-click="document.search.previous"
        aria-label="Previous match"
        title="Previous match (⇧Enter)"
        class={quick_toolbar_button_class()}
      >
        <.icon name="hero-chevron-up" class="size-4" />
      </button>
      <button
        id="document-search-next"
        type="button"
        data-role="find-next"
        phx-click="document.search.next"
        aria-label="Next match"
        title="Next match (Enter)"
        class={quick_toolbar_button_class()}
      >
        <.icon name="hero-chevron-down" class="size-4" />
      </button>
      <button
        id="document-search-close"
        type="button"
        data-role="find-close"
        phx-click="document.search.close"
        aria-label="Close find bar"
        title="Close (Esc)"
        class={quick_toolbar_button_class()}
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </.form>
    """
  end

  attr :id, :string, required: true
  attr :state, :any, required: true

  def embedded_document(%{state: %EditorPreviewState{}} = assigns) do
    ~H"""
    <div
      id={@id}
      data-role="editor-preview"
      data-preview-state={EditorPreviewState.encode(@state)}
      class="min-w-0 overflow-hidden rounded-md border border-base-content/15 bg-base-100"
    >
      <div class="flex min-w-0 items-center gap-2 border-b border-base-content/10 px-2.5 py-1.5">
        <.icon name="hero-pencil-square" class="size-3.5 shrink-0 text-base-content/55" />
        <span class="min-w-0 flex-1 truncate text-[12px] font-medium leading-4 text-base-content/80">
          {embedded_document_title(@state.document, @state.document_path)}
        </span>
        <span
          data-role="editor-preview-delta-count"
          class="shrink-0 font-mono text-[10px] leading-4 text-base-content/45"
        >
          {@state.canvas.preview_delta_count}
        </span>
        <button
          :if={@state.document_path}
          type="button"
          phx-click="workspace.document.open"
          phx-value-path={@state.document_path}
          data-role="editor-preview-open"
          class="inline-flex size-6 shrink-0 items-center justify-center rounded text-base-content/55 transition-colors hover:bg-base-200 hover:text-base-content"
          aria-label="Open in editor"
          title="Open in editor"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
        </button>
      </div>
      <div class="min-h-0 overflow-hidden bg-base-200">
        <%= if @state.preview_url do %>
          <img
            data-role="editor-preview-image"
            src={@state.preview_url}
            alt={
              "Edited region in " <>
                embedded_document_title(@state.document, @state.document_path)
            }
            loading="lazy"
            class={[
              "block max-h-64 min-h-20 w-full bg-white object-contain object-left-top"
            ]}
          />
        <% else %>
          <div class="h-64">
            <HwpPages.render
              :if={ehwp_format?(@state.document.format)}
              id={@state.canvas_id}
              pages={[]}
              state={@state.canvas}
            />
            <MarkdownEditor.render
              :if={markdown_format?(@state.document.format)}
              id={@state.canvas_id}
              state={@state.canvas}
            />
            <OfficeWasm.render
              :if={
                not ehwp_format?(@state.document.format) and
                  not markdown_format?(@state.document.format)
              }
              id={@state.canvas_id}
              state={@state.canvas}
            />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp ehwp_format?(format), do: format in ~w(hwp hwpx)
  defp markdown_format?(format), do: format in ~w(md markdown)

  defp embedded_document_title(_document, path) when is_binary(path) and path != "",
    do: Path.basename(path)

  defp embedded_document_title(%{name: name}, _path) when is_binary(name) and name != "",
    do: name

  defp embedded_document_title(_document, _path), do: "document"

  defp document_search_counter(%{query: ""}), do: ""
  defp document_search_counter(%{total: nil}), do: ""
  defp document_search_counter(%{total: 0}), do: "No matches"

  defp document_search_counter(%{total: total, index: index})
       when is_integer(total) and is_integer(index),
       do: "#{index} of #{total}"

  defp document_search_counter(%{total: total}) when is_integer(total),
    do: "#{total} matches"

  defp quick_toolbar_button_class do
    [
      "inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-md border border-transparent",
      "text-base-content/65 transition-colors duration-150",
      "hover:border-base-content/15 hover:bg-base-200 hover:text-base-content",
      "focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--cs-blue)]",
      "data-[active=true]:bg-[color-mix(in_oklab,var(--cs-blue)_12%,transparent)]",
      "data-[active=true]:text-[var(--cs-blue)]"
    ]
  end

  defp quick_toolbar_bold_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" class="size-4" aria-hidden="true">
      <path
        fill="currentColor"
        transform="translate(-0.35 -0.55)"
        d="M4.75 3.15h4.05c1.78 0 2.88.92 2.88 2.34 0 .95-.51 1.66-1.42 2.02 1.13.33 1.8 1.15 1.8 2.36 0 1.82-1.3 2.98-3.35 2.98H4.75V3.15Zm2.1 1.78v1.86h1.66c.65 0 1.04-.35 1.04-.93 0-.58-.4-.93-1.07-.93H6.85Zm0 3.56v2.56h1.86c.77 0 1.21-.47 1.21-1.29 0-.81-.46-1.27-1.28-1.27H6.85Z"
      />
    </svg>
    """
  end

  defp quick_toolbar_italic_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" class="size-4" aria-hidden="true">
      <path
        fill="currentColor"
        transform="translate(-1.1 -0.55)"
        d="M7.25 3.1h5.15l-.34 1.85h-1.45L9.42 11.05h1.45l-.35 1.85H5.36l.35-1.85h1.46l1.18-6.1H6.9l.35-1.85Z"
      />
    </svg>
    """
  end

  defp quick_toolbar_underline_icon(assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" class="size-4" aria-hidden="true">
      <path
        fill="currentColor"
        d="M4.55 2.9v4.55c0 1.05.28 1.85.85 2.4.57.55 1.4.83 2.5.83s1.93-.28 2.5-.83c.57-.55.85-1.35.85-2.4V2.9h-1.5v4.5c0 .68-.15 1.18-.44 1.5-.29.32-.75.48-1.41.48s-1.12-.16-1.41-.48c-.29-.32-.44-.82-.44-1.5V2.9H4.55Z"
      />
      <rect fill="currentColor" x="3.6" y="12.15" width="8.8" height="1.25" rx="0.45" />
    </svg>
    """
  end

  defp quick_toolbar_highlight_icon(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      class="size-4"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="m9 11-6 6v3h9l3-3" />
      <path d="m22 12-4.6 4.6a2 2 0 0 1-2.8 0l-5.2-5.2a2 2 0 0 1 0-2.8L14 4" />
    </svg>
    """
  end

  defp quick_toolbar_strikethrough_icon(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      class="size-4"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <path d="M16 4H9a3 3 0 0 0-2.83 4" />
      <path d="M14 12a4 4 0 0 1 0 8H6" />
      <line x1="4" x2="20" y1="12" y2="12" />
    </svg>
    """
  end

  attr :align, :string, required: true

  defp quick_toolbar_align_icon(assigns) do
    # Lucide-style alignment glyphs: full-width top/bottom lines, the middle
    # pair placed by alignment (left/center/right/justify).
    assigns =
      assign(
        assigns,
        :middle_lines,
        case assigns.align do
          "left" -> [{3, 15}, {3, 17}]
          "center" -> [{6, 18}, {5, 19}]
          "right" -> [{9, 21}, {7, 21}]
          _justify -> [{3, 21}, {3, 21}]
        end
      )

    ~H"""
    <svg
      viewBox="0 0 24 24"
      class="size-4"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
      aria-hidden="true"
    >
      <line x1="3" x2="21" y1="5" y2="5" />
      <line
        :for={{{x1, x2}, index} <- Enum.with_index(@middle_lines)}
        x1={x1}
        x2={x2}
        y1={10 + index * 4.5}
        y2={10 + index * 4.5}
      />
      <line x1="3" x2="21" y1="19" y2="19" />
    </svg>
    """
  end
end
