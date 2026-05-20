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
    6. Bumps `change.result_revision` to `latest + 1` and inserts.
    7. **After** the transaction commits, broadcasts
       `{:change_committed, change}` on the document's PubSub topic.
       Broadcast happens post-commit on purpose — clients must never see
       a notification without a corresponding durable row.

  ## Load flow

  `load/1` fetches the most recent `Contract.Snapshot` row (if any),
  reconstructs the `Runtime.State` from it, then folds every change
  whose `result_revision > snapshot.revision` through `Engine.apply/2`.

  An empty document (no snapshot, no changes) loads as an empty
  `Runtime.State` at `revision: 0`.
  """

  import Ecto.Query, only: [from: 2]

  alias Contract.Change
  alias Contract.ChangeInput
  alias Contract.Session.Reducer
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
        {:ok, new_state} = Reducer.apply(input, acc)
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
        # Mirror the highest result_revision onto Documents.latest_revision
        # so dashboard / list queries don't need a fold over `changes`.
        # Best-effort: if the documents table doesn't exist yet (test
        # envs that don't run the Wave-4 migration) or the row is
        # missing, touch_revision/2 swallows the error.
        _ = Contract.Documents.touch_revision(document_id, persisted.result_revision)

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
      document_id: document_id,
      chat_thread_id: change.chat_thread_id,
      source_document_id: change.source_document_id,
      source_claim_id: change.source_claim_id,
      agent_run_id: change.agent_run_id,
      command_kind: change.command_kind,
      actor_type: change.actor_type,
      actor_id: change.actor_id,
      base_revision: base || current_rev,
      result_revision: next_rev,
      idempotency_key: change.idempotency_key,
      field_path: change.field_path || [],
      op: change.op,
      payload: Enum.map(change.payload || [], &normalize_op_for_storage/1),
      marks: change.marks,
      message: change.message,
      affected_refs: change.affected_refs,
      preimage: encode_preimage(change.preimage),
      inverse: Enum.map(change.inverse || [], &normalize_op_for_storage/1),
      status: change.status || :active
    }

    case %Change{} |> Change.changeset(attrs) |> Repo.insert() do
      {:ok, %Change{} = persisted} ->
        # Mirror document-level :set_attr ops onto the `documents` table
        # row inside the SAME transaction as the Change insert. Keeps the
        # in-memory projection (Runtime.State) and the SQL row consistent.
        # Engine module bodies are untouched — propagation is purely a
        # Store-boundary concern. See Task #81.
        :ok = propagate_to_documents(document_id, persisted)
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

  # ----------------------------------------------------------------------------
  # propagate_to_documents/2
  #
  # The engine's `:set_attr` op on a `:document` target mutates the
  # in-memory `Runtime.State` projection — but the `documents` SQL row
  # (title, type_key, status) is a separate downstream surface used by
  # dashboard lists, /studio, the command palette, etc. Without
  # propagation those queries would see stale values. Runs inside the
  # outer `Repo.transaction/1` so the row + Change row commit atomically.
  # ----------------------------------------------------------------------------

  defp propagate_to_documents(document_id, %Change{payload: ops}) when is_list(ops) do
    ops
    |> Enum.map(&decode_op/1)
    |> Enum.filter(&document_set_attr?/1)
    |> Enum.each(&apply_document_attr(document_id, &1))

    :ok
  end

  defp propagate_to_documents(_document_id, _change), do: :ok

  defp document_set_attr?(%Operation{op: :set_attr, target_type: :document}), do: true
  defp document_set_attr?(_), do: false

  defp apply_document_attr(doc_id, %Operation{args: args}) do
    key = atomize_value(Map.get(args, :key) || Map.get(args, "key"))
    value = Map.get(args, :value) || Map.get(args, "value")

    case key do
      :title when is_binary(value) -> Contract.Documents.set_title(doc_id, value)
      :type_key -> Contract.Documents.set_type(doc_id, value)
      :status -> Contract.Documents.set_status(doc_id, value)
      # other keys (node_order, metadata, ...) stay in the projection only
      _ -> :ok
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
        where: c.document_id == ^document_id and c.result_revision > ^revision,
        order_by: [asc: c.result_revision]
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
        select: max(c.result_revision)
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
      action_kind: command_kind_atom(c.command_kind),
      document_id: c.document_id,
      base_revision: c.base_revision,
      idempotency_key: c.idempotency_key,
      actor_type: c.actor_type,
      actor_id: c.actor_id,
      ops: Enum.map(c.payload || [], &decode_op/1),
      marks: c.marks,
      message: c.message,
      affected_refs: c.affected_refs,
      preimage: c.preimage,
      inverse_ops: Enum.map(c.inverse || [], &decode_op/1)
    }
  end

  defp command_kind_atom(nil), do: nil
  defp command_kind_atom(atom) when is_atom(atom), do: atom

  defp command_kind_atom(str) when is_binary(str) do
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

      op_kind == :create_node and Map.has_key?(args, :kind) ->
        Map.update!(args, :kind, &coerce_create_node_kind/1)

      true ->
        args
    end
  end

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {atomize_key(k), v} end)
  end

  @create_node_kinds [
    :paragraph,
    :heading,
    :list,
    :list_item,
    :table,
    :caption,
    :footer,
    :equation,
    :cell,
    :section,
    :field_ref
  ]

  defp coerce_create_node_kind(k) when is_atom(k), do: k

  defp coerce_create_node_kind(k) when is_binary(k) do
    case Enum.find(@create_node_kinds, &(Atom.to_string(&1) == k)) do
      nil -> :paragraph
      atom -> atom
    end
  end

  defp coerce_create_node_kind(_), do: :paragraph

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
      fields: decode_fields(get_proj(projection, :fields, %{})),
      marks: decode_marks(get_proj(projection, :marks, %{})),
      refs: decode_refs(get_proj(projection, :refs, %{}))
    })
  end

  defp decode_projection(_), do: Runtime.State.empty_projection()

  defp get_proj(map, key, default \\ nil) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key), default)
  end

  defp decode_simple(value) when is_map(value), do: value
  defp decode_simple(value) when is_list(value), do: value
  defp decode_simple(other), do: other

  # ----------------------------------------------------------------------------
  # JSONB → atom coercion at the Store decode boundary.
  #
  # `Snapshot.projection` is a JSONB column; after round-tripping through Postgres
  # the in-memory shape — atom-keyed maps with atom `kind`, `intent`, etc. — comes
  # back stringified. The renderer (PreviewOverlay.render_node/1) and downstream
  # code pattern-match on atom keys and atom values, so without coercion every
  # node falls through to the catch-all clause (headings render as <div>, tables
  # don't render as <table>, etc.).
  #
  # We coerce here using strict allow-lists. NEVER `String.to_atom/1` — only
  # atoms already known to the system are produced, with safe fallbacks
  # (`:paragraph` for an unknown node kind; the raw string for unknown
  # intent/source/confidence so the catch-all renderer clause still handles it).
  # ----------------------------------------------------------------------------

  # Outer keys of a node map (`@type node_t` in Runtime.State).
  @node_keys [:id, :kind, :parent_id, :content, :children, :attrs]

  # Node kinds produced by `Contract.IO.Upstage.map_category/1` plus the
  # additional baseline kinds named in Runtime.State's @moduledoc (`:cell`,
  # `:section`, `:field_ref`). `:figure`, `:footnote`, `:header` are also
  # emitted by `map_category/1`. Anything outside this list falls back to
  # `:paragraph`, which is the safest renderer kind.
  @node_kinds [
    :paragraph,
    :heading,
    :list,
    :list_item,
    :table,
    :cell,
    :section,
    :field_ref,
    :caption,
    :footer,
    :equation,
    :figure,
    :footnote,
    :header
  ]

  # Atom-keyed attrs we care about preserving — superset of HWPX IR-richness
  # keys (table_attr_keys, cell_attr_keys) and renderer-consumed keys
  # (`:level`, `:ordered`, `:rows`). Unknown keys fall through as strings; the
  # renderer ignores them.
  @node_attr_keys [
    :level,
    :ordered,
    :rows,
    :cols,
    :column_widths,
    :border_fill_id,
    :header_row_count,
    :footer_row_count,
    :row_span,
    :col_span,
    :vertical_alignment,
    :padding_top,
    :padding_right,
    :padding_bottom,
    :padding_left,
    :page,
    :coordinates,
    :category
  ]

  # Outer keys of a mark map (`@type mark_t` in Runtime.State).
  @mark_keys [:id, :intent, :source, :target_type, :target_id, :text, :confidence, :data]

  defp decode_nodes(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, decode_node(v)} end)
  end

  defp decode_nodes(other), do: other

  defp decode_node(node) when is_map(node) do
    node
    |> atomize_known_keys(@node_keys)
    |> Map.update(:kind, :paragraph, &coerce_node_kind/1)
    |> update_if_present(:attrs, &decode_node_attrs/1)
  end

  defp decode_node(other), do: other

  defp coerce_node_kind(kind) when is_atom(kind) and not is_nil(kind) do
    if kind in @node_kinds, do: kind, else: :paragraph
  end

  defp coerce_node_kind(kind) when is_binary(kind) do
    case Enum.find(@node_kinds, &(Atom.to_string(&1) == kind)) do
      nil -> :paragraph
      atom -> atom
    end
  end

  defp coerce_node_kind(_), do: :paragraph

  defp decode_node_attrs(attrs) when is_map(attrs) do
    atomize_known_keys(attrs, @node_attr_keys)
  end

  defp decode_node_attrs(other), do: other

  defp decode_marks(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, decode_mark(v)} end)
  end

  defp decode_marks(other), do: other

  defp decode_mark(mark) when is_map(mark) do
    mark
    |> atomize_known_keys(@mark_keys)
    |> update_if_present(:intent, &coerce_known_atom/1)
    |> update_if_present(:source, &coerce_known_atom/1)
    |> update_if_present(:target_type, &coerce_known_atom/1)
    |> update_if_present(:confidence, &coerce_known_atom/1)
  end

  defp decode_mark(other), do: other

  defp decode_fields(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, decode_field(v)} end)
  end

  defp decode_fields(other), do: other

  defp decode_field(field) when is_map(field) do
    atomize_known_keys(field, [:id, :key, :value, :attrs])
  end

  defp decode_field(other), do: other

  defp decode_refs(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {k, decode_ref(v)} end)
  end

  defp decode_refs(other), do: other

  defp decode_ref(ref) when is_map(ref) do
    ref
    |> atomize_known_keys([:id, :source_node_id, :target_id, :type])
    |> update_if_present(:type, &coerce_known_atom/1)
  end

  defp decode_ref(other), do: other

  # Re-key a map so that any string key whose atom form is in `allowed` becomes
  # an atom. Unknown keys pass through unchanged. Safe because `allowed` is a
  # compile-time list of atoms — they are already loaded.
  defp atomize_known_keys(map, allowed) when is_map(map) and is_list(allowed) do
    Map.new(map, fn {k, v} -> {atomize_known_key(k, allowed), v} end)
  end

  defp atomize_known_key(k, _allowed) when is_atom(k), do: k

  defp atomize_known_key(k, allowed) when is_binary(k) do
    case Enum.find(allowed, &(Atom.to_string(&1) == k)) do
      nil -> k
      atom -> atom
    end
  end

  defp atomize_known_key(k, _allowed), do: k

  defp update_if_present(map, key, fun) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> Map.put(map, key, fun.(value))
      :error -> map
    end
  end

  # For mark intent/source/target_type/confidence: convert to atom only if the
  # string corresponds to an already-loaded atom. Otherwise leave as string so
  # downstream catch-all clauses (e.g. `intent_badge_class/1`) handle it
  # gracefully.
  defp coerce_known_atom(v) when is_atom(v), do: v

  defp coerce_known_atom(v) when is_binary(v) do
    String.to_existing_atom(v)
  rescue
    ArgumentError -> v
  end

  defp coerce_known_atom(v), do: v

  defp topic(document_id), do: "document:#{document_id}"

  @doc "PubSub topic for a document. Exposed for tests and the Runtime."
  @spec topic(T.document_id()) :: String.t()
  def pubsub_topic(document_id), do: topic(document_id)
end
