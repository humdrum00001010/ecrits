defmodule ContractWeb.Live.Studio.Components.EditorSurface do
  @moduledoc """
  Studio editor chrome reused by local document sessions.
  """

  use ContractWeb, :html

  alias ContractWeb.Live.Studio.Components.Canvas.HwpTemplate

  attr :id, :string, default: "studio-root"
  attr :shell_id, :string, required: true
  attr :toolbar_id, :string, required: true
  attr :frame_id, :string, required: true
  attr :document, :map, required: true
  attr :document_spec, :map, required: true
  attr :editable_spec_candidates, :list, default: []
  attr :canvas_id, :string, required: true
  attr :save_state, :string, required: true
  attr :snapshot, :map, required: true
  attr :snapshot_upload_event, :string, default: "rhwp.local.snapshot.save"

  def local_document(assigns) do
    assigns = assign(assigns, :document_path, assigns.document.relative_path)

    ~H"""
    <div
      id={@shell_id}
      data-component="studio-local-document-surface"
      class="h-[calc(100vh-60px)] min-h-[calc(100vh-60px)] w-full overflow-hidden"
    >
      <div
        id={@id}
        data-component="studio-document-surface"
        data-local-document-id={@document.id}
        class="h-full min-h-0 w-full overflow-hidden"
      >
        <section class="flex h-full min-h-0 min-w-0 flex-col overflow-hidden bg-transparent">
          <div id={@toolbar_id} class="contents">
            <header
              id="studio-document-header"
              class="flex min-h-11 flex-wrap items-center justify-between gap-x-2.5 gap-y-1.5 border-b border-base-300 bg-base-100 px-5 py-1.5 max-sm:min-h-0 max-sm:px-4 max-sm:py-2"
            >
              <div class="flex min-w-0 flex-1 flex-wrap items-center gap-1 max-sm:w-full">
                <div
                  id="studio-document-title-form"
                  class="flex h-8 min-w-0 max-w-[18rem] items-center"
                  data-role="document-title-form"
                >
                  <input
                    id="studio-document-title-input"
                    type="text"
                    value={@document_path}
                    aria-label="Local document path"
                    title={@document_path}
                    readonly
                    autocomplete="off"
                    spellcheck="false"
                    class="h-7 w-[min(16rem,45vw)] max-w-full truncate rounded-md border border-base-300 bg-transparent px-1.5 py-0 text-[13px] font-medium leading-none text-base-content outline-none transition-colors hover:border-base-content/30 focus:border-base-content/50 focus:bg-base-100 focus:outline-none focus:ring-0 focus:shadow-none"
                  />
                </div>

                <span
                  id="local-active-document-badge"
                  class="hidden h-7 shrink-0 items-center rounded-md border border-base-300 px-2 text-xs text-base-content/60 2xl:inline-flex"
                >
                  Open
                </span>

                <div class="inline-flex items-center gap-1">
                  <div
                    class="inline-flex h-7 w-7 flex-col items-stretch overflow-hidden rounded-md border border-base-300 text-base-content/70 transition-colors"
                    role="group"
                    aria-label="Move between editable items"
                  >
                    <div
                      role="button"
                      tabindex="0"
                      data-role="rhwp-prev-edit-target"
                      aria-label="Previous editable item"
                      aria-keyshortcuts="Shift+Tab"
                      title="Previous editable item (Shift+Tab)"
                      class="flex h-1/2 w-full cursor-pointer items-center justify-center transition-colors hover:bg-base-200 hover:text-base-content"
                    >
                      <svg
                        class="size-2.5 fill-none stroke-current"
                        viewBox="0 0 10 10"
                        aria-hidden="true"
                      >
                        <path
                          d="M2 6.5l3 -3 3 3"
                          stroke-width="1.4"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        />
                      </svg>
                    </div>
                    <div
                      role="button"
                      tabindex="0"
                      data-role="rhwp-next-edit-target"
                      aria-label="Next editable item"
                      aria-keyshortcuts="Tab"
                      title="Next editable item (Tab)"
                      class="flex h-1/2 w-full cursor-pointer items-center justify-center transition-colors hover:bg-base-200 hover:text-base-content"
                    >
                      <svg
                        class="size-2.5 fill-none stroke-current"
                        viewBox="0 0 10 10"
                        aria-hidden="true"
                      >
                        <path
                          d="M2 3.5l3 3 3 -3"
                          stroke-width="1.4"
                          stroke-linecap="round"
                          stroke-linejoin="round"
                        />
                      </svg>
                    </div>
                  </div>
                  <kbd
                    aria-hidden="true"
                    class="hidden select-none items-center px-1 font-mono text-[10px] leading-none text-base-content/55 2xl:inline-flex"
                    title="Previous = Shift+Tab, next = Tab"
                  >
                    Tab
                  </kbd>
                </div>
              </div>

              <div class="ml-auto inline-flex min-w-0 shrink-0 items-center justify-end gap-1.5 max-sm:w-full">
                <span
                  id="local-rhwp-save-state"
                  class="hidden max-w-48 truncate text-xs text-base-content/55 2xl:inline"
                  title={@save_state}
                >
                  {@save_state}
                </span>

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
          </div>

          <article class="relative m-0 flex min-h-0 flex-1 overflow-hidden border-0 bg-transparent p-0 font-sans text-[15px] leading-[1.78] text-base-content shadow-none max-sm:mx-3 max-sm:px-5 max-sm:py-7">
            <div class="relative h-full min-h-0 w-full">
              <div id={@frame_id} class="contents">
                <.live_component
                  module={HwpTemplate}
                  id={@canvas_id}
                  spec={@document_spec}
                  matching_book={%{}}
                  field_values={%{}}
                  editable_spec_candidates={@editable_spec_candidates}
                  site_id="local"
                  document_id={@document.id}
                  text_events={[]}
                  snapshot={@snapshot}
                  snapshot_candidates={[]}
                  snapshot_upload_event={@snapshot_upload_event}
                  local_document_id={@document.id}
                  local_document_revision={@document.revision}
                  local_document_format={@document.format}
                  role="local-rhwp-editor"
                />
              </div>
            </div>
          </article>
        </section>
      </div>
    </div>
    """
  end

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
