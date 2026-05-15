defmodule Contract.RuntimeTest do
  use Contract.DataCase, async: false

  import Mox

  alias Contract.Action
  alias Contract.Change
  alias Contract.IO.R2Stub
  alias Contract.Lease
  alias Contract.Runtime
  alias Contract.Session
  alias Contract.Store

  setup :set_mox_from_context
  setup :verify_on_exit!

  @ctx %Contract.Context{}

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
    test "load returns empty state for a new document" do
      doc = Ecto.UUID.generate()
      assert {:ok, %Contract.Runtime.State{revision: 0}} = Runtime.load(@ctx, doc)
    end

    test "sync_since returns [] for a fresh document" do
      assert {:ok, []} = Runtime.sync_since(@ctx, Ecto.UUID.generate(), 0)
    end
  end

  describe "subscribe/2" do
    test "subscribes the caller to the document topic" do
      doc = Ecto.UUID.generate()
      assert :ok = Runtime.subscribe(@ctx, doc)

      # Verify that we're actually subscribed by publishing.
      Phoenix.PubSub.broadcast(Contract.PubSub, Store.pubsub_topic(doc), :ping)
      assert_receive :ping, 1_000
    end
  end

  describe "ensure_session/2" do
    test "returns {:error, :missing_document_id} for nil" do
      assert {:error, :missing_document_id} = Runtime.ensure_session(@ctx, nil)
    end

    test "starts a new session and returns its pid" do
      doc = Ecto.UUID.generate()
      assert {:ok, pid} = Runtime.ensure_session(@ctx, doc)
      assert is_pid(pid)
      assert Session.whereis(doc) == pid
      cleanup_session(pid)
    end

    test "returns the existing pid when called twice for the same doc" do
      doc = Ecto.UUID.generate()
      assert {:ok, pid1} = Runtime.ensure_session(@ctx, doc)
      assert {:ok, pid2} = Runtime.ensure_session(@ctx, doc)
      assert pid1 == pid2
      cleanup_session(pid1)
    end

    test "returns :held_by_other style error when lease is held externally" do
      doc = Ecto.UUID.generate()
      {:ok, _lease} = Lease.acquire(doc, "external-holder")

      assert {:error, _} = Runtime.ensure_session(@ctx, doc)
    end
  end

  describe "apply/2 → :create_document" do
    test "persists a new Change without needing an external Session" do
      doc = Ecto.UUID.generate()

      action = %Action{
        kind: :create_document,
        document_id: doc,
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: 0,
        idempotency_key: "create-runtime-1",
        payload: %{"title" => "RT", "type_key" => "nda"}
      }

      assert {:ok, %Change{applied_revision: 1}} = Runtime.apply(@ctx, action)

      # No Session was registered for this doc — create_document goes
      # straight to the Store.
      assert Session.whereis(doc) == nil
    end
  end

  describe "apply/2 → :open_document" do
    test "loads the document's current state" do
      doc = Ecto.UUID.generate()
      _ = create_doc(doc)

      action = %Action{
        kind: :open_document,
        document_id: doc,
        actor_type: :user,
        actor_id: Ecto.UUID.generate()
      }

      assert {:ok, %Contract.Runtime.State{document_id: ^doc}} = Runtime.apply(@ctx, action)
    end

    test "errors when document_id is missing" do
      action = %Action{kind: :open_document, actor_type: :user}
      assert {:error, :missing_document_id} = Runtime.apply(@ctx, action)
    end
  end

  describe "apply/2 → session-routed kinds" do
    for kind <- [
          :rename_document,
          :update_metadata,
          :set_contract_type,
          :edit_document,
          :add_mark,
          :update_mark,
          :archive_document,
          :restore_document,
          :agent_change
        ] do
      @kind kind

      test "#{kind} routes through Session.commit and produces a Change" do
        doc = Ecto.UUID.generate()
        _ = create_doc(doc)

        action = build_session_action(@kind, doc)

        assert {:ok, %Change{}} = Runtime.apply(@ctx, action)

        # Session was started by ensure_session.
        assert pid = Session.whereis(doc)
        cleanup_session(pid)
      end
    end
  end

  describe "apply/2 → :revoke_change" do
    test "routes through Session.revoke and returns the new revoke Change" do
      doc = Ecto.UUID.generate()
      create_action = build_session_action(:rename_document, doc, idem: "rn-revtest")

      _ = create_doc(doc)
      assert {:ok, %Change{} = base} = Runtime.apply(@ctx, create_action)

      revoke = %Action{
        kind: :revoke_change,
        document_id: doc,
        change_id: base.id,
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: base.applied_revision,
        idempotency_key: "rev-#{base.id}"
      }

      assert {:ok, %Change{action_kind: "revoke_change"}} = Runtime.apply(@ctx, revoke)

      pid = Session.whereis(doc)
      cleanup_session(pid)
    end

    test "errors when document_id missing" do
      action = %Action{
        kind: :revoke_change,
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        change_id: Ecto.UUID.generate()
      }

      assert {:error, :missing_document_id} = Runtime.revoke(@ctx, action)
    end
  end

  describe "apply/2 → conversion kinds (Wave 4 — Contract.Conversion)" do
    test ":start_type_conversion without document_id is a typed error" do
      action = %Action{
        kind: :start_type_conversion,
        document_id: nil,
        actor_type: :user,
        payload: %{"target_type_key" => "nda_v1"}
      }

      assert {:error, :missing_document_id} = Runtime.apply(@ctx, action)
    end

    test ":start_type_conversion without target_type_key is a typed error" do
      action = %Action{
        kind: :start_type_conversion,
        document_id: Ecto.UUID.generate(),
        actor_type: :user,
        payload: %{}
      }

      assert {:error, :missing_target_type_key} = Runtime.apply(@ctx, action)
    end

    test ":set_field_migration_strategy without a plan is a typed error" do
      action = %Action{
        kind: :set_field_migration_strategy,
        document_id: Ecto.UUID.generate(),
        actor_type: :user,
        payload: %{}
      }

      assert {:error, :missing_plan} = Runtime.apply(@ctx, action)
    end

    test ":create_converted_variant without a plan is a typed error" do
      action = %Action{
        kind: :create_converted_variant,
        document_id: Ecto.UUID.generate(),
        actor_type: :user,
        payload: %{}
      }

      assert {:error, :missing_plan} = Runtime.apply(@ctx, action)
    end
  end

  describe "apply/2 → :chat_message" do
    test "delegates to Contract.Agent.start/2" do
      # The Agent.RunServer will eagerly call the OpenAI driver via
      # handle_continue; provide a no-op expectation so the run can spin
      # up without exploding. We don't care about agent output here, only
      # that Runtime routes :chat_message to Agent.start/2.
      Contract.IO.OpenAIMock
      |> stub(:stream_chat, fn _params, _opts ->
        {:ok, %{stream: Stream.into([], []), task_pid: self()}}
      end)

      action = %Action{
        kind: :chat_message,
        document_id: Ecto.UUID.generate(),
        actor_type: :user,
        message: "hi"
      }

      assert {:ok, %Contract.Agent.Run{} = run} = Runtime.apply(@ctx, action)

      # Defensive cleanup
      _ = Contract.Agent.cancel(@ctx, run.id)
    end
  end

  describe "apply/2 → unknown kind" do
    test "rejects unknown action kinds with {:error, {:unsupported_action_kind, _}}" do
      # An Action struct with kind set to nil makes it unmatched by all
      # routing clauses.
      action = %Action{kind: nil}
      assert {:error, {:unsupported_action_kind, nil}} = Runtime.apply(@ctx, action)
    end
  end

  describe "session_kinds/0 and helpers" do
    test "session_kinds includes all SPEC §12 mutation kinds" do
      kinds = Runtime.session_kinds()

      for kind <- [
            :rename_document,
            :update_metadata,
            :set_contract_type,
            :edit_document,
            :add_mark,
            :update_mark,
            :archive_document,
            :restore_document,
            :duplicate_document,
            :agent_change
          ] do
        assert kind in kinds
      end
    end

    test "revoke_kinds returns both revoke action kinds" do
      assert :revoke_change in Runtime.revoke_kinds()
      assert :resolve_revoke in Runtime.revoke_kinds()
    end

    test "conversion_kinds covers deferred Wave 4 kinds" do
      assert :start_type_conversion in Runtime.conversion_kinds()
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp create_doc(doc) do
    action = %Action{
      kind: :create_document,
      document_id: doc,
      actor_type: :user,
      actor_id: Ecto.UUID.generate(),
      base_revision: 0,
      idempotency_key: "create-#{doc}",
      payload: %{"title" => "Doc", "type_key" => "nda"}
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

        :add_mark ->
          {%{
             "marks" => [
               %{
                 "target_type" => "document",
                 "target_id" => doc,
                 "intent" => "label",
                 "source" => "user",
                 "text" => "label1"
               }
             ]
           }, 1}

        :update_mark ->
          {%{
             "marks" => [
               %{
                 "target_type" => "document",
                 "target_id" => doc,
                 "intent" => "label",
                 "source" => "user",
                 "text" => "label1-updated"
               }
             ]
           }, 1}

        :archive_document ->
          {%{}, 1}

        :restore_document ->
          {%{}, 1}

        :agent_change ->
          {%{"ops" => [], "marks" => []}, 1}

        _ ->
          {%{}, 1}
      end

    %Action{
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
