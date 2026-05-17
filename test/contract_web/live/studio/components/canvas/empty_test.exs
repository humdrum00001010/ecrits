defmodule ContractWeb.Live.Studio.Components.Canvas.EmptyTest do
  @moduledoc """
  Canvas.Empty test surface — rebaselined for the 2026-05-17 owner
  directive: the empty state hosts the full four-option onboarding
  surface (SPEC.md §4.2 + §4.4). The four affordances are:

    * `계약서 업로드`           — inline dropzone (NOT a modal)
    * `빈 문서로 시작`          — `agent_option_picked` key=blank
    * `최근 문서 열기`          — `agent_option_picked` key=recent
    * `에이전트와 먼저 상의하기` — JS.focus to the chat-rail textarea

  The upload pipeline is wired into the parent StudioLive's existing
  `document.upload` / `document.upload.validate` events. Component-side
  rendering of the form (phx-submit name, file input presence) is
  pinned here; the end-to-end upload flow is covered in
  `ContractWeb.StudioLiveTest` (which drives `document.upload` against
  real Blobs + SourceDocuments through the Mox-backed pipeline).
  """
  use ContractWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Contract.AccountsFixtures

  alias Contract.Context
  alias Contract.Studio.State
  alias ContractWeb.Live.Studio.Components.Canvas.Empty

  # ---------------------------------------------------------------------------
  # Persona-perm fixtures (mirror Contract.PersonaFactory)
  # ---------------------------------------------------------------------------

  defp lawyer_scope(user),
    do: %Context{
      Context.for_user(user)
      | perms: ~w(read write commit revoke export type_change agent_run)a
    }

  defp viewer_scope(user),
    do: %Context{Context.for_user(user) | perms: ~w(read)a}

  defp no_doc_state, do: %State{mode: :no_document, last_seen_revision: 0}

  # `document_upload` in production is the LV upload-config struct created
  # by `allow_upload/3` in StudioLive.mount. For component rendering we
  # only need a thing that looks-like-an-upload-config with `:ref` and
  # `:entries`. A bare map is enough — `live_file_input/1` accepts any
  # struct/map shape with these fields.
  defp upload_stub(opts \\ []) do
    %Phoenix.LiveView.UploadConfig{
      name: :document_upload,
      ref: "phx-upload-canvas-empty",
      max_entries: 1,
      max_file_size: 50_000_000,
      accept: :any,
      entries: Keyword.get(opts, :entries, [])
    }
  end

  defp render_empty(opts) do
    scope =
      Keyword.get_lazy(opts, :current_scope, fn -> lawyer_scope(user_fixture()) end)

    render_component(Empty,
      id: "canvas",
      studio_state: Keyword.get(opts, :studio_state, no_doc_state()),
      projection:
        Keyword.get(opts, :projection, %{nodes: %{}, fields: %{}, marks: %{}, refs: %{}}),
      current_scope: scope,
      document_upload: Keyword.get(opts, :document_upload, upload_stub())
    )
  end

  # ---------------------------------------------------------------------------
  # render_component cases
  # ---------------------------------------------------------------------------

  describe "render_component/2 — base render + persona gating" do
    test "renders the canvas-empty container with the illustration + headings" do
      html = render_empty([])

      assert html =~ ~s(data-stub="canvas-empty")
      assert html =~ ~s(data-role="canvas-empty")
      # Illustration reused from the dashboard empty-state.
      assert html =~ ~s(src="/images/landing/dashboard-empty.png")
      # Heading + subtitle (Korean primary).
      assert html =~ "문서를 선택하거나 새로 만드세요"
      assert html =~ "왼쪽에서 문서를 고르거나, 새 계약서를 시작합니다."
    end

    test "renders all four onboarding affordances for a lawyer (has :write)" do
      html = render_empty([])

      assert html =~ ~s(data-role="canvas-empty-actions")

      # 1. 계약서 업로드 — inline dropzone form + file input
      assert html =~ ~s(data-role="canvas-empty-upload-form")
      assert html =~ ~s(data-role="canvas-empty-upload-dropzone")
      assert html =~ ~s(data-role="canvas-empty-upload-input")
      assert html =~ "계약서 업로드"
      # The form wires the existing StudioLive upload events.
      assert html =~ ~s(phx-submit="document.upload")
      assert html =~ ~s(phx-change="document.upload.validate")

      # 2. 빈 문서로 시작
      assert html =~ ~s(data-role="canvas-empty-new-document")
      assert html =~ ~s(phx-value-key="blank")
      assert html =~ "빈 문서로 시작"

      # 3. 최근 문서 열기
      assert html =~ ~s(data-role="canvas-empty-recent")
      assert html =~ ~s(phx-value-key="recent")
      assert html =~ "최근 문서 열기"

      # 4. 에이전트와 먼저 상의하기 — JS.focus to the chat composer
      assert html =~ ~s(data-role="canvas-empty-discuss")
      assert html =~ "에이전트와 먼저 상의하기"
      # JS.focus serializes as a phx-click attribute containing the
      # "focus" op and the chat composer's id.
      assert html =~ ~r/phx-click="\[\[&quot;focus&quot;[^"]*chat-rail-textarea/u
    end

    test "renders a real <input type=file> via live_file_input" do
      html = render_empty([])

      # The dropzone is wired to a real file input — not a stub.
      assert html =~ ~s(type="file")
      assert html =~ ~s(data-role="canvas-empty-upload-input")
    end

    test "renders pending upload entries when entries != []" do
      entry = %Phoenix.LiveView.UploadEntry{
        ref: "0",
        client_name: "계약서.pdf",
        progress: 42,
        valid?: true
      }

      html = render_empty(document_upload: upload_stub(entries: [entry]))

      assert html =~ "계약서.pdf"
      assert html =~ "42%"
    end

    test "viewer persona sees illustration + copy but none of the actions" do
      user = user_fixture()
      html = render_empty(current_scope: viewer_scope(user))

      # Body still rendered.
      assert html =~ "문서를 선택하거나 새로 만드세요"
      # …but every actionable affordance is hidden.
      refute html =~ ~s(data-role="canvas-empty-actions")
      refute html =~ ~s(data-role="canvas-empty-upload-form")
      refute html =~ "빈 문서로 시작"
      refute html =~ "최근 문서 열기"
      refute html =~ "에이전트와 먼저 상의하기"
    end

    test "hides every action when current_scope.perms == [:read]" do
      user = user_fixture()
      scope = %Context{Context.for_user(user) | perms: ~w(read)a}

      html = render_empty(current_scope: scope)

      refute html =~ "빈 문서로 시작"
      refute html =~ ~s(data-role="canvas-empty-upload-form")
    end

    test "hides actions when current_scope.perms is nil (defensive)" do
      user = user_fixture()
      scope = %Context{Context.for_user(user) | perms: nil}

      html = render_empty(current_scope: scope)

      refute html =~ "빈 문서로 시작"
      refute html =~ ~s(data-role="canvas-empty-upload-form")
    end

    test "Korean strings are precomposed Hangul syllables (no jamo decomposition)" do
      html = render_empty([])

      # Precomposed: each Korean character lives in the Hangul Syllables
      # block (U+AC00..U+D7A3). NFD-decomposed strings would contain
      # Hangul Jamo (U+1100..U+11FF) or compatibility jamo (U+3130..U+318F)
      # instead.
      assert String.match?(html, ~r/[\x{AC00}-\x{D7A3}]/u)
      refute String.match?(html, ~r/[\x{1100}-\x{11FF}]/u)
      refute String.match?(html, ~r/[\x{3130}-\x{318F}]/u)

      assert html =~ :unicode.characters_to_nfc_binary("문서를 선택하거나 새로 만드세요")
      assert html =~ :unicode.characters_to_nfc_binary("계약서 업로드")
      assert html =~ :unicode.characters_to_nfc_binary("빈 문서로 시작")
      assert html =~ :unicode.characters_to_nfc_binary("최근 문서 열기")
      assert html =~ :unicode.characters_to_nfc_binary("에이전트와 먼저 상의하기")
    end
  end

  # ---------------------------------------------------------------------------
  # Click dispatch — when wired up via a live `/studio` mount, the canvas
  # buttons reach StudioLive.handle_event/3 and produce the right side
  # effects. We assert the routing for `agent_option_picked` keys
  # (the existing handlers create_blank_document + open document-picker
  # are pinned in `ContractWeb.StudioLiveTest`); here we lock the
  # buttons fire those exact keys.
  # ---------------------------------------------------------------------------

  describe "click events route through StudioLive.handle_event/3" do
    setup %{conn: conn} do
      user = user_fixture()
      %{conn: log_in_user(conn, user), user: user}
    end

    test "blank button fires agent_option_picked key=blank → mints doc + navigates",
         %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/studio")
      scope = Contract.Context.for_user(user)

      # Owner starts with zero documents.
      assert Contract.Documents.list_recent_for_scope(scope, 5) == []

      # Fire the exact event the button emits. The handler
      # create_blank_document/1 routes through Runtime.apply and
      # push_navigates to /documents/:id.
      render_hook(lv, "agent_option_picked", %{"key" => "blank"})

      # A Document row exists and the LV navigated to it.
      [doc] = Contract.Documents.list_recent_for_scope(scope, 5)
      assert doc.owner_id == user.id
      assert_redirect(lv, "/documents/" <> doc.id)
    end

    test "recent button fires agent_option_picked key=recent and opens picker",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/studio")

      refute :sys.get_state(lv.pid).socket.assigns.studio_state.document_picker_open?

      _ = render_hook(lv, "agent_option_picked", %{"key" => "recent"})

      assert :sys.get_state(lv.pid).socket.assigns.studio_state.document_picker_open? ==
               true
    end
  end
end
