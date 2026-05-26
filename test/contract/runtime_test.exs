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
  alias Contract.RouteRef
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

    test "load denies pinned route_ref without user context" do
      owner = scope()
      doc_id = create_owned_doc(owner, title: "Runtime pinned bypass")

      ref = %RouteRef{
        document_id: doc_id,
        scopes: [],
        purpose: "runtime",
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.utc_now() |> DateTime.add(3_600, :second)
      }

      ctx = %Context{perms: %{route_ref: ref}}

      assert {:error, :forbidden} = Runtime.authorize_document(ctx, doc_id)
      assert {:error, :forbidden} = Runtime.load(ctx, doc_id)
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
            :add_mark,
            :update_mark,
            :archive_document,
            :restore_document,
            :agent_change
          ] do
        doc = Ecto.UUID.generate()
        _ = create_doc(doc)

        action = build_session_action(kind, doc)
        assert {:ok, %Change{}} = Runtime.apply(@ctx, action), "expected #{kind} to commit"

        # ensure_session started a Session for the doc.
        assert pid = Session.whereis(doc)
        cleanup_session(pid)
      end
    end
  end

  describe "apply/2 → :revoke_change" do
    test "revoke rejects documents owned by another user" do
      owner = scope()
      other = scope()
      doc_id = create_owned_doc(owner, title: "No revoke")

      action = %Command{
        kind: :revoke_change,
        document_id: doc_id,
        change_id: Ecto.UUID.generate(),
        actor_type: :user,
        actor_id: other.user.id,
        base_revision: 1,
        idempotency_key: "revoke-forbidden"
      }

      assert {:error, :forbidden} = Runtime.revoke(other, action)
    end

    test "routes through Session.revoke, returns a revoke Change; errors on missing doc_id" do
      doc = Ecto.UUID.generate()
      create_action = build_session_action(:rename_document, doc, idem: "rn-revtest")

      _ = create_doc(doc)
      assert {:ok, %Change{} = base} = Runtime.apply(@ctx, create_action)

      revoke = %Command{
        kind: :revoke_change,
        document_id: doc,
        change_id: base.id,
        actor_type: :user,
        actor_id: Ecto.UUID.generate(),
        base_revision: base.result_revision,
        idempotency_key: "rev-#{base.id}"
      }

      assert {:ok, %Change{command_kind: "revoke_change"}} = Runtime.apply(@ctx, revoke)

      pid = Session.whereis(doc)
      cleanup_session(pid)

      # Missing document_id → typed error.
      assert {:error, :missing_document_id} =
               Runtime.revoke(@ctx, %Command{
                 kind: :revoke_change,
                 actor_type: :user,
                 actor_id: Ecto.UUID.generate(),
                 change_id: Ecto.UUID.generate()
               })
    end
  end

  describe "apply/2 → conversion kinds (Wave 4 — Contract.Conversion)" do
    test "missing-payload errors are typed for every conversion Command kind" do
      doc_id = Ecto.UUID.generate()
      base = %Command{actor_type: :user, payload: %{}}

      assert {:error, :missing_document_id} =
               Runtime.apply(@ctx, %{
                 base
                 | kind: :start_type_conversion,
                   document_id: nil,
                   payload: %{"target_type_key" => "nda_v1"}
               })

      assert {:error, :missing_target_type_key} =
               Runtime.apply(@ctx, %{base | kind: :start_type_conversion, document_id: doc_id})

      assert {:error, :missing_plan} =
               Runtime.apply(@ctx, %{
                 base
                 | kind: :set_field_migration_strategy,
                   document_id: doc_id
               })

      assert {:error, :missing_plan} =
               Runtime.apply(@ctx, %{base | kind: :create_converted_variant, document_id: doc_id})
    end
  end

  describe "apply/2 → :request_export format parsing" do
    test "requesting markdown and lawyer_packet creates persisted export rows" do
      ctx = scope()
      markdown_doc_id = create_owned_doc(ctx, title: "Markdown export doc")
      packet_doc_id = create_owned_doc(ctx, title: "Packet export doc")

      for {doc_id, format} <- [{markdown_doc_id, "markdown"}, {packet_doc_id, "lawyer_packet"}] do
        action = %Command{
          kind: :request_export,
          document_id: doc_id,
          actor_type: :user,
          actor_id: ctx.user.id,
          payload: %{"format" => format}
        }

        assert {:ok, %Oban.Job{} = job} = Runtime.apply(ctx, action)
        assert job.args["format"] == format
        assert is_binary(job.args["export_id"])

        assert %{
                 document_id: ^doc_id,
                 requester_id: requester_id,
                 format: ^format,
                 status: "queued",
                 progress: 0
               } = export_record(job.args["export_id"])

        assert requester_id == ctx.user.id
      end
    end

    test "rejects html / unknown formats without leaking new atoms" do
      ctx = scope()
      doc_id = create_owned_doc(ctx, title: "No HTML export doc")

      html_action = %Command{
        kind: :request_export,
        document_id: doc_id,
        actor_type: :user,
        actor_id: ctx.user.id,
        payload: %{"format" => "html"}
      }

      assert {:error, {:unsupported_export_format, "html"}} = Runtime.apply(ctx, html_action)

      # Unknown string format → typed error AND no atom created.
      format = "unknown_export_#{System.unique_integer([:positive])}"
      refute existing_atom?(format)

      unknown_action = %{html_action | payload: %{"format" => format}}
      assert {:error, {:unsupported_export_format, ^format}} = Runtime.apply(ctx, unknown_action)
      refute existing_atom?(format)
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
    test "kind-lists cover SPEC §12 mutation, revoke, and conversion families" do
      session_kinds = Runtime.session_kinds()

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
        assert kind in session_kinds
      end

      assert :revoke_change in Runtime.revoke_kinds()
      assert :resolve_revoke in Runtime.revoke_kinds()
      assert :start_type_conversion in Runtime.conversion_kinds()
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

  defp create_doc(doc) do
    action = %Command{
      kind: :create_document,
      document_id: doc,
      actor_type: :user,
      actor_id: @ctx.user.id,
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

  defp export_record(export_id) do
    export = Repo.get!(Contract.Export, export_id)

    %{
      document_id: export.document_id,
      requester_id: export.requester_id,
      format: Atom.to_string(export.format),
      status: Atom.to_string(export.status),
      progress: export.progress
    }
  end

  defp existing_atom?(value) when is_binary(value) do
    _ = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
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
