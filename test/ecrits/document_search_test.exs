defmodule Ecrits.DocumentSearchTest do
  use ExUnit.Case, async: true

  alias Ecrits.DocumentSearch

  test "the Ecto changeset rejects invalid query and engine result values" do
    search =
      DocumentSearch.new()
      |> DocumentSearch.open("drafts/service.hwpx")
      |> DocumentSearch.put_query(String.duplicate("x", 600))

    assert search.query == ""

    search =
      search
      |> DocumentSearch.put_query(String.duplicate("x", 500))
      |> DocumentSearch.put_result(%{
        "document_id" => "drafts/service.hwpx",
        "query" => String.duplicate("x", 500),
        "total" => 2,
        "index" => 2
      })

    assert String.length(search.query) == 500
    assert search.total == 2
    assert search.index == 2

    assert DocumentSearch.put_result(search, %{
             "document_id" => "drafts/service.hwpx",
             "query" => String.duplicate("x", 500),
             "total" => -2,
             "index" => 1.6
           }) == search
  end

  test "stale results cannot mutate active document search state" do
    search =
      DocumentSearch.new()
      |> DocumentSearch.open("active")
      |> DocumentSearch.put_query("needle")

    assert DocumentSearch.put_result(search, %{
             document_id: "other",
             query: "needle",
             total: 4,
             index: 1
           }) == search
  end

  test "only validated search commands are serialized for the browser engine" do
    search =
      DocumentSearch.new() |> DocumentSearch.open("active") |> DocumentSearch.put_query("x")

    assert {:ok, %{action: "search", document_id: "active", format: "hwpx", query: "x"}} =
             DocumentSearch.command(search, "search", "hwpx")

    assert :error = DocumentSearch.command(search, "delete", "hwpx")
  end
end
