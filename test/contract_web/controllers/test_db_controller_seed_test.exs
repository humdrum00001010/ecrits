defmodule ContractWeb.TestDbControllerSeedTest do
  @moduledoc """
  Plumbing tests for the retired Playwright seed routes in
  `ContractWeb.TestDbController`.

  DB seeding is gone with the local-first runtime; the route stays only
  as a stable retired envelope for older Playwright helpers.
  """

  use ContractWeb.ConnCase, async: true

  describe "Studio E2E seed helper surface" do
    test "does not expose normal matter seed helpers or routes" do
      seeds = File.read!(Path.expand("../../e2e/fixtures/seeds.ts", __DIR__))

      refute seeds =~ "seedMatter"
      refute seeds =~ "/test/db/matters"
    end
  end

  describe "POST /test/db/documents" do
    test "returns a retired envelope", %{conn: conn} do
      conn =
        post(conn, ~p"/test/db/documents", %{
          "type_key" => "nda_v1",
          "title" => "First NDA"
        })

      assert %{"ok" => false, "retired" => true, "error" => "db_retired"} =
               json_response(conn, 410)
    end
  end
end
