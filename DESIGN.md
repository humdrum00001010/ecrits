> **Status:** Design reference (v31 final synthesis, 2026-05-17).
> Treat as guidance, not ground truth. Where this conflicts with
> SPEC.md v0.5 (e.g. routes), SPEC.md wins. Where this conflicts with
> the binding memory entries in `~/.claude/projects/-home-ereignis/memory/`
> (mature-visual-language, generated-imagery, responsive-scope,
> personal-visual-review), those memories win.

# Contract Studio SPEC.md — Final UI/Frontend Direction

Version: v31 final synthesis
Frontend target: Elixir Phoenix LiveView
Source-of-truth assets: `assets/*.svg` with matching `assets/*.png` for handoff only

## 0. Final product model

Contract Studio is not a generic document editor and not a review-queue SaaS.

It has three live surfaces:

1. `/` — landing page
   Explains the value: project context is turned into contract clauses.
2. `/dashboard` — document library
   Lets the user open, create, or import contract documents.
3. `/studio/:document_id` — StudioLive
   A contract IR editor rendered as a document surface with a right-side conversational agent rail.

The core loop is:

```text
project context → agent asks missing decisions → user answers in natural language
→ answer maps to a structured edit target → contract clause updates → ledger records the change
```

Do not expose technical terms like `IR`, `MCP`, or `patch` to ordinary users. Internally, StudioLive edits structured contract IR. In the UI, translate this as:

```text
IR range   → 수정 범위
IR slot    → 열린 자리 / 입력 가능한 자리
IR patch   → 반영된 변경
IR ledger  → 변경 이력
IR node    → 조항 구조
```

## 1. Route map

```elixir
# lib/contract_web/router.ex
scope "/", ContractWeb do
  pipe_through :browser

  live "/", LandingLive, :index
  live "/dashboard", DashboardLive, :index
  live "/studio/:document_id", StudioLive, :show
end
```

`/studio/new` is not required for v1. New document creation is a dashboard action. Contract upload is also a dashboard action, not a navbar item.

## 2. Shared visual system

Use a restrained, professional light theme. The final direction is closer to a quiet document workspace than a playful SaaS dashboard.

```css
:root {
  --cs-bg: #FAFAF7;
  --cs-surface: #FFFFFF;
  --cs-surface-soft: #F6F4EE;
  --cs-ink: #171717;
  --cs-muted: #6B7280;
  --cs-line: #E5E7EB;
  --cs-line-strong: #D1D5DB;
  --cs-green: #1E5B3A;
  --cs-green-2: #2F7C58;
  --cs-blue: #2F6FEB;
  --cs-amber: #AA7B31;
  --cs-red: #B45342;
  --cs-radius-sm: 6px;
  --cs-radius-md: 9px;
  --cs-radius-lg: 14px;
  --cs-shadow-card: 0 8px 24px rgba(17, 24, 39, 0.08);
  --cs-shadow-popover: 0 18px 44px rgba(17, 24, 39, 0.12);
}
```

Typography:

```css
body {
  font-family: "Noto Sans CJK KR", "NanumSquare", system-ui, sans-serif;
  color: var(--cs-ink);
}

.cs-editor-body {
  font-family: "Noto Sans CJK KR", "NanumBarunGothic", system-ui, sans-serif;
}
```

Do not ship font files. Use the app font stack.

## 3. Endpoint: `/` LandingLive

### Purpose

Landing should not show the Studio UI. It should not look like a screenshot of the product. It should communicate one value clearly:

> 프로젝트의 맥락을 계약 조항으로 구체화합니다.

The landing should feel like a serious tool for small law firms, in-house legal teams, and contract-heavy operators.

### Copy

Primary:

```text
프로젝트의 맥락을
계약 조항으로
구체화합니다.
```

Secondary:

```text
Contract Studio는 계약서를 쓰기 전에
프로젝트가 실제로 어떻게 진행되는지 묻습니다.
그 답은 조항과 변경 이력으로 남습니다.
```

CTA:

```text
대시보드 열기
작동 방식 보기
```

### Visual composition

Use only three conceptual blocks on the hero visual:

1. `프로젝트 브리프`
2. `StudioLive가 먼저 묻는 질문`
3. `조항과 변경 이력으로 남김`

