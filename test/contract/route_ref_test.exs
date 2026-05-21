defmodule Contract.RouteRefTest do
  @moduledoc """
  Task #139 — pins the deterministic-bearer contract end-to-end.

  These tests assert the *byte-equality* of two tokens minted with the
  same (user_id, document_id, chat_thread_id) scope, plus the absence of
  `agent_run_id` (and any other per-turn nonce) from the signed payload.
  They are the cache-hit guarantee against accidental regressions on
  `Contract.Gateway.issue_route_ref/2`.
  """

  use Contract.DataCase, async: false

  alias Contract.Context
  alias Contract.Documents
  alias Contract.Gateway
  alias Contract.RouteRef

  defp scope do
    user_id = Ecto.UUID.generate()

    %Context{
      user: %Contract.Accounts.User{
        id: user_id,
        email: "route-ref-#{user_id}@example.test"
      }
    }
  end

  describe "determinism per (user, doc, thread)" do
    test "two mints with identical scope produce byte-equal tokens" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Determinism doc"})
      thread_id = Ecto.UUID.generate()

      attrs = %{
        user_id: s.user.id,
        document_id: doc.id,
        chat_thread_id: thread_id,
        purpose: "agent_doc_mcp",
        scopes: ["agent_doc"]
      }

      assert {:ok, token_a} = Gateway.issue_route_ref(s, attrs)
      assert {:ok, token_b} = Gateway.issue_route_ref(s, attrs)

      assert token_a == token_b
    end

    test "differing chat_thread_id changes the bearer (cache miss is intentional across threads)" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Two-thread doc"})

      assert {:ok, token_a} =
               Gateway.issue_route_ref(s, %{
                 user_id: s.user.id,
                 document_id: doc.id,
                 chat_thread_id: Ecto.UUID.generate(),
                 purpose: "agent_doc_mcp"
               })

      assert {:ok, token_b} =
               Gateway.issue_route_ref(s, %{
                 user_id: s.user.id,
                 document_id: doc.id,
                 chat_thread_id: Ecto.UUID.generate(),
                 purpose: "agent_doc_mcp"
               })

      refute token_a == token_b
    end

    test "verify never returns an agent_run_id, even when the mint receives one" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Agent run id absent"})
      run_id = Ecto.UUID.generate()

      assert {:ok, token} =
               Gateway.issue_route_ref(s, %{
                 user_id: s.user.id,
                 document_id: doc.id,
                 chat_thread_id: Ecto.UUID.generate(),
                 # Caller may still pass agent_run_id (ignored by mint).
                 agent_run_id: run_id,
                 purpose: "agent_doc_mcp"
               })

      assert {:ok, %RouteRef{agent_run_id: nil}} = Gateway.verify_route_ref(s, token)
    end
  end
end
