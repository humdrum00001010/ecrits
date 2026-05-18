defmodule Contract.IO.LawMCPTest do
  use ExUnit.Case, async: false

  alias Contract.IO.LawMCP

  setup do
    bypass = Bypass.open()

    original = Application.get_env(:contract, :law_mcp)

    Application.put_env(:contract, :law_mcp,
      endpoint: "http://localhost:#{bypass.port}/mcp",
      oc: "openapi"
    )

    on_exit(fn -> Application.put_env(:contract, :law_mcp, original) end)

    {:ok, bypass: bypass}
  end

  describe "call/3" do
    test "POSTs JSON-RPC 2.0 envelope to ?oc=<oc> URL", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        assert conn.query_string == "oc=openapi"
        accept_headers = Plug.Conn.get_req_header(conn, "accept")
        assert Enum.any?(accept_headers, &(&1 =~ "application/json"))
        assert Enum.any?(accept_headers, &(&1 =~ "text/event-stream"))

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)

        assert decoded["jsonrpc"] == "2.0"
        assert decoded["method"] == "tools/call"
        assert decoded["params"]["name"] == "search_law"
        assert decoded["params"]["arguments"] == %{"query" => "민법"}
        assert is_integer(decoded["id"])

        result =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => decoded["id"],
            "result" => %{
              "content" => [
                %{
                  "type" => "text",
                  "text" =>
                    Jason.encode!(%{
                      "items" => [%{"law_id" => "001", "title" => "민법"}]
                    })
                }
              ]
            }
          })

        Plug.Conn.resp(conn, 200, result)
      end)

      assert {:ok, %{"items" => [%{"law_id" => "001"}]}} =
               LawMCP.call("search_law", %{"query" => "민법"})
    end

    test "returns {:error, {:law_mcp_rpc, _}} when server returns an error envelope", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "error" => %{"code" => -32601, "message" => "method not found"}
          })
        )
      end)

      assert {:error, {:law_mcp_rpc, %{"code" => -32601}}} =
               LawMCP.call("nope", %{})
    end

    test "surfaces typed errors for non-200 / transport failure", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        Plug.Conn.resp(conn, 502, "boom")
      end)

      assert {:error, {:law_mcp_http, 502, _}} = LawMCP.call("x", %{})

      Bypass.down(bypass)
      assert {:error, {:law_mcp_transport, _}} = LawMCP.call("x", %{})
    end

    test "honors :oc opt override", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        assert conn.query_string == "oc=overridden"

        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
        )
      end)

      assert {:ok, _} = LawMCP.call("x", %{}, oc: "overridden")
    end
  end

  describe "search_law/2" do
    test "wraps :search_law tool", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)
        assert decoded["params"]["name"] == "search_law"
        assert decoded["params"]["arguments"]["query"] == "근로기준법"

        result =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "result" => %{
              "content" => [
                %{
                  "text" =>
                    Jason.encode!(%{
                      "items" => [
                        %{"law_id" => "100", "title" => "근로기준법"},
                        %{"law_id" => "101", "title" => "근로기준법 시행령"}
                      ]
                    })
                }
              ]
            }
          })

        Plug.Conn.resp(conn, 200, result)
      end)

      assert {:ok, [%{"law_id" => "100"}, %{"law_id" => "101"}]} =
               LawMCP.search_law("근로기준법")
    end

    test "passes :limit through as arguments.limit", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)
        assert decoded["params"]["arguments"]["limit"] == 5
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => []}))
      end)

      assert {:ok, _} = LawMCP.search_law("q", limit: 5)
    end
  end

  describe "verify_citations/2" do
    test "wraps :verify_citations tool with list of citations", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)
        assert decoded["params"]["name"] == "verify_citations"
        # List inputs are joined into a single `text` field with newlines.
        assert decoded["params"]["arguments"]["text"] == "민법 제390조\n상법 제42조"
        assert decoded["params"]["arguments"]["maxCitations"] == 15

        result =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "result" => %{
              "content" => [
                %{
                  "text" =>
                    Jason.encode!([
                      %{"citation" => "민법 제390조", "valid" => true},
                      %{"citation" => "상법 제42조", "valid" => true}
                    ])
                }
              ]
            }
          })

        Plug.Conn.resp(conn, 200, result)
      end)

      assert {:ok, [%{"citation" => "민법 제390조", "valid" => true}, _]} =
               LawMCP.verify_citations(["민법 제390조", "상법 제42조"])
    end

    test "single-string citation via Providers boundary", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/mcp", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)
        assert decoded["params"]["arguments"]["text"] == "민법 제390조"

        Plug.Conn.resp(
          conn,
          200,
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "result" => %{
              "content" => [
                %{"text" => Jason.encode!([%{"citation" => "민법 제390조", "valid" => true}])}
              ]
            }
          })
        )
      end)

      assert {:ok, [%{"valid" => true}]} = Contract.Providers.verify_citation(nil, "민법 제390조")
    end
  end
end
