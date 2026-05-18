defmodule ContractWeb.LegacyRedirectControllerTest do
  @moduledoc """
  Tests for `ContractWeb.LegacyRedirectController` — the dumping ground
  for routes that pre-date naming changes but must continue to resolve
  for bookmarks, Slack unfurls, email links, and agent transcripts.

  Each redirect is asserted to be a permanent (301) response so caches
  and link previews can pin the new URL.
  """
  use ContractWeb.ConnCase, async: true

  describe "GET /dashboard" do
    setup :register_and_log_in_user

    test "permanently redirects to /storage (renamed 2026-05-17)", %{conn: conn} do
      conn = get(conn, ~p"/dashboard")
      assert redirected_to(conn, 301) == ~p"/storage"
    end
  end

  describe "GET /matters/:matter_id/documents/:document_id" do
    setup :register_and_log_in_user

    test "permanently redirects to /documents/:document_id", %{conn: conn} do
      conn = get(conn, "/matters/m_42/documents/d_99")
      assert redirected_to(conn, 301) == ~p"/documents/d_99"
    end
  end
end
