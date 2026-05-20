defmodule ContractWeb.Live.Studio.Components.Canvas.Empty do
  @moduledoc """
  Canvas empty state — shown when `@studio_state.mode == :no_document`.

  Per the 2026-05-17 owner directive, the dashboard's `새 문서` button is no
  longer a doc-creation trigger; it routes the user here, and this empty
  state hosts the full four-option onboarding surface called for by
  SPEC.md §4.2 (Center Document Canvas — empty state) and §4.4 (Chat Rail
  When No Document Exists):

    * `계약서 업로드`           — inline dropzone (NOT a modal)
    * `빈 문서로 시작`          — fires `agent_option_picked` key=blank,
                                  which routes through StudioLive to a
                                  `:create_document` Command
    * `최근 문서 열기`          — fires `agent_option_picked` key=recent,
                                  opening the document-picker modal
    * `에이전트와 먼저 상의하기` — JS.focus the chat-rail composer textarea

  ## Upload pipeline

  The inline form fires `phx-submit="document.upload"` and
  `phx-change="document.upload.validate"`. Both events are owned by the
  parent `ContractWeb.StudioLive`, which already routes them through:

      `document.upload` → `event_to_command/3` → %Command{kind: :upload_document}
                       → `Studio.command/2` → `Runtime.apply/2`
                       → `Contract.SourceDocuments.create_from_upload/3`
                       → `Blobs.put_upload → SourceDocument → SourceClaim`

  The `:document_upload` LiveView upload-config struct is created in
  `StudioLive.mount/3` and passed down via the `document_upload` attr.

  ## Persona gating

  A `:viewer` (whose perms list does NOT include `:write`) sees the
  illustration + copy but none of the action buttons or the dropzone.
  Every other persona sees the full surface.
  """

  use ContractWeb, :live_component

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :projection, :map, required: true
  attr :current_scope, :map, required: true
  attr :document_upload, :any, default: nil

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={@id}
      class="min-h-0"
      data-stub="canvas-empty"
      data-role="canvas-empty"
    >
    </div>
    """
  end
end