Do not use people, cartoon-like agents, 3D props, floating neon pipelines, or actual Studio screenshots.

### Phoenix skeleton

```elixir
# lib/contract_web/live/landing_live.ex

defmodule ContractWeb.LandingLive do
  use ContractWeb, :live_view

  def render(assigns) do
    ~H"""
    <.app_shell active={nil}>
      <main class="landing">
        <section class="landing__copy">
          <p class="eyebrow">Contract Studio</p>
          <h1>프로젝트의 맥락을<br/>계약 조항으로<br/>구체화합니다.</h1>
          <p class="lead">
            Contract Studio는 계약서를 쓰기 전에<br/>
            프로젝트가 실제로 어떻게 진행되는지 묻습니다.<br/>
            그 답은 조항과 변경 이력으로 남습니다.
          </p>
          <.link navigate={~p"/dashboard"} class="primary-cta">대시보드 열기</.link>
          <a href="#how-it-works" class="secondary-link">작동 방식 보기 →</a>
        </section>

        <section class="landing__system" aria-label="project context to contract clauses">
          <.project_brief_panel />
          <.agent_questions_panel />
          <.contract_ledger_panel />
        </section>
      </main>
    </.app_shell>
    """
  end
end
```

Asset: `assets/landing.svg`, `assets/landing.png`

## 4. Endpoint: `/dashboard` DashboardLive

### Purpose

Dashboard is a document library, similar in intent to a clean Google Docs grid. It is not an analytics dashboard.

### Required behavior

- No numeric metric cards.
- No recent activity feed.
- No sidebar.
- No `다음 질문` text on document cards.
- `계약서 업로드` must not live in the global navbar.
- `새 문서` and `계약서 업로드` are content actions inside the dashboard header.
- `계약서 업로드` opens a small dropdown/popover, not a modal.

### Card information

Each card shows only:

```text
문서 썸네일
문서명
상태 dot + status text
수정일
overflow menu
```

### Upload dropdown

`계약서 업로드` means importing an existing contract file into StudioLive.

Dropdown copy:

```text
파일에서 가져오기
기존 계약서 파일을 StudioLive로 가져옵니다.

PDF, DOCX, HWP 지원
StudioLive에서 열립니다.
```

### LiveView upload setup

```elixir
# lib/contract_web/live/dashboard_live.ex

def mount(_params, _session, socket) do
  socket =
    socket
    |> assign(:documents, Documents.recent_documents())
    |> assign(:upload_menu_open?, false)
    |> allow_upload(:contract_file,
      accept: ~w(.pdf .docx .hwp),
      max_entries: 1,
      auto_upload: true
    )

  {:ok, socket}
end

def handle_event("toggle_upload_menu", _params, socket) do
  {:noreply, update(socket, :upload_menu_open?, &(!&1))}
end

def handle_event("new_document", _params, socket) do
  {:ok, doc} = Documents.create_blank_document(socket.assigns.current_user)
  {:noreply, push_navigate(socket, to: ~p"/studio/#{doc.id}")}
end

def handle_event("consume_uploaded_entries", _params, socket) do
  uploaded =
    consume_uploaded_entries(socket, :contract_file, fn %{path: path}, entry ->
      Documents.import_contract(socket.assigns.current_user, path, entry.client_name)
    end)

  case uploaded do
    [{:ok, doc}] -> {:noreply, push_navigate(socket, to: ~p"/studio/#{doc.id}")}
    _ -> {:noreply, socket}
  end
end
```

### Render skeleton

```elixir

def render(assigns) do
  ~H"""
  <.app_shell active="대시보드">
    <main class="dashboard">
      <div class="dashboard__top">
        <h1>최근 문서</h1>
        <div class="dashboard__actions">
          <button phx-click="new_document" class="button button--primary">새 문서</button>

          <div class="upload-menu" phx-click-away="close_upload_menu">
            <button phx-click="toggle_upload_menu" class="button button--secondary">
              계약서 업로드 <span aria-hidden="true">⌄</span>
            </button>
            <%= if @upload_menu_open? do %>
              <.contract_upload_menu upload={@uploads.contract_file} />
            <% end %>
          </div>
        </div>
      </div>

      <nav class="dashboard__tabs">
        <button class="is-active">모든 문서</button>
        <button>즐겨찾기</button>
      </nav>

      <section class="document-grid">
        <%= for doc <- @documents do %>
          <.document_card document={doc} />
        <% end %>
      </section>
    </main>
  </.app_shell>
  """
end
```

