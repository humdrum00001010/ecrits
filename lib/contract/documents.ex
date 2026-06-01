defmodule Contract.Documents do
  @moduledoc """
  Context module for documents and field lineage.

  Every public function (except `touch_revision/2` and friends) takes a
  `%Contract.Context{}` as the first argument. The ACL gate is owner-based:
  the caller may only read/write documents whose `owner_id` matches
  `ctx.user.id` (SPEC.md v0.5 — Matter container removed).

  `touch_revision/2`, `set_title/2`, `set_type/2`, `set_status/2` are
  scope-less helpers called by `Contract.Store.append/3` on the hot
  commit path. The caller has already passed the lease + idempotency
  gate by then, so we trust the operation.
  """

  import Ecto.Query
  alias Contract.ChatThread
  alias Contract.Context
  alias Contract.Change
  alias Contract.ContractTypes
  alias Contract.Documents.Document
  alias Contract.Lease.Record, as: LeaseRecord
  alias Contract.Operation
  alias Contract.Packets.PacketDocument
  alias Contract.Repo
  alias Contract.RhwpSnapshot.Record, as: RhwpSnapshotRecord
  alias Contract.Snapshot
  alias Contract.Types, as: T

  # ----------------------------------------------------------------------------
  # list_recent_for_scope/2
  # ----------------------------------------------------------------------------

  @doc """
  List the most recent documents visible to the scope (i.e. owned by
  `ctx.user`).

  Accepts either a positive integer (legacy positional API) or a keyword
  list with `:limit`. The default limit is `20`.
  """
  @default_recent_limit 20

  @spec list_recent_for_scope(Context.t(), pos_integer() | keyword()) :: [Document.t()]
  def list_recent_for_scope(scope, opts_or_limit \\ [])

  def list_recent_for_scope(%Context{} = scope, limit)
      when is_integer(limit) and limit > 0 do
    do_list_recent_for_scope(scope, limit)
  end

  def list_recent_for_scope(%Context{} = scope, opts) when is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_recent_limit)
    do_list_recent_for_scope(scope, limit)
  end

  defp do_list_recent_for_scope(%Context{user: nil}, _limit), do: []

  defp do_list_recent_for_scope(%Context{user: %{id: user_id}}, limit)
       when is_integer(limit) and limit > 0 do
    from(d in Document,
      where: d.owner_id == ^user_id,
      order_by: [desc: d.updated_at],
      limit: ^limit
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  # ----------------------------------------------------------------------------
  # list_all_for_scope/2
  # ----------------------------------------------------------------------------

  @doc """
  List ALL documents visible to the scope (i.e. owned by `ctx.user`),
  ordered by `updated_at DESC`. Unlike `list_recent_for_scope/2`, no
  document is dropped for being old — the dashboard surface wants the
  full library, not a "recent" slice (2026-05-17 owner directive).

  Accepts an optional keyword list with `:limit`. Callers that pass no
  limit get the full set; UI surfaces without pagination must not silently
  drop older documents.
  """
  @spec list_all_for_scope(Context.t(), keyword()) :: [Document.t()]
  def list_all_for_scope(scope, opts \\ [])

  def list_all_for_scope(%Context{user: nil}, _opts), do: []

  def list_all_for_scope(%Context{user: %{id: user_id}}, opts) when is_list(opts) do
    query =
      from(d in Document,
        where: d.owner_id == ^user_id,
        order_by: [desc: d.updated_at]
      )

    query =
      case Keyword.get(opts, :limit) do
        limit when is_integer(limit) and limit > 0 -> limit(query, ^limit)
        _ -> query
      end

    query
    |> Repo.all()
  rescue
    _ -> []
  end

  # ----------------------------------------------------------------------------
  # get/2
  # ----------------------------------------------------------------------------

  @doc """
  Fetch a single document by id, gated by owner ACL.
  """
  @spec get(Context.t(), T.id()) ::
          {:ok, Document.t()} | {:error, :not_found | :forbidden}
  def get(%Context{} = scope, document_id) when is_binary(document_id) do
    case Repo.get(Document, document_id) do
      nil ->
        {:error, :not_found}

      %Document{} = doc ->
        case authorize_owner(scope, doc) do
          :ok -> {:ok, doc}
          err -> err
        end
    end
  rescue
    Ecto.Query.CastError -> {:error, :not_found}
  end

  def get(_scope, _document_id), do: {:error, :not_found}

  # ----------------------------------------------------------------------------
  # create/2
  # ----------------------------------------------------------------------------

  @doc """
  Create a document owned by `ctx.user`.

  `attrs` should include `:title`. `:owner_id` is derived from
  `ctx.user.id` and CANNOT be overridden by `attrs`. `:type_key` is
  optional per SPEC.md §18.

  v0.5: `:matter_id` in `attrs` is silently dropped — Matter is gone
  in v1.
  """
  @spec create(Context.t(), %{
          optional(:title) => binary,
          optional(:type_key) => binary | nil
        }) ::
          {:ok, Document.t()} | {:error, Ecto.Changeset.t() | :forbidden}
  def create(%Context{user: nil}, _attrs), do: {:error, :forbidden}

  def create(%Context{user: %{id: user_id}} = _scope, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.drop(["matter_id", "document_id"])
      |> Map.put("owner_id", user_id)
      |> put_document_type_attrs()

    document = document_with_optional_id(attrs)

    document
    |> Document.changeset(Map.drop(attrs, ["id"]))
    |> Repo.insert()
  end

  # ----------------------------------------------------------------------------
  # delete/2 / set_type/3
  # ----------------------------------------------------------------------------

  @doc """
  Delete a document and its document-scoped state. Owner-only.
  """
  @spec delete(Context.t(), T.id()) ::
          {:ok, Document.t()} | {:error, term()}
  def delete(%Context{} = scope, document_id) when is_binary(document_id) do
    with {:ok, {%Document{} = deleted, r2_keys}} <- delete_db(scope, document_id) do
      :ok = delete_r2_objects_async(r2_keys)
      {:ok, deleted}
    end
  end

  def delete(_scope, _document_id), do: {:error, :not_found}

  @doc false
  @spec delete_db(Context.t(), T.id()) ::
          {:ok, {Document.t(), [String.t()]}} | {:error, term()}
  def delete_db(%Context{} = scope, document_id) when is_binary(document_id) do
    with_document_lock(
      document_id,
      fn ->
        with {:ok, %Document{} = doc} <- get(scope, document_id) do
          r2_keys = document_r2_keys(doc)

          with {:ok, %Document{} = deleted} <- delete_document_rows(doc) do
            {:ok, {deleted, r2_keys}}
          end
        end
      end,
      isolation: :repeatable_read
    )
  end

  def delete_db(_scope, _document_id), do: {:error, :not_found}

  @doc false
  @spec delete_r2_objects_async([String.t()]) :: :ok
  def delete_r2_objects_async(keys) when is_list(keys), do: :ok

  defp document_r2_keys(%Document{id: document_id, metadata: metadata}) do
    snapshot_keys =
      from(s in Snapshot,
        where: s.document_id == ^document_id,
        select: s.r2_key
      )
      |> Repo.all()

    rhwp_snapshot_keys =
      from(r in RhwpSnapshotRecord,
        where: r.document_id == ^document_id,
        select: [r.r2_key, r.ir_r2_key]
      )
      |> Repo.all()
      |> List.flatten()

    [metadata_object_key(metadata) | snapshot_keys ++ rhwp_snapshot_keys]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp metadata_object_key(metadata) when is_map(metadata) do
    case read_key(metadata, :source) do
      source when is_map(source) -> read_key(source, :object_key)
      _ -> nil
    end
  end

  defp metadata_object_key(_metadata), do: nil

  defp delete_document_rows(%Document{id: document_id} = doc) do
    from(pd in PacketDocument, where: pd.document_id == ^document_id)
    |> Repo.delete_all()

    from(t in ChatThread, where: t.document_id == ^document_id)
    |> Repo.delete_all()

    from(l in LeaseRecord, where: l.document_id == ^document_id)
    |> Repo.delete_all()

    from(r in RhwpSnapshotRecord, where: r.document_id == ^document_id)
    |> Repo.delete_all()

    from(s in Snapshot, where: s.document_id == ^document_id)
    |> Repo.delete_all()

    from(c in Change, where: c.document_id == ^document_id)
    |> Repo.delete_all()

    case Repo.delete(doc) do
      {:ok, %Document{} = deleted} -> {:ok, deleted}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Mark body/contract-condition authoring as complete.

  This is not a signing or execution state. Completion freezes the document
  body at the current DB head and requires a committed native rhwp snapshot
  at that same revision so future readers can recover the exact HWP/HWPX
  checkpoint that was approved.
  """
  @spec complete_write(Context.t(), T.id()) ::
          {:ok, Document.t()} | {:error, term()}
  def complete_write(%Context{} = scope, document_id) do
    with_document_lock(document_id, fn ->
      with {:ok, %Document{} = doc} <- get(scope, document_id),
           :ok <- ensure_not_write_completed(doc),
           {:ok, head_revision} <- Contract.Store.latest_revision(document_id),
           :ok <- ensure_head_checkpoint(document_id, head_revision) do
        doc
        |> Ecto.Changeset.change(%{
          status: :write_completed,
          latest_revision: head_revision,
          write_completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          write_completed_by_id: scope.user.id,
          write_completed_revision: head_revision,
          write_completed_snapshot_revision: head_revision
        })
        |> Repo.update()
      end
    end)
  end

  @doc false
  @spec with_document_lock(T.id(), (-> {:ok, term()} | {:error, term()}), keyword()) ::
          {:ok, term()} | {:error, term()}
  def with_document_lock(document_id, fun, opts \\ [])
      when is_binary(document_id) and is_function(fun, 0) and is_list(opts) do
    set_repeatable_read? = Keyword.get(opts, :isolation) == :repeatable_read
    already_in_transaction? = Repo.in_transaction?()

    case Repo.transaction(fn ->
           if set_repeatable_read? and not already_in_transaction? do
             set_repeatable_read!()
           end

           :ok = take_advisory_lock!(document_id)

           case fun.() do
             {:ok, value} -> value
             {:error, reason} -> Repo.rollback(reason)
             other -> Repo.rollback({:bad_document_lock_return, other})
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns `:ok` unless the document is write-completed and the supplied
  change mutates body or contract-condition content, or the change attempts to
  replace an already-selected document type.

  Called from the Store append boundary so direct writers, LiveView, MCP, and
  agents all share the same freeze semantics.
  """
  @spec guard_body_mutation(T.id(), Change.t()) ::
          :ok | {:error, :write_completed | :document_type_already_set}
  def guard_body_mutation(document_id, %Change{} = change) when is_binary(document_id) do
    case Repo.get(Document, document_id) do
      %Document{} = doc ->
        cond do
          document_type_replacement?(doc, change) ->
            {:error, :document_type_already_set}

          write_completed?(doc) and body_mutation_change?(change) ->
            {:error, :write_completed}

          true ->
            :ok
        end

      _ ->
        :ok
    end
  rescue
    Ecto.Query.CastError -> :ok
  end

  def guard_body_mutation(_document_id, _change), do: :ok

  @doc "True when the document has passed body/condition authoring completion."
  @spec write_completed?(T.id() | Document.t() | nil) :: boolean()
  def write_completed?(%Document{status: :write_completed}), do: true
  def write_completed?(%Document{write_completed_at: %DateTime{}}), do: true
  def write_completed?(%Document{}), do: false
  def write_completed?(nil), do: false

  def write_completed?(document_id) when is_binary(document_id) do
    case Repo.get(Document, document_id) do
      %Document{} = doc -> write_completed?(doc)
      _ -> false
    end
  rescue
    Ecto.Query.CastError -> false
  end

  def write_completed?(_), do: false

  @doc """
  Select a document's `:type_key` exactly once.

  A non-nil `:type_key` is immutable after selection.
  """
  @spec set_type(Context.t(), T.id(), T.contract_type_key()) ::
          {:ok, Document.t()} | {:error, term()}
  def set_type(%Context{} = scope, document_id, type_key) when is_binary(type_key) do
    with {:ok, doc} <- get(scope, document_id) do
      cond do
        type_key_unset?(doc.type_key) ->
          doc
          |> Document.changeset(type_attrs(type_key))
          |> Repo.update()

        doc.type_key == type_key ->
          {:ok, doc}

        true ->
          {:error, :document_type_already_set}
      end
    end
  end

  # ----------------------------------------------------------------------------
  # set_title/2, set_type/2, set_status/2 (called by Store on propagation)
  # ----------------------------------------------------------------------------

  @doc """
  Set a document's `:title`. Called from `Contract.Store.append/3` on the
  hot commit path to mirror the engine's document-level `:set_attr` op
  onto the `documents` table. Not gated by scope.
  """
  @spec set_title(T.id(), String.t()) :: :ok
  def set_title(document_id, title) when is_binary(document_id) and is_binary(title) do
    from(d in Document,
      where: d.id == ^document_id,
      update: [set: [title: ^title, updated_at: ^now()]]
    )
    |> Repo.update_all([])

    :ok
  rescue
    _ -> :ok
  end

  def set_title(_, _), do: :ok

  @doc """
  Set a document's `:type_key` if it has not been selected yet. Scope-less
  variant used by `Contract.Store.append/3`.
  """
  @spec set_type(T.id(), String.t() | nil) :: :ok
  def set_type(document_id, type_key) when is_binary(document_id) do
    cast =
      cond do
        is_binary(type_key) -> type_key
        is_atom(type_key) and not is_nil(type_key) -> Atom.to_string(type_key)
        true -> nil
      end

    if is_binary(cast) and cast != "" do
      from(d in Document,
        where: d.id == ^document_id and is_nil(d.type_key),
        update: [
          set: [
            type_key: ^cast,
            document_type_id: ^document_type_id(cast),
            updated_at: ^now()
          ]
        ]
      )
      |> Repo.update_all([])
    end

    :ok
  rescue
    _ -> :ok
  end

  def set_type(_, _), do: :ok

  @doc """
  Set a document's `:status`. Scope-less variant used by
  `Contract.Store.append/3`.
  """
  @spec set_status(T.id(), atom() | String.t()) :: :ok
  def set_status(document_id, status) when is_binary(document_id) do
    cast =
      case status do
        s when is_atom(s) ->
          s

        s when is_binary(s) ->
          try do
            String.to_existing_atom(s)
          rescue
            ArgumentError -> nil
          end

        _ ->
          nil
      end

    if cast in [
         :draft,
         :importing,
         :editing,
         :reviewing,
         :write_completed,
         :export_ready
       ] do
      from(d in Document,
        where: d.id == ^document_id,
        update: [set: [status: ^cast, updated_at: ^now()]]
      )
      |> Repo.update_all([])
    end

    :ok
  rescue
    _ -> :ok
  end

  def set_status(_, _), do: :ok

  # ----------------------------------------------------------------------------
  # touch_revision/2 (called by Store)
  # ----------------------------------------------------------------------------

  @doc """
  Bump a document's `latest_revision` to `revision` IFF the supplied
  value is strictly greater than the stored one. Idempotent.
  """
  @spec touch_revision(T.id(), T.revision()) :: :ok
  def touch_revision(document_id, revision)
      when is_binary(document_id) and is_integer(revision) and revision >= 0 do
    from(d in Document,
      where: d.id == ^document_id and d.latest_revision < ^revision,
      update: [set: [latest_revision: ^revision, updated_at: ^now()]]
    )
    |> Repo.update_all([])

    :ok
  rescue
    _ -> :ok
  end

  def touch_revision(_, _), do: :ok

  defp take_advisory_lock!(document_id) do
    {:ok, _} = Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [document_id])
    :ok
  end

  defp set_repeatable_read! do
    unless Repo.config()[:pool] == Ecto.Adapters.SQL.Sandbox do
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ", [])
    end

    :ok
  end

  defp ensure_not_write_completed(%Document{} = doc) do
    if write_completed?(doc), do: {:error, :write_completed}, else: :ok
  end

  defp type_key_unset?(value), do: is_nil(value) or value == ""

  defp document_type_replacement?(%Document{type_key: current}, %Change{} = change)
       when is_binary(current) and current != "" do
    change
    |> document_type_set_values()
    |> Enum.any?(&(is_binary(&1) and &1 != "" and &1 != current))
  end

  defp document_type_replacement?(_doc, _change), do: false

  defp document_type_set_values(%Change{payload: ops}) when is_list(ops) do
    Enum.flat_map(ops, &document_type_set_value/1)
  end

  defp document_type_set_values(_change), do: []

  defp document_type_set_value(%Operation{} = op) do
    document_type_set_value?(op.op, op.target_type, op.args || %{})
  end

  defp document_type_set_value(op) when is_map(op) do
    document_type_set_value?(
      read_key(op, :op),
      read_key(op, :target_type),
      read_key(op, :args) || %{}
    )
  end

  defp document_type_set_value(_op), do: []

  defp document_type_set_value?(op, target_type, args) when is_map(args) do
    if atom_or_string(op) == "set_attr" and atom_or_string(target_type) == "document" and
         atom_or_string(read_key(args, :key)) == "type_key" do
      [read_key(args, :value)]
    else
      []
    end
  end

  defp document_type_set_value?(_op, _target_type, _args), do: []

  defp ensure_head_checkpoint(document_id, revision) do
    if Contract.RhwpSnapshot.committed_for_revision?(document_id, revision) do
      :ok
    else
      {:error, :checkpoint_required}
    end
  end

  @body_command_kinds ~w(edit_document edit_text set_contract_type agent_change update_metadata)
  @body_op_kinds ~w(insert_text delete_text insert_paragraph merge_paragraph
                    table_row_insert table_row_delete table_column_insert
                    table_column_delete table_delete set_field create_node
                    delete_node move_node replace_content bind_ref unbind_ref
                    create_projection)
  @body_document_attr_keys ~w(type_key node_order metadata)

  defp body_mutation_change?(%Change{command_kind: kind, payload: ops}) do
    atom_or_string(kind) in @body_command_kinds or
      (is_list(ops) and Enum.any?(ops, &body_mutation_op?/1))
  end

  defp body_mutation_change?(_change), do: false

  defp body_mutation_op?(%Operation{} = op) do
    body_mutation_op?(%{
      "op" => op.op,
      "target_type" => op.target_type,
      "args" => op.args || %{}
    })
  end

  defp body_mutation_op?(op) when is_map(op) do
    op_kind = op |> read_key(:op) |> atom_or_string()
    target_type = op |> read_key(:target_type) |> atom_or_string()
    args = read_key(op, :args) || %{}
    attr_key = args |> read_key(:key) |> atom_or_string()

    op_kind in @body_op_kinds or target_type in ["node", "field", "projection"] or
      (target_type == "document" and attr_key in @body_document_attr_keys)
  end

  defp body_mutation_op?(_op), do: false

  defp read_key(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp atom_or_string(value) when is_atom(value), do: Atom.to_string(value)
  defp atom_or_string(value) when is_binary(value), do: value
  defp atom_or_string(_), do: nil

  defp put_document_type_attrs(%{"type_key" => type_key} = attrs) do
    Map.merge(attrs, type_attrs(type_key))
  end

  defp put_document_type_attrs(attrs), do: attrs

  defp type_attrs(type_key) when is_binary(type_key) and type_key != "" do
    %{"type_key" => type_key, "document_type_id" => document_type_id(type_key)}
  end

  defp type_attrs(_type_key), do: %{"type_key" => nil, "document_type_id" => nil}

  defp document_type_id(nil), do: nil
  defp document_type_id(""), do: nil

  defp document_type_id(type_key) when is_binary(type_key) do
    case ContractTypes.document_type_id_for_key(type_key) do
      {:ok, id} -> id
      {:error, _reason} -> nil
    end
  end

  # ----------------------------------------------------------------------------
  # search/2 — substring title search for the command palette
  # ----------------------------------------------------------------------------

  @doc """
  Search documents by case-insensitive title substring within the scope.
  Returns at most `limit` rows (default 20).
  """
  @spec search(Context.t(), String.t(), pos_integer()) :: [Document.t()]
  def search(scope, query, limit \\ 20)

  def search(%Context{user: nil}, _query, _limit), do: []

  def search(%Context{user: %{id: user_id}}, query, limit)
      when is_binary(query) and is_integer(limit) and limit > 0 do
    pattern = "%" <> String.downcase(query) <> "%"

    from(d in Document,
      where: d.owner_id == ^user_id,
      where: fragment("lower(?) LIKE ?", d.title, ^pattern),
      order_by: [desc: d.updated_at],
      limit: ^limit
    )
    |> Repo.all()
  rescue
    _ -> []
  end

  def search(_scope, _query, _limit), do: []

  # ----------------------------------------------------------------------------
  # internals
  # ----------------------------------------------------------------------------

  # Owner-based ACL. Legacy ownerless rows are not globally visible.
  defp authorize_owner(_scope, %Document{owner_id: nil}), do: {:error, :forbidden}

  defp authorize_owner(%Context{user: %{id: user_id}}, %Document{owner_id: owner_id})
       when owner_id == user_id,
       do: :ok

  defp authorize_owner(_scope, _doc), do: {:error, :forbidden}

  defp document_with_optional_id(%{"id" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> %Document{id: uuid}
      :error -> %Document{}
    end
  end

  defp document_with_optional_id(_attrs), do: %Document{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp now do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_naive()
  end
end
