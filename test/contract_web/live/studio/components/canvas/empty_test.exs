defmodule ContractWeb.Live.Studio.Components.Canvas.EmptyTest do
  @moduledoc """
  Canvas.Empty is currently a compatibility stub. The product empty
  surface lives in DocumentLive itself, where `/studio` renders the upload
  action and contract-type selection before navigating to `/studio/:id`.
  """
  use ContractWeb.ConnCase, async: true

  @moduletag :legacy_saas

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
    test "renders the canvas-empty compatibility stub" do
      html = render_empty([])

      assert html =~ ~s(data-stub="canvas-empty")
      assert html =~ ~s(data-role="canvas-empty")
      assert html =~ ~s(id="canvas")
      assert html =~ ~s(class="min-h-0")
    end

    test "does not render the DocumentLive-owned upload/type UI for writer personas" do
      html = render_empty([])

      refute html =~ ~s(data-role="canvas-empty-type-picker")
      refute html =~ ~s(data-role="canvas-empty-upload-action")
      refute html =~ ~s(data-role="canvas-empty-type-option")
      refute html =~ ~s(phx-click="set_contract_type")
      refute html =~ ~s(type="file")
    end

    test "does not render the DocumentLive-owned upload/type UI for viewer personas" do
      user = user_fixture()
      html = render_empty(current_scope: viewer_scope(user))

      assert html =~ ~s(data-stub="canvas-empty")
      refute html =~ ~s(data-role="canvas-empty-type-picker")
      refute html =~ ~s(data-role="canvas-empty-upload-action")
      refute html =~ ~s(data-role="canvas-empty-type-option")
    end

    test "hides every action when current_scope.perms == [:read]" do
      user = user_fixture()
      scope = %Context{Context.for_user(user) | perms: ~w(read)a}

      html = render_empty(current_scope: scope)

      assert html =~ ~s(data-stub="canvas-empty")
      refute html =~ ~s(data-role="canvas-empty-upload-action")
      refute html =~ ~s(data-role="canvas-empty-type-option")
    end

    test "hides actions when current_scope.perms is nil (defensive)" do
      user = user_fixture()
      scope = %Context{Context.for_user(user) | perms: nil}

      html = render_empty(current_scope: scope)

      assert html =~ ~s(data-stub="canvas-empty")
      refute html =~ ~s(data-role="canvas-empty-upload-action")
      refute html =~ ~s(data-role="canvas-empty-type-option")
    end

    test "does not render stale onboarding copy" do
      html = render_empty([])

      refute html =~ "문서를 선택하거나 새로 만드세요"
      refute html =~ "계약서 업로드"
      refute html =~ "빈 문서로 시작"
      refute html =~ "최근 문서 열기"
    end
  end

  # ---------------------------------------------------------------------------
  # Click dispatch — when wired up via a live `/studio` mount, the canvas
  # buttons reach DocumentLive.handle_event/3 and produce the right side
  # effects. We assert the routing for `agent_option_picked` keys
  # (the existing handlers create_blank_document + open document-picker
  # are pinned in `ContractWeb.DocumentLiveTest`); here we lock the
  # buttons fire those exact keys.
  # ---------------------------------------------------------------------------

  describe "click events route through DocumentLive.handle_event/3" do
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
      # push_navigates to /studio/:id.
      render_hook(lv, "agent_option_picked", %{"key" => "blank"})

      # A Document row exists and the LV navigated to it.
      [doc] = Contract.Documents.list_recent_for_scope(scope, 5)
      assert doc.owner_id == user.id
      assert_redirect(lv, "/studio/" <> doc.id)
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
