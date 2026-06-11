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
  attr :document_loading?, :boolean, default: false
  attr :document_spec, :map, default: nil
  attr :canvas_id, :string, default: nil
  attr :hwp_bytes_url, :string, default: nil
  attr :save_state, :string, default: nil
  attr :open_documents, :list, default: []
  attr :active_document_id, :string, default: nil
  attr :dirty_document_ids, :any, default: nil
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
              class="flex min-h-9 items-stretch justify-between border-b border-base-300 bg-base-100 max-sm:min-h-0"
            >
              <div
                id="studio-document-tabs"
                role="tablist"
                aria-label="Open documents"
                data-role="document-tabs"
                class="flex min-w-0 flex-1 items-stretch overflow-hidden max-sm:w-full"
              >
                <div
                  :for={tab <- @open_documents}
                  id={"studio-document-tab-#{tab.id}"}
                  role="tab"
                  data-role="document-tab"
                  data-tab-id={tab.id}
                  data-active={to_string(tab.id == @active_document_id)}
                  aria-selected={to_string(tab.id == @active_document_id)}
                  title={tab.path}
                  class={[
                    "group flex min-w-0 shrink items-center gap-1 border-r border-base-300 px-3 max-w-[15rem] text-[13px] leading-none transition-colors border-b-2",
                    if(tab.id == @active_document_id,
                      do: "bg-base-100 text-base-content font-medium border-b-primary",
                      else:
                        "bg-base-200/50 text-base-content/55 border-b-transparent hover:bg-base-100/70 hover:text-base-content"
                    )
                  ]}
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
                  <button
                    type="button"
                    phx-click="tab_switch"
                    phx-value-id={tab.id}
                    data-role="document-tab-switch"
                    class="min-w-0 flex-1 truncate text-left outline-none"
                    title={tab.path}
                  >
                    {tab.name}
                  </button>
                  <button
                    type="button"
                    phx-click="tab_close"
                    phx-value-id={tab.id}
                    data-role="document-tab-close"
                    aria-label={"Close #{tab.name}"}
                    class="inline-flex size-4 shrink-0 items-center justify-center rounded text-base-content/45 transition-colors hover:bg-base-200 hover:text-base-content"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </div>
              </div>

              <div class="ml-auto inline-flex min-w-0 shrink-0 items-center justify-end gap-1.5 pl-2 pr-3 max-sm:w-full">
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
                  class="inline-flex h-8 shrink-0 items-center gap-1.5 rounded-md border border-base-300 bg-base-100 px-2 text-xs text-base-content/70 transition-colors hover:border-base-content/25 hover:text-base-content md:hidden"
                  title="Show chat"
                >
                  <.icon name="hero-chat-bubble-left-right" class="size-4" />
                  <span>Chat</span>
                </button>

                <button
                  id="local-document-element-picker"
                  type="button"
                  phx-click={JS.dispatch("ecrits:document-element-picker.toggle", to: "body")}
                  class="hidden h-8 w-8 shrink-0 items-center justify-center rounded-md text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content data-[active=true]:bg-base-200 data-[active=true]:text-base-content lg:inline-flex"
                  aria-label="Pick document element"
                  aria-controls="local-editor-shell local-agent-input"
                  aria-pressed="false"
                  data-active="false"
                  data-role="document-element-picker-toggle"
                  title="Pick document element"
                >
                  <.icon name="hero-cursor-arrow-rays" class="size-4" />
                </button>

                <button
                  id="local-rhwp-fullscreen"
                  type="button"
                  phx-click={toggle_local_fullscreen()}
                  class="hidden h-8 w-8 shrink-0 items-center justify-center rounded-md text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content lg:inline-flex"
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
          </div>

          <article class="relative m-0 flex min-h-0 flex-1 overflow-hidden border-0 bg-transparent p-0 font-sans text-[15px] leading-[1.78] text-base-content shadow-none max-sm:mx-3 max-sm:px-5 max-sm:py-7">
            <div class="relative h-full min-h-0 w-full">
              <div :if={@document} id={@frame_id} class="contents">
                <LocalHwpPages.render
                  :if={ehwp_format?(@document.format)}
                  id={@canvas_id}
                  pages={@hwp_pages}
                  page_count={@hwp_page_count}
                  spec={@document_spec}
                  document_id={@document.id}
                  bytes_url={@hwp_bytes_url}
                  local_document_format={@document.format}
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

  defp ehwp_format?(format), do: format in ~w(hwp hwpx)
  defp markdown_format?(format), do: format in ~w(md markdown)
  defp document_path(%{relative_path: relative_path}), do: relative_path
  defp document_path(_document), do: nil

  defp toggle_local_fullscreen(js \\ %JS{}) do
    js
    |> JS.toggle_class("hidden", to: "#local-file-tree-panel")
    |> JS.toggle_class("hidden", to: "#local-agent-sidebar")
    |> JS.toggle_class("lg:col-span-3", to: "#local-editor-shell")
    |> JS.toggle_attribute({"aria-pressed", "true", "false"})
    |> JS.toggle(to: "#local-rhwp-fullscreen [data-role='enter-fullscreen']")
    |> JS.toggle(to: "#local-rhwp-fullscreen [data-role='exit-fullscreen']")
  end
end
