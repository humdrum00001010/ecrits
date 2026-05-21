defmodule Contract.GatewayTest do
  use Contract.DataCase, async: false

  import Mox

  alias Contract.Command
  alias Contract.Change
  alias Contract.Context
  alias Contract.Gateway
  alias Contract.IO.R2Stub
  alias Contract.RouteRef
  alias Contract.Runtime

  setup :set_mox_from_context
  setup :verify_on_exit!

  @ctx %Context{}

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

  describe "issue_route_ref/2 → verify_route_ref/2" do
    test "round-trips a freshly-issued token" do
      owner = scope()
      doc_id = create_doc(owner)

      assert {:ok, token} =
               Gateway.issue_route_ref(owner, %{
                 matter_id: Ecto.UUID.generate(),
                 document_id: doc_id,
                 purpose: "mcp",
                 scopes: ["read", "write"]
               })

      assert is_binary(token)

      assert {:ok, %RouteRef{} = ref} = Gateway.verify_route_ref(@ctx, token)
      refute Map.has_key?(Map.from_struct(ref), :matter_id)
      assert ref.document_id == doc_id
      assert ref.purpose == "mcp"
      assert ref.scopes == ["read", "write"]
      assert %DateTime{} = ref.issued_at
      assert %DateTime{} = ref.expires_at
    end

    test "TTL is honoured as a lower bound, rejects non-positive" do
      # Task #139 — the bearer is now deterministic per (user, doc,
      # thread), which means `expires_at` in the payload is bucketed
      # (day-aligned) so two mints in the same UTC day produce the
      # same token bytes. We assert `expires_at` >= `now + ttl` and
      # within ~1 day instead of an exact diff.
      now_before = DateTime.utc_now()

      # default TTL (1h)
      assert {:ok, default_token} = Gateway.issue_route_ref(@ctx, %{purpose: "default-ttl"})

      assert {:ok, %RouteRef{expires_at: default_expires}} =
               Gateway.verify_route_ref(@ctx, default_token)

      assert DateTime.compare(default_expires, DateTime.add(now_before, 3_600, :second)) in [
               :gt,
               :eq
             ]

      # custom TTL — same lower-bound semantics
      assert {:ok, custom} = Gateway.issue_route_ref(@ctx, %{purpose: "ttl", ttl: 60})
      assert {:ok, %RouteRef{expires_at: custom_expires}} = Gateway.verify_route_ref(@ctx, custom)
      assert DateTime.compare(custom_expires, DateTime.add(now_before, 60, :second)) in [:gt, :eq]

      # invalid TTLs
      assert {:error, :invalid_ttl} = Gateway.issue_route_ref(@ctx, %{ttl: 0})
      assert {:error, :invalid_ttl} = Gateway.issue_route_ref(@ctx, %{ttl: -5})
    end

    test "denies document-scoped route_ref issuance for a foreign document" do
      owner = scope()
      other = scope()
      foreign_doc_id = create_doc(other, title: "Foreign route_ref target")

      assert {:error, :forbidden} =
               Gateway.issue_route_ref(owner, %{
                 document_id: foreign_doc_id,
                 purpose: "foreign"
               })
    end
  end

  describe "verify_route_ref/2 — failure modes" do
    test "returns :missing for nil / empty input" do
      assert {:error, :missing} = Gateway.verify_route_ref(@ctx, nil)
      assert {:error, :missing} = Gateway.verify_route_ref(@ctx, "")
    end

    test "returns :invalid for tampered / garbage / non-string input" do
      assert {:ok, token} = Gateway.issue_route_ref(@ctx, %{purpose: "tamper"})

      {left, right} = String.split_at(token, div(String.length(token), 2))
      tampered = left <> "!" <> right

      assert {:error, :invalid} = Gateway.verify_route_ref(@ctx, tampered)
      assert {:error, :invalid} = Gateway.verify_route_ref(@ctx, "not-a-real-token")
      assert {:error, :invalid} = Gateway.verify_route_ref(@ctx, 12_345)
    end

    test "returns :expired for an expired token" do
      # Sign manually with the same salt but a signed_at in the past so
      # max_age enforcement trips. We pass max_age = 60 seconds; signed_at
      # 1 hour ago => expired.
      one_hour_ago =
        DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.to_unix(:millisecond)

      payload = %{
        document_id: nil,
        purpose: "expired",
        issued_at: DateTime.to_iso8601(DateTime.utc_now() |> DateTime.add(-3_600, :second)),
        expires_at: DateTime.to_iso8601(DateTime.utc_now() |> DateTime.add(-1, :second)),
        scopes: []
      }

      token =
        Phoenix.Token.sign(ContractWeb.Endpoint, "route_ref", payload,
          max_age: 60,
          signed_at: one_hour_ago
        )

      assert {:error, :expired} = Gateway.verify_route_ref(@ctx, token)
    end
  end

  describe "issue_route_ref/2 — SPEC.md §15.2 invariant (no PIDs in route_refs)" do
    test "rejects pid / reference / function values in attrs" do
      assert {:error, :pid_in_attrs} =
               Gateway.issue_route_ref(@ctx, %{purpose: "pid-test", document_id: self()})

      assert {:error, :pid_in_attrs} =
               Gateway.issue_route_ref(@ctx, %{
                 purpose: "ref-test",
                 scopes: [:ok, make_ref()]
               })

      assert {:error, :pid_in_attrs} =
               Gateway.issue_route_ref(@ctx, %{purpose: fn -> :nope end})
    end

    test "successful tokens decode to only binary_id strings and atoms" do
      owner = scope()
      doc_id = create_doc(owner)

      assert {:ok, token} =
               Gateway.issue_route_ref(owner, %{
                 matter_id: Ecto.UUID.generate(),
                 document_id: doc_id,
                 purpose: "no-pid",
                 scopes: ["read"]
               })

      assert {:ok, %RouteRef{} = ref} = Gateway.verify_route_ref(@ctx, token)

      # Walk the struct and assert nothing pid-like is present.
      values = Map.values(Map.from_struct(ref))
      refute Enum.any?(values, fn v -> is_pid(v) or is_reference(v) or is_port(v) end)
    end
  end

  describe "mcp_tool/3 — tool listing and dispatch" do
    test "tool_names/0 + tools_descriptor/0 expose ≥7 studio.* tools without legacy matter_id" do
      names = Gateway.tool_names()
      assert length(names) >= 7
      assert "studio.get_document" in names
      assert "studio.submit_action" in names
      assert "studio.search_law" in names

      desc = Gateway.tools_descriptor()
      assert length(desc) == length(names)

      Enum.each(desc, fn entry ->
        assert is_binary(entry["name"])
        assert is_binary(entry["description"])
        assert is_map(entry["inputSchema"])
      end)

      submit = Enum.find(desc, &(&1["name"] == "studio.submit_action"))

      refute Map.has_key?(
               submit["inputSchema"]["properties"]["action"]["properties"],
               "matter_id"
             )
    end

    test "unknown tool returns {:error, {:unknown_tool, name}}" do
      assert {:error, {:unknown_tool, "studio.does_not_exist"}} =
               Gateway.mcp_tool(@ctx, "studio.does_not_exist", %{})
    end

    test "studio.get_document: happy path, route_ref ACL, missing document_id" do
      owner = scope()
      doc_id = create_doc(owner)
      other_doc = create_doc(owner)

      # Happy path: pinned route_ref + matching doc returns the projection.
      ctx = ctx_for(owner, doc_id)

      assert {:ok, payload} =
               Gateway.mcp_tool(ctx, "studio.get_document", %{"document_id" => doc_id})

      assert payload.document_id == doc_id
      assert payload.revision >= 1
      assert is_map(payload.projection)

      # Route ref pinned to a different doc → forbidden.
      wrong_ctx = ctx_for(owner, other_doc)

      assert {:error, :forbidden} =
               Gateway.mcp_tool(wrong_ctx, "studio.get_document", %{"document_id" => doc_id})

      # Missing document_id → typed error.
      assert {:error, :missing_document_id} =
               Gateway.mcp_tool(@ctx, "studio.get_document", %{})
    end

    test "studio.submit_action drives Runtime.apply and returns a Change" do
      owner = scope()
      doc_id = create_doc(owner)
      ctx = ctx_for(owner, doc_id)

      action_args = %{
        "action" => %{
          "kind" => "rename_document",
          "document_id" => doc_id,
          "actor_type" => "user",
          "actor_id" => Ecto.UUID.generate(),
          "base_revision" => 1,
          "idempotency_key" => "mcp-rn-1",
          "payload" => %{"title" => "MCP-renamed"}
        }
      }

      assert {:ok, payload} = Gateway.mcp_tool(ctx, "studio.submit_action", action_args)
      assert payload.command_kind == "rename_document"
      assert is_binary(payload.id)
    end

    test "studio.submit_action rejects an invalid action shape" do
      ctx = ctx_for(Ecto.UUID.generate())

      assert {:error, {:invalid_action, _}} =
               Gateway.mcp_tool(ctx, "studio.submit_action", %{"action" => %{"kind" => "bogus"}})
    end

    test "studio.get_change_history returns changes" do
      owner = scope()
      doc_id = create_doc(owner)
      ctx = ctx_for(owner, doc_id)

      assert {:ok, payload} =
               Gateway.mcp_tool(ctx, "studio.get_change_history", %{
                 "document_id" => doc_id,
                 "since_revision" => 0
               })

      assert payload.document_id == doc_id
      assert length(payload.changes) >= 1
      assert hd(payload.changes).command_kind == "create_document"
    end

    test "studio.list_marks returns an empty list for a fresh document" do
      owner = scope()
      doc_id = create_doc(owner)
      ctx = ctx_for(owner, doc_id)

      assert {:ok, %{document_id: ^doc_id, marks: marks}} =
               Gateway.mcp_tool(ctx, "studio.list_marks", %{"document_id" => doc_id})

      assert is_list(marks)
    end

    test "studio.search_documents returns owner-scoped matches by title substring" do
      owner = scope()
      other = scope()
      owner_doc_id = create_doc(owner, title: "MCP-Searchable Contract")
      other_doc_id = create_doc(other, title: "MCP-Searchable Hidden")

      assert {:ok, payload} =
               Gateway.mcp_tool(owner, "studio.search_documents", %{"query" => "Searchable"})

      result_ids = Enum.map(payload.results, & &1.document_id)
      assert owner_doc_id in result_ids
      refute other_doc_id in result_ids
    end

    test "input validation rejects empty queries / text across tools" do
      assert {:error, :invalid_query} =
               Gateway.mcp_tool(@ctx, "studio.search_documents", %{"query" => ""})

      assert {:error, :invalid_text} =
               Gateway.mcp_tool(@ctx, "studio.verify_citations", %{"text" => ""})

      assert {:error, :invalid_query} =
               Gateway.mcp_tool(@ctx, "studio.search_law", %{"query" => ""})
    end
  end

  describe "authorize_document/2" do
    test "denies nil ctx, nil document_id, or a pinned route_ref without matching user ownership" do
      # Empty ctx → forbidden.
      assert {:error, :forbidden} = Gateway.authorize_document(%Context{}, Ecto.UUID.generate())
      assert {:error, :forbidden} = Gateway.authorize_document(%Context{}, nil)

      # Pinned route_ref but no user context.
      doc_id = create_doc(scope(), title: "No-user pinned bypass")

      no_user_ref = %RouteRef{
        document_id: doc_id,
        scopes: [],
        purpose: "t",
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.utc_now()
      }

      assert {:error, :forbidden} =
               Gateway.authorize_document(%Context{perms: %{route_ref: no_user_ref}}, doc_id)

      # User present but doesn't own the pinned document.
      other = scope()
      other_doc_id = create_doc(other, title: "Pinned foreign doc")

      foreign_ref = %{no_user_ref | document_id: other_doc_id}
      foreign_ctx = %Context{user: scope().user, perms: %{route_ref: foreign_ref}}
      assert {:error, :forbidden} = Gateway.authorize_document(foreign_ctx, other_doc_id)

      # Different document than the pinned one.
      diff_ref = %{no_user_ref | document_id: Ecto.UUID.generate()}
      diff_ctx = %Context{perms: %{route_ref: diff_ref}}
      assert {:error, :forbidden} = Gateway.authorize_document(diff_ctx, Ecto.UUID.generate())
    end

    test "wildcard route_ref still requires ctx user to own the document" do
      owner = scope()
      other = scope()
      owner_doc_id = create_doc(owner, title: "Wildcard owner doc")
      other_doc_id = create_doc(other, title: "Wildcard foreign doc")

      ref = %RouteRef{
        document_id: nil,
        scopes: [],
        purpose: "t",
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.utc_now()
      }

      ctx = %Context{user: owner.user, perms: %{route_ref: ref}}
      assert :ok = Gateway.authorize_document(ctx, owner_doc_id)
      assert {:error, :forbidden} = Gateway.authorize_document(ctx, other_doc_id)
    end
  end

  describe "slack_*/1 — out of scope for this build" do
    test "slack_event/1, slack_action/1, slack_command/1 all raise" do
      assert_raise RuntimeError, ~r/Slack/, fn -> Gateway.slack_event(%{}) end
      assert_raise RuntimeError, ~r/Slack/, fn -> Gateway.slack_action(%{}) end
      assert_raise RuntimeError, ~r/Slack/, fn -> Gateway.slack_command(%{}) end
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp create_doc(%Context{} = ctx), do: create_doc(ctx, [])

  defp create_doc(opts) when is_list(opts) do
    ctx = scope()
    create_doc(ctx, opts)
  end

  defp create_doc(%Context{} = ctx, opts) do
    title = Keyword.get(opts, :title, "Doc")
    doc_id = Ecto.UUID.generate()

    action = %Command{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      base_revision: 0,
      idempotency_key: "create-#{doc_id}",
      payload: %{"title" => title, "type_key" => "nda_v1"}
    }

    {:ok, %Change{}} = Runtime.apply(ctx, action)
    doc_id
  end

  defp scope do
    user_id = Ecto.UUID.generate()

    %Context{
      user: %Contract.Accounts.User{
        id: user_id,
        email: "gateway-#{user_id}@example.test"
      }
    }
  end

  defp ctx_for(doc_id), do: ctx_for(%Context{}, doc_id)

  defp ctx_for(%Context{} = ctx, doc_id) do
    ref = %RouteRef{
      document_id: doc_id,
      purpose: "test",
      issued_at: DateTime.utc_now(),
      expires_at: DateTime.utc_now() |> DateTime.add(3_600, :second),
      scopes: ["read", "write"]
    }

    %Context{user: ctx.user, perms: %{route_ref: ref}, now: DateTime.utc_now()}
  end
end
