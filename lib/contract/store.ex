defmodule Contract.Store do
  @moduledoc """
  Durable truth. Commit order lives here — not in LiveView, not in Agent,
  not in Session alone. See SPEC.md §16.

  ## Append flow

  `append/3` is the only mutation entrypoint. It:

    1. Opens a `Repo.transaction/1`.
    2. Acquires a Postgres advisory lock keyed by the document id so
       concurrent writers to the same document serialize behind the same
       in-database mutex.
    3. Calls `Contract.Lease.assert_current!/2` to verify the supplied
       fencing token still matches the live lease — old sessions whose
       leases have been taken over fail here.
    4. Idempotency check: if a Change with the same `(document_id,
       idempotency_key)` already exists, the existing row is returned
       unchanged. This is the §15.6 replay-safe path.
    5. Revision check: `change.base_revision` must equal the current
       `latest_revision/1` — otherwise `{:error, {:revision_conflict, ...}}`.
    6. Bumps `change.applied_revision` to `latest + 1` and inserts.
    7. **After** the transaction commits, broadcasts
       `{:change_committed, change}` on the document's PubSub topic.
       Broadcast happens post-commit on purpose — clients must never see
       a notification without a corresponding durable row.

  ## Load flow

  `load/1` fetches the most recent `Contract.Snapshot` row (if any),
  reconstructs the `Runtime.State` from it, then folds every change
  whose `applied_revision > snapshot.revision` through `Engine.apply/2`.

  An empty document (no snapshot, no changes) loads as an empty
  `Runtime.State` at `revision: 0`.
  """

  import Ecto.Query, only: [from: 2]

  alias Contract.Change
  alias Contract.ChangeInput
  alias Contract.Engine
  alias Contract.Lease
  alias Contract.Operation
  alias Contract.Repo
  alias Contract.Runtime
  alias Contract.Snapshot
  alias Contract.Types, as: T

  @pubsub Contract.PubSub

  defp r2_driver do
    Application.get_env(:contract, :io_drivers, [])
    |> Keyword.get(:r2, Contract.IO.R2)
  end

  # ----------------------------------------------------------------------------
  # load/1
  # ----------------------------------------------------------------------------

  @spec load(T.document_id()) :: T.result(Runtime.State.t())
  def load(document_id) do
    base =
      case latest_snapshot(document_id) do
        nil ->
          %Runtime.State{document_id: document_id, revision: 0}

        %Snapshot{revision: rev, projection: proj} ->
          %Runtime.State{
            document_id: document_id,
            revision: rev,
            projection: decode_projection(proj)
          }
      end

    {:ok, changes} = changes_since(document_id, base.revision)

    state =
      Enum.reduce(changes, base, fn change, acc ->
        input = change_to_input(change)
        {:ok, new_state} = Engine.apply(input, acc)
        new_state
      end)

    {:ok, state}
  end

  defp latest_snapshot(document_id) do
    from(s in Snapshot,
      where: s.document_id == ^document_id,
      order_by: [desc: s.revision],
      limit: 1
    )
    |> Repo.one()
  end

  # ----------------------------------------------------------------------------
  # snapshot/2
  # ----------------------------------------------------------------------------

  @doc """
  Materialize the current `Runtime.State` at `revision` as a durable
  snapshot. Writes both the Postgres `snapshots` row and a JSON copy in
  R2 under `documents/<id>/snapshots/<revision>.json`. Both must succeed —
  the R2 put happens inside the Repo transaction so that an R2 failure
  rolls back the DB row.

  The returned `Runtime.State` is the same projection that was persisted.
  """
  @spec snapshot(T.document_id(), T.revision()) :: T.result(Runtime.State.t())
  def snapshot(document_id, revision) do
    {:ok, %Runtime.State{} = state} = load(document_id)

    if state.revision != revision do
      {:error, {:snapshot_revision_mismatch, expected: revision, got: state.revision}}
    else
      r2_key = "documents/#{document_id}/snapshots/#{revision}.json"
      projection_json = Jason.encode!(state.projection)

      result =
        transaction(fn ->
          with {:ok, _} <-
                 r2_driver().put(r2_key, projection_json, content_type: "application/json"),
               {:ok, _snap} <- insert_snapshot(document_id, revision, state.projection, r2_key) do
            {:ok, state}
          else
            {:error, reason} -> {:error, reason}
          end
        end)

      case result do
        {:ok, state} -> {:ok, state}
        {:error, _} = err -> err
      end
    end
  end

  defp insert_snapshot(document_id, revision, projection, r2_key) do
    %Snapshot{}
    |> Snapshot.changeset(%{
      document_id: document_id,
      revision: revision,
      projection: projection,
      r2_key: r2_key
    })
    |> Repo.insert(
      on_conflict: {:replace, [:projection, :r2_key]},
      conflict_target: [:document_id, :revision]
    )
  end

  # ----------------------------------------------------------------------------
  # append/3
  # ----------------------------------------------------------------------------

  @spec append(T.document_id(), Change.t(), integer()) :: T.result(Change.t())
  def append(document_id, %Change{} = change, fencing_token) when is_integer(fencing_token) do
    result =
      Repo.transaction(fn ->
        :ok = take_advisory_lock!(document_id)

        try do
          Lease.assert_current!(document_id, fencing_token)
        rescue
          e in Lease.FencedOut ->
            Repo.rollback({:fenced_out, e.current_token, e.supplied_token, reason: e.reason})
        end

        case lookup_idempotent(document_id, change.idempotency_key) do
          {:ok, existing} ->
            {:idempotent, existing}

          :none ->
            do_append(document_id, change)
        end
      end)

    case result do
      {:ok, {:idempotent, existing}} ->
        {:ok, existing}

      {:ok, %Change{} = persisted} ->
        # Mirror the highest applied_revision onto Documents.latest_revision
        # so dashboard / list queries don't need a fold over `changes`.
        # Best-effort: if the documents table doesn't exist yet (test
        # envs that don't run the Wave-4 migration) or the row is
        # missing, touch_revision/2 swallows the error.
        _ = Contract.Documents.touch_revision(document_id, persisted.applied_revision)

        Phoenix.PubSub.broadcast(@pubsub, topic(document_id), {:change_committed, persisted})
        {:ok, persisted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_append(document_id, %Change{} = change) do
    {:ok, current_rev} = latest_revision_unsafe(document_id)

    base = change.base_revision

    if not is_nil(base) and base != current_rev do
      Repo.rollback({:revision_conflict, expected: current_rev, got: base})
    end

    next_rev = current_rev + 1

    attrs = %{
      matter_id: change.matter_id,
      document_id: document_id,
      artifact_id: change.artifact_id,
      action_kind: change.action_kind,
      actor_type: change.actor_type,
      actor_id: change.actor_id,
      base_revision: base || current_rev,
      applied_revision: next_rev,
      idempotency_key: change.idempotency_key,
      ops: Enum.map(change.ops || [], &normalize_op_for_storage/1),
      marks: change.marks,
      message: change.message,
      affected_refs: change.affected_refs,
      preimage: encode_preimage(change.preimage),
      inverse_ops: Enum.map(change.inverse_ops || [], &normalize_op_for_storage/1),
      status: change.status || :active
    }

    case %Change{} |> Change.changeset(attrs) |> Repo.insert() do
      {:ok, %Change{} = persisted} ->
        persisted

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if idempotency_conflict?(errors) do
          case lookup_idempotent(document_id, change.idempotency_key) do
            {:ok, existing} -> {:idempotent, existing}
            :none -> Repo.rollback({:insert_failed, changeset})
          end
        else
          Repo.rollback({:insert_failed, changeset})
        end
    end
  end

  defp idempotency_conflict?(errors) do
    Enum.any?(errors, fn
      {_, {_, opts}} ->
        Keyword.get(opts, :constraint_name) ==
          "changes_document_id_idempotency_key_index"

      _ ->
        false
    end)
  end

  defp take_advisory_lock!(document_id) do
    {:ok, _} =
      Repo.query("SELECT pg_advisory_xact_lock(hashtext($1))", [document_id])

    :ok
  end

  defp lookup_idempotent(_document_id, nil), do: :none

  defp lookup_idempotent(document_id, key) when is_binary(key) do
    case Repo.one(
           from c in Change,
             where: c.document_id == ^document_id and c.idempotency_key == ^key,
             limit: 1
         ) do
      nil -> :none
      %Change{} = change -> {:ok, change}
    end
  end

  # ----------------------------------------------------------------------------
  # changes_since/2
  # ----------------------------------------------------------------------------

  @spec changes_since(T.document_id(), T.revision()) :: T.result([Change.t()])
  def changes_since(document_id, revision) when is_integer(revision) and revision >= 0 do
    changes =
      from(c in Change,
        where: c.document_id == ^document_id and c.applied_revision > ^revision,
        order_by: [asc: c.applied_revision]
      )
      |> Repo.all()

    {:ok, changes}
  end

  # ----------------------------------------------------------------------------
  # latest_revision/1
  # ----------------------------------------------------------------------------

  @spec latest_revision(T.document_id()) :: T.result(T.revision())
  def latest_revision(document_id) do
    latest_revision_unsafe(document_id)
  end

  defp latest_revision_unsafe(document_id) do
    rev =
      from(c in Change,
        where: c.document_id == ^document_id,
        select: max(c.applied_revision)
      )
      |> Repo.one()

    {:ok, rev || 0}
  end

  # ----------------------------------------------------------------------------
  # idempotency_seen? / previous_result
  # ----------------------------------------------------------------------------

  @spec idempotency_seen?(T.document_id(), T.idempotency_key()) :: boolean()
  def idempotency_seen?(_document_id, nil), do: false

  def idempotency_seen?(document_id, key) when is_binary(key) do
    Repo.exists?(
      from c in Change,
        where: c.document_id == ^document_id and c.idempotency_key == ^key
    )
  end

  @spec previous_result(T.document_id(), T.idempotency_key()) :: T.result(Change.t())
  def previous_result(_document_id, nil), do: {:error, :not_found}

  def previous_result(document_id, key) when is_binary(key) do
    case lookup_idempotent(document_id, key) do
      {:ok, change} -> {:ok, change}
      :none -> {:error, :not_found}
    end
  end

  # ----------------------------------------------------------------------------
  # transaction/1
  # ----------------------------------------------------------------------------

  @doc """
  Run `fun` in a `Repo.transaction/1`, unwrapping ok/error tuples. A
  return value of `{:ok, value}` commits and returns `{:ok, value}`; an
  `{:error, reason}` rolls back and returns `{:error, reason}`.

  Useful for grouping multiple Store operations into one atomic unit
  (e.g. `Session.revoke/2` writing a `RevokeRequest` and updating a
  `Change.status` atomically).
  """
  @spec transaction((-> T.result(term()))) :: T.result(term())
  def transaction(fun) when is_function(fun, 0) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, value} -> value
             {:error, reason} -> Repo.rollback(reason)
             other -> Repo.rollback({:bad_transaction_return, other})
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  # ----------------------------------------------------------------------------
  # helpers — change ↔ change_input
  # ----------------------------------------------------------------------------

  @doc """
  Convert a persisted `Contract.Change` row back into a `ChangeInput` so
  it can be folded through `Engine.apply/2`. Used by `load/1` during
  hydration.
  """
  @spec change_to_input(Change.t()) :: ChangeInput.t()
  def change_to_input(%Change{} = c) do
    %ChangeInput{
      action_kind: action_kind_atom(c.action_kind),
      matter_id: c.matter_id,
      document_id: c.document_id,
      base_revision: c.base_revision,
      idempotency_key: c.idempotency_key,
      actor_type: c.actor_type,
      actor_id: c.actor_id,
      ops: Enum.map(c.ops, &decode_op/1),
      marks: c.marks,
      message: c.message,
      affected_refs: c.affected_refs,
      preimage: c.preimage,
      inverse_ops: Enum.map(c.inverse_ops, &decode_op/1)
    }
  end

  defp action_kind_atom(nil), do: nil
  defp action_kind_atom(atom) when is_atom(atom), do: atom

  defp action_kind_atom(str) when is_binary(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> nil
  end

  # Preimage maps are keyed by `{op_index, target_id}` tuples in memory; JSONB
  # can't store tuple keys, so we stringify them on the way in. On the way
  # out (`change_to_input/1`) we don't actually use the preimage — Engine
  # only reads it during the original commit — so we leave the persisted
  # form as-is.
  defp encode_preimage(nil), do: nil

  defp encode_preimage(map) when is_map(map) do
    Map.new(map, fn
      {{idx, target_id}, value} ->
        {"#{idx}:#{inspect(target_id)}", encode_preimage_value(value)}

      {key, value} when is_binary(key) or is_atom(key) ->
        {key, encode_preimage_value(value)}

      {key, value} ->
        {inspect(key), encode_preimage_value(value)}
    end)
  end

  defp encode_preimage_value(%Operation{} = op), do: normalize_op_for_storage(op)
  defp encode_preimage_value(map) when is_map(map), do: stringify_keys_shallow(map)

  defp encode_preimage_value(list) when is_list(list),
    do: Enum.map(list, &encode_preimage_value/1)

  defp encode_preimage_value(other), do: other

  defp stringify_keys_shallow(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), encode_preimage_value(v)}
      {k, v} when is_binary(k) -> {k, encode_preimage_value(v)}
      {k, v} -> {inspect(k), encode_preimage_value(v)}
    end)
  end

  defp normalize_op_for_storage(%Operation{} = op) do
    %{
      "op" => atom_to_string(op.op),
      "target_type" => atom_to_string(op.target_type),
      "target_id" => op.target_id,
      "args" => normalize_args_for_storage(op.args || %{})
    }
  end

  defp normalize_op_for_storage(map) when is_map(map), do: map

  defp normalize_args_for_storage(args) when is_map(args) do
    Map.new(args, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), normalize_arg_value(v)}
      {k, v} when is_binary(k) -> {k, normalize_arg_value(v)}
      {k, v} -> {inspect(k), normalize_arg_value(v)}
    end)
  end

  defp normalize_arg_value(v) when is_atom(v) and v in [nil, true, false], do: v
  defp normalize_arg_value(v) when is_atom(v), do: Atom.to_string(v)

  defp normalize_arg_value(v) when is_map(v) do
    Map.new(v, fn
      {k, val} when is_atom(k) -> {Atom.to_string(k), normalize_arg_value(val)}
      {k, val} when is_binary(k) -> {k, normalize_arg_value(val)}
      {k, val} -> {inspect(k), normalize_arg_value(val)}
    end)
  end

  defp normalize_arg_value(v) when is_list(v), do: Enum.map(v, &normalize_arg_value/1)
  defp normalize_arg_value(v), do: v

  defp atom_to_string(nil), do: nil
  defp atom_to_string(v) when is_atom(v), do: Atom.to_string(v)
  defp atom_to_string(v) when is_binary(v), do: v

  @doc """
  Decode a single persisted op map (string-keyed, from JSONB) back into a
  `Contract.Operation` struct with atomized fields. Exposed for callers
  like `Contract.Session` that need to replay stored `inverse_ops` through
  the Engine.
  """
  @spec decode_op(Operation.t() | map()) :: Operation.t()
  def decode_op(%Operation{} = op), do: op

  def decode_op(map) when is_map(map) do
    map = atomize_keys(map)

    op_kind = atomize_value(Map.get(map, :op))

    %Operation{
      op: op_kind,
      target_type: atomize_value(Map.get(map, :target_type)),
      target_id: Map.get(map, :target_id),
      args: decode_op_args(op_kind, Map.get(map, :args, %{}))
    }
  end

  defp decode_op_args(op_kind, args) do
    args = atomize_args(args)

    cond do
      op_kind in [:set_attr, :set_field] and Map.has_key?(args, :key) ->
        Map.update!(args, :key, &atomize_value/1)

      true ->
        args
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {atomize_key(k), v} end)
  end

  defp atomize_key(k) when is_atom(k), do: k

  defp atomize_key(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> k
  end

  defp atomize_value(nil), do: nil
  defp atomize_value(atom) when is_atom(atom), do: atom

  # Op kinds and target types known to the Engine. Listed explicitly so the
  # atoms are guaranteed loaded before `decode_op/1` runs (otherwise a fresh
  # BEAM that has never reached `Engine.compile/2` would `rescue
  # ArgumentError` on `String.to_existing_atom`).
  @known_op_kinds ~w(create_node delete_node move_node replace_content set_field
                     set_attr bind_ref unbind_ref create_projection add_mark
                     update_mark)
  @known_target_types ~w(artifact document node field mark projection change op
                         evidence)
  @known_misc ~w(title type_key metadata kind parent_id content attrs id key
                 value status)

  defp atomize_value(str) when is_binary(str) do
    cond do
      str in @known_op_kinds ->
        String.to_atom(str)

      str in @known_target_types ->
        String.to_atom(str)

      str in @known_misc ->
        String.to_atom(str)

      true ->
        try do
          String.to_existing_atom(str)
        rescue
          ArgumentError -> str
        end
    end
  end

  defp atomize_args(nil), do: %{}

  defp atomize_args(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {atomize_key(k), v} end)
  end

  defp decode_projection(projection) when is_map(projection) do
    base = Runtime.State.empty_projection()

    Map.merge(base, %{
      title: get_proj(projection, :title),
      type_key: get_proj(projection, :type_key),
      metadata: decode_simple(get_proj(projection, :metadata, %{})),
      nodes: decode_nodes(get_proj(projection, :nodes, %{})),
      node_order: get_proj(projection, :node_order, []),
      fields: decode_simple(get_proj(projection, :fields, %{})),
      marks: decode_simple(get_proj(projection, :marks, %{})),
      refs: decode_simple(get_proj(projection, :refs, %{}))
    })
  end

  defp decode_projection(_), do: Runtime.State.empty_projection()

  defp get_proj(map, key, default \\ nil) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key), default)
  end

  defp decode_simple(value) when is_map(value), do: value
  defp decode_simple(value) when is_list(value), do: value
  defp decode_simple(other), do: other

  defp decode_nodes(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, decode_simple(v)} end)
  end

  defp decode_nodes(other), do: other

  defp topic(document_id), do: "document:#{document_id}"

  @doc "PubSub topic for a document. Exposed for tests and the Runtime."
  @spec topic(T.document_id()) :: String.t()
  def pubsub_topic(document_id), do: topic(document_id)
end