### Components

```elixir
attr :document, :map, required: true

def document_card(assigns) do
  ~H"""
  <article class="document-card">
    <div class="document-card__preview">
      <.document_thumbnail document={@document} />
      <button class="document-card__menu" aria-label="문서 메뉴">⋮</button>
    </div>
    <div class="document-card__body">
      <h2><%= @document.title %></h2>
      <p class="document-card__status">
        <span class={["status-dot", "status-dot--#{@document.status}"]}></span>
        <%= status_label(@document.status) %>
      </p>
      <p class="document-card__date">수정일 <%= format_date(@document.updated_at) %></p>
    </div>
  </article>
  """
end
```

Asset: `assets/dashboard.svg`, `assets/dashboard.png`, `assets/contract-upload-menu.svg`, `assets/contract-upload-menu.png`

## 5. Endpoint: `/studio/:document_id` StudioLive

### Purpose

StudioLive is an IR editor rendered as a contract document. It must not look like Google Docs or Word.

### Non-negotiables

- No generic rich-text formatting toolbar as the primary UI.
- No font selector, alignment toolbar, generic bold/italic ribbon.
- No `AI 수정`, `patch`, or `IR` labels inside the document body.
- No Accept/Decline review queue.
- No left activity rail.
- The right rail is conversational and must show user answers before agent-applied changes.
- Tool calls are collapsed one-line traces.

### What the user sees

The document looks directly editable, but edits are scoped to structured units:

```text
열린 자리       제3조 금액   제4조 지연 기준   현재: 제8조 특약 1항
```

Inside the document:

- Human-editable fields use compact inline controls.
- Repeatable special-term slots are natural contract lines, not form cards.
- Only one unfinished special-term slot is visible at a time.
- AI-applied changes use subtle underline only, no label.

### StudioLive data model

```elixir
defmodule ContractStudio.Studio.EditableSlot do
  @enforce_keys [:id, :label, :kind, :path, :active?]
  defstruct [:id, :label, :kind, :path, :active?, :value, :placeholder]
end

defmodule ContractStudio.Studio.ToolTrace do
  @enforce_keys [:id, :label, :status]
  defstruct [:id, :label, :meta, :status, :expanded?, :raw_name, :args, :result]
end

defmodule ContractStudio.Studio.Message do
  @enforce_keys [:id, :role, :body]
  defstruct [:id, :role, :body, :inserted_at]
end
```

### Mount and events

```elixir
# lib/contract_web/live/studio_live.ex

def mount(%{"document_id" => id}, _session, socket) do
  document = Documents.get_document!(id)
  ir = Studio.load_document_ir(document)

  {:ok,
   socket
   |> assign(:document, document)
   |> assign(:ir, ir)
   |> assign(:open_slots, Studio.open_editable_slots(ir))
   |> assign(:active_slot_id, Studio.active_slot_id(ir))
   |> assign(:messages, Studio.recent_messages(document))
   |> assign(:tool_traces, [])
   |> assign(:composer, "")}
end

def handle_event("set_active_slot", %{"slot-id" => slot_id}, socket) do
  {:noreply, assign(socket, :active_slot_id, slot_id)}
end

def handle_event("edit_slot", %{"slot-id" => slot_id, "value" => value}, socket) do
  {:ok, ir} = Studio.update_slot_value(socket.assigns.ir, slot_id, value)
  {:noreply, assign(socket, :ir, ir)}
end

def handle_event("materialize_slot", %{"slot-id" => slot_id}, socket) do
  {:ok, ir, ledger_entry} = Studio.materialize_slot(socket.assigns.ir, slot_id)

  {:noreply,
   socket
   |> assign(:ir, ir)
   |> assign(:open_slots, Studio.open_editable_slots(ir))
   |> push_event("ledger-recorded", %{id: ledger_entry.id})}
end

def handle_event("send_message", %{"message" => text}, socket) do
  {:ok, result} = Studio.agent_answer(socket.assigns.document, text)

  {:noreply,
   socket
   |> assign(:messages, result.messages)
   |> assign(:tool_traces, result.tool_traces)
   |> assign(:ir, result.ir)}
end
```

