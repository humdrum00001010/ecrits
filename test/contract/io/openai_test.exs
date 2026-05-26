defmodule Contract.IO.OpenAITest do
  use ExUnit.Case, async: false

  alias Contract.IO.OpenAI

  setup do
    bypass = Bypass.open()

    original_openai = Application.get_env(:contract, :openai)
    original_law = Application.get_env(:contract, :law_mcp)

    Application.put_env(:contract, :openai,
      api_key: "test-key",
      base_url: "http://localhost:#{bypass.port}/v1",
      default_model: "gpt-5-mini",
      reasoning_effort: "high"
    )

    Application.put_env(:contract, :law_mcp,
      endpoint: "http://localhost:9999/mcp",
      oc: "openapi"
    )

    on_exit(fn ->
      Application.put_env(:contract, :openai, original_openai)
      Application.put_env(:contract, :law_mcp, original_law)
    end)

    {:ok, bypass: bypass}
  end

  describe "law_mcp_tool/1" do
    test "builds the canonical Korean Law MCP entry with :oc override" do
      default = OpenAI.law_mcp_tool()
      assert default.type == "mcp"
      assert default.server_label == "korean-law"
      assert default.require_approval == "never"
      assert default.server_url =~ "?oc=openapi"

      assert OpenAI.law_mcp_tool(oc: "custom-oc").server_url =~ "?oc=custom-oc"
    end
  end

  describe "slack_mcp_tool/1 (Wave 6)" do
    test "returns nil for non-Context input (nil or arbitrary)" do
      assert OpenAI.slack_mcp_tool(nil) == nil
      assert OpenAI.slack_mcp_tool(:not_a_scope) == nil
    end
  end

  describe "contract_doc_mcp_tool/1" do
    test "allows the read tools referenced by the document-editing prompt" do
      Application.put_env(:contract, :mcp, public_base_url: "http://localhost:4000")

      tool = OpenAI.contract_doc_mcp_tool("route-ref-token")

      assert "doc.get" in tool.allowed_tools
      assert "doc.find" in tool.allowed_tools
      assert "doc.read" in tool.allowed_tools
      assert "doc.edit_text" in tool.allowed_tools
    end
  end

  describe "one_shot/2" do
    test "POSTs Responses-API payload with auth + model + reasoning + law MCP tool", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        assert ["Bearer test-key"] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)

        assert decoded["model"] == "gpt-5-mini"
        assert decoded["reasoning"]["effort"] == "high"
        assert is_binary(decoded["input"])
        refute Map.has_key?(decoded, "stream")

        law_tool = Enum.find(decoded["tools"], &(&1["type"] == "mcp"))
        assert law_tool["server_label"] == "korean-law"
        assert law_tool["require_approval"] == "never"
        assert law_tool["server_url"] =~ "?oc=openapi"

        response = %{
          "id" => "resp_123",
          "object" => "response",
          "output_text" => "hello"
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      assert {:ok, %{"id" => "resp_123"}} = OpenAI.one_shot(%{input: "ping"})
    end

    test "merges caller-supplied :extra_tools", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)

        tools = decoded["tools"]
        assert Enum.any?(tools, &(&1["server_label"] == "korean-law"))
        assert Enum.any?(tools, &(&1["type"] == "function"))

        Plug.Conn.resp(conn, 200, Jason.encode!(%{"id" => "r", "output_text" => ""}))
      end)

      extra = [%{type: "function", name: "echo"}]
      assert {:ok, _} = OpenAI.one_shot(%{input: "x"}, extra_tools: extra)
    end

    test "deduplicates MCP tools by server_label before posting", %{bypass: bypass} do
      duplicate_law_tool = OpenAI.law_mcp_tool(oc: "duplicate")

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)

        law_tools = Enum.filter(decoded["tools"], &(&1["server_label"] == "korean-law"))
        assert length(law_tools) == 1
        assert hd(law_tools)["server_url"] =~ "?oc=openapi"

        Plug.Conn.resp(conn, 200, Jason.encode!(%{"id" => "r", "output_text" => ""}))
      end)

      assert {:ok, _} = OpenAI.one_shot(%{input: "x", tools: [duplicate_law_tool]})
    end

    test "omits law MCP tool when include_law_mcp?: false", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)
        refute Enum.any?(decoded["tools"], &(&1["server_label"] == "korean-law"))
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"id" => "r", "output_text" => ""}))
      end)

      assert {:ok, _} = OpenAI.one_shot(%{input: "x"}, include_law_mcp?: false)
    end

    test "honors caller-supplied model + reasoning overrides", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "gpt-5"
        assert decoded["reasoning"]["effort"] == "low"
        Plug.Conn.resp(conn, 200, Jason.encode!(%{"id" => "r", "output_text" => ""}))
      end)

      assert {:ok, _} =
               OpenAI.one_shot(%{
                 model: "gpt-5",
                 reasoning: %{effort: "low"},
                 input: "x"
               })
    end

    test "returns {:error, _} on non-2xx", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        Plug.Conn.resp(conn, 429, Jason.encode!(%{"error" => %{"message" => "rate limit"}}))
      end)

      assert {:error, _} = OpenAI.one_shot(%{input: "x"})
    end
  end

  describe "stream_chat/2" do
    test "parses SSE events into %{type, data} maps", %{bypass: bypass} do
      sse_body =
        Enum.join(
          [
            "event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"id\":\"r1\"}}\n\n",
            "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"hel\"}\n\n",
            "event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\"lo\"}\n\n",
            "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"r1\",\"output_text\":\"hello\"}}\n\n"
          ],
          ""
        )

      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)
        assert decoded["stream"] == true

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(200, sse_body)
      end)

      assert {:ok, %{stream: stream, task_pid: pid}} = OpenAI.stream_chat(%{input: "ping"})
      assert is_pid(pid)

      events = stream |> Enum.to_list()
      types = Enum.map(events, & &1.type)
      assert "response.created" in types
      assert "response.output_text.delta" in types
      assert "response.completed" in types

      deltas =
        events
        |> Enum.filter(&(&1.type == "response.output_text.delta"))
        |> Enum.map(& &1.data["delta"])

      assert deltas == ["hel", "lo"]
    end

    test "stream tools array contains the law MCP tool", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
        decoded = Jason.decode!(body)
        assert Enum.any?(decoded["tools"], &(&1["server_label"] == "korean-law"))

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.resp(
          200,
          "event: response.completed\ndata: {\"type\":\"response.completed\"}\n\n"
        )
      end)

      assert {:ok, %{stream: stream}} = OpenAI.stream_chat(%{input: "ping"})
      _ = Enum.to_list(stream)
    end
  end
end
