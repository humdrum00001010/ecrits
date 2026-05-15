defmodule Contract.Runtime do
  @moduledoc """
  Routes `Contract.Action`s into the correct execution path
  (Engine/Store directly, Session, Agent, IO import/export, Conversion).
  See SPEC.md §12.

  ## Routing table

      :create_document             → Engine + Store.append  (no Session needed)
      :upload_document             → Contract.IO.import_upload (returns Action,
                                                                recurse)
      :open_document               → Runtime.load
      :rename_document             → ensure_session → Session.commit
      :update_metadata             → ensure_session → Session.commit
      :set_contract_type           → ensure_session → Session.commit
      :edit_document               → ensure_session → Session.commit
      :add_mark                    → ensure_session → Session.commit
      :update_mark                 → ensure_session → Session.commit
      :archive_document            → ensure_session → Session.commit
      :restore_document            → ensure_session → Session.commit
      :duplicate_document          → ensure_session → Session.commit
      :agent_change                → ensure_session → Session.commit
      :chat_message                → Contract.Agent.start
      :start_type_conversion       → Contract.Conversion.plan/4
      :set_field_migration_strategy→ Contract.Conversion.set_field_strategy/4
      :create_converted_variant    → Contract.Conversion.create_variant/2
      :revoke_change               → ensure_session → Session.revoke
      :resolve_revoke              → ensure_session → Session.revoke
      :request_export              → Contract.IO.export
  """

  alias Contract.Action
  alias Contract.Change
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
    :add_mark,
    :update_mark,
    :archive_document,
    :restore_document,
    :duplicate_document,
    :agent_change
  ]

  @revoke_kinds [:revoke_change, :resolve_revoke]

  @conversion_kinds [
    :start_type_conversion,
    :set_field_migration_strategy,
    :create_converted_variant
  ]

  @doc "Kinds routed through a per-document Session."
  @spec session_kinds() :: [atom()]
  def session_kinds, do: @session_kinds

  @doc "Kinds routed through Session.revoke/2."
  @spec revoke_kinds() :: [atom()]
  def revoke_kinds, do: @revoke_kinds

  @doc "Kinds owned by Contract.Conversion (SPEC.md §19)."
  @spec conversion_kinds() :: [atom()]
  def conversion_kinds, do: @conversion_kinds

  # ----------------------------------------------------------------------------
  # load / sync_since / subscribe
  # ----------------------------------------------------------------------------

  @spec load(T.ctx(), T.document_id()) :: T.result(Contract.Runtime.State.t())
  def load(_ctx, document_id), do: Store.load(document_id)

  @spec sync_since(T.ctx(), T.document_id(), T.revision()) :: T.result([Change.t()])
  def sync_since(_ctx, document_id, revision) do
    Store.changes_since(document_id, revision)
  end

  @spec subscribe(T.ctx(), T.document_id()) :: :ok
  def subscribe(_ctx, document_id) do
    Phoenix.PubSub.subscribe(@pubsub, Store.pubsub_topic(document_id))
  end

  # ----------------------------------------------------------------------------
  # apply/2
  # ----------------------------------------------------------------------------

  @spec apply(T.ctx(), Action.t()) :: T.result(term())
  def apply(ctx, %Action{kind: :open_document} = action) do
    case action.document_id do
      nil -> {:error, :missing_document_id}
      doc_id -> Self.load(ctx, doc_id)
    end
  end

  def apply(ctx, %Action{kind: :create_document} = action) do
    create_document_directly(ctx, action)
  end

  def apply(ctx, %Action{kind: :upload_document} = action) do
    import_via_io(ctx, action)
  end

  def apply(ctx, %Action{kind: :chat_message} = action) do
    Contract.Agent.start(ctx, action)
  end

  def apply(ctx, %Action{kind: :request_export} = action) do
    format = export_format(action)
    Contract.IO.export(ctx, action.document_id, format, [])
  end

  def apply(ctx, %Action{kind: :start_type_conversion} = action) do
    payload = normalize_payload(action.payload)
    target_type_key = Map.get(payload, "target_type_key") || Map.get(payload, :target_type_key)

    cond do
      is_nil(action.document_id) -> {:error, :missing_document_id}
      is_nil(target_type_key) -> {:error, :missing_target_type_key}
      true -> Contract.Conversion.plan(ctx, action.document_id, target_type_key, [])
    end
  end

  def apply(ctx, %Action{kind: :set_field_migration_strategy} = action) do
    payload = normalize_payload(action.payload)
    plan = Map.get(payload, "plan") || Map.get(payload, :plan)
    field_id = Map.get(payload, "source_field_id") || Map.get(payload, :source_field_id)
    strategy = Map.get(payload, "strategy") || Map.get(payload, :strategy)

    cond do
      not match?(%Contract.Conversion.Plan{}, plan) ->
        {:error, :missing_plan}

      is_nil(field_id) ->
        {:error, :missing_field_id}

      is_nil(strategy) ->
        {:error, :missing_strategy}

      true ->
        Contract.Conversion.set_field_strategy(ctx, plan, to_string(field_id), strategy)
    end
  end

  def apply(ctx, %Action{kind: :create_converted_variant} = action) do
    payload = normalize_payload(action.payload)
    plan = Map.get(payload, "plan") || Map.get(payload, :plan)

    cond do
      match?(%Contract.Conversion.Plan{}, plan) ->
        Contract.Conversion.create_variant(ctx, plan)

      true ->
        {:error, :missing_plan}
    end
  end

  def apply(ctx, %Action{kind: kind} = action) when kind in @session_kinds do
    with {:ok, _pid} <- ensure_session(ctx, action.document_id) do
      Session.commit(action.document_id, action)
    end
  end

  def apply(ctx, %Action{kind: kind} = action) when kind in @revoke_kinds do
    Self.revoke(ctx, action)
  end

  def apply(_ctx, %Action{kind: kind}) do
    {:error, {:unsupported_action_kind, kind}}
  end

  # ----------------------------------------------------------------------------
  # revoke/2
  # ----------------------------------------------------------------------------

  @spec revoke(T.ctx(), Action.t()) :: T.result(term())
  def revoke(ctx, %Action{kind: kind} = action) when kind in @revoke_kinds do
    case action.document_id do
      nil ->
        {:error, :missing_document_id}

      doc_id ->
        with {:ok, _pid} <- ensure_session(ctx, doc_id) do
          Session.revoke(doc_id, action)
        end
    end
  end

  def revoke(_ctx, %Action{kind: kind}),
    do: {:error, {:not_a_revoke, kind}}

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

  defp create_document_directly(_ctx, %Action{} = action) do
    document_id = action.document_id || Ecto.UUID.generate()
    action = %{action | document_id: document_id, base_revision: action.base_revision || 0}

    empty_state = %Contract.Runtime.State{document_id: document_id, revision: 0}

    with {:ok, %Contract.ChangeInput{} = input} <- Contract.Engine.compile(action, empty_state),
         {:ok, _} <- Contract.Engine.validate(input, empty_state),
         {:ok, preimage} <- Contract.Engine.preimage(input, empty_state),
         {:ok, inverse_ops} <- Contract.Engine.inverse(input, preimage),
         {:ok, affected_refs} <- Contract.Engine.affected_refs(input, empty_state),
         input = %Contract.ChangeInput{
           input
           | preimage: preimage,
             inverse_ops: inverse_ops,
             affected_refs: affected_refs
         },
         {:ok, change} <- Contract.Engine.build_change(action, input, empty_state) do
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

  defp import_via_io(ctx, %Action{} = action) do
    upload = Map.get(action.payload, "upload") || Map.get(action.payload, :upload)
    matter_id = action.matter_id

    case Contract.IO.import_upload(ctx, matter_id, upload) do
      {:ok, %Action{} = next_action} -> Self.apply(ctx, next_action)
      {:error, _} = err -> err
    end
  end

  defp export_format(%Action{payload: payload}) do
    case payload do
      %{"format" => fmt} when is_binary(fmt) -> String.to_atom(fmt)
      %{format: fmt} when is_atom(fmt) -> fmt
      %{format: fmt} when is_binary(fmt) -> String.to_atom(fmt)
      _ -> :pdf
    end
  end

  defp normalize_payload(nil), do: %{}
  defp normalize_payload(map) when is_map(map), do: map
  defp normalize_payload(_), do: %{}
end
