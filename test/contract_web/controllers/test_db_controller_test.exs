defmodule ContractWeb.TestDbControllerTest do
  @moduledoc """
  Plumbing tests for the retired Playwright DB inspection routes. These
  ExUnit cases only prove that

    * the routes are reachable when `:test_auth` is on (the test env);
    * each endpoint returns the documented retired JSON envelope;
    * unknown or malformed documents return an empty list (not 500).

  The compile-time prod gating is asserted by the existence of the
  `if Application.compile_env(...) do` wrapper in the controller — there
  isn't a portable way to flip a compile-env in ExUnit, so we rely on the
  same pattern already validated by `TestAuthController`.
  """

  use ContractWeb.ConnCase, async: true

  describe "GET /test/db/changes/:document_id" do
    test "returns an empty list for a never-seen document id", %{conn: conn} do
      doc_id = Ecto.UUID.generate()
      conn = get(conn, ~p"/test/db/changes/#{doc_id}")

      assert %{
               "ok" => false,
               "retired" => true,
               "document_id" => ^doc_id,
               "changes" => []
             } = json_response(conn, 200)
    end

    test "returns [] (not 500) for a malformed document id", %{conn: conn} do
      conn = get(conn, ~p"/test/db/changes/not-a-uuid")

      assert %{
               "ok" => false,
               "retired" => true,
               "document_id" => "not-a-uuid",
               "changes" => []
             } = json_response(conn, 200)
    end
  end

  describe "GET /test/db/documents" do
    test "returns a retired empty document envelope", %{conn: conn} do
      conn = get(conn, ~p"/test/db/documents")

      assert %{"ok" => false, "retired" => true, "documents" => documents} =
               json_response(conn, 200)

      assert is_list(documents)
    end
  end

  describe "GET /test/db/oban_jobs" do
    test "returns the retired envelope for a queue", %{conn: conn} do
      conn = get(conn, ~p"/test/db/oban_jobs?queue=default")

      assert %{"ok" => false, "retired" => true, "queue" => "default", "jobs" => jobs} =
               json_response(conn, 200)

      assert is_list(jobs)
    end

    test "defaults the queue to 'default' when none is given", %{conn: conn} do
      conn = get(conn, ~p"/test/db/oban_jobs")

      assert %{"ok" => false, "retired" => true, "queue" => "default", "jobs" => _} =
               json_response(conn, 200)
    end
  end
end
