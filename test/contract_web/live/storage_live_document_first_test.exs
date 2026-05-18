defmodule ContractWeb.StorageLiveDocumentFirstTest do
  @moduledoc """
  Per the 2026-05-17 owner directive, the storage surface's `새 문서`
  button navigates to `/studio` — it no longer mints a Document.
  Document creation, upload, and recent-document selection all live
  inside Studio's Canvas.Empty surface (SPEC.md §4.2 + §4.4).

  This test was originally written to lock in document-first behavior
  ("clicking 새 문서 lands the user on /documents/:id with an
  owner-scoped row"). We keep the file as the binding regression test
  for the new contract: NO doc is minted on /storage; the user lands
  on /studio instead.
  """
  use ContractWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Contract.Documents

  setup :register_and_log_in_user

  test "새 문서 navigates to /studio without minting a Document", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, ~p"/storage")

    assert Documents.list_recent_for_scope(scope, 5) == []

    lv |> element(~s(button[data-role="dashboard-new-document"])) |> render_click()

    # The storage surface must NOT create a Document — that responsibility
    # moved to /studio's Canvas.Empty surface.
    assert Documents.list_recent_for_scope(scope, 5) == []
    assert_redirect(lv, ~p"/studio")
  end
end
