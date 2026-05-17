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
    assigns = assign(assigns, :can_write?, can_write?(assigns.current_scope))

    ~H"""
    <div
      id={@id}
      class="overflow-auto flex items-center justify-center"
      data-stub="canvas-empty"
      data-role="canvas-empty"
    >
      <div class="max-w-md mx-auto py-24 text-center">
        <img
          src={~p"/images/landing/dashboard-empty.png"}
          alt={dgettext("studio", "An empty folder line drawing — no document selected.")}
          class="mx-auto w-32 sm:w-40 h-auto object-contain opacity-90"
          width="1024"
          height="1024"
          loading="lazy"
        />

        <h2 class="mt-6 text-lg font-semibold tracking-tight text-base-content">
          {dgettext("studio", "문서를 선택하거나 새로 만드세요")}
        </h2>
        <p class="mt-2 text-sm text-base-content/60">
          {dgettext("studio", "왼쪽에서 문서를 고르거나, 새 계약서를 시작합니다.")}
        </p>

        <div
          :if={@can_write?}
          class="mt-6 flex flex-col gap-3"
          data-role="canvas-empty-actions"
        >
          <%!-- ------------------------------------------------------------ --%>
          <%!-- 계약서 업로드 — inline dropzone, NOT a modal. The form fires --%>
          <%!-- the existing document.upload / document.upload.validate     --%>
          <%!-- events on the parent StudioLive, which routes them through  --%>
          <%!-- the :upload_document Command → real Blobs/SourceDocuments    --%>
          <%!-- pipeline.                                                    --%>
          <%!-- ------------------------------------------------------------ --%>
          <.form
            :let={_f}
            for={%{}}
            as={:upload}
            id={"#{@id}-upload-form"}
            phx-submit="document.upload"
            phx-change="document.upload.validate"
            data-role="canvas-empty-upload-form"
            class="text-left"
          >
            <label
              :if={@document_upload}
              for={@document_upload.ref}
              class="studio-empty-upload__dropzone"
              data-role="canvas-empty-upload-dropzone"
            >
              <.live_file_input
                upload={@document_upload}
                class="sr-only"
                data-role="canvas-empty-upload-input"
              />
              <span class="studio-empty-upload__dropzone-text">
                {dgettext("studio", "계약서 업로드")}
              </span>
              <span class="studio-empty-upload__dropzone-hint">
                {dgettext("studio", "PDF · DOCX · HWP · HWPX")}
              </span>
            </label>

            <ul
              :if={@document_upload && @document_upload.entries != []}
              class="studio-empty-upload__entries"
            >
              <li
                :for={entry <- @document_upload.entries}
                class="studio-empty-upload__entry"
              >
                <span class="studio-empty-upload__entry-name">{entry.client_name}</span>
                <span class="studio-empty-upload__entry-progress">{entry.progress}%</span>
              </li>
            </ul>
          </.form>

          <%!-- ------------------------------------------------------------ --%>
          <%!-- 빈 문서로 시작 / 최근 문서 열기 / 에이전트와 먼저 상의하기   --%>
          <%!-- ------------------------------------------------------------ --%>
          <div class="flex flex-wrap items-center justify-center gap-x-4 gap-y-2 text-sm">
            <button
              type="button"
              phx-click="agent_option_picked"
              phx-value-key="blank"
              class="link link-primary link-hover font-medium"
              data-role="canvas-empty-new-document"
            >
              {dgettext("studio", "빈 문서로 시작")}
            </button>
            <span class="text-base-content/30" aria-hidden="true">·</span>
            <button
              type="button"
              phx-click="agent_option_picked"
              phx-value-key="recent"
              class="link link-primary link-hover font-medium"
              data-role="canvas-empty-recent"
            >
              {dgettext("studio", "최근 문서 열기")}
            </button>
            <span class="text-base-content/30" aria-hidden="true">·</span>
            <button
              type="button"
              phx-click={JS.focus(to: "#chat-rail-textarea")}
              class="link link-primary link-hover font-medium"
              data-role="canvas-empty-discuss"
            >
              {dgettext("studio", "에이전트와 먼저 상의하기")}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Persona perm check
  #
  # The :viewer persona has perms `[:read]`. Every other persona
  # (:lawyer, :paralegal, :agent_supervised, :admin) carries `:write`. So
  # "can use the inline create/import actions" maps to "has :write".
  # ---------------------------------------------------------------------------

  defp can_write?(%{perms: perms}) when is_list(perms), do: :write in perms
  defp can_write?(_), do: false
end
