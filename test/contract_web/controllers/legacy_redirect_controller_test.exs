defmodule ContractWeb.LegacyRedirectControllerTest do
  @moduledoc """
  Tests for hosted browser routes retired by the localize migration.
  """
  use ContractWeb.ConnCase, async: true

  describe "GET /dashboard" do
    test "returns gone instead of reaching old storage", %{conn: conn} do
      conn = get(conn, ~p"/dashboard")
      assert response(conn, 410) =~ "hosted route has been retired"
    end
  end
end
