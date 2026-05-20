defmodule Contract.Runtime do
  @moduledoc """
  Routes `Contract.Command`s into the correct execution path
  (Store directly, Session, Agent, source import, export, Conversion).
  See SPEC.md §12.

  ## Routing table

      :create_document             → Store.append  (no Session needed)
      :upload_document             → Contract.SourceDocuments.create_from_upload
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
      :request_export              → Contract.Exports + ExportJob
  """

  alias Contract.ChatThreads
  alias Contract.Command
  alias Contract.Change
  alias Contract.Documents
  alias Contract.Exports
  alias Contract.Documents.Document
  alias Contract.RouteRef
  alias Contract.SourceClaims
  alias Contract.SourceDocuments
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
    :add_mark,
    :update_mark,
    :archive_document,
    :restore_document,
    :duplicate_document,
    :agent_change
  ]

  @revoke_kinds [:revoke_change, :resolve_revoke]

  @source_claim_kinds [
    :source_claim_confirm,
    :source_claim_correct,
    :source_claim_reject,
    :source_claim_link_to_document,
    :source_claim_unlink_from_document
  ]
  @export_formats [:pdf, :docx, :hwpx, :markdown, :lawyer_packet]

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

  def apply(ctx, %Command{kind: :upload_document} = action) do
    import_via_io(ctx, action)
  end

  def apply(ctx, %Command{kind: :chat_message} = action) do
    with {:ok, _thread, persisted_action, _message} <-
           ChatThreads.persist_user_message(ctx, action) do
      Contract.Agent.start(ctx, persisted_action)
    end
  end

  def apply(ctx, %Command{kind: kind} = action) when kind in @source_claim_kinds do
    SourceClaims.apply_command(ctx, action)
  end

  def apply(ctx, %Command{kind: :request_export} = action) do
    cond do
      is_nil(action.document_id) ->
        {:error, :missing_document_id}

      true ->
        with :ok <- authorize_document(ctx, action.document_id),
             {:ok, format} <- export_format(action),
             {:ok, export} <-
               Exports.create_request(ctx, action.document_id, format, action.actor_id) do
          args = %{
            "export_id" => export.id,
            "document_id" => action.document_id,
            "format" => Atom.to_string(format),
            "requester_id" => action.actor_id
          }

          args
          |> Contract.Workers.ExportJob.new()
          |> Oban.insert()
        end
    end
  end

  def apply(ctx, %Command{kind: :start_type_conversion} = action) do
    payload = normalize_payload(action.payload)
    target_type_key = Map.get(payload, "target_type_key") || Map.get(payload, :target_type_key)

    cond do
      is_nil(action.document_id) -> {:error, :missing_document_id}
      is_nil(target_type_key) -> {:error, :missing_target_type_key}
      true -> Contract.Conversion.plan(ctx, action.document_id, target_type_key, [])
    end
  end

  def apply(ctx, %Command{kind: :set_field_migration_strategy} = action) do
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

  def apply(ctx, %Command{kind: :create_converted_variant} = action) do
    payload = normalize_payload(action.payload)
    plan = Map.get(payload, "plan") || Map.get(payload, :plan)

    cond do
      match?(%Contract.Conversion.Plan{}, plan) ->
        Contract.Conversion.create_variant(ctx, plan)

      true ->
        {:error, :missing_plan}
    end
  end

  def apply(ctx, %Command{kind: kind} = action) when kind in @session_kinds do
    with :ok <- authorize_document(ctx, action.document_id),
         {:ok, _pid} <- ensure_session(ctx, action.document_id) do
      Session.commit(action.document_id, action)
    end
  end

  def apply(ctx, %Command{kind: kind} = action) when kind in @revoke_kinds do
    Self.revoke(ctx, action)
  end

  def apply(_ctx, %Command{kind: kind}) do
    {:error, {:unsupported_action_kind, kind}}
  end

  # ----------------------------------------------------------------------------
  # revoke/2
  # ----------------------------------------------------------------------------

  @spec revoke(T.ctx(), Command.t()) :: T.result(term())
  def revoke(ctx, %Command{kind: kind} = action) when kind in @revoke_kinds do
    case action.document_id do
      nil ->
        {:error, :missing_document_id}

      doc_id ->
        with :ok <- authorize_document(ctx, doc_id),
             {:ok, _pid} <- ensure_session(ctx, doc_id) do
          Session.revoke(doc_id, action)
        end
    end
  end

  def revoke(_ctx, %Command{kind: kind}),
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

  defp import_via_io(ctx, %Command{} = action) do
    payload = normalize_payload(action.payload)
    upload = Map.get(payload, "upload") || Map.get(payload, :upload)

    opts =
      []
      |> maybe_put_opt(:document_id, action.document_id)
      |> maybe_put_opt(:chat_thread_id, action.chat_thread_id)

    SourceDocuments.create_from_upload(ctx, upload, opts)
  end

  @doc false
  @spec authorize_document(T.ctx(), T.document_id() | nil) :: :ok | {:error, term()}
  def authorize_document(_ctx, nil), do: {:error, :missing_document_id}

  def authorize_document(ctx, document_id) when is_binary(document_id) do
    case route_ref(ctx) do
      %RouteRef{document_id: ^document_id} ->
        authorize_visible_document(ctx, document_id)

      %RouteRef{document_id: nil} ->
        {:error, :forbidden}

      %RouteRef{} ->
        {:error, :forbidden}

      _ ->
        authorize_visible_document(ctx, document_id)
    end
  end

  def authorize_document(_ctx, _document_id), do: {:error, :forbidden}

  defp authorize_visible_document(ctx, document_id) do
    case Documents.get(ctx, document_id) do
      {:ok, %Document{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp route_ref(%Contract.Context{perms: %{route_ref: %RouteRef{} = ref}}), do: ref
  defp route_ref(_ctx), do: nil

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp export_format(%Command{payload: payload}) do
    format =
      case payload do
        %{"format" => fmt} -> fmt
        %{format: fmt} -> fmt
        _ -> :pdf
      end

    parse_export_format(format)
  end

  defp parse_export_format(format) when format in @export_formats, do: {:ok, format}

  defp parse_export_format(format) when is_binary(format) do
    case format do
      "pdf" -> {:ok, :pdf}
      "docx" -> {:ok, :docx}
      "hwpx" -> {:ok, :hwpx}
      "markdown" -> {:ok, :markdown}
      "md" -> {:ok, :markdown}
      "lawyer_packet" -> {:ok, :lawyer_packet}
      _ -> {:error, {:unsupported_export_format, format}}
    end
  end

  defp parse_export_format(format), do: {:error, {:unsupported_export_format, format}}

  defp normalize_payload(nil), do: %{}
  defp normalize_payload(map) when is_map(map), do: map
  defp normalize_payload(_), do: %{}
end
