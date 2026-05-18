defmodule ContractWeb.LandingLive do
  @moduledoc """
  v33 public landing surface.

  The page is intentionally not a Studio screenshot and not a technical
  pipeline. It explains the product loop as project context becoming concrete
  contract clauses and change history.
  """
  use ContractWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Contract Studio")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell active={nil} current_scope={@current_scope}>
      <main class="landing-page" id="landing-page">
        <section class="landing-copy" aria-labelledby="landing-headline">
          <p class="eyebrow">Contract Studio</p>
          <h1 id="landing-headline">
            프로젝트의 맥락을<br />계약 조항으로<br />구체화합니다.
          </h1>
          <p class="lead">
            Contract Studio는 계약서를 쓰기 전에<br /> 프로젝트가 실제로 어떻게 진행되는지 묻습니다.<br /> 그 답은 조항과 변경 이력으로 남습니다.
          </p>
          <div class="landing-actions">
            <%= if match?(%{user: %{}}, @current_scope) do %>
              <.cs_button navigate={~p"/dashboard"} id="landing-dashboard-link">
                대시보드 열기
              </.cs_button>
            <% else %>
              <.cs_button navigate={~p"/users/register"} id="landing-dashboard-link">
                사용하기
              </.cs_button>
            <% end %>
            <.link navigate={~p"/preview"} class="text-link" id="landing-how-link">
              작동 방식 보기 →
            </.link>
          </div>
        </section>

        <section id="how" class="landing-preview" aria-label="StudioLive 미리보기">
          <div class="landing-preview__frame">
            <header class="landing-preview__bar">
              <span class="landing-preview__title">용역계약서</span>
              <span class="landing-preview__status">
                <span class="status-dot status-dot--review" aria-hidden="true"></span>검토 중
              </span>
              <span class="landing-preview__saved">저장됨</span>
            </header>

            <article class="landing-preview__doc">
              <p class="landing-preview__clause">
                <span class="landing-preview__clause-num">제3조 (대금)</span>
                본 계약의 대금은
                <span class="landing-preview__slot landing-preview__slot--active">12,000,000원</span>으로 한다.
              </p>
              <p class="landing-preview__clause">
                <span class="landing-preview__clause-num">제4조 (지급 기한)</span>
                대금은
                <span class="landing-preview__slot">계약 체결일로부터 30일 이내</span>에 지급한다.
              </p>
              <p class="landing-preview__clause">
                <span class="landing-preview__clause-num">제8조 (특약)</span>
                <span class="ai-applied-change">최근 변경: 위약금 한도 8% → 5%</span>로 한다.
              </p>
            </article>

            <aside class="landing-preview__rail" aria-label="StudioLive 대화">
              <p class="landing-preview__rail-meta">에이전트</p>
              <p class="landing-preview__rail-q">
                대금 지급 기한을 30일로 두는 이유가 있나요?
              </p>
              <p class="landing-preview__rail-a">
                세금계산서 발행 주기에 맞췄습니다.
              </p>
              <p class="landing-preview__rail-trace">
                › 답변을 수정 범위에 연결함 <span>제4조 · 84ms</span>
              </p>
            </aside>
          </div>

          <ul class="landing-preview__legend" aria-label="구성 요소">
            <li>
              <span class="landing-preview__legend-dot landing-preview__legend-dot--slot"></span>수정 가능한 자리
            </li>
            <li>
              <span class="landing-preview__legend-dot landing-preview__legend-dot--change"></span>반영된 변경
            </li>
            <li>
              <span class="landing-preview__legend-dot landing-preview__legend-dot--rail"></span>대화 · 변경 이력
            </li>
          </ul>
        </section>

        <nav class="landing-process" aria-label="Contract Studio 작동 방식">
          <a href="#how">프로젝트를 이해합니다</a>
          <a href="#how">빠진 결정을 질문합니다</a>
          <a href="#how">답변을 조항으로 정리합니다</a>
          <a href="#how">변경 이력을 남깁니다</a>
        </nav>
      </main>

      <footer class="landing-footer" aria-label="시작하기">
        <div class="landing-footer__primary">
          <p class="landing-footer__meta">Contract Studio · 비공개 베타 · 2026</p>
        </div>

        <div class="landing-footer__contacts" aria-label="문의">
          <p class="landing-footer__contacts-label">문의</p>
          <ul class="landing-footer__contacts-list">
            <li>
              <a href="mailto:ereignis@korea.ac.kr">ereignis@korea.ac.kr</a>
            </li>
          </ul>
        </div>
      </footer>
    </.app_shell>
    """
  end

  defp project_context_panel(assigns) do
    ~H"""
    <article class="project-context-panel" id="landing-project-context">
      <h2>프로젝트 브리프</h2>
      <dl class="project-context-panel__facts">
        <div>
          <dt>프로젝트명</dt>
          <dd>신축 오피스 빌딩 건설사업</dd>
        </div>
        <div>
          <dt>발주자</dt>
          <dd>에이전건설(주)</dd>
        </div>
        <div>
          <dt>수급인(예정)</dt>
          <dd>케이씨종합건설(주)</dd>
        </div>
        <div>
          <dt>기간</dt>
          <dd>착공 2024.07 · 준공 2026.12</dd>
        </div>
      </dl>
    </article>
    """
  end

  defp agent_questions_panel(assigns) do
    ~H"""
    <article class="agent-questions-panel" id="landing-agent-questions">
      <h2>StudioLive가 먼저 묻는 질문</h2>
      <ol class="agent-questions-panel__list">
        <li>
          <span aria-hidden="true">?</span>
          <div>
            <strong>완료는 언제 성립하나요?</strong>
            <p>산출물 승인, 운영 반영, 최종 검수 중 무엇인가요?</p>
          </div>
        </li>
        <li>
          <span aria-hidden="true">?</span>
          <div>
            <strong>방향 변경은 수정인가요, 새 과업인가요?</strong>
            <p>어디까지 포함된 수정인지 정해야 합니다.</p>
          </div>
        </li>
        <li>
          <span aria-hidden="true">?</span>
          <div>
            <strong>자료 지연 시 책임은 어떻게 바뀌나요?</strong>
            <p>일정 연장과 추가 비용 기준을 확인합니다.</p>
          </div>
        </li>
      </ol>
    </article>
    """
  end

  defp change_history_panel(assigns) do
    ~H"""
    <article class="change-history-panel" id="landing-change-history">
      <h2>조항과 변경 이력으로 남김</h2>
      <div class="change-history-panel__flow" aria-label="질문에서 변경 이력까지">
        <div>
          <span>질문</span>
          <strong>완료 기준 확인</strong>
        </div>
        <div class="change-history-panel__arrow" aria-hidden="true">→</div>
        <div>
          <span>답변</span>
          <strong>산출물 승인 완료</strong>
        </div>
        <div class="change-history-panel__arrow" aria-hidden="true">→</div>
        <div>
          <span>조항 반영</span>
          <strong>제8조 특약 3항</strong>
        </div>
        <div class="change-history-panel__arrow" aria-hidden="true">→</div>
        <div>
          <span>이력</span>
          <strong>2024.05.23 기록</strong>
        </div>
      </div>
    </article>
    """
  end
end
