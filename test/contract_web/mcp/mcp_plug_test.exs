defmodule ContractWeb.MCP.MCPPlugTest do
  use ContractWeb.ConnCase, async: false

  import Mox
  import Contract.AccountsFixtures

  alias Contract.Command
  alias Contract.Change
  alias Contract.Context
  alias Contract.Gateway
  alias Contract.Documents
  alias Contract.IO.R2Stub
  alias Contract.Runtime

  setup :set_mox_from_context
  setup :verify_on_exit!

  @ctx %Context{
    user: %Contract.Accounts.User{
      id: "00000000-0000-0000-0000-0000000000ab",
      email: "mcp-plug@example.test"
    }
  }

  setup do
    R2Stub.setup()
    R2Stub.reset()

    original_drivers = Application.get_env(:contract, :io_drivers, [])

    Application.put_env(
      :contract,
      :io_drivers,
      Keyword.put(original_drivers, :r2, R2Stub)
    )

    on_exit(fn -> Application.put_env(:contract, :io_drivers, original_drivers) end)
    :ok
  end

  describe "auth — bearer enforcement" do
    test "rejects requests with no / malformed / unrecognized bearer (all 401 -32000)",
         %{conn: conn} do
      body = jsonrpc_body(1, "initialize", %{})

      # No Authorization header.
      no_auth =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert no_auth.status == 401
      assert {:ok, env} = Jason.decode(no_auth.resp_body)
      assert env["error"]["code"] == -32_000

      # Malformed header.
      malformed =
        conn
        |> put_req_header("authorization", "NotBearer x")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert malformed.status == 401

      # Unrecognized bearer.
      unknown =
        conn
        |> put_req_header("authorization", "Bearer not-a-valid-token")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert unknown.status == 401
    end

    test "accepts both route_ref and user-api-token bearers", %{conn: conn} do
      {:ok, route_token} = Gateway.issue_route_ref(@ctx, %{purpose: "test"})

      route_resp = jsonrpc_call(conn, route_token, 1, "initialize", %{})
      assert route_resp.status == 200
      assert {:ok, env} = Jason.decode(route_resp.resp_body)
      assert env["jsonrpc"] == "2.0"
      assert env["id"] == 1
      assert env["result"]["serverInfo"]["name"] == "contract-studio"

      api_token =
        Phoenix.Token.sign(ContractWeb.Endpoint, "api_token", %{user_id: Ecto.UUID.generate()})

      assert jsonrpc_call(conn, api_token, 1, "initialize", %{}).status == 200
    end
  end

  describe "method: initialize" do
    test "returns server info and capabilities", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "init"})
      resp = jsonrpc_call(conn, token, 99, "initialize", %{})

      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["id"] == 99
      # No `protocolVersion` in the request → server advertises the
      # newest version it implements (2025-03-26, Streamable HTTP).
      assert env["result"]["protocolVersion"] == "2025-03-26"
      assert env["result"]["serverInfo"]["name"] == "contract-studio"
      assert is_map(env["result"]["capabilities"]["tools"])
      assert is_map(env["result"]["capabilities"]["resources"])
    end

    test "echoes client's protocolVersion when supported", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "init"})

      # Older client (still on 2024-11-05) — we negotiate down.
      resp =
        jsonrpc_call(conn, token, 1, "initialize", %{"protocolVersion" => "2024-11-05"})

      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["result"]["protocolVersion"] == "2024-11-05"
    end

    test "falls back to newest version on unknown protocolVersion", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "init"})

      resp =
        jsonrpc_call(conn, token, 1, "initialize", %{"protocolVersion" => "9999-99-99"})

      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["result"]["protocolVersion"] == "2025-03-26"
    end
  end

  describe "method: tools/list" do
    test "returns ≥7 studio.* tools each with name/description/inputSchema",
         %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "list"})
      resp = jsonrpc_call(conn, token, 1, "tools/list", %{})
      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)

      tools = env["result"]["tools"]
      assert is_list(tools)
      assert length(tools) >= 7

      names = Enum.map(tools, & &1["name"])

      for name <- ~w(studio.get_document studio.submit_action studio.search_documents
                     studio.get_change_history studio.list_marks studio.search_law
                     studio.verify_citations) do
        assert name in names
      end

      Enum.each(tools, fn t ->
        assert is_binary(t["name"])
        assert is_binary(t["description"])
        assert is_map(t["inputSchema"])
      end)
    end
  end

  describe "method: resources/list and resources/read" do
    test "returns MCP resource list/read shapes scoped to the bearer owner", %{conn: conn} do
      user = user_fixture()
      ctx = Context.for_user(user)
      doc_id = create_doc(ctx, title: "Plug Resource Doc")
      token = Phoenix.Token.sign(ContractWeb.Endpoint, "api_token", %{user_id: user.id})

      list_resp = jsonrpc_call(conn, token, 21, "resources/list", %{})
      assert list_resp.status == 200
      {:ok, list_env} = Jason.decode(list_resp.resp_body)
      assert is_list(list_env["result"]["resources"])
      uris = Enum.map(list_env["result"]["resources"], & &1["uri"])
      assert "document://#{doc_id}/state" in uris

      read_resp =
        jsonrpc_call(conn, token, 22, "resources/read", %{
          "uri" => "document://#{doc_id}/state"
        })

      assert read_resp.status == 200
      {:ok, read_env} = Jason.decode(read_resp.resp_body)
      assert %{"contents" => [%{"uri" => uri, "text" => text}]} = read_env["result"]
      assert uri == "document://#{doc_id}/state"
      assert {:ok, %{"document_id" => ^doc_id}} = Jason.decode(text)
    end
  end

  describe "auth — api_token owner scoping" do
    test "document tools only see the persisted token user's documents", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()
      user_ctx = Context.for_user(user)
      other_ctx = Context.for_user(other_user)

      own_doc_id = create_doc(user_ctx, title: "Token Owned Searchable")
      other_doc_id = create_doc(other_ctx, title: "Token Foreign Searchable")

      token = Phoenix.Token.sign(ContractWeb.Endpoint, "api_token", %{user_id: user.id})

      search_resp =
        jsonrpc_call(conn, token, 10, "tools/call", %{
          "name" => "studio.search_documents",
          "arguments" => %{"query" => "Searchable"}
        })

      assert search_resp.status == 200
      {:ok, search_env} = Jason.decode(search_resp.resp_body)
      [%{"text" => search_text}] = search_env["result"]["content"]
      {:ok, search_payload} = Jason.decode(search_text)
      result_ids = Enum.map(search_payload["results"], & &1["document_id"])
      assert own_doc_id in result_ids
      refute other_doc_id in result_ids

      own_get_resp =
        jsonrpc_call(conn, token, 11, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => own_doc_id}
        })

      {:ok, own_get_env} = Jason.decode(own_get_resp.resp_body)
      assert own_get_env["result"]["isError"] == false

      foreign_get_resp =
        jsonrpc_call(conn, token, 12, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => other_doc_id}
        })

      {:ok, foreign_get_env} = Jason.decode(foreign_get_resp.resp_body)
      assert foreign_get_env["error"]["code"] == -32_001

      own_submit_resp =
        jsonrpc_call(conn, token, 13, "tools/call", %{
          "name" => "studio.submit_action",
          "arguments" => %{
            "action" => %{
              "kind" => "rename_document",
              "document_id" => own_doc_id,
              "actor_type" => "user",
              "actor_id" => user.id,
              "base_revision" => 1,
              "idempotency_key" => "api-token-own-rename",
              "payload" => %{"title" => "Token Renamed"}
            }
          }
        })

      {:ok, own_submit_env} = Jason.decode(own_submit_resp.resp_body)
      assert own_submit_env["result"]["isError"] == false

      foreign_submit_resp =
        jsonrpc_call(conn, token, 14, "tools/call", %{
          "name" => "studio.submit_action",
          "arguments" => %{
            "action" => %{
              "kind" => "rename_document",
              "document_id" => other_doc_id,
              "actor_type" => "user",
              "actor_id" => user.id,
              "base_revision" => 1,
              "idempotency_key" => "api-token-foreign-rename",
              "payload" => %{"title" => "Leaked Rename"}
            }
          }
        })

      {:ok, foreign_submit_env} = Jason.decode(foreign_submit_resp.resp_body)
      assert foreign_submit_env["error"]["code"] == -32_001
      assert {:ok, other_doc} = Documents.get(other_ctx, other_doc_id)
      assert other_doc.title == "Token Foreign Searchable"
    end
  end

  describe "method: tools/call — studio.get_document" do
    test "returns 401 without bearer", %{conn: conn} do
      doc_id = create_doc()

      body =
        jsonrpc_body(1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => doc_id}
        })

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert resp.status == 401
    end

    test "forbidden (-32001) for pinned route_ref without user context or wrong doc",
         %{conn: conn} do
      doc_id = create_doc()
      other = create_doc(title: "Other pinned doc")

      # Pinned ref with no user context.
      {:ok, no_user_token} =
        Gateway.issue_route_ref(@ctx, %{purpose: "get", document_id: doc_id})

      no_user_resp =
        jsonrpc_call(conn, no_user_token, 1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => doc_id}
        })

      assert no_user_resp.status == 200
      {:ok, env1} = Jason.decode(no_user_resp.resp_body)
      assert env1["error"]["code"] == -32_001

      # Pinned ref for a different doc.
      {:ok, wrong_doc_token} =
        Gateway.issue_route_ref(@ctx, %{purpose: "wrong", document_id: other})

      wrong_doc_resp =
        jsonrpc_call(conn, wrong_doc_token, 1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => doc_id}
        })

      {:ok, env2} = Jason.decode(wrong_doc_resp.resp_body)
      assert env2["error"]["code"] == -32_001
    end

    test "returns -32602 when document_id is missing", %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "miss"})

      resp =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{}
        })

      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["error"]["code"] == -32_602
    end
  end

  describe "method: tools/call — studio.submit_action" do
    test "drives Runtime.apply and produces a Change via :rename_document", %{conn: conn} do
      user = user_fixture()
      ctx = Context.for_user(user)
      doc_id = create_doc(ctx, [])
      token = Phoenix.Token.sign(ContractWeb.Endpoint, "api_token", %{user_id: user.id})

      args = %{
        "name" => "studio.submit_action",
        "arguments" => %{
          "action" => %{
            "kind" => "rename_document",
            "document_id" => doc_id,
            "actor_type" => "user",
            "actor_id" => user.id,
            "base_revision" => 1,
            "idempotency_key" => "plug-rn-1",
            "payload" => %{"title" => "Plug-Renamed"}
          }
        }
      }

      resp = jsonrpc_call(conn, token, 42, "tools/call", args)
      assert resp.status == 200

      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["id"] == 42
      assert env["result"]["isError"] == false

      [%{"text" => text}] = env["result"]["content"]
      {:ok, payload} = Jason.decode(text)
      assert payload["command_kind"] == "rename_document"
      assert payload["result_revision"] == 2
    end

    test "returns -32602 for an invalid action shape", %{conn: conn} do
      doc_id = create_doc()
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "submit-bad", document_id: doc_id})

      resp =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.submit_action",
          "arguments" => %{"action" => %{"kind" => "not_a_real_kind"}}
        })

      {:ok, env} = Jason.decode(resp.resp_body)
      assert env["error"]["code"] == -32_602
    end
  end

  describe "method: tools/call — studio.get_change_history and studio.list_marks" do
    test "studio.get_change_history returns recorded changes", %{conn: conn} do
      user = user_fixture()
      ctx = Context.for_user(user)
      doc_id = create_doc(ctx, [])
      token = Phoenix.Token.sign(ContractWeb.Endpoint, "api_token", %{user_id: user.id})

      resp =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.get_change_history",
          "arguments" => %{"document_id" => doc_id, "since_revision" => 0}
        })

      assert resp.status == 200
      {:ok, env} = Jason.decode(resp.resp_body)
      [%{"text" => text}] = env["result"]["content"]
      {:ok, payload} = Jason.decode(text)
      assert payload["document_id"] == doc_id
      assert is_list(payload["changes"])
      assert length(payload["changes"]) >= 1
    end

    test "studio.list_marks returns the marks list", %{conn: conn} do
      user = user_fixture()
      ctx = Context.for_user(user)
      doc_id = create_doc(ctx, [])
      token = Phoenix.Token.sign(ContractWeb.Endpoint, "api_token", %{user_id: user.id})

      resp =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.list_marks",
          "arguments" => %{"document_id" => doc_id}
        })

      {:ok, env} = Jason.decode(resp.resp_body)
      [%{"text" => text}] = env["result"]["content"]
      {:ok, payload} = Jason.decode(text)
      assert payload["document_id"] == doc_id
      assert is_list(payload["marks"])
    end
  end

  describe "error handling" do
    test "maps unknown-tool / unknown-method / parse / invalid-request / missing-name to codes",
         %{conn: conn} do
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "err"})

      # -32601 unknown tool.
      unk_tool =
        jsonrpc_call(conn, token, 1, "tools/call", %{
          "name" => "studio.does_not_exist",
          "arguments" => %{}
        })

      {:ok, env1} = Jason.decode(unk_tool.resp_body)
      assert env1["error"]["code"] == -32_601

      # -32601 unknown JSON-RPC method.
      {:ok, env2} = Jason.decode(jsonrpc_call(conn, token, 1, "wat/wat", %{}).resp_body)
      assert env2["error"]["code"] == -32_601

      # -32700 malformed JSON.
      parse_resp =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", "{not valid")

      {:ok, env3} = Jason.decode(parse_resp.resp_body)
      assert env3["error"]["code"] == -32_700

      # -32600 body missing method.
      inv_resp =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", ~s({"jsonrpc":"2.0","id":1}))

      {:ok, env4} = Jason.decode(inv_resp.resp_body)
      assert env4["error"]["code"] == -32_600

      # -32602 tools/call missing name.
      noname =
        jsonrpc_call(conn, token, 1, "tools/call", %{"arguments" => %{}})

      {:ok, env5} = Jason.decode(noname.resp_body)
      assert env5["error"]["code"] == -32_602
    end
  end

  describe "SSE transport" do
    test "responds with text/event-stream when Accept asks for it", %{conn: conn} do
      doc_id = create_doc()
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "sse", document_id: doc_id})

      body =
        jsonrpc_body(1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => doc_id}
        })

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/event-stream")
        |> post("/mcp", body)

      assert resp.status == 200
      assert {"content-type", ct} = List.keyfind(resp.resp_headers, "content-type", 0)
      assert String.contains?(ct, "text/event-stream")
      assert String.starts_with?(resp.resp_body, "data: ")
      assert String.contains?(resp.resp_body, "\"jsonrpc\":\"2.0\"")
    end

    test "responds as JSON when Accept is application/json", %{conn: conn} do
      doc_id = create_doc()
      {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "json", document_id: doc_id})

      body =
        jsonrpc_body(1, "tools/call", %{
          "name" => "studio.get_document",
          "arguments" => %{"document_id" => doc_id}
        })

      resp =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json")
        |> post("/mcp", body)

      assert resp.status == 200
      assert {"content-type", ct} = List.keyfind(resp.resp_headers, "content-type", 0)
      assert String.contains?(ct, "application/json")
      refute String.starts_with?(resp.resp_body, "data: ")
    end
  end

  describe "Slack ingress remains 501 (out of scope for this build)" do
    test "/slack/{events,actions,commands} all return 501", %{conn: conn} do
      for path <- ~w(/slack/events /slack/actions /slack/commands) do
        assert post(conn, path, %{}).status == 501
      end
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp create_doc(opts \\ []) do
    create_doc(@ctx, opts)
  end

  defp create_doc(%Context{} = ctx, opts) do
    doc_id = Ecto.UUID.generate()
    title = Keyword.get(opts, :title, "Plug Doc")

    action = %Command{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      base_revision: 0,
      idempotency_key: "create-#{doc_id}",
      payload: %{"title" => title, "type_key" => "nda"}
    }

    {:ok, %Change{}} = Runtime.apply(ctx, action)
    doc_id
  end

  defp jsonrpc_body(id, method, params) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => method,
      "params" => params
    })
  end

  defp jsonrpc_call(conn, token, id, method, params) do
    body = jsonrpc_body(id, method, params)

    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", body)
  end
end
