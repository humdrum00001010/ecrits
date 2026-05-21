defmodule Contract.StudioTest do
  use Contract.DataCase, async: false

  import Mox

  alias Contract.Change
  alias Contract.ChatThread
  alias Contract.Command
  alias Contract.Context
  alias Contract.Documents
  alias Contract.IO.R2Stub
  alias Contract.Repo
  alias Contract.RouteRef
  alias Contract.Studio
  alias Contract.Studio.State

  setup :set_mox_from_context
  setup :verify_on_exit!

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

  defp scope do
    user = %Contract.Accounts.User{id: Ecto.UUID.generate(), email: "studio@example.com"}
    Context.for_user(user)
  end

  describe "open/2" do
    test "loads no-document state when no document_id is supplied" do
      assert {:ok, {%State{} = state, projection}} = Studio.open(scope(), %{})
      assert state.selected_document_id == nil
      assert state.mode == :no_document
      assert projection == Contract.Runtime.State.empty_projection()
    end

    test "loads an owner-scoped document from string-keyed params" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Studio doc"})

      assert {:ok, {%State{} = state, _projection}} = Studio.open(s, %{"document_id" => doc.id})
      assert state.selected_document_id == doc.id
      assert state.mode == :briefing
    end

    test "rejects a document owned by another user" do
      owner = scope()
      other = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Private"})

      assert {:error, :forbidden} = Studio.open(other, %{"document_id" => doc.id})
    end
  end

  describe "command/2" do
    test "routes a document-scoped Command to Runtime.apply/2" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Original"})

      command = %Command{
        kind: :rename_document,
        document_id: doc.id,
        actor_type: :user,
        actor_id: s.user.id,
        base_revision: 0,
        idempotency_key: "rename-#{doc.id}",
        payload: %{"title" => "Renamed"}
      }

      assert {:ok, %Change{} = change} = Studio.command(s, command)
      assert change.command_kind == "rename_document"
    end

    test "accepts a chat-only Command with document_id=nil (SPEC §4.4)" do
      # SPEC.md §4.4: the user opens /studio without a document and starts
      # chatting. A `:chat_message` Command with document_id=nil must be
      # accepted by the façade and routed to the agent — the agent
      # gathers context until it can propose a Command(:create_document).
      Contract.IO.OpenAIMock
      |> stub(:stream_chat, fn _params, _opts ->
        {:ok, %{stream: Stream.into([], []), task_pid: self()}}
      end)

      s = scope()

      command = %Command{
        kind: :chat_message,
        document_id: nil,
        actor_type: :user,
        actor_id: s.user.id,
        message: "I need an NDA."
      }

      assert {:ok, %Contract.Agent.Run{} = run} = Studio.command(s, command)
      assert is_binary(run.id)

      _ = Contract.Agent.cancel(s, run.id)
    end

    test "propagates Runtime errors verbatim" do
      s = scope()

      # rename_document without a document_id violates Runtime's session-kind
      # contract (needs an ensure_session step that wants a binary id).
      command = %Command{
        kind: :rename_document,
        document_id: nil,
        actor_type: :user,
        actor_id: s.user.id,
        payload: %{"title" => "Nope"}
      }

      assert {:error, _} = Studio.command(s, command)
    end
  end

  # ---------------------------------------------------------------------------
  # sync/3 — the new (ctx, document_id, from_revision) signature
  # ---------------------------------------------------------------------------

  describe "sync/3" do
    test "returns [] when no document is selected (nil document_id)" do
      assert {:ok, []} = Studio.sync(scope(), nil, 0)
    end

    test "returns committed changes after a known revision" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Sync source"})

      # Apply one change so we have a Change row past revision 0.
      command = %Command{
        kind: :rename_document,
        document_id: doc.id,
        actor_type: :user,
        actor_id: s.user.id,
        base_revision: 0,
        idempotency_key: "sync-rename-#{doc.id}",
        payload: %{"title" => "Renamed for sync"}
      }

      {:ok, %Change{result_revision: rev_after_rename}} = Studio.command(s, command)

      assert {:ok, changes} = Studio.sync(s, doc.id, 0)
      assert is_list(changes)
      assert Enum.any?(changes, &(&1.result_revision == rev_after_rename))

      # Asking for sync from the latest known revision returns nothing
      # later than that — this is the steady-state reconnect noop.
      assert {:ok, later} = Studio.sync(s, doc.id, rev_after_rename)
      assert Enum.all?(later, &(&1.result_revision > rev_after_rename))
    end

    test "tolerates a from_revision beyond head (no error, no clamp, just empty)" do
      # Unclear behavior pin: if the LV's last_seen_revision somehow
      # races ahead of Store's head (shouldn't happen but a defensive
      # reconnect could) the façade must NOT crash — it returns an
      # empty change list so the LV settles quietly.
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Forward-rev sync"})

      # Pick a revision certain to be past head.
      future_rev = 9_999

      assert {:ok, changes} = Studio.sync(s, doc.id, future_rev)
      assert changes == []
    end

    test "rejects negative revisions as :invalid_revision" do
      assert {:error, :invalid_revision} = Studio.sync(scope(), Ecto.UUID.generate(), -1)
    end
  end

  # ---------------------------------------------------------------------------
  # subscribe/2 — new (ctx, document_id) signature
  # ---------------------------------------------------------------------------

  describe "subscribe/2" do
    test "subscribes the caller to the document topic for binary document_id" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Subscribe target"})

      assert :ok = Studio.subscribe(s, doc.id)

      # Verify the subscription by broadcasting on the document topic
      # and asserting the test receives it.
      topic = Contract.Store.pubsub_topic(doc.id)
      doc_id = doc.id
      Phoenix.PubSub.broadcast(Contract.PubSub, topic, {:probe, doc_id})
      assert_receive {:probe, ^doc_id}, 200
    end

    test "returns :ok noop for nil document_id" do
      assert :ok = Studio.subscribe(scope(), nil)
    end

    test "denies subscribing to a foreign document" do
      owner = scope()
      other = scope()
      {:ok, doc} = Documents.create(owner, %{title: "Private subscribe target"})

      assert {:error, :forbidden} = Studio.subscribe(other, doc.id)
    end

    test "subscription lifecycle is tied to caller pid — exit cleans it up" do
      # Unclear behavior pin: SPEC.md §10 says subscribe takes a
      # document_id (no explicit unsubscribe call). The implicit
      # contract is that Phoenix.PubSub tracks subscriptions per pid
      # via Registry — when the calling process exits, the
      # subscription is dropped. Pin this so a future refactor
      # doesn't silently leak subscriptions across LV reconnects.
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Lifecycle subscribe"})
      topic = Contract.Store.pubsub_topic(doc.id)

      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          :ok = Studio.subscribe(s, doc.id)
          send(parent, :subscribed)

          receive do
            :die -> :ok
          after
            1_000 -> :ok
          end
        end)

      assert_receive :subscribed, 200

      # While alive, the subscriber is registered.
      subscribers = Registry.lookup(Contract.PubSub, topic)
      assert Enum.any?(subscribers, fn {sub_pid, _} -> sub_pid == pid end)

      # Kill the subscriber and wait for the down.
      send(pid, :die)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500

      # Give Registry a tick to clean up, then verify.
      Process.sleep(50)
      subscribers = Registry.lookup(Contract.PubSub, topic)
      refute Enum.any?(subscribers, fn {sub_pid, _} -> sub_pid == pid end)
    end

    test "state-flavored shim subscribes to document topic when state has selected_document_id" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "State-shim subscribe"})

      state = %State{selected_document_id: doc.id, last_seen_revision: 0}
      assert :ok = Studio.subscribe(s, state)
    end
  end

  describe "subscribe_agent/2" do
    test "subscribes to agent topic when agent_run_id is binary" do
      s = scope()
      run_id = Ecto.UUID.generate()

      assert :ok = Studio.subscribe_agent(s, run_id)

      Phoenix.PubSub.broadcast(Contract.PubSub, "agent:" <> run_id, {:agent_probe, run_id})
      assert_receive {:agent_probe, ^run_id}, 200
    end

    test "is a noop for nil" do
      assert :ok = Studio.subscribe_agent(scope(), nil)
    end
  end

  # ---------------------------------------------------------------------------
  # route_ref/3 — new SPEC §10 helper
  # ---------------------------------------------------------------------------

  describe "route_ref/3" do
    test "mints a signed token for a Document struct, embedding the document_id" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Route_ref target"})

      assert {:ok, token} = Studio.route_ref(s, doc, purpose: "deep_link", scopes: ["read"])
      assert is_binary(token)

      assert {:ok, %RouteRef{} = ref} = Contract.Gateway.verify_route_ref(s, token)
      assert ref.document_id == doc.id
      assert ref.purpose == "deep_link"
      assert "read" in ref.scopes
    end

    test "accepts a binary document_id directly" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Bin doc_id"})
      doc_id = doc.id

      assert {:ok, token} = Studio.route_ref(s, doc.id, purpose: "mcp")

      assert {:ok, %RouteRef{document_id: ^doc_id, purpose: "mcp"}} =
               Contract.Gateway.verify_route_ref(s, token)
    end

    test "does NOT embed agent_run_id in the signed token (task #139 — deterministic bearer)" do
      # Task #139 — the route_ref bearer is intentionally deterministic
      # per (user, doc, thread) so OpenAI's hosted MCP tools/list cache
      # (keyed by bearer) hits across turns. `agent_run_id` is no
      # longer part of the signed payload; it's reconstructed
      # server-side at submit_change time via
      # `Contract.Agent.RunServer.whereis_for_scope/2`.
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Agent route_ref"})
      run_id = Ecto.UUID.generate()

      assert {:ok, token} =
               Studio.route_ref(s, doc, purpose: "agent", agent_run_id: run_id)

      assert {:ok, %RouteRef{agent_run_id: nil}} =
               Contract.Gateway.verify_route_ref(s, token)
    end

    test "two mints with the same scope produce byte-equal tokens" do
      # Task #139 — bearer determinism is the whole point: OpenAI caches
      # tools/list keyed by bearer, so a fresh token per turn busts the
      # cache (~700ms cold rebuild on every first message).
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Determinism doc"})
      thread_id = Ecto.UUID.generate()

      opts = [purpose: "agent_doc_mcp", scopes: ["agent_doc"], chat_thread_id: thread_id]

      assert {:ok, token_a} = Studio.route_ref(s, doc, opts)
      assert {:ok, token_b} = Studio.route_ref(s, doc, opts)
      assert token_a == token_b
    end

    test "accepts a ChatThread and embeds chat_thread_id (no document_id)" do
      s = scope()

      thread =
        Repo.insert!(%ChatThread{
          owner_id: s.user.id,
          messages: []
        })

      assert {:ok, token} = Studio.route_ref(s, thread, purpose: "slack_thread")
      assert {:ok, %RouteRef{} = ref} = Contract.Gateway.verify_route_ref(s, token)
      assert ref.chat_thread_id == thread.id
      assert ref.document_id == nil
      assert ref.purpose == "slack_thread"
    end

    test "accepts nil and mints a scope-only token" do
      s = scope()
      assert {:ok, token} = Studio.route_ref(s, nil, purpose: "scope_only")

      assert {:ok, %RouteRef{document_id: nil, purpose: "scope_only"}} =
               Contract.Gateway.verify_route_ref(s, token)
    end

    test "rejects pid-in-attrs (regression guard for SPEC §15.2)" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Pid guard"})

      assert {:error, :pid_in_attrs} =
               Studio.route_ref(s, doc, purpose: self())
    end
  end

  # ---------------------------------------------------------------------------
  # list/search documents (unchanged from prior pass — kept for coverage)
  # ---------------------------------------------------------------------------

  describe "list/search documents" do
    test "list_documents/1 returns owner-scoped rows" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Visible", type_key: "nda_v1"})

      assert [%{document_id: id, title: "Visible"}] = Studio.list_documents(s)
      assert id == doc.id
    end

    test "search_documents/2 returns owner-scoped matches" do
      s = scope()
      {:ok, doc} = Documents.create(s, %{title: "Needle draft", type_key: nil})

      assert [%{document_id: id, title: "Needle draft"}] = Studio.search_documents(s, "Needle")
      assert id == doc.id
    end
  end
end
