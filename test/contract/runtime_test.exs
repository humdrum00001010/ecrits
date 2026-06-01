defmodule Contract.RuntimeTest do
  use Contract.DataCase, async: false

  import Mox

  alias Contract.Command
  alias Contract.Change
  alias Contract.Context
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.IO.R2Stub
  alias Contract.Lease
  alias Contract.Runtime
  alias Contract.Session
  alias Contract.Store

  setup :set_mox_from_context
  setup :verify_on_exit!

  @ctx %Context{
    user: %Contract.Accounts.User{
      id: "00000000-0000-0000-0000-000000000001",
      email: "runtime-default@example.test"
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

  describe "load/2 and sync_since/3" do
    test "load/sync_since enforce owner ACL and return :not_found for missing docs" do
      owner = scope()
      other = scope()
      doc_id = create_owned_doc(owner, title: "Private runtime doc")

      assert {:error, :forbidden} = Runtime.load(other, doc_id)
      assert {:error, :forbidden} = Runtime.sync_since(other, doc_id, 0)

      missing = Ecto.UUID.generate()
      assert {:error, :not_found} = Runtime.load(@ctx, missing)
      assert {:error, :not_found} = Runtime.sync_since(@ctx, missing, 0)
    end
  end

  describe "subscribe/2" do
    test "subscribes the caller to the document topic" do
      doc = Ecto.UUID.generate()
      _ = create_doc(doc)
      assert :ok = Runtime.subscribe(@ctx, doc)

      # Verify that we're actually subscribed by publishing.
      Phoenix.PubSub.broadcast(Contract.PubSub, Store.pubsub_topic(doc), :ping)
      assert_receive :ping, 1_000
    end
  end

  describe "ensure_session/2" do
    test "nil → missing_document_id; new doc starts/reuses; held lease → error" do
      # nil document_id → typed error.
      assert {:error, :missing_document_id} = Runtime.ensure_session(@ctx, nil)

      # Fresh start.
      doc = Ecto.UUID.generate()
      assert {:ok, pid1} = Runtime.ensure_session(@ctx, doc)
      assert is_pid(pid1)
      assert Session.whereis(doc) == pid1

      # Second call returns the same pid (idempotent).
      assert {:ok, ^pid1} = Runtime.ensure_session(@ctx, doc)
      cleanup_session(pid1)

      # Lease held externally → error.
      held_doc = Ecto.UUID.generate()
      {:ok, _lease} = Lease.acquire(held_doc, "external-holder")
      assert {:error, _} = Runtime.ensure_session(@ctx, held_doc)
    end
  end

  describe "apply/2 → :create_document" do
    test "creates an owner-scoped Document row before appending the initial Change" do
      ctx = scope()
      doc_id = Ecto.UUID.generate()

      action = %Command{
        kind: :create_document,
        document_id: doc_id,
        actor_type: :user,
        actor_id: ctx.user.id,
        base_revision: 0,
        idempotency_key: "create-persists-row",
        payload: %{"title" => "Persisted row", "type_key" => "nda_v1"}
      }

      assert {:ok, %Change{document_id: ^doc_id, result_revision: 1}} =
               Runtime.apply(ctx, action)

      assert {:ok, %Document{id: ^doc_id, owner_id: owner_id, title: "Persisted row"}} =
               Documents.get(ctx, doc_id)

      assert owner_id == ctx.user.id
    end

    test "persists a new Change without needing an external Session" do
      doc = Ecto.UUID.generate()

      action = %Command{
        kind: :create_document,
        document_id: doc,
        actor_type: :user,
        actor_id: @ctx.user.id,
        base_revision: 0,
        idempotency_key: "create-runtime-1",
        payload: %{"title" => "RT", "type_key" => "nda"}
      }

      assert {:ok, %Change{result_revision: 1}} = Runtime.apply(@ctx, action)

      # No Session was registered for this doc — create_document goes
      # straight to the Store.
      assert Session.whereis(doc) == nil
    end
  end

  describe "apply/2 → :open_document" do
    test "loads state for an existing doc; errors when document_id is missing" do
      doc = Ecto.UUID.generate()
      _ = create_doc(doc)

      assert {:ok, %Contract.Runtime.State{document_id: ^doc}} =
               Runtime.apply(@ctx, %Command{
                 kind: :open_document,
                 document_id: doc,
                 actor_type: :user,
                 actor_id: Ecto.UUID.generate()
               })

      assert {:error, :missing_document_id} =
               Runtime.apply(@ctx, %Command{kind: :open_document, actor_type: :user})
    end
  end

  describe "apply/2 → session-routed kinds" do
    test "session-routed writes reject documents owned by another user" do
      owner = scope()
      other = scope()
      doc_id = create_owned_doc(owner, title: "Not yours")

      assert {:error, :forbidden} =
               Runtime.apply(other, build_session_action(:rename_document, doc_id))
    end

    test "every session-routed kind routes through Session.commit and produces a Change" do
      for kind <- [
            :rename_document,
            :update_metadata,
            :set_contract_type,
            :edit_document,
            :agent_change
          ] do
        doc = Ecto.UUID.generate()

        if kind == :set_contract_type do
          _ = create_doc(doc, type_key: nil)
        else
          _ = create_doc(doc)
        end

        action = build_session_action(kind, doc)
        assert {:ok, %Change{}} = Runtime.apply(@ctx, action), "expected #{kind} to commit"

        # ensure_session started a Session for the doc.
        assert pid = Session.whereis(doc)
        cleanup_session(pid)
      end
    end

    test "set_contract_type is allowed once and rejected after the document is typed" do
      ctx = scope()
      doc_id = Ecto.UUID.generate()

      assert {:ok, %Change{result_revision: 1}} =
               Runtime.apply(ctx, %Command{
                 kind: :create_document,
                 document_id: doc_id,
                 actor_type: :user,
                 actor_id: ctx.user.id,
                 base_revision: 0,
                 idempotency_key: "create-untyped-#{doc_id}",
                 payload: %{"title" => "Untyped"}
               })

      assert {:ok, %Change{result_revision: 2}} =
               Runtime.apply(ctx, %Command{
                 kind: :set_contract_type,
                 document_id: doc_id,
                 actor_type: :user,
                 actor_id: ctx.user.id,
                 base_revision: 1,
                 idempotency_key: "select-type-#{doc_id}",
                 payload: %{"type_key" => "service_agreement_v1"}
               })

      assert %Document{type_key: "service_agreement_v1"} = Contract.Repo.get!(Document, doc_id)

      assert {:ok, %Runtime.State{projection: %{type_key: "service_agreement_v1"}}} =
               Runtime.load(ctx, doc_id)

      assert {:error, :document_type_already_set} =
               Runtime.apply(ctx, %Command{
                 kind: :set_contract_type,
                 document_id: doc_id,
                 actor_type: :user,
                 actor_id: ctx.user.id,
                 base_revision: 2,
                 idempotency_key: "replace-type-#{doc_id}",
                 payload: %{"type_key" => "employment_v1"}
               })

      assert %Document{type_key: "service_agreement_v1"} = Contract.Repo.get!(Document, doc_id)

      assert {:ok, %Runtime.State{projection: %{type_key: "service_agreement_v1"}}} =
               Runtime.load(ctx, doc_id)
    end
  end

  describe "apply/2 → pruned DB-backed kinds" do
    test "source/import/export/revoke/conversion/mark kinds are unsupported" do
      doc_id = Ecto.UUID.generate()

      for kind <- [
            :upload_document,
            :duplicate_document,
            :request_export,
            :revoke_change,
            :resolve_revoke,
            :start_type_conversion,
            :set_field_migration_strategy,
            :create_converted_variant,
            :source_claim_confirm,
            :source_claim_correct,
            :source_claim_reject,
            :source_claim_link_to_document,
            :source_claim_unlink_from_document,
            :add_mark,
            :update_mark
          ] do
        action = %Command{
          kind: kind,
          document_id: doc_id,
          actor_type: :user,
          actor_id: Ecto.UUID.generate(),
          payload: %{}
        }

        assert {:error, {:unsupported_action_kind, ^kind}} = Runtime.apply(@ctx, action)
      end
    end
  end

  describe "apply/2 → :chat_message" do
    test "persists the user message and routes through Contract.Agent.Document" do
      parent = self()

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts ->
        send(parent, :runtime_agent_stream_started)

        stream = [
          %{
            type: "response.output_text.delta",
            data: %{"type" => "response.output_text.delta", "delta" => "done"}
          }
        ]

        {:ok, %{stream: stream, task_pid: self()}}
      end)

      document_id = Ecto.UUID.generate()

      action = %Command{
        kind: :chat_message,
        document_id: document_id,
        actor_type: :user,
        message: "hi",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, %Contract.Agent.Run{} = run} = Runtime.apply(@ctx, action)
      assert run.document_id == document_id
      assert run.owner_id == @ctx.user.id
      assert_receive :runtime_agent_stream_started, 1_000
      assert_receive {:agent_completed, run_id, %Command{message: "done"}}, 1_000
      assert run_id == run.id
    end
  end

  describe "apply/2 → unknown kind" do
    test "rejects unknown action kinds with {:error, {:unsupported_action_kind, _}}" do
      # An Action struct with kind set to nil makes it unmatched by all
      # routing clauses.
      action = %Command{kind: nil}
      assert {:error, {:unsupported_action_kind, nil}} = Runtime.apply(@ctx, action)
    end
  end

  describe "session_kinds/0 and helpers" do
    test "kind-lists cover only live session mutation families" do
      session_kinds = Runtime.session_kinds()

      for kind <- [
            :rename_document,
            :update_metadata,
            :set_contract_type,
            :edit_document,
            :edit_text,
            :agent_change
          ] do
        assert kind in session_kinds
      end

      refute :add_mark in session_kinds
      refute :update_mark in session_kinds
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp scope do
    user_id = Ecto.UUID.generate()

    %Context{
      user: %Contract.Accounts.User{
        id: user_id,
        email: "runtime-#{user_id}@example.test"
      }
    }
  end

  defp create_owned_doc(%Context{} = ctx, opts) do
    title = Keyword.fetch!(opts, :title)
    doc_id = Ecto.UUID.generate()

    action = %Command{
      kind: :create_document,
      document_id: doc_id,
      actor_type: :user,
      actor_id: ctx.user.id,
      base_revision: 0,
      idempotency_key: "create-owned-#{doc_id}",
      payload: %{"title" => title, "type_key" => "nda_v1"}
    }

    {:ok, %Change{}} = Runtime.apply(ctx, action)
    doc_id
  end

  defp create_doc(doc, opts \\ []) do
    type_key = Keyword.get(opts, :type_key, "nda")

    payload =
      if is_nil(type_key),
        do: %{"title" => "Doc"},
        else: %{"title" => "Doc", "type_key" => type_key}

    action = %Command{
      kind: :create_document,
      document_id: doc,
      actor_type: :user,
      actor_id: @ctx.user.id,
      base_revision: 0,
      idempotency_key: "create-#{doc}",
      payload: payload
    }

    {:ok, _} = Runtime.apply(@ctx, action)
    :ok
  end

  defp build_session_action(kind, doc, opts \\ []) do
    {payload, base_rev} =
      case kind do
        :rename_document ->
          {%{"title" => "Renamed"}, 1}

        :update_metadata ->
          {%{"metadata" => %{"draft_state" => "in_review"}}, 1}

        :set_contract_type ->
          {%{"type_key" => "service"}, 1}

        :edit_document ->
          {%{
             "ops" => [
               %{
                 "op" => "set_attr",
                 "target_type" => "document",
                 "target_id" => doc,
                 "args" => %{"key" => "title", "value" => "Edited"}
               }
             ]
           }, 1}

        :agent_change ->
          {%{"ops" => [], "marks" => []}, 1}

        _ ->
          {%{}, 1}
      end

    %Command{
      kind: kind,
      document_id: doc,
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: base_rev,
      idempotency_key: Keyword.get(opts, :idem, "#{kind}-#{System.unique_integer([:positive])}"),
      payload: payload
    }
  end

  defp cleanup_session(nil), do: :ok

  defp cleanup_session(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :shutdown)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        500 -> :ok
      end
    end

    :ok
  end
end
