defmodule ContractWeb.StudioLiveDocumentFirstTest do
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contract.Command
  alias Contract.Context
  alias Contract.Documents
  alias Contract.Studio.State
  alias ContractWeb.StudioLive

  setup :register_and_log_in_user

  test "authenticated document route mounts owner-scoped Studio", %{conn: conn, scope: scope} do
    {:ok, doc} = Documents.create(scope, %{title: "Owner draft", type_key: "nda_v1"})

    {:ok, lv, html} = live(conn, ~p"/documents/#{doc.id}")

    assert html =~ ~s(id="studio-root")
    assert :sys.get_state(lv.pid).socket.assigns.studio_state.selected_document_id == doc.id
  end

  test "authenticated v33 studio route mounts the same owner-scoped document", %{
    conn: conn,
    scope: scope
  } do
    {:ok, doc} = Documents.create(scope, %{title: "Studio v33 draft", type_key: "nda_v1"})

    {:ok, lv, html} = live(conn, ~p"/studio/#{doc.id}")

    # The studio main pane used to carry a `.studio-live` class; after
    # the Tailwind utility migration we pin the surface via its #studio-root
    # id and the inline phx-hook attribute.
    assert html =~ ~s(id="studio-root")
    assert html =~ ~s(phx-hook="ContractWeb.StudioLive.Viewport")
    assert html =~ "Studio v33 draft"
    assert :sys.get_state(lv.pid).socket.assigns.studio_state.selected_document_id == doc.id
  end

  test "v33 studio document surface uses natural labels and no technical body tags", %{
    conn: conn,
    scope: scope
  } do
    {:ok, doc} = Documents.create(scope, %{title: "용역계약서", type_key: "nda_v1"})

    {:ok, lv, _html} = live(conn, ~p"/studio/#{doc.id}")
    html = lv |> element("#studio-document-header") |> render()

    # Title input lives in the document header bar (the former
    # `.studio-document__bar` class is now Tailwind utilities).
    assert has_element?(lv, "#studio-document-header")
    # The "수정 가능한 자리" pre-aggregated nav was removed in #34 —
    # editability is now communicated by inline coloring + input-like
    # UI in the document body itself, not by an upfront chip rail.
    refute has_element?(lv, "[data-role='open-slots']")
    visible_text = visible_text(html)
    refute visible_text =~ "ledger"
    refute visible_text =~ "AI 수정"
    refute visible_text =~ "IR"
    refute visible_text =~ "patch"
    refute visible_text =~ "tool call"
    refute visible_text =~ "Tool call"
    refute visible_text =~ "font selector"
  end

  test "tool protocol messages render as compact v33 trace rows by default", %{
    conn: conn,
    scope: scope
  } do
    {:ok, _doc} = Documents.create(scope, %{title: "Trace draft", type_key: "nda_v1"})
    {:ok, lv, _html} = live(conn, ~p"/studio")

    send(
      lv.pid,
      {:tool_call_completed, "agent-run-1", "tool-1",
       %{raw_name: "contract_ir.patch.apply", summary: "제8조 1항 · 84ms"}}
    )

    html = render(lv)

    assert html =~ ~s(id="tool-trace-tool-agent-run-1-tool-1")
    assert html =~ ~s(data-role="tool-trace")
    assert html =~ ~s(data-status="completed")
    assert html =~ ~s(class="tool-trace)
    assert html =~ "답변을 수정 범위에 연결함"
    assert html =~ "제8조 1항"

    collapsed_trace =
      lv
      |> element("#tool-trace-tool-agent-run-1-tool-1")
      |> render()

    refute collapsed_trace =~ "contract_ir.patch.apply"
    refute html =~ "Tool call"
  end

  test "document route does not mount a document owned by a different user", %{conn: conn} do
    other_user = Contract.AccountsFixtures.user_fixture()
    other_scope = Context.for_user(other_user)
    {:ok, other_doc} = Documents.create(other_scope, %{title: "Other owner draft"})

    {:ok, lv, _html} = live(conn, ~p"/documents/#{other_doc.id}")

    assigns = :sys.get_state(lv.pid).socket.assigns
    assert assigns.studio_state.selected_document_id == nil
    assert assigns.studio_state.mode == :no_document
  end

  test "dotted UI events build document-first commands without matter fields", %{scope: scope} do
    doc_id = Ecto.UUID.generate()

    assigns = %{
      current_scope: scope,
      studio_state: %State{selected_document_id: doc_id, last_seen_revision: 7, mode: :editing}
    }

    assert {:ok, %Command{} = command} =
             StudioLive.event_to_command("chat.submit", %{"message" => "Review this"}, assigns)

    assert command.kind == :chat_message
    assert command.document_id == doc_id
    assert command.chat_thread_id == nil
    refute Map.has_key?(Map.from_struct(command), :matter_id)
  end

  defp visible_text(html) do
    html
    |> String.replace(~r/<script[\s\S]*?<\/script>/, "")
    |> String.replace(~r/<!--[\s\S]*?-->/, "")
    |> String.replace(~r/<[^>]+>/, " ")
  end
end
