defmodule Contract.Studio do
  @moduledoc """
  Product façade for the one big LiveView. Orchestrates open, select, command,
  sync, subscribe, route_ref. See SPEC.md §10.

  Studio is the thin product seam between `ContractWeb.StudioLive` and
  `Contract.Runtime`. It does **not** own document truth — `Store` is truth.
  It only:

    * shapes a `%Contract.Studio.State{}` for the LV to render against;
    * routes UI-level intents (open, select, command, sync) through the
      `Runtime`;
    * subscribes the calling process to the right PubSub topics so
      `handle_info/2` in the LV receives the §9 protocol messages;
    * mints signed `route_ref` tokens via `Contract.Gateway` so external
      callers (Slack, MCP, deep links) can act on a Document without ever
      seeing a BEAM pid (SPEC.md §15 invariant 2).

  v0.5: Matter is gone — `open/2` no longer reads `:matter_id` from
  params. The Context Reservoir is no longer in spec — the
  `load_context_reservoir/2`, `refresh_context_reservoir/2`, and
  `submit_context_action/3` functions have been removed.
  """

  alias Contract.Agent.Run
  alias Contract.Command
  alias Contract.Change
  alias Contract.Context
  alias Contract.Gateway
  alias Contract.Runtime
  alias Contract.Store
  alias Contract.Studio.State
  alias Contract.Types, as: T

  @pubsub Contract.PubSub

  # ----------------------------------------------------------------------------
  # open/2  (was load/2)
  # ----------------------------------------------------------------------------

  @doc """
  Hydrates a `%Studio.State{}` for the calling LiveView from the routing
  params + scope. Accepts either string-keyed (Phoenix params) or atom-keyed
  maps; the only key recognised is `"document_id"`.

  When a `document_id` is present, the call also primes `Runtime.load/2`
  and stamps `last_seen_revision` from the loaded projection. The
  `Runtime.State.projection` itself is returned through the second tuple
  slot so the LV can `assign(:projection, ...)` directly without a
  second round-trip.
  """
  @spec open(T.ctx(), T.params() | map()) :: T.result({State.t(), map()})
  def open(%Context{} = ctx, params) when is_map(params) do
    document_id = read_param(params, [:document_id, "document_id"])

    case do_open(ctx, document_id) do
      {:ok, %State{} = state, projection, revision} ->
        {:ok,
         {%State{
            state
            | last_seen_revision: revision
          }, projection}}

      {:error, _} = err ->
        err
    end
  end

  def open(_ctx, _params), do: {:error, :invalid_params}

  defp do_open(_ctx, nil) do
    state = %State{
      selected_document_id: nil,
      mode: :no_document,
      last_seen_revision: 0
    }

    {:ok, state, empty_projection(), 0}
  end

  defp do_open(ctx, document_id) do
    with {:ok, _doc} <- Contract.Documents.get(ctx, document_id),
         {:ok, %Runtime.State{revision: rev, projection: proj}} <- Runtime.load(ctx, document_id) do
      state = %State{
        selected_document_id: document_id,
        mode: derive_mode(document_id, proj),
        last_seen_revision: rev
      }

      {:ok, state, proj, rev}
    else
      {:error, _} = err -> err
    end
  end

  # ----------------------------------------------------------------------------
  # reload/2
  # ----------------------------------------------------------------------------

  @doc """
  Reloads the currently-selected document from `Runtime.load/2`. Used after
  a reconnect when the LV doesn't know whether it lost messages.
  """
  @spec reload(T.ctx(), State.t()) :: T.result({State.t(), map()})
  def reload(%Context{} = _ctx, %State{selected_document_id: nil} = state) do
    {:ok, {state, empty_projection()}}
  end

  def reload(%Context{} = ctx, %State{selected_document_id: doc_id} = state) do
    case Runtime.load(ctx, doc_id) do
      {:ok, %Runtime.State{revision: rev, projection: proj}} ->
        {:ok, {%State{state | last_seen_revision: rev}, proj}}

      {:error, _} = err ->
        err
    end
  end

  # ----------------------------------------------------------------------------
  # select_document/3
  # ----------------------------------------------------------------------------

  @doc """
  Switches the LV to a different document. Loads the new document's
  projection and resets ephemeral selection state.
  """
  @spec select_document(T.ctx(), State.t(), T.document_id() | nil) ::
          T.result({State.t(), map()})
  def select_document(_ctx, %State{} = state, nil) do
    new_state = %State{
      state
      | selected_document_id: nil,
        selected_node_id: nil,
        last_seen_revision: 0,
        mode: :no_document,
        agent_run_id: nil
    }

    {:ok, {new_state, empty_projection()}}
  end

  def select_document(%Context{} = ctx, %State{} = state, document_id)
      when is_binary(document_id) do
    case Runtime.load(ctx, document_id) do
      {:ok, %Runtime.State{revision: rev, projection: proj}} ->
        new_state = %State{
          state
          | selected_document_id: document_id,
            selected_node_id: nil,
            last_seen_revision: rev,
            mode: derive_mode(document_id, proj),
            agent_run_id: nil
        }

        {:ok, {new_state, proj}}

      {:error, _} = err ->
        err
    end
  end

  # ----------------------------------------------------------------------------
  # command/2  (was submit/3 — Command now carries document_id)
  # ----------------------------------------------------------------------------

  @doc """
  Submits a Command. Routes through `Runtime.apply/2` (or `Runtime.revoke/2`
  for revoke kinds).

  The Command struct already carries `document_id` (per W2), so the façade
  no longer threads it through the call. For chat-only commands (SPEC.md
  §4.4) `document_id` is `nil` — that's expected; `chat_message` doesn't
  require one.

  On success, returns whatever `Runtime.apply/2` returned (typically a
  `%Change{}` for document mutations, a `%Run{}` for `:chat_message`,
  or kind-specific records for source-claim / conversion / export
  routes).

  The LV doesn't mutate the projection from here — `Store.append/3`
  broadcasts `{:change_committed, change}` which `handle_info/2` consumes.
  """
  @spec command(T.ctx(), Command.t()) :: T.result(term())
  def command(%Context{} = ctx, %Command{} = command) do
    Runtime.apply(ctx, command)
  end

  # Internal helper used by `ContractWeb.StudioLive.dispatch/2`. Submits a
  # command and folds any new `agent_run_id` back into the LV's state. Public
  # callers should use `command/2` and update state themselves.
  @doc false
  @spec command_result(T.ctx(), State.t(), Command.t()) ::
          {:ok, State.t(), term()} | {:error, term()}
  def command_result(%Context{} = ctx, %State{} = state, %Command{} = command) do
    case command(ctx, command) do
      {:ok, %Change{} = change} ->
        {:ok, state, change}

      {:ok, %Run{id: agent_run_id} = run} when is_binary(agent_run_id) ->
        {:ok, %State{state | agent_run_id: agent_run_id}, run}

      {:ok, %{agent_run_id: agent_run_id} = agent} when is_binary(agent_run_id) ->
        {:ok, %State{state | agent_run_id: agent_run_id}, agent}

      {:ok, other} ->
        {:ok, state, other}

      {:error, _} = err ->
        err
    end
  end

  # ----------------------------------------------------------------------------
  # sync/3
  # ----------------------------------------------------------------------------

  @doc """
  Replays missed changes for `document_id` from `from_revision` to current
  head. Returns the list of changes the caller must re-fold into its
  projection.

  Per SPEC.md §10, the new signature is `(ctx, document_id, from_revision)`
  — the LV passes its `studio_state.last_seen_revision` for
  `from_revision`. The state-folded variant remains as a `@doc false`
  helper for the LV's `handle_protocol_message({:session_recovered, …})`
  path.

  Behavior:

    * `document_id` is `nil` → `{:ok, []}` (no document selected, no
      changes to replay).
    * `from_revision` is past current head → `{:ok, []}` (no later
      changes exist; this is treated as a noop, NOT an error, so a
      racy reconnect that already saw the latest change doesn't
      surface as a flash).
    * Otherwise → `{:ok, [Change.t()]}` for every change with
      `result_revision > from_revision`.
  """
  @spec sync(T.ctx(), T.document_id() | nil, T.revision()) :: T.result([Change.t()])
  def sync(_ctx, nil, _from_revision), do: {:ok, []}

  def sync(%Context{} = ctx, document_id, from_revision)
      when is_binary(document_id) and is_integer(from_revision) and from_revision >= 0 do
    Runtime.sync_since(ctx, document_id, from_revision)
  end

  def sync(_ctx, _document_id, _from_revision), do: {:error, :invalid_revision}

  # Internal helper: state-folded form of `sync/3` for the LV's session-
  # recovery path. Drops the `selected_document_id` out of `state` and
  # forwards. Public callers should use `sync/3` directly.
  @doc false
  @spec sync_state(T.ctx(), State.t(), T.revision()) :: T.result({State.t(), [Change.t()]})
  def sync_state(_ctx, %State{selected_document_id: nil} = state, _from_revision) do
    {:ok, {state, []}}
  end

  def sync_state(%Context{} = ctx, %State{selected_document_id: doc_id} = state, from_revision)
      when is_integer(from_revision) and from_revision >= 0 do
    case sync(ctx, doc_id, from_revision) do
      {:ok, changes} ->
        new_rev =
          changes
          |> Enum.map(& &1.result_revision)
          |> Enum.max(fn -> state.last_seen_revision end)

        {:ok, {%State{state | last_seen_revision: new_rev}, changes}}

      {:error, _} = err ->
        err
    end
  end

  # ----------------------------------------------------------------------------
  # subscribe/2
  # ----------------------------------------------------------------------------

  @doc """
  Subscribes the calling process to the PubSub topic for one document.

  Per SPEC.md §10 the new signature is `(ctx, document_id)`. The
  subscription lifecycle follows the calling process — when the LV
  exits, `Phoenix.PubSub` cleans the subscription up automatically
  (it's tied to `self()` via `Registry`). The caller does not need to
  unsubscribe by hand.

  Accepts:

    * `document_id` (binary UUID) — subscribes to the document topic.
      Authorization is enforced by `Runtime.subscribe/2` (returns
      `{:error, :forbidden}` if the scope can't read the document).
    * `nil` — `:ok` noop. Lets the LV call `subscribe/2` unconditionally
      at mount time without checking whether a document is selected.

  For agent stream subscriptions (`agent:<run_id>` topic), call
  `subscribe_agent/2` separately when an agent run starts.

  The state-flavored form, `subscribe(ctx, %State{})`, is kept as a
  `@doc false` shim for the LV's existing call sites and folds in the
  agent-run subscription if `state.agent_run_id` is set.
  """
  @spec subscribe(T.ctx(), T.document_id() | nil | State.t()) :: :ok | {:error, term()}
  def subscribe(_ctx, nil), do: :ok

  def subscribe(%Context{} = ctx, document_id) when is_binary(document_id) do
    case Runtime.subscribe(ctx, document_id) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  # state-flavored shim retained so the LV's mount/dispatch don't need
  # to be reshuffled in this pass.
  def subscribe(%Context{} = ctx, %State{selected_document_id: doc_id} = state)
      when is_binary(doc_id) do
    _ = Runtime.subscribe(ctx, doc_id)
    _ = subscribe_agent(ctx, state.agent_run_id)
    :ok
  end

  def subscribe(%Context{} = ctx, %State{} = state) do
    _ = subscribe_agent(ctx, state.agent_run_id)
    :ok
  end

  @doc """
  Subscribes the calling process to an agent run's PubSub topic. Used by
  the LV when it learns a new `agent_run_id` from a submitted command.

  No-op if `agent_run_id` is `nil`. Returns `:ok`.
  """
  @spec subscribe_agent(T.ctx(), T.agent_run_id() | nil) :: :ok
  def subscribe_agent(_ctx, nil), do: :ok

  def subscribe_agent(_ctx, agent_run_id) when is_binary(agent_run_id) do
    Phoenix.PubSub.subscribe(@pubsub, "agent:" <> agent_run_id)
    :ok
  end

  # ----------------------------------------------------------------------------
  # route_ref/3
  # ----------------------------------------------------------------------------

  @doc """
  Builds a signed, opaque `route_ref` token that authorizes an external
  client (Slack thread, MCP tool caller, deep link) to act on a specific
  document or chat thread without ever seeing a BEAM pid (SPEC.md §15
  invariant 2).

  Delegates to `Contract.Gateway.issue_route_ref/2`, which returns
  `{:ok, token}` on success and `{:error, reason}` otherwise.

  `document_or_thread` may be:

    * a `%Contract.Documents.Document{}` — the `:document_id` field is
      embedded.
    * a `%Contract.ChatThread{}` — the `:chat_thread_id` field is
      embedded (Document is left `nil` — useful for chat-only / pre-
      document RouteRefs).
    * a binary UUID — assumed to be a `document_id`.
    * `nil` — produces a scope-only token (no document attached).

  `opts` is forwarded to the Gateway. Common keys:

    * `:purpose` — string label, e.g. `"slack_thread"`, `"mcp"`,
      `"deep_link"`. Defaults to `"generic"`.
    * `:scopes` — list of permission strings/atoms.
    * `:ttl` — integer seconds. Defaults to the Gateway default.
    * `:agent_run_id` — embedded when an in-flight agent run is the
      authoritative actor for the link.
    * `:base_revision` — embedded so the receiver can detect drift.
  """
  @spec route_ref(T.ctx(), term(), keyword() | map()) ::
          T.result(T.route_ref_token())
  def route_ref(ctx, document_or_thread, opts \\ [])

  def route_ref(%Context{} = ctx, %Contract.Documents.Document{id: doc_id}, opts) do
    do_route_ref(ctx, %{document_id: doc_id}, opts)
  end

  def route_ref(%Context{} = ctx, %Contract.ChatThread{id: thread_id}, opts) do
    do_route_ref(ctx, %{chat_thread_id: thread_id}, opts)
  end

  def route_ref(%Context{} = ctx, document_id, opts) when is_binary(document_id) do
    do_route_ref(ctx, %{document_id: document_id}, opts)
  end

  def route_ref(%Context{} = ctx, nil, opts) do
    do_route_ref(ctx, %{}, opts)
  end

  defp do_route_ref(ctx, base_attrs, opts) when is_list(opts) do
    do_route_ref(ctx, base_attrs, Map.new(opts))
  end

  defp do_route_ref(ctx, base_attrs, opts) when is_map(opts) do
    attrs = Map.merge(opts, base_attrs)
    Gateway.issue_route_ref(ctx, attrs)
  end

  # ----------------------------------------------------------------------------
  # search_documents/2
  # ----------------------------------------------------------------------------

  @doc """
  Substring search across the scope's documents. Routes through
  `Contract.Documents.search/3`; the resulting rows are mapped to the
  shape the command palette expects.
  """
  @spec search_documents(T.ctx(), String.t()) :: [map()]
  def search_documents(_ctx, ""), do: []

  def search_documents(%Context{} = ctx, query) when is_binary(query) do
    ctx
    |> Contract.Documents.search(query, 20)
    |> Enum.map(fn doc ->
      %{
        id: doc.id,
        document_id: doc.id,
        title: doc.title,
        type_key: doc.type_key,
        last_revision: doc.latest_revision
      }
    end)
  end

  def search_documents(_ctx, _query), do: []

  # ----------------------------------------------------------------------------
  # list_documents/1 — for DocumentList sidebar
  # ----------------------------------------------------------------------------

  @doc """
  List recent documents visible to the scope. Returns the shape the
  Studio sidebar uses (`document_id, title, type_key, status,
  last_activity_at, last_revision`).
  """
  @spec list_documents(T.ctx()) :: [map()]
  def list_documents(%Context{} = ctx) do
    ctx
    |> Contract.Documents.list_recent_for_scope(limit: 50)
    |> Enum.map(&document_row/1)
  end

  def list_documents(_ctx), do: []

  defp document_row(doc) do
    %{
      document_id: doc.id,
      title: doc.title,
      type_key: doc.type_key,
      status: doc.status,
      last_activity_at: doc.updated_at,
      last_revision: doc.latest_revision
    }
  end

  # ----------------------------------------------------------------------------
  # helpers
  # ----------------------------------------------------------------------------

  defp read_param(params, [key | rest]) do
    case Map.get(params, key) do
      nil -> read_param(params, rest)
      "" -> read_param(params, rest)
      value -> value
    end
  end

  defp read_param(_params, []), do: nil

  # mode derivation: we look at the most recent change for the document.
  # If none, briefing. If the last change was an edit/revoke, editing.
  # If the most recent activity is a review-style action, reviewing.
  # No DB? Fall back to :briefing.
  #
  # SPEC.md §18: untyped documents (no `type_key`) start in `:briefing`
  # regardless of change history.
  defp derive_mode(document_id, projection)
       when is_binary(document_id) and is_map(projection) do
    case Map.get(projection, :type_key) do
      nil -> :briefing
      _typed -> derive_mode_from_history(document_id)
    end
  end

  defp derive_mode(document_id, _projection) when is_binary(document_id) do
    derive_mode_from_history(document_id)
  end

  defp derive_mode(_, _), do: :no_document

  defp derive_mode_from_history(document_id) do
    case Store.changes_since(document_id, 0) do
      {:ok, []} ->
        :briefing

      {:ok, changes} ->
        last = List.last(changes)
        command_kind = last && last.command_kind

        cond do
          command_kind in [
            "edit_document",
            "rename_document",
            "update_metadata",
            "set_contract_type",
            "add_mark",
            "update_mark",
            "agent_change"
          ] ->
            :editing

          command_kind in ["revoke_change", "resolve_revoke"] ->
            :reviewing

          true ->
            :editing
        end
    end
  rescue
    DBConnection.ConnectionError -> :briefing
    Postgrex.Error -> :briefing
  end

  defp empty_projection, do: Runtime.State.empty_projection()
end
