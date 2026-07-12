defmodule EcritsWeb.Live.Studio.Components.EditorSurface do
  @moduledoc """
  Studio editor chrome reused by local document sessions.
  """

  use EcritsWeb, :html

  alias EcritsWeb.Live.Studio.Components.Canvas.LocalHwpPages
  alias EcritsWeb.Live.Studio.Components.Canvas.LocalMarkdownEditor
  alias EcritsWeb.Live.Studio.Components.Canvas.LocalOfficeWasm

  attr :id, :string, default: "studio-root"
  attr :shell_id, :string, required: true
  attr :toolbar_id, :string, required: true
  attr :frame_id, :string, required: true
  attr :document, :map, default: nil
  attr :document_path, :string, default: nil
  attr :document_viewport, :map, default: nil
  attr :document_loading?, :boolean, default: false
  attr :document_spec, :map, default: nil
  attr :canvas_id, :string, default: nil
  attr :hwp_bytes_url, :string, default: nil
  attr :save_state, :string, default: nil
  attr :open_documents, :list, default: []
  attr :active_document_id, :string, default: nil
  attr :dirty_document_ids, :any, default: nil
  attr :document_element_picker_enabled, :boolean, default: false
  attr :hwp_pages, :any, required: true
  attr :hwp_page_count, :integer, default: 0
  attr :markdown_source, :string, default: ""
  attr :markdown_preview_html, :any, default: ""

  def local_document(assigns) do
    assigns =
      assign(assigns, :document_path, assigns.document_path || document_path(assigns.document))

    ~H"""
    <div
      id={@shell_id}
      data-component="studio-local-document-surface"
      phx-window-keydown="rhwp_save"
      phx-key="s"
      class="h-[calc(100vh-60px)] min-h-[calc(100vh-60px)] w-full overflow-hidden"
    >
      <div
        id={@id}
        data-component="studio-document-surface"
        data-local-document-id={@document && @document.id}
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
                  :for={tab <- @open_documents}
                  id={"studio-document-tab-#{tab.id}"}
                  role="presentation"
                  data-role="document-tab"
                  data-tab-id={tab.id}
                  data-active={to_string(tab.id == @active_document_id)}
                  title={tab.path}
                  class={[
                    "group flex min-w-0 shrink items-stretch border-r border-base-300 max-w-[15rem] text-[13px] leading-none transition-colors border-b-2",
                    if(tab.id == @active_document_id,
                      do: "bg-base-100 text-base-content font-medium border-b-primary",
                      else:
                        "bg-base-200/50 text-base-content/70 border-b-transparent hover:bg-base-100/70 hover:text-base-content"
                    )
                  ]}
                >
                  <button
                    type="button"
                    aria-pressed={to_string(tab.id == @active_document_id)}
                    tabindex={if(tab.id == @active_document_id, do: "0", else: "-1")}
                    phx-click="tab_switch"
                    phx-value-id={tab.id}
                    data-role="document-tab-switch"
                    class="inline-flex h-full min-w-0 flex-1 items-center gap-1 px-3 text-left outline-none"
                    title={tab.path}
                  >
                    <span
                      :if={@dirty_document_ids && MapSet.member?(@dirty_document_ids, tab.id)}
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
                    phx-click={tab_close_js(tab)}
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
                  title={@save_state}
                >
                  {@save_state}
                </span>

                <button
                  id="local-mobile-open-chat"
                  type="button"
                  data-role="mobile-open-chat"
                  aria-controls="local-editor-shell local-agent-sidebar"
                  aria-pressed="false"
                  class="hidden h-8 shrink-0 items-center gap-1.5 rounded-md border border-base-300 bg-base-100 px-2 text-xs text-base-content/70 transition-colors hover:border-base-content/25 hover:text-base-content"
                  title="Show chat"
                >
                  <.icon name="hero-chat-bubble-left-right" class="size-4" />
                  <span>Chat</span>
                </button>

                <button
                  id="local-document-element-picker"
                  type="button"
                  phx-click="document_element_picker.toggle"
                  class="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-transparent text-base-content/60 transition-colors hover:border-base-content/15 hover:bg-base-200 hover:text-base-content focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--cs-blue)] data-[active=true]:border-[var(--cs-blue)] data-[active=true]:bg-[color-mix(in_oklab,var(--cs-blue)_12%,transparent)] data-[active=true]:text-[var(--cs-blue)]"
                  aria-label="Pick document element"
                  aria-controls="local-editor-shell local-agent-input"
                  aria-pressed={to_string(@document_element_picker_enabled)}
                  data-active={to_string(@document_element_picker_enabled)}
                  data-role="document-element-picker-toggle"
                  title="Pick document element"
                >
                  <.icon name="hero-cursor-arrow-rays" class="size-4" />
                </button>

                <button
                  id="local-rhwp-fullscreen"
                  type="button"
                  phx-click={toggle_local_fullscreen()}
                  class="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded-md text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content"
                  aria-label="Toggle fullscreen"
                  aria-controls="local-editor-shell local-file-tree-panel local-agent-sidebar"
                  aria-pressed="false"
                  data-role="toggle-chat-rail"
                  title="Toggle fullscreen"
                >
                  <span data-role="enter-fullscreen" class="inline-flex">
                    <.icon name="hero-arrows-pointing-out" class="size-4" />
                  </span>
                  <span data-role="exit-fullscreen" class="hidden">
                    <.icon name="hero-arrows-pointing-in" class="size-4" />
                  </span>
                </button>
              </div>
            </header>
            <div
              :if={@document}
              id="local-document-quick-toolbar"
              phx-hook="LocalEditorToolbar"
              data-role="local-editor-toolbar"
              data-local-document-id={@document.id}
              data-local-document-format={@document.format}
              class="flex h-9 items-center gap-0.5 overflow-x-auto border-b border-base-300 bg-base-100 px-2"
            >
              <button
                type="button"
                data-command="bold"
                aria-label="Bold"
                title="Bold (⌘B)"
                class={quick_toolbar_button_class()}
              >
                <.quick_toolbar_bold_icon />
              </button>
              <button
                type="button"
                data-command="italic"
                aria-label="Italic"
                title="Italic (⌘I)"
                class={quick_toolbar_button_class()}
              >
                <.quick_toolbar_italic_icon />
              </button>
              <button
                :if={not markdown_format?(@document.format)}
                type="button"
                data-command="underline"
                aria-label="Underline"
                title="Underline (⌘U)"
                class={quick_toolbar_button_class()}
              >
                <.quick_toolbar_underline_icon />
              </button>
              <button
                type="button"
                data-command="strikethrough"
                aria-label="Strikethrough"
                title="Strikethrough (⌘⇧X)"
                class={quick_toolbar_button_class()}
              >
                <.quick_toolbar_strikethrough_icon />
              </button>
              <span
                :if={not markdown_format?(@document.format)}
                aria-hidden="true"
                class="mx-1 h-4 w-px shrink-0 self-center bg-base-300"
              >
              </span>
              <input
                :if={not markdown_format?(@document.format)}
                type="text"
                inputmode="decimal"
                data-role="font-size-input"
                aria-label="Font size (pt)"
                title="Font size (pt) — Enter to apply"
                class="h-7 w-9 shrink-0 rounded-md border border-base-300 bg-base-100 text-center text-[12px] text-base-content/80 focus:border-[var(--cs-blue)] focus:outline-none"
              />
              <button
                :if={not markdown_format?(@document.format)}
                type="button"
                data-command="text-color"
                aria-label="Text color"
                title="Text color"
                class={[quick_toolbar_button_class(), "relative"]}
              >
                <span class="text-[13px] font-semibold leading-none">A</span>
                <span
                  data-role="text-color-bar"
                  class="absolute bottom-1 left-1.5 right-1.5 h-[3px] rounded-sm bg-[#e11d48]"
                >
                </span>
              </button>
              <input
                id="local-document-text-color-input"
                type="color"
                value="#e11d48"
                data-role="text-color-input"
                aria-label="Text color picker"
                class="pointer-events-none absolute h-0 w-0 opacity-0"
                tabindex="-1"
              />
              <button
                :if={not markdown_format?(@document.format)}
                type="button"
                data-command="highlight"
                aria-label="Highlight color"
                title="Highlight color"
                class={[quick_toolbar_button_class(), "relative"]}
              >
                <.quick_toolbar_highlight_icon />
                <span
                  data-role="highlight-color-bar"
                  class="absolute bottom-1 left-1.5 right-1.5 h-[3px] rounded-sm bg-[#fde047]"
                >
                </span>
              </button>
              <input
                id="local-document-highlight-color-input"
                type="color"
                value="#fde047"
                data-role="highlight-color-input"
                aria-label="Highlight color picker"
                class="pointer-events-none absolute h-0 w-0 opacity-0"
                tabindex="-1"
              />
              <span
                :if={not markdown_format?(@document.format)}
                aria-hidden="true"
                class="mx-1 h-4 w-px shrink-0 self-center bg-base-300"
              >
              </span>
              <div
                :if={not markdown_format?(@document.format)}
                data-role="align-dropdown"
                class="relative flex shrink-0"
              >
                <button
                  type="button"
                  data-role="align-menu-button"
                  aria-label="Paragraph alignment"
                  aria-haspopup="menu"
                  aria-expanded="false"
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
                      if(align == "left", do: "flex", else: "hidden")
                    ]}
                  >
                    <.quick_toolbar_align_icon align={align} />
                  </span>
                  <.icon name="hero-chevron-down" class="size-3 shrink-0 opacity-60" />
                </button>
                <div
                  data-role="align-menu"
                  role="menu"
                  aria-label="Paragraph alignment"
                  hidden
                  class="fixed z-40 min-w-44 rounded-md border border-base-300 bg-base-100 p-1 shadow-lg"
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
              </div>
              <span
                :if={not markdown_format?(@document.format)}
                aria-hidden="true"
                class="mx-1 h-4 w-px shrink-0 self-center bg-base-300"
              >
              </span>
              <button
                :if={not markdown_format?(@document.format)}
                type="button"
                data-command="image"
                aria-label="Insert image"
                title="Insert image"
                class={quick_toolbar_button_class()}
              >
                <span class="flex size-4 items-center justify-center">
                  <.icon name="hero-photo" class="size-4" />
                </span>
              </button>
              <input
                id="local-document-toolbar-image-input"
                type="file"
                accept="image/*"
                data-role="local-editor-toolbar-image-input"
                class="hidden"
              />
              <%!-- Markdown PREVIEW <-> SOURCE toggle, folded in from the old
                   markdown-editor header. Drives the panes in the markdown
                   canvas (id = @canvas_id) via the shared JS toggle. --%>
              <button
                :if={markdown_format?(@document.format)}
                type="button"
                data-role="markdown-editor-toggle"
                phx-click={LocalMarkdownEditor.toggle_markdown_view(@canvas_id)}
                aria-label="Toggle source and preview"
                title="Toggle source / preview"
                class={["ml-auto", quick_toolbar_button_class()]}
              >
                <span data-toggle-label="preview" title="Edit source">
                  <.icon name="hero-code-bracket" class="size-4" />
                </span>
                <span data-toggle-label="source" class="hidden" title="Show preview">
                  <.icon name="hero-eye" class="size-4" />
                </span>
              </button>
            </div>
          </div>

          <article class="relative m-0 flex min-h-0 flex-1 overflow-hidden border-0 bg-transparent p-0 font-sans text-[15px] leading-[1.78] text-base-content shadow-none">
            <div class="relative h-full min-h-0 w-full">
              <div :if={@document} id={@frame_id} class="contents">
                <LocalHwpPages.render
                  :if={ehwp_format?(@document.format)}
                  id={@canvas_id}
                  pages={@hwp_pages}
                  page_count={@hwp_page_count}
                  spec={@document_spec}
                  document_id={@document.id}
                  document_path={@document_path}
                  bytes_url={@hwp_bytes_url}
                  local_document_format={@document.format}
                  scroll_top={document_scroll(@document_viewport, :scroll_top)}
                  scroll_left={document_scroll(@document_viewport, :scroll_left)}
                />
                <LocalMarkdownEditor.render
                  :if={markdown_format?(@document.format)}
                  id={@canvas_id}
                  document_id={@document.id}
                  local_document_format={@document.format}
                  source={@markdown_source}
                  preview_html={@markdown_preview_html}
                />
                <LocalOfficeWasm.render
                  :if={
                    not ehwp_format?(@document.format) and
                      not markdown_format?(@document.format)
                  }
                  id={@canvas_id}
                  document_id={@document.id}
                  document_path={@document_path}
                  local_document_format={@document.format}
                  bytes_url={@hwp_bytes_url}
                  scroll_top={document_scroll(@document_viewport, :scroll_top)}
                  scroll_left={document_scroll(@document_viewport, :scroll_left)}
                />
              </div>

              <div
                :if={!@document && @document_loading?}
                id="studio-document-loading-body"
                data-role="document-loading"
                class="flex h-full min-h-0 w-full items-start justify-center gap-2 px-5 py-6 text-sm text-base-content/60"
              >
                <.icon name="hero-arrow-path" class="mt-0.5 size-4 animate-spin" />
                <span class="truncate">
                  Opening {Path.basename(@document_path || "document")}
                </span>
              </div>

              <div
                :if={!@document && !@document_loading?}
                id="studio-document-empty-body"
                class="flex h-full min-h-0 w-full items-start justify-center px-5 py-6 text-sm text-base-content/60"
              >
                This file type can't be rendered in the editor.
              </div>
            </div>
          </article>
        </section>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :document, :map, required: true
  attr :document_path, :string, default: nil
  attr :document_spec, :map, default: nil
  attr :canvas_id, :string, required: true
  attr :hwp_bytes_url, :string, default: nil
  attr :status, :atom, default: :running
  attr :turn_id, :string, default: nil
  attr :preview_text, :string, default: ""
  attr :delta_count, :integer, default: 0
  attr :preview_highlights, :list, default: []
  attr :markdown_source, :string, default: ""
  attr :markdown_preview_html, :any, default: ""

  def embedded_document(assigns) do
    assigns =
      assigns
      |> assign(:document_path, assigns.document_path || document_path(assigns.document))
      |> assign(:document_spec, assigns.document_spec || embedded_document_spec(assigns.document))
      |> assign(:preview_highlights_json, Jason.encode!(assigns.preview_highlights || []))

    ~H"""
    <div
      id={@id}
      data-role="editor-preview"
      data-document-id={@document.id}
      data-document-path={@document_path}
      data-preview-delta-count={@delta_count}
      data-preview-status={@status}
      class="min-w-0 overflow-hidden rounded-md border border-base-content/15 bg-base-100"
    >
      <div class="flex min-w-0 items-center gap-2 border-b border-base-content/10 px-2.5 py-1.5">
        <.icon name="hero-pencil-square" class="size-3.5 shrink-0 text-base-content/55" />
        <span class="min-w-0 flex-1 truncate text-[12px] font-medium leading-4 text-base-content/80">
          {embedded_document_title(@document, @document_path)}
        </span>
        <span
          data-role="editor-preview-delta-count"
          class="shrink-0 font-mono text-[10px] leading-4 text-base-content/45"
        >
          {@delta_count}
        </span>
        <button
          :if={@document_path}
          type="button"
          phx-click="open_file"
          phx-value-path={@document_path}
          data-role="editor-preview-open"
          class="inline-flex size-6 shrink-0 items-center justify-center rounded text-base-content/55 transition-colors hover:bg-base-200 hover:text-base-content"
          aria-label="Open in editor"
          title="Open in editor"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
        </button>
      </div>
      <div class="h-64 min-h-0 overflow-hidden bg-base-200">
        <LocalHwpPages.render
          :if={ehwp_format?(@document.format)}
          id={@canvas_id}
          pages={[]}
          page_count={0}
          spec={@document_spec}
          document_id={@document.id}
          bytes_url={@hwp_bytes_url}
          local_document_format={@document.format}
          mirror?={true}
          preview_turn_id={@turn_id}
          preview_text={@preview_text}
          preview_delta_count={@delta_count}
          preview_highlights={@preview_highlights_json}
        />
        <LocalMarkdownEditor.render
          :if={markdown_format?(@document.format)}
          id={@canvas_id}
          document_id={@document.id}
          local_document_format={@document.format}
          source={@markdown_source || @preview_text}
          preview_html={@markdown_preview_html}
        />
        <LocalOfficeWasm.render
          :if={not ehwp_format?(@document.format) and not markdown_format?(@document.format)}
          id={@canvas_id}
          document_id={@document.id}
          document_path={@document_path}
          local_document_format={@document.format}
          bytes_url={@hwp_bytes_url}
          mirror?={true}
          preview_turn_id={@turn_id}
          preview_text={@preview_text}
          preview_delta_count={@delta_count}
          preview_highlights={@preview_highlights_json}
        />
      </div>
    </div>
    """
  end

  defp ehwp_format?(format), do: format in ~w(hwp hwpx)
  defp markdown_format?(format), do: format in ~w(md markdown)
  defp document_path(%{relative_path: relative_path}), do: relative_path
  defp document_path(_document), do: nil

  defp document_scroll(viewport, key) when is_map(viewport) do
    Map.get(viewport, key) || Map.get(viewport, Atom.to_string(key))
  end

  defp document_scroll(_viewport, _key), do: nil

  defp embedded_document_title(_document, path) when is_binary(path) and path != "",
    do: Path.basename(path)

  defp embedded_document_title(%{name: name}, _path) when is_binary(name) and name != "",
    do: name

  defp embedded_document_title(_document, _path), do: "document"

  defp embedded_document_spec(%{format: "hwp"} = document) do
    %{
      key: "local_hwp_preview",
      name: Path.basename(document.relative_path),
      template_hwp_path: document.relative_path
    }
  end

  defp embedded_document_spec(%{relative_path: relative_path}) do
    %{
      key: "local_hwpx_preview",
      name: Path.basename(relative_path),
      template_hwpx_path: relative_path
    }
  end

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

  defp toggle_local_fullscreen(js \\ %JS{}) do
    js
    |> JS.toggle_class("hidden", to: "#local-file-tree-panel")
    |> JS.toggle_class("hidden", to: "#local-agent-sidebar")
    |> JS.toggle_class("col-span-3", to: "#local-editor-shell")
    |> JS.toggle_attribute({"aria-pressed", "true", "false"})
    |> JS.toggle(to: "#local-rhwp-fullscreen [data-role='enter-fullscreen']")
    |> JS.toggle(to: "#local-rhwp-fullscreen [data-role='exit-fullscreen']")
  end

  defp tab_close_js(tab) do
    JS.set_attribute({"hidden", ""}, to: "#studio-document-tab-#{tab.id}")
    |> JS.push("tab_close", value: %{id: tab.id})
  end
end
