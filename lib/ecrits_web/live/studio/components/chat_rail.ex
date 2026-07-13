defmodule EcritsWeb.Live.Studio.Components.ChatRail do
  @moduledoc """
  The central agent dialog surface (Wave 3C1 / chat-rail).

  Responsibilities:

    * Renders the streamed conversation (`@streams.chat_messages`) — both
      user-authored messages and agent prose (streamed + completed).
    * Mounts the `GrillRail` sub-LiveComponent when the latest agent
      message has unresolved `mode: "grill"` ask-marks.
    * Owns the textarea + send button input footer.
    * Uses agent status to switch the composer between send and stop actions.
    * Switches between a desktop right-rail layout and a mobile full-viewport
      layout depending on the `layout` attr / `viewport` assign.

  Submission belongs to LiveView through the form's `phx-submit`. The
  colocated `.ChatInput` hook translates Enter into a native form submission
  and applies textarea autosizing; it does not own message or submission state.

  Keyboard rules:

    * Enter (no shift) → submit
    * Shift+Enter → newline
    * Send button → native form submit
  """
  use EcritsWeb, :live_component

  alias Ecrits.Studio.ChatRailState
  alias EcritsWeb.Live.Studio.Components.GrillRail

  attr :id, :string, required: true
  attr :state, :map, required: true
  attr :streams, :map, required: true

  @impl true
  def render(%{state: %ChatRailState{}} = assigns) do
    ~H"""
    <aside
      id={@id}
      data-component="chat-rail"
      data-layout={if ChatRailState.mobile?(@state), do: "mobile", else: "desktop"}
      data-stub="chat-rail"
      class={[
        "group/chat flex flex-col bg-base-200 text-base-content min-h-0 h-full w-full",
        not ChatRailState.mobile?(@state) && "shrink-0 border-l border-base-300",
        ChatRailState.mobile?(@state) && "w-full flex-1 h-full"
      ]}
    >
      <div
        data-role="chat-rail-controls"
        class="flex shrink-0 items-center justify-between gap-1.5 border-b border-base-300 bg-base-200/95 px-1.5 py-0.5"
      >
        <h2
          data-role="chat-thread-title"
          title={chat_thread_title(@state)}
          class="flex min-w-0 flex-1 items-center gap-1.5 text-sm font-semibold leading-5 text-base-content"
        >
          <img
            src={~p"/images/icons/openai-blossom.svg"}
            data-role="chat-title-favicon"
            aria-hidden="true"
            alt=""
            class="size-4 shrink-0 opacity-85"
          />
          <form
            id="chat-thread-title-form"
            phx-submit="chat.thread.rename"
            phx-change="chat.thread.rename"
            data-role="chat-thread-title-form"
            class="min-w-0 flex-1"
          >
            <input
              id="chat-thread-title-input"
              type="text"
              name="title"
              value={chat_thread_title(@state)}
              phx-debounce="blur"
              aria-label={dgettext("studio", "Chat title")}
              title={chat_thread_title(@state)}
              autocomplete="off"
              spellcheck="false"
              data-role="chat-thread-title-input"
              class="block h-6 w-full min-w-0 truncate rounded-sm border border-transparent bg-transparent px-1 py-0 text-sm font-semibold leading-5 text-base-content outline-none transition-colors hover:border-base-300 hover:bg-base-100/60 focus:border-base-content/30 focus:bg-base-100 disabled:cursor-default disabled:text-base-content/70"
            />
          </form>
        </h2>

        <div class="flex shrink-0 items-center gap-1">
          <button
            type="button"
            phx-click="chat.context_reset"
            data-role="chat-context-reset"
            disabled={ChatRailState.chat_context_empty?(@state)}
            class="inline-flex size-8 items-center justify-center rounded-md text-base-content/60 hover:bg-base-300 hover:text-base-content disabled:cursor-not-allowed disabled:opacity-35 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-base-content/25"
            aria-label={dgettext("studio", "Reset chat context")}
            title={dgettext("studio", "Reset chat context")}
          >
            <.icon name="hero-arrow-path" class="size-4" />
          </button>
        </div>
      </div>

      <%!-- Observer-mode banner (agent_supervised persona) --%>
      <div
        :if={ChatRailState.observer_mode?(@state)}
        data-role="observer-banner"
        role="status"
        class="px-4 py-2 text-xs bg-warning/10 text-warning-content border-b border-warning/30"
      >
        {dgettext("studio", "관찰 모드 — 메시지는 다른 사용자가 받습니다")}
      </div>

      <%!-- GrillRail (unanswered ask-marks) --%>
      <div :if={@state.grill_active?} class="shrink-0">
        <.live_component
          module={GrillRail}
          id={"#{@id}-grill"}
          state={@state}
        />
      </div>

      <%!-- Generic welcome sits outside the stream so the stream can be a
           pure phx-update="stream" container. Hidden via the `group/chat`
           on the aside as soon as any chat-message appears in the stream. --%>
      <div
        :if={not ChatRailState.no_document?(@state)}
        id={"#{@id}-welcome"}
        data-role="chat-welcome"
        class="shrink-0 px-1.5 py-6 text-sm text-base-content/60 italic text-center group-has-[[data-role=chat-message]]/chat:hidden"
      >
        {dgettext(
          "studio",
          "에이전트에게 무엇이든 물어보세요 — 초안, 마크, 내보내기."
        )}
      </div>

      <%!-- Streamed conversation. Single scroll + stream container —
           no inner wrapper. --%>
      <div
        id={"#{@id}-stream"}
        phx-update="stream"
        data-role="chat-stream"
        class="flex-1 min-h-0 overflow-y-auto px-3 py-3 flex flex-col items-stretch gap-3"
      >
        <article
          :for={{dom_id, msg} <- @streams.chat_messages}
          :if={msg_visible?(msg)}
          id={dom_id}
          data-role="chat-message"
          data-message-role={msg_role(msg)}
          data-message-kind={msg_kind(msg)}
          data-transient={msg_transient?(msg)}
          hidden={msg_hidden?(msg)}
          class={
            [
              "group/message relative flex flex-col items-stretch gap-0.5 w-full",
              msg_role(msg) == "agent" && "self-start",
              # Collapse the parent stream's gap-3 between adjacent agent-side
              # articles so a tool_call row and the agent text that follows
              # read as a single turn rather than two separate messages.
              # Negative top margin on the *next* agent article cancels the
              # gap. Applied via Tailwind's next-sibling variant on this
              # element when it's an agent article.
              msg_role(msg) == "agent" && "[&+[data-message-role=agent]]:!-mt-3",
              tool_call_message?(msg) && "focus-visible:outline-none"
            ]
          }
        >
          <.operation_block
            :if={msg_operation(msg)}
            operation={msg_operation(msg)}
            transient?={msg_transient?(msg) == "true"}
          />
          <%!-- User message: full-width rounded card (Codex CLI style).
               Slightly elevated background distinguishes the input echo
               from the agent's flat prose without needing a colored fill
               or a chat-tail pill. --%>
          <div
            :if={is_nil(msg_operation(msg)) and msg_role(msg) == "user"}
            class="w-full border border-base-content/10 bg-base-300/50 px-3 py-1.5 text-[13px] leading-snug whitespace-normal break-words text-base-content/95 shadow-[inset_0_1px_3px_rgba(0,0,0,0.10)]"
          >
            <.markdown_body body={msg_body(msg)} paragraph_role="chat-md-paragraph" />
          </div>

          <%!-- Agent message: flat prose, no card. Sits flush at the
               column edge like ChatGPT / Codex CLI. `agent-text` span is
               the per-token append target. Completed messages render through
               the limited Markdown renderer; transient JS appends still add
               escaped text nodes until the final message is inserted. --%>
          <div
            :if={is_nil(msg_operation(msg)) and msg_role(msg) == "agent"}
            data-role="agent-text"
            data-message-id={dom_id}
            aria-busy={msg_transient?(msg)}
            class="block px-3 py-1 text-[14px] leading-relaxed break-words text-base-content"
          >
            <.markdown_body body={msg_body(msg)} paragraph_role="agent-paragraph" />
            <span
              :if={agent_loading?(msg)}
              data-role="agent-loading"
              role="status"
              aria-label={dgettext("studio", "답변 작성 중")}
              class="ml-1 inline-flex h-4 translate-y-[0.125rem] items-end gap-0.5 align-baseline text-base-content/45"
            >
              <span
                aria-hidden="true"
                class="size-1 rounded-full bg-current motion-safe:animate-bounce [animation-delay:-240ms]"
              >
              </span>
              <span
                aria-hidden="true"
                class="size-1 rounded-full bg-current motion-safe:animate-bounce [animation-delay:-120ms]"
              >
              </span>
              <span
                aria-hidden="true"
                class="size-1 rounded-full bg-current motion-safe:animate-bounce"
              >
              </span>
            </span>
          </div>

          <time
            :if={not is_nil(msg_timestamp(msg)) and is_nil(msg_operation(msg))}
            datetime={msg_timestamp(msg)}
            class="text-[10px] text-base-content/35 self-end whitespace-nowrap"
          >
            {format_msg_time(msg_timestamp(msg))}
          </time>
        </article>
      </div>

      <%!-- Input footer — icon upload + message input + icon send.
           The row shape is identical on desktop and mobile. --%>
      <form
        id={"#{@id}-form"}
        phx-hook=".ChatInput"
        phx-submit="chat.submit"
        data-role="chat-form"
        class={[
          "border-t border-base-300 bg-base-200 shrink-0 px-3 py-2",
          ChatRailState.mobile?(@state) && "pb-[max(0.5rem,env(safe-area-inset-bottom))]"
        ]}
        autocomplete="off"
      >
        <%!-- Codex-style composer: full-width textarea on top, a faint
             meta row underneath (left = upload affordance, right = send
             arrow). Mono placeholder reads as a CLI prompt. --%>
        <div class="rounded-md border border-base-300 bg-base-100 focus-within:border-base-content/40 transition-colors">
          <label for={"#{@id}-textarea"} class="sr-only">
            {dgettext("studio", "메시지")}
          </label>
          <textarea
            id={"#{@id}-textarea"}
            name="message"
            rows="1"
            data-role="chat-textarea"
            data-autosize="true"
            placeholder={dgettext("studio", "메시지를 입력하세요 · Enter 보내기, Shift+Enter 줄바꿈")}
            class="block w-full min-h-[2.25rem] max-h-40 px-3 pt-2 pb-1 bg-transparent border-0 text-[13px] leading-snug text-base-content placeholder:text-base-content/35 resize-none outline-none focus:outline-none focus:ring-0 focus:shadow-none"
          ></textarea>
          <div class="flex items-center justify-between gap-2 px-2 pb-1.5 pt-0.5 text-[11px] text-base-content/45">
            <div class="flex items-center gap-1">
              <label
                id={"#{@id}-upload"}
                data-role="chat-upload"
                for="document-direct-upload-input"
                class="inline-flex h-6 w-6 cursor-pointer items-center justify-center rounded text-base-content/45 hover:text-base-content hover:bg-base-200 transition-colors"
                aria-label={dgettext("studio", "파일 업로드")}
              >
                <.icon name="hero-paper-clip" class="size-3.5" />
              </label>
            </div>
            <%= if ChatRailState.busy?(@state) do %>
              <button
                id={"#{@id}-send"}
                type="button"
                phx-click="cancel_agent"
                data-role="chat-stop"
                data-action="stop"
                class="inline-flex h-6 w-6 items-center justify-center rounded bg-base-content text-base-100 hover:bg-base-content/80 transition-colors"
                aria-label={dgettext("studio", "중지")}
              >
                <.icon name="hero-stop" class="size-3.5" />
              </button>
            <% else %>
              <button
                id={"#{@id}-send"}
                type="submit"
                data-role="chat-send"
                data-action="send"
                class="inline-flex h-6 w-6 items-center justify-center rounded text-base-content/45 hover:text-base-content transition-colors"
                aria-label={dgettext("studio", "보내기")}
              >
                <.icon name="hero-paper-airplane" class="size-3.5" />
              </button>
            <% end %>
          </div>
        </div>
      </form>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ChatInput">
        const autosizeChatInput = form => {
          const textarea = form.querySelector('[data-role="chat-textarea"]')
          if (!textarea || textarea.dataset.autosize !== "true") return
          textarea.style.height = "auto"
          textarea.style.height = `${Math.min(textarea.scrollHeight, 128)}px`
        }

        const handleChatInput = event => autosizeChatInput(event.currentTarget)

        const handleChatKeydown = event => {
          const submit = event.target.matches('[data-role="chat-textarea"]')
            && event.key === "Enter"
            && !event.shiftKey
            && !event.isComposing
          if (!submit) return
          event.preventDefault()
          event.currentTarget.requestSubmit()
        }

        export default {
          mounted() {
            this.el.addEventListener("keydown", handleChatKeydown)
            this.el.addEventListener("input", handleChatInput)
            autosizeChatInput(this.el)
          },
          destroyed() {
            this.el.removeEventListener("keydown", handleChatKeydown)
            this.el.removeEventListener("input", handleChatInput)
          }
        }
      </script>
    </aside>
    """
  end

  attr :body, :string, required: true
  attr :paragraph_role, :string, default: nil

  def markdown_body(assigns) do
    ~H"""
    <.markdown_prose data-role="chat-md-body">
      {render_markdown(@body, @paragraph_role)}
    </.markdown_prose>
    """
  end

  # GFM markdown -> sanitized HTML via the shared MDEx renderer. Raw HTML in the
  # source is escaped by default, so agent/user output can't inject markup. On any
  # parse error the helper falls back to the plain text rather than crash.
  defp render_markdown(body, paragraph_role) do
    body
    |> EcritsWeb.Markdown.to_safe_html()
    |> markdown_html_string()
    |> EcritsWeb.Markdown.repair_chat_prose_boundaries()
    |> put_markdown_paragraph_role(paragraph_role)
    |> Phoenix.HTML.raw()
  end

  defp markdown_html_string({:safe, _iodata} = safe), do: Phoenix.HTML.safe_to_string(safe)

  defp markdown_html_string(html) when is_binary(html) and html != "" do
    html
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end

  defp markdown_html_string(_html), do: ""

  defp put_markdown_paragraph_role(html, role)
       when is_binary(html) and is_binary(role) and role != "" do
    if Regex.match?(~r/^[a-z0-9_-]+$/i, role) do
      String.replace(html, ~r/<p\b(?![^>]*\bdata-role=)([^>]*)>/, ~s(<p data-role="#{role}"\\1>))
    else
      html
    end
  end

  defp put_markdown_paragraph_role(html, _role), do: html

  attr :operation, :map, required: true
  attr :transient?, :boolean, default: false

  def operation_block(assigns) do
    assigns =
      assigns
      |> assign(:operation_id, operation_id(assigns.operation))
      |> assign(:operation_type, operation_type(assigns.operation))
      |> assign(:operation_status, operation_status(assigns.operation))
      |> assign(:operation_title, operation_title(assigns.operation))
      |> assign(:operation_summary, operation_summary(assigns.operation))
      |> then(fn assigns ->
        assign(
          assigns,
          :reasoning_message_id,
          reasoning_message_id(assigns.operation_type, assigns.operation_id)
        )
      end)

    ~H"""
    <%= if @operation_type in ["tool_call", "reasoning"] do %>
      <details class={[
        "group/trace relative flex w-full items-center gap-1 px-3 py-1.5",
        @operation_type == "reasoning" && @transient? && "animate-pulse"
      ]}>
        <summary
          id={"tool-trace-#{@operation_id}"}
          data-role="tool-trace"
          data-status={@operation_status}
          class={[
            "tool-trace inline-flex min-w-0 cursor-pointer list-none items-center gap-1.5 py-0.5 text-left text-[12px] leading-snug transition",
            @operation_status == "running" &&
              "text-base-content/45 animate-pulse",
            @operation_status == "completed" &&
              "text-base-content/55 hover:text-base-content/80",
            @operation_status == "failed" && "text-error/80"
          ]}
        >
          <.icon name="hero-wrench-screwdriver" class="size-3.5 shrink-0 opacity-70" />
          <span class="truncate">
            <span class="select-none">{operation_prefix_label(@operation_type)}: </span>
            <%= if @operation_type == "reasoning" do %>
              <span
                data-role="agent-reasoning-text"
                data-message-id={@reasoning_message_id}
                data-placeholder={reasoning_text_placeholder?(@operation_summary)}
                title={operation_reasoning_full(@operation)}
                class="min-w-0 truncate whitespace-nowrap"
              >
                {reasoning_text_or_placeholder(@operation_summary)}
              </span>
            <% else %>
              <span class="font-mono">{@operation_title}</span>
            <% end %>
            <span
              :if={@operation_type == "tool_call" and @operation_summary != ""}
              data-role="tool-trace-summary"
              class="ml-1 text-base-content/40"
            >
              {@operation_summary}
            </span>
          </span>
        </summary>
        <span
          id={"tool-trace-#{@operation_id}-expand"}
          data-role="tool-trace-expand"
          data-visible={tool_trace_expand_visible(@operation_status)}
          title={tool_trace_expand_label(@operation_status)}
          aria-label={tool_trace_expand_label(@operation_status)}
          class={[
            "absolute right-0 top-1/2 inline-flex size-6 -translate-y-1/2 items-center justify-center text-base-content/55 transition pointer-events-none",
            @operation_status == "failed" && "opacity-100 text-error/80",
            @operation_status != "failed" &&
              "opacity-0 group-hover/message:opacity-100 group-hover/trace:opacity-100"
          ]}
        >
          <.icon name="hero-chevron-down" class="size-3" />
        </span>
        <div
          id={"tool-trace-#{@operation_id}-details"}
          data-role="tool-trace-details"
          class="self-start w-full max-w-full"
        >
          <div
            data-role={reasoning_details_content_data_role(@operation_type)}
            data-message-id={@reasoning_message_id}
            class="rounded-md border border-base-300 bg-base-100 px-3 py-2 font-mono text-[11px] leading-relaxed text-base-content/60 shadow-sm"
          >
            <pre
              data-role={reasoning_details_data_role(@operation_type)}
              data-message-id={@reasoning_message_id}
              class="whitespace-pre-wrap break-words"
            >{operation_expanded_body(@operation_type, @operation)}</pre>
          </div>
          <div data-role="tool-trace-collapse-row" class="flex justify-center pt-1">
            <span
              id={"tool-trace-#{@operation_id}-collapse"}
              data-role="tool-trace-collapse"
              title={dgettext("studio", "접기")}
              aria-label={dgettext("studio", "접기")}
              class="inline-flex items-center gap-1 text-[11px] text-base-content/55 pointer-events-none"
            >
              <.icon name="hero-chevron-up" class="size-3" />
              {dgettext("studio", "접기")}
            </span>
          </div>
        </div>
      </details>
    <% else %>
      <details
        id={"operation-block-#{@operation_id}"}
        data-role="operation-block"
        data-operation-type={@operation_type}
        data-operation-status={@operation_status}
        class={[
          "w-full rounded-md border border-base-300 bg-base-100 text-base-content shadow-sm overflow-hidden",
          @operation_type == "tool_call" && "tool-trace"
        ]}
      >
        <summary
          id={"operation-block-#{@operation_id}-toggle"}
          aria-controls={"operation-block-#{@operation_id}-details"}
          class="flex w-full cursor-pointer list-none items-start gap-2 px-3 py-2 text-left transition hover:bg-base-200/70"
        >
          <span
            data-role="chev-right"
            class="mt-0.5 size-4 shrink-0 text-base-content/50 hero-chevron-right"
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
        </summary>
        <div
          id={"operation-block-#{@operation_id}-details"}
          data-role="operation-details"
          class="border-t border-base-200 bg-base-50 px-3 py-2"
        >
          <pre class="whitespace-pre-wrap break-words text-xs leading-relaxed text-base-content/70">{operation_details(@operation)}</pre>
        </div>
      </details>
    <% end %>
    """
  end

  # ----------------------------------------------------------------------------
  # Header helpers
  # ----------------------------------------------------------------------------

  defp chat_thread_title(%ChatRailState{thread_title: title})
       when is_binary(title) and title != "",
       do: title

  defp chat_thread_title(_), do: dgettext("studio", "새 대화")

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

  defp tool_call_message?(msg), do: match?(%{}, tool_call_operation(msg))

  defp tool_call_operation(msg) do
    case msg_operation(msg) do
      operation when is_map(operation) ->
        if operation_type(operation) in ["tool_call", "reasoning"], do: operation

      _ ->
        nil
    end
  end

  defp operation_id(operation), do: operation_value(operation, "id") || Ecto.UUID.generate()

  defp operation_type(operation) do
    operation_value(operation, "type") ||
      if(
        operation_value(operation, "name") || operation_value(operation, "output") ||
          operation_value(operation, "error"),
        do: "tool_call",
        else: "operation"
      )
  end

  defp operation_status(operation) do
    operation_value(operation, "status") ||
      cond do
        operation_value(operation, "error") -> "failed"
        operation_value(operation, "output") -> "completed"
        true -> "pending"
      end
  end

  defp operation_title(operation) do
    operation_value(operation, "title") || operation_value(operation, "name") ||
      operation_label(operation_type(operation))
  end

  defp operation_summary(operation) do
    operation_value(operation, "summary") || operation_value(operation, "body") || ""
  end

  defp operation_details_map(operation) do
    case operation_value(operation, "details") do
      details when is_map(details) -> stringify_detail_keys(details)
      _ -> %{}
    end
  end

  defp stringify_detail_keys(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp operation_details(operation) do
    tool_name = operation_value(operation, "name") || operation_title(operation)

    details =
      operation_value(operation, "details") || operation_value(operation, "output") ||
        case operation_value(operation, "error") do
          nil -> operation
          error -> %{"error" => error}
        end

    details = Ecrits.Doc.ToolPayloadSanitizer.sanitize_tool_payload(tool_name, details)

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

  defp operation_label(type) when is_binary(type), do: dgettext("studio", "작업")

  defp operation_label(_), do: "작업"

  defp tool_trace_expand_visible("failed"), do: "true"
  defp tool_trace_expand_visible(_status), do: "false"

  defp tool_trace_expand_label("failed"), do: dgettext("studio", "실패 세부 정보")
  defp tool_trace_expand_label(_status), do: dgettext("studio", "펼치기")

  defp operation_status_label("completed"), do: dgettext("studio", "완료")
  defp operation_status_label("ready"), do: dgettext("studio", "준비됨")
  defp operation_status_label("proposed"), do: dgettext("studio", "제안됨")
  defp operation_status_label("pending"), do: dgettext("studio", "대기")
  defp operation_status_label("failed"), do: dgettext("studio", "실패")
  defp operation_status_label(status) when is_binary(status), do: dgettext("studio", "진행 중")
  defp operation_status_label(_), do: dgettext("studio", "진행 중")

  defp msg_role(%{role: :user}), do: "user"
  defp msg_role(%{role: "user"}), do: "user"
  defp msg_role(%{role: :agent}), do: "agent"
  defp msg_role(%{role: "agent"}), do: "agent"
  defp msg_role(%{role: :assistant}), do: "agent"
  defp msg_role(%{role: "assistant"}), do: "agent"
  defp msg_role(_), do: "agent"

  defp msg_transient?(%{transient?: true}), do: "true"
  defp msg_transient?(_), do: "false"

  defp msg_kind(%{kind: kind}) when is_atom(kind), do: Atom.to_string(kind)
  defp msg_kind(%{kind: kind}) when is_binary(kind), do: kind
  defp msg_kind(_), do: "text"

  defp msg_visible?(msg) do
    # Legacy `kind: :reasoning` rows with no operation are filtered out —
    # the production path now persists reasoning as an `operation` map and
    # the `:agent_reasoning_done` handler deletes the streaming bubble
    # when the body ends up empty. Keeping the guard prevents stale ghost
    # rows in tests / older serialized state.
    not (is_nil(msg_operation(msg)) and msg_kind(msg) == "reasoning")
  end

  defp msg_hidden?(msg) do
    case msg_operation(msg) do
      operation when is_map(operation) ->
        operation_type(operation) == "reasoning" and
          String.trim(operation_summary(operation)) == "" and
          String.trim(operation_reasoning_full(operation)) == ""

      _ ->
        false
    end
  end

  defp reasoning_text_or_placeholder(summary) when is_binary(summary) do
    case String.trim(summary) do
      "" -> ""
      text -> text
    end
  end

  defp reasoning_text_or_placeholder(_), do: ""

  defp reasoning_text_placeholder?(summary) when is_binary(summary) do
    if String.trim(summary) == "", do: "true", else: "false"
  end

  defp reasoning_text_placeholder?(_), do: "true"

  defp reasoning_run_id("reasoning-" <> rest), do: rest
  defp reasoning_run_id(id) when is_binary(id), do: id
  defp reasoning_run_id(_), do: ""

  defp reasoning_message_id("reasoning", operation_id),
    do: "chat-msg-reasoning-#{reasoning_run_id(operation_id)}"

  defp reasoning_message_id(_, _), do: nil

  defp reasoning_details_content_data_role("reasoning"), do: "agent-reasoning-details-content"
  defp reasoning_details_content_data_role(_), do: nil

  defp reasoning_details_data_role("reasoning"), do: "agent-reasoning-details-text"
  defp reasoning_details_data_role(_), do: nil

  defp operation_prefix_label("reasoning"), do: "Thinking"
  defp operation_prefix_label(_), do: "Tool"

  defp operation_reasoning_full(operation) do
    details = operation_details_map(operation)
    Map.get(details, "text", "")
  end

  defp operation_expanded_body("reasoning", operation), do: operation_reasoning_full(operation)
  defp operation_expanded_body(_, operation), do: operation_details(operation)

  # Show the bouncing-dots indicator only while the message is in-flight
  # AND has no visible body yet. Once the first token has landed, drop the
  # dots — otherwise the indicator keeps trailing the prose as the JS hook
  # ferries it from paragraph to paragraph during streaming.
  defp agent_loading?(msg) do
    msg_transient?(msg) == "true" and msg_body(msg) == ""
  end

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

  # Compact wall-time HH:MM for the message side-marker. Falls back to the
  # raw string if parsing fails so tests / non-iso inputs don't crash.
  defp format_msg_time(nil), do: ""

  defp format_msg_time(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _} -> format_kst(dt)
      _ -> ts
    end
  end

  defp format_msg_time(%DateTime{} = dt), do: format_kst(dt)
  defp format_msg_time(_), do: ""

  # Render in Korea Standard Time (UTC+9, no DST → safe to hard-shift
  # without a tzdata dependency). Display-only — the underlying DateTime
  # stays tagged UTC in the DB.
  defp format_kst(%DateTime{} = dt) do
    dt
    |> DateTime.add(9 * 3600, :second)
    |> Calendar.strftime("%Y/%m/%d %H:%M")
  end
end
