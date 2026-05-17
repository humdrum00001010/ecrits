defmodule ContractWeb.Live.Studio.Components.ChatRail do
  @moduledoc """
  The central agent dialog surface (Wave 3C1 / chat-rail).

  Responsibilities:

    * Renders the streamed conversation (`@streams.chat_messages`) — both
      user-authored messages and agent bubbles (streamed + completed).
    * Mounts the `GrillRail` sub-LiveComponent when the latest agent
      message has unresolved `mode: "grill"` ask-marks.
    * Owns the textarea + send button input footer.
    * Surfaces a header status pill keyed off `@studio_state.agent_run_id`.
    * Switches between a desktop right-rail layout and a mobile full-viewport
      layout depending on the `layout` attr / `viewport` assign.

  ## Hard local constraint

  The send button is `type="button"` (never `type="submit"`). The form's
  `phx-submit` exists as a fallback, but the colocated `.ChatInput` hook
  intercepts both Enter-in-textarea and click-on-send-button, calling
  `pushEvent` directly. This preserves keyboard focus on mobile across
  sends — losing focus mid-thread on Korean IME is the regression
  recorded in the responsive-scope memory.

  Keyboard rules:

    * Enter (no shift) → submit
    * Shift+Enter → newline
    * On send: clear textarea + refocus
  """
  use ContractWeb, :live_component

  alias ContractWeb.Live.Studio.Components.GrillRail

  attr :id, :string, required: true
  attr :studio_state, :map, required: true
  attr :streams, :map, required: true
  attr :current_scope, :map, required: true
  attr :layout, :atom, default: :default

  # Whether to mount the GrillRail sub-LiveComponent. Parent decides this
  # based on the latest agent message's mode (`"grill"` = unanswered
  # ask-marks). Defaults to nil; the component falls back to
  # `studio_state.grill_active?` if the parent set that flag.
  attr :grill_active?, :any, default: nil

  # Unresolved ask-marks for the current agent_run_id. Computed by the
  # parent shell (filters `@projection.marks` for `intent: :ask` matching
  # the current `agent_run_id`) and forwarded into GrillRail. The shell
  # wiring is a separate merge-fix; this component just accepts + forwards.
  attr :grill_marks, :list, default: []

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:mobile?, fn -> assigns.layout == :mobile_full end)
      |> assign(:agent_status, agent_status(assigns.studio_state))
      |> assign(:observer_mode?, observer_mode?(assigns.current_scope))
      |> assign(:grill_active?, resolve_grill_active?(assigns))
      |> assign(:no_document?, no_document?(assigns.studio_state))
      |> assign(:start_options, start_options())

    ~H"""
    <aside
      id={@id}
      data-component="chat-rail"
      data-layout={if @mobile?, do: "mobile", else: "desktop"}
      data-stub="chat-rail"
      class={[
        "flex flex-col bg-base-100 min-h-0",
        not @mobile? && "shrink-0 w-[360px] border-l border-base-200",
        @mobile? && "w-full flex-1 h-full"
      ]}
    >
      <%!-- Header --%>
      <header class={[
        "flex items-center gap-2 px-4 py-3 border-b border-base-200 shrink-0",
        @mobile? && "py-2"
      ]}>
        <button
          :if={@mobile?}
          type="button"
          phx-click="toggle_preview"
          data-role="chat-rail-open-document"
          class="inline-flex items-center gap-1 rounded-md border border-base-300 px-2 py-1 text-xs text-base-content/80 hover:bg-base-200"
          aria-label={dgettext("studio", "문서 보기")}
        >
          <.icon name="hero-document-text" class="size-4" />
          {dgettext("studio", "문서")}
        </button>

        <h2 :if={not @mobile?} class="font-medium text-sm text-base-content/80">
          {dgettext("studio", "에이전트")}
        </h2>

        <span
          data-role="agent-status-pill"
          data-status={@agent_status.key}
          class={[
            "ml-auto inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs",
            status_pill_class(@agent_status.key)
          ]}
        >
          <span
            :if={@agent_status.key == :responding}
            class="inline-block size-1.5 rounded-full bg-current animate-pulse"
            aria-hidden="true"
          >
          </span>
          {@agent_status.label}
        </span>
      </header>

      <%!-- Observer-mode banner (agent_supervised persona) --%>
      <div
        :if={@observer_mode?}
        data-role="observer-banner"
        role="status"
        class="px-4 py-2 text-xs bg-warning/10 text-warning-content border-b border-warning/30"
      >
        {dgettext("studio", "관찰 모드 — 메시지는 다른 사용자가 받습니다")}
      </div>

      <%!-- GrillRail (unanswered ask-marks) --%>
      <div :if={@grill_active?} class="shrink-0">
        <.live_component
          module={GrillRail}
          id={"#{@id}-grill"}
          studio_state={@studio_state}
          current_scope={@current_scope}
          grill_marks={@grill_marks}
        />
      </div>

      <%!-- Streamed conversation. The wrapper uses `:has()` to hide the
           welcome panel as soon as the stream contains a message. --%>
      <div
        id={"#{@id}-scroll"}
        data-role="chat-scroll"
        class="flex-1 min-h-0 overflow-y-auto px-4 py-3 group/chat"
      >
        <div
          :if={not @no_document?}
          id={"#{@id}-welcome"}
          data-role="chat-welcome"
          class="text-sm text-base-content/60 italic text-center py-8 group-has-[[data-role=chat-message]]/chat:hidden"
        >
          {dgettext(
            "studio",
            "에이전트에게 무엇이든 물어보세요 — 초안, 마크, 내보내기."
          )}
        </div>

        <div
          :if={@no_document?}
          id={"#{@id}-no-doc-welcome"}
          data-role="chat-no-doc-welcome"
          class="group-has-[[data-role=chat-message]]/chat:hidden flex flex-col gap-3 max-w-[88%] self-start"
        >
          <div
            data-role="chat-no-doc-message"
            class="rounded-lg bg-base-200 text-base-content text-sm px-3 py-2"
          >
            <p class="mb-2">{dgettext("studio", "새 문서를 시작합니다. 어떻게 시작할까요?")}</p>
            <ol class="list-decimal list-inside space-y-1 marker:text-base-content/60">
              <li>
                <strong>{dgettext("studio", "최근 문서 열기")}</strong>
                <span class="text-base-content/70">
                  {dgettext("studio", " — 최근 작업한 문서로 이동")}
                </span>
              </li>
              <li>
                <strong>{dgettext("studio", "빈 계약서 만들기")}</strong>
                <span class="text-base-content/70">
                  {dgettext("studio", " — 처음부터 작성")}
                </span>
              </li>
              <li>
                <strong>{dgettext("studio", "논의에서 시작")}</strong>
                <span class="text-base-content/70">
                  {dgettext("studio", " — 사실관계, 거래 배경부터 정리한 뒤 초안")}
                </span>
              </li>
              <li>
                <strong>{dgettext("studio", "다른 문서에서 변형 만들기")}</strong>
                <span class="text-base-content/70">
                  {dgettext("studio", " — 기존 문서의 유형 변환")}
                </span>
              </li>
            </ol>
            <p class="mt-2 text-base-content/70">
              {dgettext("studio", "무엇으로 시작할까요?")}
            </p>

            <div
              class="flex flex-wrap gap-2 mt-3"
              data-role="chat-no-doc-options"
            >
              <button
                :for={opt <- @start_options}
                type="button"
                phx-click="agent_option_picked"
                phx-value-key={opt.key}
                data-role="chat-no-doc-option"
                data-option-key={opt.key}
                class="btn btn-sm btn-ghost border border-base-300 rounded-full font-normal normal-case shadow-none hover:bg-base-200"
              >
                {opt.label}
              </button>
            </div>
          </div>
        </div>

        <div
          id={"#{@id}-stream"}
          phx-update="stream"
          data-role="chat-stream"
          class="flex flex-col gap-3"
        >
          <article
            :for={{dom_id, msg} <- @streams.chat_messages}
            id={dom_id}
            data-role="chat-message"
            data-message-role={msg_role(msg)}
            data-transient={msg_transient?(msg)}
            class={[
              "flex flex-col gap-1 max-w-[88%]",
              msg_role(msg) == "user" && "self-end items-end ml-auto",
              msg_role(msg) == "agent" && "self-start items-start"
            ]}
          >
            <.operation_block
              :if={msg_operation(msg)}
              operation={msg_operation(msg)}
              expanded={operation_expanded?(@expanded_operation_ids, msg, msg_operation(msg))}
              target={@myself}
            />
            <div
              :if={is_nil(msg_operation(msg))}
              class={[
                "chat-message whitespace-pre-wrap break-words",
                msg_role(msg) == "user" && "chat-message--user",
                msg_role(msg) == "agent" && msg_transient?(msg) == "true" && "italic opacity-70"
              ]}
            >
              {msg_body(msg)}
            </div>
            <time
              :if={msg_timestamp(msg)}
              datetime={msg_timestamp(msg)}
              class="text-[10px] text-base-content/40 px-1"
            >
              {msg_timestamp(msg)}
            </time>
          </article>
        </div>
      </div>

      <%!-- Input footer — three controls in a horizontal row:
           [upload] [input] [send]. Identical on desktop and mobile. The
           upload button reuses the existing `agent_option_picked` flow
           (key="upload") which the parent StudioLive handles by opening
           the upload modal. --%>
      <form
        id={"#{@id}-form"}
        phx-hook=".ChatInput"
        phx-submit="chat.submit"
        data-role="chat-form"
        class={[
          "border-t border-base-200 bg-base-100 shrink-0 px-3 py-2",
          @mobile? && "pb-[max(0.5rem,env(safe-area-inset-bottom))]"
        ]}
        autocomplete="off"
      >
        <div class="flex items-end gap-2">
          <button
            id={"#{@id}-upload"}
            type="button"
            data-role="chat-upload"
            phx-click="agent_option_picked"
            phx-value-key="upload"
            class="composer-btn shrink-0"
            aria-label={dgettext("studio", "파일 업로드")}
          >
            <.icon name="hero-arrow-up-tray" class="size-4" />
          </button>
          <label for={"#{@id}-textarea"} class="sr-only">
            {dgettext("studio", "메시지")}
          </label>
          <div class="flex-1 [&_.fieldset]:!mb-0">
            <.input
              id={"#{@id}-textarea"}
              type="textarea"
              name="message"
              value=""
              rows="1"
              data-role="chat-textarea"
              data-autosize="true"
              placeholder={dgettext("studio", "메시지를 입력하세요…")}
              class="w-full textarea textarea-bordered textarea-sm resize-none min-h-[2.25rem] max-h-32"
            />
          </div>
          <button
            id={"#{@id}-send"}
            type="button"
            data-role="chat-send"
            data-action="send"
            class="composer-btn composer-btn--primary shrink-0"
            aria-label={dgettext("studio", "보내기")}
          >
            <.icon name="hero-paper-airplane" class="size-4" />
          </button>
        </div>
      </form>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatInput">
        export default {
          mounted() {
            this.form = this.el

            // Resolve the live textarea each call — morphdom may swap the node
            // across patches, so a cached ref can go stale.
            const textarea = () => this.form.querySelector('[data-role="chat-textarea"]')

            this.send = (e) => {
              if (e) e.preventDefault()
              const ta = textarea()
              if (!ta) return
              const value = ta.value
              if (!value || !value.trim()) return
              // chat.submit is handled by the parent StudioLive — pushEvent
              // from a LiveComponent-hosted hook still routes to the root LV.
              this.pushEvent("chat.submit", { message: value })
              ta.value = ""
              this.autosize()
              // Keep focus on the textarea so the mobile keyboard never hides.
              ta.focus({ preventScroll: true })
            }

            this.autosize = () => {
              const ta = textarea()
              if (!ta) return
              if (ta.dataset.autosize !== "true") return
              ta.style.height = "auto"
              const next = Math.min(ta.scrollHeight, 128)
              ta.style.height = next + "px"
            }

            // Event delegation on the stable <form> node. This is robust
            // against morphdom replacing the button or textarea subtree —
            // listeners on direct refs would silently break after a patch.
            this.onFormKeydown = (e) => {
              if (e.target.matches('[data-role="chat-textarea"]')
                  && e.key === "Enter" && !e.shiftKey && !e.isComposing) {
                this.send(e)
              }
            }

            this.onFormInput = (e) => {
              if (e.target.matches('[data-role="chat-textarea"]')) this.autosize()
            }

            // Mobile (iOS Safari) regression fix: tapping the send button
            // fires `blur` on the textarea, which dismisses the keyboard.
            // With `h-[100dvh]` the layout reflows mid-tap and the `click`
            // never lands. Calling preventDefault() on pointerdown/mousedown
            // for the send button stops the focus shift, so the textarea
            // stays focused, the keyboard stays open, no reflow happens,
            // and the subsequent `click` fires cleanly.
            this.onFormPointerDown = (e) => {
              const btn = e.target.closest('[data-role="chat-send"]')
              if (btn && this.form.contains(btn)) e.preventDefault()
            }

            this.onFormClick = (e) => {
              const btn = e.target.closest('[data-role="chat-send"]')
              if (btn && this.form.contains(btn)) this.send(e)
            }

            this.onFormSubmit = (e) => this.send(e)

            this.form.addEventListener("keydown", this.onFormKeydown)
            this.form.addEventListener("input", this.onFormInput)
            this.form.addEventListener("pointerdown", this.onFormPointerDown)
            this.form.addEventListener("mousedown", this.onFormPointerDown)
            this.form.addEventListener("click", this.onFormClick)
            this.form.addEventListener("submit", this.onFormSubmit)

            this.autosize()
          },
          destroyed() {
            if (!this.form) return
            this.form.removeEventListener("keydown", this.onFormKeydown)
            this.form.removeEventListener("input", this.onFormInput)
            this.form.removeEventListener("pointerdown", this.onFormPointerDown)
            this.form.removeEventListener("mousedown", this.onFormPointerDown)
            this.form.removeEventListener("click", this.onFormClick)
            this.form.removeEventListener("submit", this.onFormSubmit)
          }
        }
      </script>
    </aside>
    """
  end

  attr :operation, :map, required: true
  attr :expanded, :boolean, default: false
  attr :target, :any, default: nil

  def operation_block(assigns) do
    assigns =
      assigns
      |> assign(:operation_id, operation_id(assigns.operation))
      |> assign(:operation_type, operation_type(assigns.operation))
      |> assign(:operation_status, operation_status(assigns.operation))
      |> assign(:operation_title, operation_title(assigns.operation))
      |> assign(:operation_summary, operation_summary(assigns.operation))

    ~H"""
    <%= if @operation_type == "tool_call" do %>
      <button
        id={"tool-trace-#{@operation_id}"}
        type="button"
        phx-click="ui.toggle_expand"
        phx-value-operation_id={@operation_id}
        phx-target={@target}
        data-role="tool-trace"
        data-status={@operation_status}
        class="tool-trace flex w-full items-center gap-2 rounded-md border border-base-200 bg-base-100 px-3 py-2 text-left text-sm text-base-content/75 transition hover:border-base-300 hover:text-base-content"
      >
        <.icon
          name={if(@expanded, do: "hero-chevron-down", else: "hero-check")}
          class="size-4 shrink-0 text-base-content/50"
        />
        <span class="tool-trace__label min-w-0 flex-1 truncate">
          {dgettext("studio", "답변을 수정 범위에 연결함")}
        </span>
        <span
          :if={@operation_summary != ""}
          class="tool-trace__meta shrink-0 text-xs text-base-content/50"
        >
          {@operation_summary}
        </span>
      </button>
      <div
        :if={@expanded}
        id={"tool-trace-#{@operation_id}-details"}
        data-role="tool-trace-details"
        class="border-t border-base-200 bg-base-50 px-3 py-2 text-xs text-base-content/70"
      >
        <pre class="whitespace-pre-wrap break-words leading-relaxed">{operation_details(@operation)}</pre>
      </div>
    <% else %>
      <section
        id={"operation-block-#{@operation_id}"}
        data-role="operation-block"
        data-operation-type={@operation_type}
        data-operation-status={@operation_status}
        class={[
          "w-full rounded-md border border-base-300 bg-base-100 text-base-content shadow-sm overflow-hidden",
          @operation_type == "tool_call" && "tool-trace"
        ]}
      >
        <button
          id={"operation-block-#{@operation_id}-toggle"}
          type="button"
          phx-click="ui.toggle_expand"
          phx-value-operation_id={@operation_id}
          phx-target={@target}
          class="flex w-full items-start gap-2 px-3 py-2 text-left transition hover:bg-base-200/70"
        >
          <.icon
            name={if(@expanded, do: "hero-chevron-down", else: "hero-chevron-right")}
            class="mt-0.5 size-4 shrink-0 text-base-content/50"
          />
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2">
              <span class="truncate text-xs font-semibold uppercase text-base-content/60">
                {operation_label(@operation_type)}
              </span>
              <span class="rounded-full bg-base-200 px-1.5 py-0.5 text-[10px] font-medium text-base-content/60">
                {operation_status_label(@operation_status)}
              </span>
            </div>
            <p class="truncate text-sm font-medium text-base-content">{@operation_title}</p>
            <p :if={@operation_summary != ""} class="mt-0.5 text-xs text-base-content/60">
              {@operation_summary}
            </p>
          </div>
        </button>
        <div
          :if={@operation_type == "evidence"}
          data-role="evidence-block"
          class="border-t border-base-200 bg-base-50 px-3 py-2 text-xs text-base-content/70"
        >
          <div class="flex items-start justify-between gap-3">
            <dl class="grid min-w-0 flex-1 grid-cols-[auto_1fr] gap-x-2 gap-y-1">
              <dt class="text-base-content/50">인용</dt>
              <dd class="truncate font-medium text-base-content">{evidence_citation(@operation)}</dd>
              <dt class="text-base-content/50">출처</dt>
              <dd class="truncate">{evidence_source(@operation)}</dd>
              <dt class="text-base-content/50">수집 시각</dt>
              <dd>
                <time datetime={evidence_captured_at(@operation)}>
                  {evidence_captured_at(@operation)}
                </time>
              </dd>
            </dl>
            <button
              :if={evidence_snapshot_id(@operation)}
              type="button"
              data-role="evidence-attach"
              phx-click="evidence.attach"
              phx-value-evidence_snapshot_id={evidence_snapshot_id(@operation)}
              class="inline-flex size-8 shrink-0 items-center justify-center rounded-md border border-base-300 text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
              aria-label={dgettext("studio", "근거 연결")}
            >
              <.icon name="hero-link" class="size-4" />
            </button>
          </div>
        </div>
        <div
          :if={@operation_type == "source_interpretation"}
          data-role="source-interpretation-block"
          class="border-t border-base-200 bg-base-50 px-3 py-2 text-xs text-base-content/70"
        >
          <div class="flex items-center justify-between gap-3">
            <span class="font-medium text-base-content">{dgettext("studio", "원문 문서")}</span>
            <span>{source_claim_count_label(length(source_operation_claims(@operation)))}</span>
          </div>
          <ul
            :if={source_operation_regions(@operation) != []}
            class="mt-2 space-y-1"
            data-role="source-regions"
          >
            <li :for={region <- source_operation_regions(@operation)} class="truncate">
              <span>{detail_value(region, "raw_text")}</span>
            </li>
          </ul>
          <ul
            :if={source_operation_claims(@operation) != []}
            class="mt-2 space-y-1"
            data-role="source-claims"
          >
            <li
              :for={claim <- source_operation_claims(@operation)}
              class="rounded border border-base-200 px-2 py-1"
            >
              <span class="font-medium">{claim_kind_label(claim)}</span>
              <span class="ml-1">{claim_value(claim)}</span>
            </li>
          </ul>
        </div>
        <div
          :if={@operation_type == "source_claim"}
          data-role="source-claim-block"
          class="border-t border-base-200 bg-base-50 px-3 py-2 text-xs text-base-content/70"
        >
          <dl class="grid grid-cols-[auto_minmax(0,1fr)] gap-x-2 gap-y-1">
            <dt class="font-medium text-base-content/60">항목</dt>
            <dd>{source_claim_field_label(@operation)}</dd>
            <dt class="font-medium text-base-content/60">값</dt>
            <dd>{source_claim_value(@operation)}</dd>
            <dt class="font-medium text-base-content/60">신뢰도</dt>
            <dd>{source_claim_confidence(@operation)}</dd>
          </dl>
          <ul
            :if={source_claim_anchors(@operation) != []}
            class="mt-2 space-y-1"
            data-role="source-claim-anchors"
          >
            <li
              :for={anchor <- source_claim_anchors(@operation)}
              class="rounded border border-base-200 px-2 py-1"
            >
              <span :if={detail_value(anchor, "page")}>p.{detail_value(anchor, "page")}</span>
              <span>{detail_value(anchor, "text") || inspect(anchor)}</span>
            </li>
          </ul>
          <div class="mt-2 flex flex-wrap gap-1.5" data-role="source-claim-controls">
            <button
              type="button"
              class="btn btn-xs btn-primary"
              phx-click="source_claim.confirm"
              phx-value-source_claim_id={source_claim_id(@operation)}
              phx-value-source_document_id={source_document_id(@operation)}
            >
              확정
            </button>
            <details class="group/correct" data-role="source-claim-correct-panel">
              <summary class="btn btn-xs list-none marker:hidden">
                수정
              </summary>
              <.form
                for={source_claim_correction_form(@operation)}
                id={"source-claim-correct-form-#{source_claim_id(@operation)}"}
                phx-submit="source_claim.correct"
                data-role="source-claim-correct-form"
                class="mt-2 flex w-full min-w-64 items-end gap-2 rounded-md border border-base-200 bg-base-100 p-2"
              >
                <input type="hidden" name="source_claim_id" value={source_claim_id(@operation)} />
                <input type="hidden" name="source_document_id" value={source_document_id(@operation)} />
                <.input
                  id={"source-claim-correct-value-#{source_claim_id(@operation)}"}
                  name="value"
                  type="text"
                  value={source_claim_value(@operation)}
                  class="input input-xs min-w-0 flex-1"
                />
                <button type="submit" class="btn btn-xs btn-primary">저장</button>
              </.form>
            </details>
            <button
              type="button"
              class="btn btn-xs btn-ghost"
              phx-click="source_claim.reject"
              phx-value-source_claim_id={source_claim_id(@operation)}
              phx-value-source_document_id={source_document_id(@operation)}
            >
              반려
            </button>
            <button
              type="button"
              class="btn btn-xs"
              phx-click="source_claim.link_to_document"
              phx-value-source_claim_id={source_claim_id(@operation)}
              phx-value-source_document_id={source_document_id(@operation)}
            >
              문서에 연결
            </button>
            <button
              type="button"
              class="btn btn-xs btn-ghost"
              phx-click="source_claim.unlink"
              phx-value-source_claim_id={source_claim_id(@operation)}
              phx-value-source_document_id={source_document_id(@operation)}
            >
              연결 해제
            </button>
          </div>
        </div>
        <div
          :if={@expanded}
          id={"operation-block-#{@operation_id}-details"}
          data-role="operation-details"
          class="border-t border-base-200 bg-base-50 px-3 py-2"
        >
          <pre class="whitespace-pre-wrap break-words text-xs leading-relaxed text-base-content/70">{operation_details(@operation)}</pre>
        </div>
      </section>
    <% end %>
    """
  end

  @impl true
  def mount(socket) do
    {:ok, assign(socket, :expanded_operation_ids, MapSet.new())}
  end

  @impl true
  def handle_event("ui.toggle_expand", %{"operation_id" => operation_id}, socket) do
    expanded = socket.assigns[:expanded_operation_ids] || MapSet.new()

    expanded =
      if MapSet.member?(expanded, operation_id) do
        MapSet.delete(expanded, operation_id)
      else
        MapSet.put(expanded, operation_id)
      end

    {:noreply, assign(socket, :expanded_operation_ids, expanded)}
  end

  # ----------------------------------------------------------------------------
  # Status pill helpers
  # ----------------------------------------------------------------------------

  @doc false
  def agent_status(%{agent_run_id: nil}), do: %{key: :idle, label: status_idle()}

  def agent_status(%{agent_run_id: id}) when is_binary(id),
    do: %{key: :responding, label: status_busy()}

  def agent_status(_), do: %{key: :idle, label: status_idle()}

  defp status_idle, do: dgettext("studio", "대기 중")
  defp status_busy, do: dgettext("studio", "응답 중…")

  defp status_pill_class(:responding),
    do: "bg-primary/10 text-primary"

  defp status_pill_class(:error),
    do: "bg-error/10 text-error"

  defp status_pill_class(_),
    do: "bg-base-200 text-base-content/60"

  # ----------------------------------------------------------------------------
  # Observer / persona helpers
  # ----------------------------------------------------------------------------

  @doc false
  # agent_supervised persona perm signature: has agent_run + write + commit
  # but lacks both :export and :type_change. This is the unique fingerprint
  # vs. lawyer (has both), paralegal (has type_change), viewer (no write),
  # admin (has both).
  def observer_mode?(%{perms: perms}) when is_list(perms) do
    :agent_run in perms and :write in perms and :commit in perms and
      :export not in perms and :type_change not in perms
  end

  def observer_mode?(_), do: false

  # ----------------------------------------------------------------------------
  # No-document welcome — SPEC.md §10. When the LV mounts WITHOUT a selected
  # document, the chat shows a pre-canned agent message with 5 quick-start
  # options. Each chip emits `agent_option_picked` with a `key`, which the
  # parent StudioLive handles uniformly.
  # ----------------------------------------------------------------------------

  @doc false
  def no_document?(%Contract.Studio.State{mode: :no_document}), do: true
  def no_document?(%{mode: :no_document}), do: true
  def no_document?(_), do: false

  @doc false
  def start_options do
    [
      %{key: "recent", label: dgettext("studio", "최근 문서 열기")},
      %{key: "blank", label: dgettext("studio", "빈 계약서 만들기")},
      %{key: "draft_from_discussion", label: dgettext("studio", "논의에서 시작")},
      %{key: "variant_from_other", label: dgettext("studio", "다른 문서에서 변형 만들기")}
    ]
  end

  # ----------------------------------------------------------------------------
  # Grill helpers — the parent decides whether the latest agent message has
  # unanswered ask-marks; we just render the sub-component when told.
  # ----------------------------------------------------------------------------

  defp resolve_grill_active?(assigns) do
    cond do
      assigns[:grill_active?] == true -> true
      Map.get(assigns[:studio_state] || %{}, :grill_active?) == true -> true
      true -> false
    end
  end

  # ----------------------------------------------------------------------------
  # Message field extractors — the stream items use a few shapes:
  #
  #   * user message:   %{id, role: :user, body, timestamp}
  #   * agent stream:   %{id, role: :agent, event: <event>, transient?: true}
  #   * agent complete: %{id, role: :agent, result: <result>, transient?: false}
  # ----------------------------------------------------------------------------

  defp msg_operation(%{operation: operation}) when is_map(operation), do: operation
  defp msg_operation(%{"operation" => operation}) when is_map(operation), do: operation
  defp msg_operation(_), do: nil

  defp operation_expanded?(expanded_ids, msg, operation) do
    operation_id = operation_id(operation)
    MapSet.member?(expanded_ids || MapSet.new(), operation_id) || msg_expanded?(msg)
  end

  defp msg_expanded?(%{expanded?: true}), do: true
  defp msg_expanded?(%{"expanded?" => true}), do: true
  defp msg_expanded?(_), do: false

  defp operation_id(operation), do: operation_value(operation, "id") || Ecto.UUID.generate()
  defp operation_type(operation), do: operation_value(operation, "type") || "operation"
  defp operation_status(operation), do: operation_value(operation, "status") || "pending"

  defp operation_title(operation) do
    case operation_type(operation) do
      "source_claim" ->
        dgettext("studio", "%{field} 확인", field: source_claim_field_label(operation))

      _ ->
        operation_value(operation, "title") || operation_label(operation_type(operation))
    end
  end

  defp operation_summary(operation) do
    case operation_type(operation) do
      "source_interpretation" ->
        source_claim_count_label(length(source_operation_claims(operation)))

      _ ->
        operation_value(operation, "summary") || operation_value(operation, "body") || ""
    end
  end

  defp evidence_snapshot_id(operation), do: operation_value(operation, "evidence_snapshot_id")

  defp evidence_source(operation) do
    operation
    |> operation_value("source")
    |> source_label(operation_value(operation, "provider"))
  end

  defp evidence_citation(operation),
    do: operation_value(operation, "citation") || operation_title(operation)

  defp evidence_captured_at(operation), do: operation_value(operation, "captured_at") || ""

  defp operation_details_map(operation) do
    case operation_value(operation, "details") do
      details when is_map(details) -> stringify_detail_keys(details)
      _ -> %{}
    end
  end

  defp stringify_detail_keys(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp source_operation_claims(operation),
    do: operation |> operation_details_map() |> Map.get("claims", []) |> List.wrap()

  defp source_operation_regions(operation),
    do: operation |> operation_details_map() |> Map.get("regions", []) |> List.wrap()

  defp source_claim_id(operation),
    do: operation_details_map(operation)["source_claim_id"] || operation_value(operation, "id")

  defp source_claim_correction_form(operation),
    do: Phoenix.Component.to_form(%{"value" => source_claim_value(operation)})

  defp source_document_id(operation),
    do: operation_details_map(operation)["source_document_id"] || ""

  defp source_claim_anchors(operation) do
    details = operation_details_map(operation)

    (details["anchors"] || get_in(details, ["proposed_structured", "anchors"]) || [])
    |> List.wrap()
  end

  defp source_claim_confidence(operation),
    do: operation |> operation_details_map() |> Map.get("confidence") |> display_value()

  defp source_claim_field(operation) do
    details = operation_details_map(operation)
    details["proposed_kind"] || details["field"] || details["field_id"] || ""
  end

  defp source_claim_field_label(operation), do: source_claim_field(operation) |> field_label()

  defp source_claim_value(operation) do
    details = operation_details_map(operation)
    details["user_value"] || details["value"] || details["proposed_value"] || ""
  end

  defp display_value(nil), do: ""
  defp display_value(value) when is_binary(value), do: value
  defp display_value(value) when is_integer(value), do: Integer.to_string(value)
  defp display_value(value) when is_float(value), do: Float.to_string(value)
  defp display_value(value), do: inspect(value)

  defp claim_kind(claim),
    do: detail_value(claim, "proposed_kind") || detail_value(claim, "kind") || ""

  defp claim_kind_label(claim), do: claim |> claim_kind() |> field_label()

  defp claim_value(claim),
    do: detail_value(claim, "proposed_value") || detail_value(claim, "value") || ""

  defp detail_value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp detail_value(_map, _key), do: nil

  defp operation_details(operation) do
    details = operation_value(operation, "details") || operation

    case Jason.encode(details, pretty: true) do
      {:ok, encoded} -> encoded
      {:error, _} -> inspect(details, pretty: true)
    end
  end

  defp operation_value(operation, key) when is_map(operation) do
    Map.get(operation, key) || Map.get(operation, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(operation, key)
  end

  defp operation_value(_operation, _key), do: nil

  defp operation_label("tool_call"), do: "도구 실행"
  defp operation_label("source_interpretation"), do: "원문 해석"
  defp operation_label("source_claim"), do: "추출값"
  defp operation_label("evidence"), do: "근거"
  defp operation_label("export_status"), do: "내보내기"
  defp operation_label("conversion_plan"), do: "변환 계획"

  defp operation_label(_type) when is_binary(_type), do: dgettext("studio", "작업")

  defp operation_label(_), do: "작업"

  defp operation_status_label("completed"), do: dgettext("studio", "완료")
  defp operation_status_label("ready"), do: dgettext("studio", "준비됨")
  defp operation_status_label("proposed"), do: dgettext("studio", "제안됨")
  defp operation_status_label("pending"), do: dgettext("studio", "대기")
  defp operation_status_label("failed"), do: dgettext("studio", "실패")
  defp operation_status_label(_status) when is_binary(_status), do: dgettext("studio", "진행 중")
  defp operation_status_label(_), do: dgettext("studio", "진행 중")

  defp source_claim_count_label(count), do: dgettext("studio", "추출값 %{count}개", count: count)

  defp source_label(source, provider) do
    source = to_string(source || "")
    provider = to_string(provider || "")

    cond do
      String.contains?(provider, "law_mcp") or String.contains?(source, "Korea Law MCP") ->
        dgettext("studio", "법령 검색 결과")

      source == "" ->
        dgettext("studio", "제공된 근거")

      true ->
        dgettext("studio", "제공된 근거")
    end
  end

  defp field_label("effective_date"), do: dgettext("studio", "효력 발생일")
  defp field_label("party_a"), do: dgettext("studio", "갑")
  defp field_label("party_b"), do: dgettext("studio", "을")
  defp field_label("counterparty"), do: dgettext("studio", "상대방")
  defp field_label("contract_amount"), do: dgettext("studio", "계약 금액")
  defp field_label("payment_terms"), do: dgettext("studio", "지급 조건")
  defp field_label("term"), do: dgettext("studio", "계약 기간")
  defp field_label(value) when is_binary(value) and value != "", do: dgettext("studio", "문서 항목")
  defp field_label(_), do: dgettext("studio", "문서 항목")

  defp msg_role(%{role: :user}), do: "user"
  defp msg_role(%{role: "user"}), do: "user"
  defp msg_role(%{role: :agent}), do: "agent"
  defp msg_role(%{role: "agent"}), do: "agent"
  defp msg_role(%{role: :assistant}), do: "agent"
  defp msg_role(%{role: "assistant"}), do: "agent"
  defp msg_role(_), do: "agent"

  defp msg_transient?(%{transient?: true}), do: "true"
  defp msg_transient?(_), do: "false"

  defp msg_body(%{body: body}) when is_binary(body), do: body
  defp msg_body(%{result: %{body: body}}) when is_binary(body), do: body
  defp msg_body(%{result: result}) when is_binary(result), do: result
  defp msg_body(%{event: %{delta: delta}}) when is_binary(delta), do: delta
  defp msg_body(%{event: %{body: body}}) when is_binary(body), do: body
  defp msg_body(%{event: %{text: text}}) when is_binary(text), do: text
  defp msg_body(%{event: text}) when is_binary(text), do: text
  defp msg_body(_), do: ""

  defp msg_timestamp(%{timestamp: %DateTime{} = ts}), do: DateTime.to_iso8601(ts)
  defp msg_timestamp(%{timestamp: ts}) when is_binary(ts), do: ts
  defp msg_timestamp(_), do: nil
end
