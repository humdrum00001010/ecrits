defmodule Contract.Studio do
  @moduledoc """
  Product façade for the one big LiveView. Orchestrates load, select, submit,
  sync, subscribe. See SPEC.md §8.

  Studio is the thin product seam between `ContractWeb.StudioLive` and
  `Contract.Runtime`. It does **not** own document truth — `Store` is truth.
  It only:

    * shapes a `%Contract.Studio.State{}` for the LV to render against;
    * routes UI-level intents (load, select, submit, sync) through the
      `Runtime`;
    * subscribes the calling process to the right PubSub topics so
      `handle_info/2` in the LV receives the §11 protocol messages.
  """

  alias Contract.Action
  alias Contract.Change
  alias Contract.Context
  alias Contract.Runtime
  alias Contract.Store
  alias Contract.Studio.State
  alias Contract.Types, as: T

  @pubsub Contract.PubSub

  # ----------------------------------------------------------------------------
  # load/2
  # ----------------------------------------------------------------------------

  @doc """
  Hydrates a `%Studio.State{}` for the calling LiveView from the routing
  params + scope. Accepts either string-keyed (Phoenix params) or atom-keyed
  maps; the optional keys recognised are `"matter_id"` and `"document_id"`.

  When a `document_id` is present, the call also primes `Runtime.load/2`
  and stamps `last_seen_revision` from the loaded projection. The
  `Runtime.State.projection` itself is returned through the second tuple
  slot so the LV can `assign(:projection, ...)` directly without a
  second round-trip.
  """
  @spec load(T.ctx(), T.params() | map()) :: T.result({State.t(), map()})
  def load(%Context{} = ctx, params) when is_map(params) do
    matter_id = read_param(params, [:matter_id, "matter_id"])
    document_id = read_param(params, [:document_id, "document_id"])

    case do_load(ctx, matter_id, document_id) do
      {:ok, state, projection, revision} ->
        {:ok,
         {%State{
            state
            | last_seen_revision: revision
          }, projection}}

      {:error, _} = err ->
        err
    end
  end

  def load(_ctx, _params), do: {:error, :invalid_params}

  defp do_load(_ctx, matter_id, nil) do
    state = %State{
      matter_id: matter_id,
      selected_document_id: nil,
      mode: :no_document,
      last_seen_revision: 0
    }

    {:ok, state, empty_projection(), 0}
  end

  defp do_load(ctx, matter_id, document_id) do
    case Runtime.load(ctx, document_id) do
      {:ok, %Runtime.State{revision: rev, projection: proj}} ->
        state = %State{
          matter_id: matter_id,
          selected_document_id: document_id,
          mode: derive_mode(document_id, proj),
          last_seen_revision: rev
        }

        {:ok, state, proj, rev}

      {:error, _} = err ->
        err
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
  # submit/3
  # ----------------------------------------------------------------------------

  @doc """
  Submits an Action. Routes through `Runtime.apply/2` (or `Runtime.revoke/2`
  for revoke kinds). On success, optionally advances `agent_run_id` if the
  action was a `:chat_message` that returned an agent run.

  The LV doesn't mutate the projection from here — `Store.append/3`
  broadcasts `{:change_committed, change}` which `handle_info/2` consumes.
  """
  @spec submit(T.ctx(), State.t(), Action.t()) :: T.result(State.t())
  def submit(%Context{} = ctx, %State{} = state, %Action{} = action) do
    case Runtime.apply(ctx, action) do
      {:ok, %Change{}} ->
        {:ok, state}

      {:ok, %{agent_run_id: agent_run_id} = _agent} when is_binary(agent_run_id) ->
        {:ok, %State{state | agent_run_id: agent_run_id}}

      {:ok, _other} ->
        {:ok, state}

      {:error, _} = err ->
        err
    end
  end

  # ----------------------------------------------------------------------------
  # sync/3
  # ----------------------------------------------------------------------------

  @doc """
  Replays missed changes from `revision` to current head. The caller is
  expected to fold the returned changes into its projection (or simply
  call `reload/2` if it doesn't track op-by-op).
  """
  @spec sync(T.ctx(), State.t(), T.revision()) :: T.result({State.t(), [Change.t()]})
  def sync(_ctx, %State{selected_document_id: nil} = state, _from_revision) do
    {:ok, {state, []}}
  end

  def sync(%Context{} = ctx, %State{selected_document_id: doc_id} = state, from_revision)
      when is_integer(from_revision) and from_revision >= 0 do
    case Runtime.sync_since(ctx, doc_id, from_revision) do
      {:ok, changes} ->
        new_rev =
          changes
          |> Enum.map(& &1.applied_revision)
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
  Subscribes the calling process to the PubSub topics relevant to this
  Studio session.

    * `document:<id>` — when a document is selected, picks up
      `{:change_committed, change}` and friends per SPEC.md §11.
    * `agent:<run_id>` — only when an agent run is in flight; picks up
      `{:agent_stream, ...}` etc.
  """
  @spec subscribe(T.ctx(), State.t()) :: :ok
  def subscribe(_ctx, %State{selected_document_id: nil, agent_run_id: nil}) do
    :ok
  end

  def subscribe(ctx, %State{selected_document_id: doc_id} = state)
      when is_binary(doc_id) do
    _ = Runtime.subscribe(ctx, doc_id)
    maybe_subscribe_agent(state)
    :ok
  end

  def subscribe(_ctx, %State{} = state) do
    maybe_subscribe_agent(state)
    :ok
  end

  defp maybe_subscribe_agent(%State{agent_run_id: nil}), do: :ok

  defp maybe_subscribe_agent(%State{agent_run_id: id}) when is_binary(id) do
    Phoenix.PubSub.subscribe(@pubsub, "agent:" <> id)
    :ok
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
        matter_id: doc.matter_id,
        last_revision: doc.latest_revision
      }
    end)
  end

  def search_documents(_ctx, _query), do: []

  # ----------------------------------------------------------------------------
  # list_documents/2 — for DocumentList sidebar
  # ----------------------------------------------------------------------------

  @doc """
  List documents for a matter, gated by ACL. Returns the shape the
  Studio sidebar uses (`document_id, title, type_key, status,
  last_activity_at, last_revision`).
  """
  @spec list_documents(T.ctx(), T.id() | nil) :: [map()]
  def list_documents(%Context{} = ctx, matter_id) when is_binary(matter_id) do
    ctx
    |> Contract.Documents.list_for_matter(matter_id)
    |> Enum.map(&document_row/1)
  end

  def list_documents(_ctx, _matter_id), do: []

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
  # regardless of change history — the agent's first job is to
  # understand the document well enough to suggest a contract type.
  # Once `Action(:set_contract_type)` has filled the key in, the normal
  # change-history rules take over.
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
        action_kind = last && last.action_kind

        cond do
          action_kind in [
            "edit_document",
            "rename_document",
            "update_metadata",
            "set_contract_type",
            "add_mark",
            "update_mark",
            "agent_change"
          ] ->
            :editing

          action_kind in ["revoke_change", "resolve_revoke"] ->
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
