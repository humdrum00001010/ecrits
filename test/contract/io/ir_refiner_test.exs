defmodule Contract.IO.IRRefinerTest do
  use ExUnit.Case, async: false

  alias Contract.IO.IRRefiner

  setup do
    bypass = Bypass.open()
    original = Application.get_env(:contract, :openai)

    Application.put_env(:contract, :openai,
      api_key: "test-openai-key",
      base_url: "http://localhost:#{bypass.port}/v1",
      default_model: "gpt-5-mini",
      reasoning_effort: "high"
    )

    on_exit(fn -> Application.put_env(:contract, :openai, original) end)

    {:ok, bypass: bypass}
  end

  describe "refine/2" do
    test "POSTs the responses API, sends auth, returns parsed refinement", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        assert ["Bearer test-openai-key"] = Plug.Conn.get_req_header(conn, "authorization")

        {:ok, body, conn} = Plug.Conn.read_body(conn, length: 10_000_000)
        {:ok, decoded} = Jason.decode(body)
        assert decoded["model"] == "gpt-5-mini"
        assert decoded["reasoning"]["effort"] == "high"
        assert decoded["text"]["format"]["type"] == "json_schema"
        assert decoded["text"]["format"]["name"] == "ir_refinement"
        assert decoded["text"]["format"]["strict"] == true

        # User payload contains node ids verbatim so the LLM can reference them.
        assert [%{"role" => "system"}, %{"role" => "user", "content" => user}] = decoded["input"]
        assert user =~ "node:5"
        assert user =~ "12,000,000"

        refinement = %{
          "nodes_patch" => [],
          "fields" => [
            %{
              "id" => "field:rent",
              "key" => "rent",
              "value" => "12,000,000원",
              "attrs" => %{"kind" => "money", "label" => "대금"}
            }
          ],
          "field_bindings" => [
            %{"node_id" => "node:5", "field_id" => "field:rent", "start" => 10, "end" => 20}
          ]
        }

        response = %{
          "output" => [
            %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(refinement)}]}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      nodes = [
        %{
          "id" => "node:5",
          "kind" => "paragraph",
          "content" => %{"text" => "본 계약의 대금은 12,000,000원으로 한다."}
        }
      ]

      assert {:ok, refinement} = IRRefiner.refine(nodes)
      assert refinement.nodes_patch == []
      assert [field] = refinement.fields
      assert field["key"] == "rent"
      assert field["value"] == "12,000,000원"
      assert [binding] = refinement.field_bindings
      assert binding["node_id"] == "node:5"
      assert binding["field_id"] == "field:rent"
      assert binding["start"] == 10
      assert binding["end"] == 20
    end

    test "honors output_text shortcut shape", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        refinement = %{"nodes_patch" => [], "fields" => [], "field_bindings" => []}

        response = %{"output_text" => Jason.encode!(refinement)}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      assert {:ok, %{nodes_patch: [], fields: [], field_bindings: []}} =
               IRRefiner.refine([
                 %{"id" => "node:0", "kind" => "paragraph", "content" => %{"text" => "x"}}
               ])
    end

    test "5xx returns {:error, {:openai_http, ...}}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        Plug.Conn.resp(conn, 502, ~s({"error":"bad gateway"}))
      end)

      assert {:error, {:openai_http, 502, _}} =
               IRRefiner.refine([
                 %{"id" => "node:0", "kind" => "paragraph", "content" => %{"text" => "x"}}
               ])
    end

    test "transport failure returns {:error, {:openai_transport, _}}", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, {:openai_transport, _}} =
               IRRefiner.refine([
                 %{"id" => "node:0", "kind" => "paragraph", "content" => %{"text" => "x"}}
               ])
    end

    test "missing api_key returns {:error, :no_api_key} without contacting the network" do
      original = Application.get_env(:contract, :openai)

      Application.put_env(:contract, :openai,
        api_key: nil,
        base_url: "http://localhost:0/v1",
        default_model: "gpt-5-mini"
      )

      on_exit(fn -> Application.put_env(:contract, :openai, original) end)

      assert {:error, :no_api_key} =
               IRRefiner.refine([
                 %{"id" => "node:0", "kind" => "paragraph", "content" => %{"text" => "x"}}
               ])
    end

    test "empty string api_key returns {:error, :no_api_key}" do
      original = Application.get_env(:contract, :openai)

      Application.put_env(:contract, :openai,
        api_key: "",
        base_url: "http://localhost:0/v1",
        default_model: "gpt-5-mini"
      )

      on_exit(fn -> Application.put_env(:contract, :openai, original) end)

      assert {:error, :no_api_key} = IRRefiner.refine([])
    end

    test "malformed JSON in model response returns {:error, _}", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/responses", fn conn ->
        response = %{"output_text" => "not actually json {"}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(response))
      end)

      assert {:error, _} =
               IRRefiner.refine([
                 %{"id" => "node:0", "kind" => "paragraph", "content" => %{"text" => "x"}}
               ])
    end
  end

  describe "apply_patches/3" do
    test "drop removes the node from both nodes and order" do
      nodes = [
        %{"id" => "node:0", "kind" => "paragraph", "content" => %{"text" => "keep"}},
        %{"id" => "node:1", "kind" => "paragraph", "content" => %{"text" => "- 1 -"}}
      ]

      order = ["node:0", "node:1"]

      {new_nodes, new_order} =
        IRRefiner.apply_patches(nodes, order, [%{"action" => "drop", "node_id" => "node:1"}])

      assert new_order == ["node:0"]
      assert length(new_nodes) == 1
      assert hd(new_nodes)["id"] == "node:0"
    end

    test "set_kind updates kind + merges attrs in place" do
      nodes = [
        %{
          "id" => "node:0",
          "kind" => "paragraph",
          "content" => %{"text" => "제1조 (목적)"},
          "attrs" => %{"page" => 1}
        }
      ]

      order = ["node:0"]

      patches = [
        %{
          "action" => "set_kind",
          "node_id" => "node:0",
          "kind" => "heading",
          "attrs" => %{"level" => 1}
        }
      ]

      {[node], ["node:0"]} = IRRefiner.apply_patches(nodes, order, patches)
      assert node["kind"] == "heading"
      assert node["attrs"]["level"] == 1
      # original attrs preserved
      assert node["attrs"]["page"] == 1
    end

    test "replace substitutes one or more new nodes preserving position" do
      nodes = [
        %{"id" => "node:0", "kind" => "paragraph", "content" => %{"text" => "before"}},
        %{
          "id" => "node:1",
          "kind" => "paragraph",
          "content" => %{"text" => "1. first 2. second"}
        },
        %{"id" => "node:2", "kind" => "paragraph", "content" => %{"text" => "after"}}
      ]

      order = ["node:0", "node:1", "node:2"]

      patches = [
        %{
          "action" => "replace",
          "node_id" => "node:1",
          "with" => [
            %{"kind" => "list_item", "content" => "first", "attrs" => %{"number" => "1"}},
            %{"kind" => "list_item", "content" => "second", "attrs" => %{"number" => "2"}}
          ]
        }
      ]

      {new_nodes, new_order} = IRRefiner.apply_patches(nodes, order, patches)

      assert new_order == ["node:0", "node:1:1", "node:1:2", "node:2"]
      assert length(new_nodes) == 4

      [_before, n1, n2, _after] = new_nodes
      assert n1["id"] == "node:1:1"
      assert n1["kind"] == "list_item"
      assert n1["content"] == "first"
      assert n2["id"] == "node:1:2"
      assert n2["content"] == "second"
    end

    test "unknown action / missing node_id is silently dropped" do
      nodes = [%{"id" => "node:0", "kind" => "paragraph", "content" => %{"text" => "x"}}]
      order = ["node:0"]

      patches = [
        %{"action" => "wat", "node_id" => "node:0"},
        %{"action" => "drop", "node_id" => "node:nonexistent"}
      ]

      assert {^nodes, ^order} = IRRefiner.apply_patches(nodes, order, patches)
    end
  end
end
