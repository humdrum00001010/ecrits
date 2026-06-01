defmodule ContractWeb.StorageLiveDocumentFirstTest do
  @moduledoc """
  Storage is packet-first: `/storage` creates packets, not documents.
  """
  use ContractWeb.ConnCase, async: false

  @moduletag :legacy_saas

  import Phoenix.LiveViewTest

  alias Contract.Documents
  alias Contract.Packets

  setup :register_and_log_in_user

  test "storage create form mints a packet and never a document", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, html} = live(conn, ~p"/storage")

    assert Documents.list_recent_for_scope(scope, 5) == []

    assert html =~ ~s(id="open-packet-create-modal")
    refute html =~ ~s(id="packet-create-form")
    refute html =~ "계약서 업로드"

    lv
    |> element("#open-packet-create-modal")
    |> render_click()

    lv
    |> form("#packet-create-form",
      packet: %{title: "패킷 우선"}
    )
    |> render_submit()

    assert Documents.list_recent_for_scope(scope, 5) == []
    [packet] = Packets.list_packets_for_scope(scope)
    assert packet.title == "패킷 우선"
    assert_redirect(lv, ~p"/packets/#{packet.id}")
  end
end
