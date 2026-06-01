defmodule Contract.Runtime do
  @moduledoc """
  Routes `Contract.Command`s into the correct execution path
  (Store directly, Session, Agent).
  See SPEC.md §12.

  ## Routing table

      :create_document             → Store.append  (no Session needed)
      :open_document               → Runtime.load
      :rename_document             → ensure_session → Session.commit
      :update_metadata             → ensure_session → Session.commit
      :set_contract_type           → ensure_session → Session.commit
      :edit_document               → ensure_session → Session.commit
      :edit_text                   → ensure_session → Session.commit
      :doc_write                   → ensure_session → Session.commit
      :agent_change                → ensure_session → Session.commit
      :chat_message                → Contract.Agent.Document.start
  """

  alias Contract.ChatThreads
  alias Contract.Command
  alias Contract.Change
  alias Contract.Documents
  alias Contract.Documents.Document
  alias Contract.Runtime, as: Self
  alias Contract.Session
  alias Contract.Store
  alias Contract.Types, as: T

  @pubsub Contract.PubSub

  @session_kinds [
    :rename_document,
    :update_metadata,
    :set_contract_type,
    :edit_document,
    :edit_text,
    :doc_write,
    :agent_change
  ]

  @doc "Kinds routed through a per-document Session."
  @spec session_kinds() :: [atom()]
  def session_kinds, do: @session_kinds

  # ----------------------------------------------------------------------------
  # load / sync_since / subscribe
  # ----------------------------------------------------------------------------

  @spec load(T.ctx(), T.document_id()) :: T.result(Contract.Runtime.State.t())
  def load(ctx, document_id) do
    with :ok <- authorize_document(ctx, document_id) do
      Store.load(document_id)
    end
  end

  @spec sync_since(T.ctx(), T.document_id(), T.revision()) :: T.result([Change.t()])
  def sync_since(ctx, document_id, revision) do
    with :ok <- authorize_document(ctx, document_id) do
      Store.changes_since(document_id, revision)
    end
  end

  @spec subscribe(T.ctx(), T.document_id()) :: :ok | {:error, term()}
  def subscribe(ctx, document_id) do
    with :ok <- authorize_document(ctx, document_id) do
      Phoenix.PubSub.subscribe(@pubsub, Store.pubsub_topic(document_id))
    end
  end

  # ----------------------------------------------------------------------------
  # apply/2
  # ----------------------------------------------------------------------------

  @spec apply(T.ctx(), Command.t()) :: T.result(term())
  def apply(ctx, %Command{kind: :open_document} = action) do
    case action.document_id do
      nil -> {:error, :missing_document_id}
      doc_id -> Self.load(ctx, doc_id)
    end
  end

  def apply(ctx, %Command{kind: :create_document} = action) do
    create_document_directly(ctx, action)
  end

  def apply(ctx, %Command{kind: :chat_message} = action) do
    with {:ok, _thread, persisted_action, _message} <-
           ChatThreads.persist_user_message(ctx, action) do
      Contract.Agent.Document.start(ctx, persisted_action)
    end
  end

  def apply(ctx, %Command{kind: kind} = action) when kind in @session_kinds do
    with :ok <- authorize_document(ctx, action.document_id),
         {:ok, _pid} <- ensure_session(ctx, action.document_id) do
      Session.commit(action.document_id, action)
    end
  end

  def apply(_ctx, %Command{kind: kind}) do
    {:error, {:unsupported_action_kind, kind}}
  end

  # ----------------------------------------------------------------------------
  # ensure_session/2
  # ----------------------------------------------------------------------------

  @spec ensure_session(T.ctx(), T.document_id()) :: T.result(pid())
  def ensure_session(_ctx, nil), do: {:error, :missing_document_id}

  def ensure_session(_ctx, document_id) when is_binary(document_id) do
    case Session.whereis(document_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(
               Contract.Session.Supervisor,
               {Session, [document_id: document_id]}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:ok, pid, _info} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ----------------------------------------------------------------------------
  # internals
  # ----------------------------------------------------------------------------

  defp create_document_directly(ctx, %Command{} = action) do
    payload = normalize_payload(action.payload)

    attrs = %{
      "id" => action.document_id,
      "title" => Map.get(payload, "title") || Map.get(payload, :title) || "Untitled document",
      "type_key" => Map.get(payload, "type_key") || Map.get(payload, :type_key),
      "metadata" => Map.get(payload, "metadata") || Map.get(payload, :metadata) || %{}
    }

    with {:ok, %Document{} = doc} <- get_or_create_document(ctx, attrs) do
      document_id = doc.id
      action = %{action | document_id: document_id, base_revision: action.base_revision || 0}

      empty_state = %Contract.Runtime.State{document_id: document_id, revision: 0}

      with {:ok, %Contract.ChangeInput{} = input} <-
             Contract.Session.Reducer.compile(action, empty_state),
           {:ok, _} <- Contract.Session.Reducer.validate(input, empty_state),
           {:ok, preimage} <- Contract.Session.Reducer.preimage(input, empty_state),
           {:ok, inverse_ops} <- Contract.Session.Reducer.inverse(input, preimage),
           {:ok, affected_refs} <- Contract.Session.Reducer.affected_refs(input, empty_state),
           input = %Contract.ChangeInput{
             input
             | preimage: preimage,
               inverse_ops: inverse_ops,
               affected_refs: affected_refs
           },
           {:ok, change} <- Contract.Session.Reducer.build_change(action, input, empty_state) do
        # Create-document needs no lease since the document doesn't exist yet.
        # We use a synthetic fencing token of 0 + skip the lease assertion
        # path by acquiring a fresh lease first.
        with {:ok, lease} <- Contract.Lease.acquire(document_id, "system:create"),
             {:ok, persisted} <- Store.append(document_id, change, lease.fencing_token) do
          _ = Contract.Lease.release(document_id, "system:create", lease.fencing_token)
          {:ok, persisted}
        end
      end
    end
  end

  defp get_or_create_document(ctx, %{"id" => id} = attrs) when is_binary(id) do
    case Documents.get(ctx, id) do
      {:ok, %Document{} = doc} -> {:ok, doc}
      {:error, :not_found} -> Documents.create(ctx, attrs)
      {:error, _} = err -> err
    end
  end

  defp get_or_create_document(ctx, attrs), do: Documents.create(ctx, attrs)

  @doc false
  @spec authorize_document(T.ctx(), T.document_id() | nil) :: :ok | {:error, term()}
  def authorize_document(_ctx, nil), do: {:error, :missing_document_id}

  def authorize_document(ctx, document_id) when is_binary(document_id) do
    authorize_visible_document(ctx, document_id)
  end

  def authorize_document(_ctx, _document_id), do: {:error, :forbidden}

  defp authorize_visible_document(ctx, document_id) do
    case Documents.get(ctx, document_id) do
      {:ok, %Document{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_payload(nil), do: %{}
  defp normalize_payload(map) when is_map(map), do: map
  defp normalize_payload(_), do: %{}
end