### Render skeleton

```elixir

def render(assigns) do
  ~H"""
  <.app_shell active="스튜디오">
    <main class="studio-live">
      <section class="studio-document">
        <header class="studio-document__bar">
          <h1><%= @document.title %></h1>
          <span class="document-status"><%= status_label(@document.status) %></span>
          <span class="saved-state">저장됨</span>
        </header>

        <.open_slots_strip slots={@open_slots} active_slot_id={@active_slot_id} />

        <article class="contract-projection">
          <.render_contract_ir ir={@ir} active_slot_id={@active_slot_id} />
        </article>
      </section>

      <aside class="studio-rail">
        <.agent_rail messages={@messages} traces={@tool_traces} composer={@composer} />
      </aside>
    </main>
  </.app_shell>
  """
end
```

### Editable fields

```elixir
attr :slot, :map, required: true
attr :active?, :boolean, default: false

def editable_slot(assigns) do
  ~H"""
  <span
    class={["editable-slot", @active? && "editable-slot--active"]}
    phx-click="set_active_slot"
    phx-value-slot-id={@slot.id}
  >
    <input
      name={@slot.id}
      value={@slot.value || ""}
      placeholder={@slot.placeholder}
      phx-change="edit_slot"
      phx-value-slot-id={@slot.id}
      phx-blur="materialize_slot"
      autocomplete="off"
    />
  </span>
  """
end
```

CSS guidance:

```css
.editable-slot {
  display: inline-flex;
  width: max-content;
  min-width: 7ch;
  max-width: 34ch;
  border: 1px solid var(--cs-line-strong);
  border-radius: 6px;
  background: #fff;
  vertical-align: baseline;
}

.editable-slot input {
  width: auto;
  min-width: inherit;
  max-width: inherit;
  border: 0;
  background: transparent;
  padding: 3px 8px;
  font: inherit;
  outline: none;
}

.editable-slot--active {
  border-color: #7A9FE8;
  box-shadow: 0 0 0 2px rgba(47, 111, 235, 0.08);
}

.ai-applied-change {
  text-decoration-line: underline;
  text-decoration-thickness: 1.5px;
  text-decoration-color: var(--cs-green-2);
  text-underline-offset: 4px;
}
```

### Agent rail behavior

The agent must not appear to decide alone. The sequence must be visible:

```text
Agent asks project-level question.
User answers in natural language.
Tool trace maps answer to 수정 범위.
Tool trace applies change.
Agent confirms what changed and where it was recorded.
```

Collapsed tool traces:

```text
› 답변을 수정 범위에 연결함     제8조 1항 · 84ms
› 조항에 반영함                p_0482 · 128ms
```

Raw tool names such as `mcp.apply_ir_patch` may appear only in expanded developer details, not by default.

Asset: `assets/studio-live.svg`, `assets/studio-live.png`

## 6. Asset manifest

Only these generated assets are part of the final handoff:

```text
assets/landing.svg
assets/landing.png
assets/dashboard.svg
assets/dashboard.png
assets/contract-upload-menu.svg
assets/contract-upload-menu.png
assets/studio-live.svg
assets/studio-live.png
```

No contact sheets, no preview composites, no extra speculative components.

## 7. Final design prohibitions

Do not reintroduce:

- dashboard metric cards
- dashboard `다음 질문` in document cards
- upload action in global navbar
- upload modal for contract import
- StudioLive as a generic rich-text editor
- body tags like `AI 수정`, `IR`, `patch`
- large tool-call cards
- Accept/Decline approval queues
- left activity/sidebar rail in StudioLive
- playful 3D objects, people-as-agent imagery, or cartoonish visual metaphors
- landing page pipeline diagrams
- user-facing technical terms: IR, MCP, patch, tool call

## 8. Endpoint-to-asset mapping

| Endpoint | Source asset | Notes |
|---|---|---|
| `/` | `assets/landing.svg` | Landing value page; no product screenshot. |
| `/dashboard` | `assets/dashboard.svg` | Document grid; upload action inside content header. |
| `/dashboard` upload menu | `assets/contract-upload-menu.svg` | Small dropdown/popover, not modal. |
| `/studio/:document_id` | `assets/studio-live.svg` | IR projection editor + conversational rail. |
