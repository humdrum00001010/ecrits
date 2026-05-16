defmodule Contract.Engine do
  @moduledoc """
  Pure mechanics for turning a `Contract.Action` into a durable
  `Contract.Change`. See SPEC.md §13.

  No LiveView, no OpenAI, no Slack, no MCP, no DB, no HTTP. The Engine is a
  pure function over `(action, state)` and `(change_input, state)`.

  ## Pipeline

      action
      |> compile(state)       # → {:ok, %ChangeInput{ops, marks, ...}}
      |> validate(state)      # → :ok | {:error, {:revision_conflict, ...}} | {:error, ...}
      |> preimage(state)      # → {:ok, preimage_map}
      |> inverse(preimage)    # → {:ok, [Operation.t()]}
      |> apply(state)         # → {:ok, %State{revision: state.revision + 1, ...}}
      |> affected_refs(state) # → {:ok, [refs]}
      |> build_change(action, change_input, state) # → {:ok, %Change{}}

  ## What Engine does NOT handle

  Several `Action.kind` values are routed elsewhere by `Contract.Runtime` /
  `Contract.Studio` before they reach the Engine. Calling `compile/2` with
  one of those kinds raises `ArgumentError`:

  * `:open_document` — pure read; no Change.
  * `:upload_document` — IO layer.
  * `:duplicate_document` — multi-document; handled by Conversion / Studio.
  * `:start_type_conversion`, `:set_field_migration_strategy` —
    `Contract.Conversion`.
  * `:chat_message` — `Contract.Agent`.
  * `:request_export` — `Contract.IO`.
  """

  alias Contract.{Action, Change, ChangeInput, MarkInput, Operation, Runtime, Types}

  @type preimage :: map()

  @valid_op_kinds [
    :create_node,
    :delete_node,
    :move_node,
    :replace_content,
    :set_field,
    :set_attr,
    :bind_ref,
    :unbind_ref,
    :create_projection,
    :add_mark,
    :update_mark
  ]

  @unsupported_kinds [
    :open_document,
    :upload_document,
    :duplicate_document,
    :start_type_conversion,
    :set_field_migration_strategy,
    :chat_message,
    :request_export
  ]

  # ----------------------------------------------------------------------------
  # compile/2
  # ----------------------------------------------------------------------------

  @doc """
  Compile an `Action` against the current `Runtime.State` projection into a
  `ChangeInput`. The `ChangeInput` is the validated, ready-to-apply form.

  ## Examples

      iex> state = %Contract.Runtime.State{revision: 0}
      iex> action = %Contract.Action{
      ...>   kind: :create_document,
      ...>   document_id: "11111111-1111-1111-1111-111111111111",
      ...>   actor_type: :user,
      ...>   actor_id: "22222222-2222-2222-2222-222222222222",
      ...>   base_revision: 0,
      ...>   payload: %{"title" => "Hello", "type_key" => "nda"}
      ...> }
      iex> {:ok, input} = Contract.Engine.compile(action, state)
      iex> input.action_kind
      :create_document
      iex> length(input.ops)
      1
  """
  @spec compile(Action.t(), Runtime.State.t()) :: Types.result(ChangeInput.t())
  def compile(%Action{kind: kind}, _state) when kind in @unsupported_kinds do
    raise ArgumentError,
          "Contract.Engine.compile/2 does not handle Action.kind=#{inspect(kind)} — " <>
            "route it via the appropriate layer (Runtime, Studio, Agent, IO, Conversion)."
  end

  def compile(%Action{} = action, %Runtime.State{} = state) do
    {ops, marks, metadata} = build_ops_and_marks(action, state)

    {:ok,
     %ChangeInput{
       action_kind: action.kind,
       matter_id: action.matter_id,
       document_id: action.document_id || state.document_id,
       base_revision: action.base_revision,
       idempotency_key: action.idempotency_key,
       actor_type: action.actor_type || :user,
       actor_id: action.actor_id,
       agent_run_id: action.agent_run_id,
       ops: ops,
       marks: marks,
       message: action.message,
       metadata: metadata
     }}
  end

  # ----------------------------------------------------------------------------
  # validate/2
  # ----------------------------------------------------------------------------

  @doc """
  Validate a compiled `ChangeInput` against the current `Runtime.State`.

  Returns `:ok` on success, or `{:error, reason}` describing the first
  validation failure. The most common failure is a base-revision mismatch
  (optimistic concurrency).
  """
  @spec validate(ChangeInput.t(), Runtime.State.t()) :: Types.result(:ok)
  def validate(%ChangeInput{} = input, %Runtime.State{} = state) do
    with :ok <- check_revision(input, state),
         :ok <- check_ops(input, state) do
      {:ok, :ok}
    end
  end

  defp check_revision(%ChangeInput{base_revision: nil}, _state), do: :ok

  defp check_revision(%ChangeInput{base_revision: base}, %Runtime.State{revision: rev})
       when base == rev,
       do: :ok

  defp check_revision(%ChangeInput{base_revision: base}, %Runtime.State{revision: rev}) do
    {:error, {:revision_conflict, expected: rev, got: base}}
  end

  defp check_ops(%ChangeInput{ops: ops}, state) do
    Enum.reduce_while(Enum.with_index(ops), :ok, fn {op, idx}, _acc ->
      case validate_op(op, idx, state) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp validate_op(%Operation{op: kind} = op, idx, state) do
    cond do
      kind not in @valid_op_kinds ->
        {:error, {:invalid_op_kind, index: idx, kind: kind}}

      true ->
        validate_op_shape(op, idx, state)
    end
  end

  defp validate_op_shape(%Operation{op: :create_node, args: args}, idx, _state) do
    cond do
      not is_map(args) ->
        {:error, {:invalid_op_args, index: idx, reason: :args_not_map}}

      not Map.has_key?(normalize_args(args), :kind) ->
        {:error, {:invalid_op_args, index: idx, reason: :missing_kind}}

      true ->
        :ok
    end
  end

  defp validate_op_shape(%Operation{op: :replace_content, args: args}, idx, _state) do
    args = normalize_args(args)

    if Map.has_key?(args, :content) do
      :ok
    else
      {:error, {:invalid_op_args, index: idx, reason: :missing_content}}
    end
  end

  defp validate_op_shape(%Operation{op: :set_attr} = op, idx, state) do
    with :ok <-
           (if needs_target?(op), do: check_target_exists(op, idx, state), else: :ok),
         :ok <- check_set_attr_node_kind(op, idx, state) do
      :ok
    end
  end

  defp validate_op_shape(%Operation{op: kind} = op, idx, state)
       when kind in [:delete_node, :move_node, :set_field, :bind_ref, :unbind_ref] do
    if needs_target?(op) do
      check_target_exists(op, idx, state)
    else
      :ok
    end
  end

  defp validate_op_shape(_op, _idx, _state), do: :ok

  # IR-richness (task #37): structural validation of the table/cell attr keys.
  # Additive — only rejects when a *known* key is present with the wrong shape;
  # unknown keys and absent keys are always allowed.
  defp check_set_attr_node_kind(%Operation{target_type: :node, target_id: id, args: args}, idx, state)
       when not is_nil(id) do
    args = normalize_args(args)
    key = Map.get(args, :key)
    value = Map.get(args, :value)
    node = Map.get(state.projection.nodes, id, %{})
    kind = Map.get(node, :kind)

    cond do
      kind == :table and key in Runtime.State.table_attr_keys() ->
        validate_table_attr(key, value, idx)

      kind == :cell and key in Runtime.State.cell_attr_keys() ->
        validate_cell_attr(key, value, idx)

      true ->
        :ok
    end
  end

  defp check_set_attr_node_kind(_op, _idx, _state), do: :ok

  defp validate_table_attr(:column_widths, value, idx) do
    if is_list(value) and Enum.all?(value, &(is_integer(&1) and &1 > 0)) do
      :ok
    else
      {:error, {:invalid_attr_value, index: idx, key: :column_widths, reason: :not_pos_int_list}}
    end
  end

  defp validate_table_attr(:border_fill_id, nil, _idx), do: :ok

  defp validate_table_attr(:border_fill_id, value, idx) do
    if is_binary(value) do
      :ok
    else
      {:error, {:invalid_attr_value, index: idx, key: :border_fill_id, reason: :not_string}}
    end
  end

  defp validate_table_attr(key, value, idx)
       when key in [:header_row_count, :footer_row_count, :rows, :cols] do
    if is_integer(value) and value >= 0 do
      :ok
    else
      {:error, {:invalid_attr_value, index: idx, key: key, reason: :not_non_neg_int}}
    end
  end

  defp validate_table_attr(_key, _value, _idx), do: :ok

  defp validate_cell_attr(key, value, idx) when key in [:row_span, :col_span] do
    if is_integer(value) and value >= 1 do
      :ok
    else
      {:error, {:invalid_attr_value, index: idx, key: key, reason: :not_pos_int}}
    end
  end

  defp validate_cell_attr(:border_fill_id, nil, _idx), do: :ok

  defp validate_cell_attr(:border_fill_id, value, idx) do
    if is_binary(value) do
      :ok
    else
      {:error, {:invalid_attr_value, index: idx, key: :border_fill_id, reason: :not_string}}
    end
  end

  defp validate_cell_attr(:vertical_alignment, value, idx) do
    if value in [:top, :center, :bottom] do
      :ok
    else
      {:error, {:invalid_attr_value, index: idx, key: :vertical_alignment, reason: :not_enum}}
    end
  end

  defp validate_cell_attr(key, value, idx)
       when key in [:padding_top, :padding_right, :padding_bottom, :padding_left] do
    if is_integer(value) and value >= 0 do
      :ok
    else
      {:error, {:invalid_attr_value, index: idx, key: key, reason: :not_non_neg_int}}
    end
  end

  defp validate_cell_attr(_key, _value, _idx), do: :ok

  defp needs_target?(%Operation{target_id: nil}), do: false
  defp needs_target?(%Operation{}), do: true

  defp check_target_exists(%Operation{op: op, target_type: type, target_id: id}, idx, state)
       when not is_nil(id) do
    bucket =
      case type do
        :node -> :nodes
        :field -> :fields
        :mark -> :marks
        :document -> :document
        _ -> nil
      end

    cond do
      bucket == :document ->
        :ok

      is_nil(bucket) ->
        :ok

      Map.has_key?(Map.get(state.projection, bucket, %{}), id) ->
        :ok

      true ->
        {:error, {:target_not_found, index: idx, op: op, target_type: type, target_id: id}}
    end
  end

  defp check_target_exists(_op, _idx, _state), do: :ok

  # ----------------------------------------------------------------------------
  # preimage/2
  # ----------------------------------------------------------------------------

  @doc """
  Capture the pre-mutation state of everything the ops will touch. The result
  is a map keyed by `{op_index, op_target_id}` whose values are op-specific
  preimage payloads used by `inverse/2`.
  """
  @spec preimage(ChangeInput.t(), Runtime.State.t()) :: Types.result(preimage())
  def preimage(%ChangeInput{ops: ops}, %Runtime.State{} = state) do
    image =
      ops
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {op, idx}, acc ->
        Map.put(acc, {idx, op.target_id}, capture_preimage(op, state))
      end)

    {:ok, image}
  end

  defp capture_preimage(%Operation{op: :create_node, target_id: id}, _state) do
    %{op: :create_node, target_id: id}
  end

  defp capture_preimage(%Operation{op: :delete_node, target_id: id}, state) do
    %{op: :delete_node, node: Map.get(state.projection.nodes, id)}
  end

  defp capture_preimage(%Operation{op: :move_node, target_id: id}, state) do
    node = Map.get(state.projection.nodes, id)

    %{
      op: :move_node,
      parent_id: node && Map.get(node, :parent_id),
      position: position_of(state, id)
    }
  end

  defp capture_preimage(%Operation{op: :replace_content, target_id: id}, state) do
    node = Map.get(state.projection.nodes, id)
    %{op: :replace_content, content: node && Map.get(node, :content)}
  end

  defp capture_preimage(%Operation{op: :set_field, target_id: id, args: args}, state) do
    args = normalize_args(args)
    field = Map.get(state.projection.fields, id, %{})
    key = Map.get(args, :key)
    value = if key, do: Map.get(field, key), else: field

    %{op: :set_field, key: key, value: value}
  end

  defp capture_preimage(%Operation{op: :set_attr, target_type: type, args: args} = op, state) do
    args = normalize_args(args)
    key = Map.get(args, :key)
    previous = read_attr(type, op.target_id, key, state)
    %{op: :set_attr, target_type: type, key: key, value: previous}
  end

  defp capture_preimage(%Operation{op: :bind_ref, target_id: id}, state) do
    %{op: :bind_ref, ref: Map.get(state.projection.refs, id)}
  end

  defp capture_preimage(%Operation{op: :unbind_ref, target_id: id}, state) do
    %{op: :unbind_ref, ref: Map.get(state.projection.refs, id)}
  end

  defp capture_preimage(%Operation{op: :add_mark, target_id: id}, _state) do
    %{op: :add_mark, target_id: id}
  end

  defp capture_preimage(%Operation{op: :update_mark, target_id: id}, state) do
    %{op: :update_mark, mark: Map.get(state.projection.marks, id)}
  end

  defp capture_preimage(%Operation{op: :create_projection, target_id: id}, _state) do
    %{op: :create_projection, target_id: id}
  end

  defp position_of(state, node_id) do
    Enum.find_index(state.projection.node_order, &(&1 == node_id))
  end

  defp read_attr(:document, _id, :title, state), do: state.projection.title
  defp read_attr(:document, _id, :type_key, state), do: state.projection.type_key
  defp read_attr(:document, _id, :metadata, state), do: state.projection.metadata
  defp read_attr(:document, _id, :node_order, state), do: state.projection.node_order
  defp read_attr(:document, _id, :status, state), do: Map.get(state.projection.metadata, :status)

  defp read_attr(:document, _id, key, state) do
    Map.get(state.projection.metadata, key)
  end

  defp read_attr(:node, id, key, state) do
    node = Map.get(state.projection.nodes, id, %{})
    Map.get(node, key) || get_in(node, [:attrs, key])
  end

  defp read_attr(_type, _id, _key, _state), do: nil

  # ----------------------------------------------------------------------------
  # inverse/2
  # ----------------------------------------------------------------------------

  @doc """
  Given a compiled `ChangeInput` and the preimage map from `preimage/2`, build
  the list of operations that would undo this Change. Used by
  `Contract.Revocation` (SPEC.md §17).

  Marks are append-only per SPEC.md §15 invariant 11 — `:add_mark` ops do not
  produce an inverse op.
  """
  @spec inverse(ChangeInput.t(), preimage()) :: Types.result([Operation.t()])
  def inverse(%ChangeInput{ops: ops}, preimage) when is_map(preimage) do
    inverse_ops =
      ops
      |> Enum.with_index()
      |> Enum.flat_map(fn {op, idx} ->
        case build_inverse_op(op, Map.get(preimage, {idx, op.target_id})) do
          nil -> []
          inv -> [inv]
        end
      end)

    {:ok, inverse_ops}
  end

  defp build_inverse_op(%Operation{op: :create_node, target_type: type, target_id: id}, _pre) do
    %Operation{op: :delete_node, target_type: type, target_id: id, args: %{}}
  end

  defp build_inverse_op(%Operation{op: :delete_node, target_type: type, target_id: id}, pre) do
    %Operation{
      op: :create_node,
      target_type: type,
      target_id: id,
      args: %{node: pre && pre.node}
    }
  end

  defp build_inverse_op(%Operation{op: :move_node, target_type: type, target_id: id}, pre) do
    %Operation{
      op: :move_node,
      target_type: type,
      target_id: id,
      args: %{parent_id: pre && pre.parent_id, position: pre && pre.position}
    }
  end

  defp build_inverse_op(%Operation{op: :replace_content, target_type: type, target_id: id}, pre) do
    %Operation{
      op: :replace_content,
      target_type: type,
      target_id: id,
      args: %{content: pre && pre.content}
    }
  end

  defp build_inverse_op(
         %Operation{op: :set_field, target_type: type, target_id: id, args: args},
         pre
       ) do
    args = normalize_args(args)

    %Operation{
      op: :set_field,
      target_type: type,
      target_id: id,
      args: %{key: Map.get(args, :key), value: pre && pre.value}
    }
  end

  defp build_inverse_op(
         %Operation{op: :set_attr, target_type: type, target_id: id, args: args},
         pre
       ) do
    args = normalize_args(args)

    %Operation{
      op: :set_attr,
      target_type: type,
      target_id: id,
      args: %{key: Map.get(args, :key), value: pre && pre.value}
    }
  end

  defp build_inverse_op(%Operation{op: :bind_ref, target_type: type, target_id: id}, _pre) do
    %Operation{op: :unbind_ref, target_type: type, target_id: id, args: %{}}
  end

  defp build_inverse_op(%Operation{op: :unbind_ref, target_type: type, target_id: id}, pre) do
    %Operation{
      op: :bind_ref,
      target_type: type,
      target_id: id,
      args: %{ref: pre && pre.ref}
    }
  end

  # Marks are append-only — no inverse for :add_mark.
  defp build_inverse_op(%Operation{op: :add_mark}, _pre), do: nil

  defp build_inverse_op(%Operation{op: :update_mark, target_type: type, target_id: id}, pre) do
    %Operation{
      op: :update_mark,
      target_type: type,
      target_id: id,
      args: %{mark: pre && pre.mark}
    }
  end

  defp build_inverse_op(
         %Operation{op: :create_projection, target_type: type, target_id: id},
         _pre
       ) do
    # Inverse of creating a variant projection is unsupported as a single op;
    # represent as a no-op marker for traceability.
    %Operation{op: :create_projection, target_type: type, target_id: id, args: %{inverse: true}}
  end

  # ----------------------------------------------------------------------------
  # apply/2
  # ----------------------------------------------------------------------------

  @doc """
  Apply the ops of a `ChangeInput` against the projection in `Runtime.State`
  and bump the revision by one. Pure — does not touch the DB.
  """
  @spec apply(ChangeInput.t(), Runtime.State.t()) :: Types.result(Runtime.State.t())
  def apply(%ChangeInput{ops: ops}, %Runtime.State{} = state) do
    new_projection = Enum.reduce(ops, state.projection, &apply_op/2)

    {:ok,
     %Runtime.State{
       document_id: state.document_id,
       revision: state.revision + 1,
       projection: new_projection
     }}
  end

  defp apply_op(%Operation{op: :create_node, target_type: :document, args: args}, projection) do
    args = normalize_args(args)

    projection
    |> Map.put(:title, Map.get(args, :title))
    |> Map.put(:type_key, Map.get(args, :type_key))
  end

  defp apply_op(%Operation{op: :create_node, target_id: id, args: args}, projection) do
    args = normalize_args(args)

    cond do
      Map.has_key?(args, :node) and is_map(args.node) ->
        node = Map.put(args.node, :id, id)
        place_node(projection, node)

      true ->
        node =
          %{id: id, kind: Map.get(args, :kind, :paragraph)}
          |> maybe_put(:parent_id, Map.get(args, :parent_id))
          |> maybe_put(:content, Map.get(args, :content))
          |> maybe_put(:attrs, Map.get(args, :attrs))

        place_node(projection, node)
    end
  end

  defp apply_op(%Operation{op: :delete_node, target_id: id}, projection) do
    %{
      projection
      | nodes: Map.delete(projection.nodes, id),
        node_order: Enum.reject(projection.node_order, &(&1 == id))
    }
  end

  defp apply_op(%Operation{op: :move_node, target_id: id, args: args}, projection) do
    args = normalize_args(args)
    parent_id = Map.get(args, :parent_id)
    position = Map.get(args, :position)

    node =
      projection.nodes
      |> Map.get(id, %{id: id, kind: :paragraph})
      |> Map.put(:parent_id, parent_id)

    nodes = Map.put(projection.nodes, id, node)

    order =
      projection.node_order
      |> Enum.reject(&(&1 == id))
      |> insert_at(id, position)

    %{projection | nodes: nodes, node_order: order}
  end

  defp apply_op(%Operation{op: :replace_content, target_id: id, args: args}, projection) do
    args = normalize_args(args)
    node = Map.get(projection.nodes, id, %{id: id, kind: :paragraph})
    node = Map.put(node, :content, Map.get(args, :content))
    %{projection | nodes: Map.put(projection.nodes, id, node)}
  end

  defp apply_op(%Operation{op: :set_field, target_id: id, args: args}, projection) do
    args = normalize_args(args)
    key = Map.get(args, :key)
    value = Map.get(args, :value)
    field = Map.get(projection.fields, id, %{id: id})

    new_field =
      if key do
        Map.put(field, key, value)
      else
        Map.merge(field, value || %{})
      end

    %{projection | fields: Map.put(projection.fields, id, new_field)}
  end

  defp apply_op(
         %Operation{op: :set_attr, target_type: :document, args: args},
         projection
       ) do
    args = normalize_args(args)
    key = Map.get(args, :key)
    value = Map.get(args, :value)

    case key do
      :title ->
        Map.put(projection, :title, value)

      :type_key ->
        Map.put(projection, :type_key, value)

      :metadata when is_map(value) ->
        Map.put(projection, :metadata, value)

      :node_order when is_list(value) ->
        Map.put(projection, :node_order, value)

      _ when is_atom(key) ->
        Map.update!(projection, :metadata, &Map.put(&1, key, value))

      _ ->
        projection
    end
  end

  defp apply_op(
         %Operation{op: :set_attr, target_type: :node, target_id: id, args: args},
         projection
       ) do
    args = normalize_args(args)
    key = Map.get(args, :key)
    value = Map.get(args, :value)
    node = Map.get(projection.nodes, id, %{id: id, kind: :paragraph})

    node =
      cond do
        key in [:content, :kind, :parent_id] -> Map.put(node, key, value)
        true -> Map.update(node, :attrs, %{key => value}, &Map.put(&1, key, value))
      end

    %{projection | nodes: Map.put(projection.nodes, id, node)}
  end

  defp apply_op(%Operation{op: :set_attr}, projection), do: projection

  defp apply_op(%Operation{op: :bind_ref, target_id: id, args: args}, projection) do
    args = normalize_args(args)
    ref = Map.get(args, :ref) || %{id: id}
    ref = Map.put(ref, :id, id)
    %{projection | refs: Map.put(projection.refs, id, ref)}
  end

  defp apply_op(%Operation{op: :unbind_ref, target_id: id}, projection) do
    %{projection | refs: Map.delete(projection.refs, id)}
  end

  defp apply_op(%Operation{op: :add_mark, target_id: id, args: args}, projection) do
    args = normalize_args(args)
    mark = Map.get(args, :mark, %{}) |> Map.put(:id, id)
    %{projection | marks: Map.put(projection.marks, id, mark)}
  end

  defp apply_op(%Operation{op: :update_mark, target_id: id, args: args}, projection) do
    args = normalize_args(args)

    payload =
      Map.get(args, :mark) || Map.delete(args, :mark)

    existing = Map.get(projection.marks, id, %{id: id})
    updated = Map.merge(existing, payload || %{}) |> Map.put(:id, id)
    %{projection | marks: Map.put(projection.marks, id, updated)}
  end

  defp apply_op(%Operation{op: :create_projection}, projection) do
    # No-op on the current state. Variant creation produces a *new* projection
    # in the caller (Conversion module); the source projection is untouched.
    projection
  end

  defp place_node(projection, node) do
    nodes = Map.put(projection.nodes, node.id, node)

    order =
      case Map.get(node, :parent_id) do
        nil -> projection.node_order ++ [node.id]
        _ -> projection.node_order
      end

    %{projection | nodes: nodes, node_order: Enum.uniq(order)}
  end

  defp insert_at(list, value, nil), do: list ++ [value]

  defp insert_at(list, value, pos) when is_integer(pos) and pos >= 0 do
    {head, tail} = Enum.split(list, pos)
    head ++ [value] ++ tail
  end

  defp insert_at(list, value, _), do: list ++ [value]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ----------------------------------------------------------------------------
  # affected_refs/2
  # ----------------------------------------------------------------------------

  @doc """
  Walk the ops and report which refs in the projection touch one of the op
  targets. Used by `Contract.Revocation` overlap detection (SPEC.md §17).
  """
  @spec affected_refs(ChangeInput.t(), Runtime.State.t()) :: Types.result([map()])
  def affected_refs(%ChangeInput{ops: ops}, %Runtime.State{projection: projection}) do
    op_target_ids =
      ops
      |> Enum.map(& &1.target_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    refs =
      projection.refs
      |> Map.values()
      |> Enum.filter(fn ref ->
        MapSet.member?(op_target_ids, Map.get(ref, :target_id)) or
          MapSet.member?(op_target_ids, Map.get(ref, :source_node_id))
      end)
      |> Enum.map(fn ref ->
        %{
          ref_id: Map.get(ref, :id),
          type: Map.get(ref, :type),
          source_node_id: Map.get(ref, :source_node_id),
          target_id: Map.get(ref, :target_id)
        }
      end)

    {:ok, refs}
  end

  # ----------------------------------------------------------------------------
  # build_change/3
  # ----------------------------------------------------------------------------

  @doc """
  Construct a durable `Contract.Change` struct from `(action, change_input,
  state)`. The `change_input` must already have `:inverse_ops`, `:preimage`,
  and `:affected_refs` filled in by the caller (typically via the Engine
  pipeline above).

  The returned `Change` is **not** persisted — that is the responsibility of
  `Contract.Store.append/3`.
  """
  @spec build_change(Action.t(), ChangeInput.t(), Runtime.State.t()) ::
          Types.result(Change.t())
  def build_change(%Action{} = action, %ChangeInput{} = input, %Runtime.State{} = state) do
    change = %Change{
      matter_id: input.matter_id || action.matter_id,
      document_id: input.document_id || action.document_id || state.document_id,
      action_kind: Atom.to_string(input.action_kind || action.kind),
      actor_type: input.actor_type || action.actor_type || :user,
      actor_id: input.actor_id || action.actor_id,
      base_revision: input.base_revision || action.base_revision,
      applied_revision: state.revision + 1,
      idempotency_key: input.idempotency_key || action.idempotency_key,
      ops: Enum.map(input.ops, &op_to_map/1),
      marks: Enum.map(input.marks, &mark_to_map/1),
      message: input.message || action.message,
      affected_refs: input.affected_refs,
      preimage: input.preimage,
      inverse_ops: Enum.map(input.inverse_ops, &op_to_map/1),
      status: :active
    }

    {:ok, change}
  end

  defp op_to_map(%Operation{} = op) do
    %{
      op: op.op,
      target_type: op.target_type,
      target_id: op.target_id,
      args: op.args || %{}
    }
  end

  defp op_to_map(map) when is_map(map), do: map

  defp mark_to_map(%MarkInput{} = m) do
    %{
      target_type: m.target_type,
      target_id: m.target_id,
      intent: m.intent,
      text: m.text,
      confidence: m.confidence,
      source: m.source,
      data: m.data || %{}
    }
  end

  defp mark_to_map(map) when is_map(map), do: map

  # ----------------------------------------------------------------------------
  # ops/marks construction — per Action.kind
  # ----------------------------------------------------------------------------

  defp build_ops_and_marks(%Action{kind: :create_document} = action, _state) do
    payload = normalize_payload(action.payload)
    title = Map.get(payload, :title)
    type_key = Map.get(payload, :type_key)
    nodes = Map.get(payload, :nodes) || []
    node_order = Map.get(payload, :node_order) || []

    document_op = %Operation{
      op: :create_node,
      target_type: :document,
      target_id: action.document_id,
      args: %{title: title, type_key: type_key, kind: :document}
    }

    node_ops =
      nodes
      |> List.wrap()
      |> Enum.map(&node_payload_to_op/1)

    order_ops =
      case node_order do
        [] ->
          []

        list when is_list(list) ->
          [
            %Operation{
              op: :set_attr,
              target_type: :document,
              target_id: action.document_id,
              args: %{key: :node_order, value: list}
            }
          ]

        _ ->
          []
      end

    ops = [document_op | node_ops] ++ order_ops

    {ops, [],
     %{
       title: title,
       type_key: type_key,
       node_count: length(node_ops)
     }}
  end

  defp build_ops_and_marks(%Action{kind: :archive_document} = action, _state) do
    op = %Operation{
      op: :set_attr,
      target_type: :document,
      target_id: action.document_id,
      args: %{key: :status, value: :archived}
    }

    {[op], [], %{}}
  end

  defp build_ops_and_marks(%Action{kind: :restore_document} = action, _state) do
    op = %Operation{
      op: :set_attr,
      target_type: :document,
      target_id: action.document_id,
      args: %{key: :status, value: :active}
    }

    {[op], [], %{}}
  end

  defp build_ops_and_marks(%Action{kind: :rename_document} = action, _state) do
    payload = normalize_payload(action.payload)
    title = Map.get(payload, :title) || Map.get(payload, :new_title)

    op = %Operation{
      op: :set_attr,
      target_type: :document,
      target_id: action.document_id,
      args: %{key: :title, value: title}
    }

    {[op], [], %{title: title}}
  end

  defp build_ops_and_marks(%Action{kind: :update_metadata} = action, state) do
    payload = normalize_payload(action.payload)
    incoming = Map.get(payload, :metadata, payload) |> coerce_metadata()
    merged = Map.merge(state.projection.metadata || %{}, incoming)

    op = %Operation{
      op: :set_attr,
      target_type: :document,
      target_id: action.document_id,
      args: %{key: :metadata, value: merged}
    }

    {[op], [], %{merged_metadata: merged}}
  end

  defp build_ops_and_marks(%Action{kind: :set_contract_type} = action, _state) do
    payload = normalize_payload(action.payload)
    type_key = Map.get(payload, :type_key) || Map.get(payload, :new_type_key)

    op = %Operation{
      op: :set_attr,
      target_type: :document,
      target_id: action.document_id,
      args: %{key: :type_key, value: type_key}
    }

    {[op], [], %{type_key: type_key}}
  end

  defp build_ops_and_marks(%Action{kind: kind} = action, _state)
       when kind in [:edit_document, :agent_change] do
    payload = normalize_payload(action.payload)
    ops = parse_ops(Map.get(payload, :ops, []))
    marks = parse_marks(Map.get(payload, :marks, []))
    {ops, marks, %{}}
  end

  defp build_ops_and_marks(%Action{kind: :add_mark} = action, _state) do
    payload = normalize_payload(action.payload)
    marks = parse_marks(Map.get(payload, :marks, [payload]))
    {[], marks, %{}}
  end

  defp build_ops_and_marks(%Action{kind: :update_mark} = action, _state) do
    payload = normalize_payload(action.payload)
    marks = parse_marks(Map.get(payload, :marks, [payload]))
    {[], marks, %{update: true}}
  end

  defp build_ops_and_marks(%Action{kind: :create_converted_variant} = action, _state) do
    payload = normalize_payload(action.payload)
    parent_doc = Map.get(payload, :parent_document_id) || action.document_id
    target_type_key = Map.get(payload, :target_type_key)
    new_doc_id = Map.get(payload, :new_document_id) || action.document_id

    op = %Operation{
      op: :create_projection,
      target_type: :projection,
      target_id: new_doc_id,
      args: %{
        parent_document_id: parent_doc,
        target_type_key: target_type_key
      }
    }

    {[op], [], %{parent_document_id: parent_doc, target_type_key: target_type_key}}
  end

  defp build_ops_and_marks(%Action{kind: :revoke_change} = action, _state) do
    payload = normalize_payload(action.payload)
    inverse_ops = parse_ops(Map.get(payload, :inverse_ops, []))
    change_id = Map.get(payload, :change_id) || action.change_id

    explain_mark = %MarkInput{
      target_type: :change,
      target_id: change_id,
      intent: :explain,
      source: :system,
      text: "Revoked change #{change_id}",
      data: %{revoked_change_id: change_id}
    }

    {inverse_ops, [explain_mark], %{revoked_change_id: change_id}}
  end

  defp build_ops_and_marks(%Action{kind: :resolve_revoke} = action, _state) do
    payload = normalize_payload(action.payload)
    ops = parse_ops(Map.get(payload, :ops, []))
    marks = parse_marks(Map.get(payload, :marks, []))

    {ops, marks,
     %{
       reconciliation: true,
       revoke_request_id: Map.get(payload, :revoke_request_id)
     }}
  end

  defp build_ops_and_marks(%Action{kind: kind}, _state) do
    raise ArgumentError,
          "Contract.Engine: unhandled Action.kind=#{inspect(kind)} in build_ops_and_marks/2"
  end

  # ----------------------------------------------------------------------------
  # node payload → :create_node op helpers (used by :create_document)
  # ----------------------------------------------------------------------------

  # Convert a payload-shaped node (string- or atom-keyed) into a :create_node
  # Operation targeting the projection's nodes map.
  defp node_payload_to_op(%Operation{} = op), do: op

  defp node_payload_to_op(node) when is_map(node) do
    node = Map.new(node, fn {k, v} -> {atomize(k), v} end)

    target_id =
      case Map.get(node, :id) do
        id when is_binary(id) and id != "" -> id
        _ -> Ecto.UUID.generate()
      end

    kind = node |> Map.get(:kind) |> atomize_kind()
    content = Map.get(node, :content)
    attrs = Map.get(node, :attrs) || %{}
    parent_id = Map.get(node, :parent_id)
    position = Map.get(node, :position)

    args =
      %{kind: kind}
      |> maybe_put(:content, content)
      |> maybe_put(:attrs, attrs)
      |> maybe_put(:parent_id, parent_id)
      |> maybe_put(:position, position)

    %Operation{
      op: :create_node,
      target_type: :node,
      target_id: target_id,
      args: args
    }
  end

  defp atomize_kind(nil), do: :paragraph
  defp atomize_kind(k) when is_atom(k), do: k

  defp atomize_kind(k) when is_binary(k) do
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> String.to_atom(k)
    end
  end

  defp atomize_kind(_), do: :paragraph

  # ----------------------------------------------------------------------------
  # payload coercion
  # ----------------------------------------------------------------------------

  defp normalize_payload(nil), do: %{}

  defp normalize_payload(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {atomize(k), v} end)
  end

  defp normalize_payload(other), do: %{value: other}

  defp atomize(k) when is_atom(k), do: k

  defp atomize(k) when is_binary(k) do
    String.to_atom(k)
  end

  defp atomize(other), do: other

  defp normalize_args(nil), do: %{}

  defp normalize_args(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {atomize(k), v} end)
  end

  defp normalize_args(other), do: %{value: other}

  defp coerce_metadata(nil), do: %{}

  defp coerce_metadata(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {atomize(k), v} end)
  end

  defp coerce_metadata(_), do: %{}

  defp parse_ops(list) when is_list(list) do
    Enum.map(list, &parse_op/1)
  end

  defp parse_ops(_), do: []

  defp parse_op(%Operation{} = op), do: %Operation{op | args: normalize_args(op.args)}

  defp parse_op(map) when is_map(map) do
    map = Map.new(map, fn {k, v} -> {atomize(k), v} end)

    %Operation{
      op: atomize(Map.get(map, :op)),
      target_type: atomize(Map.get(map, :target_type)),
      target_id: Map.get(map, :target_id),
      args: normalize_args(Map.get(map, :args, %{}))
    }
  end

  defp parse_marks(list) when is_list(list) do
    Enum.map(list, &parse_mark/1)
  end

  defp parse_marks(_), do: []

  defp parse_mark(%MarkInput{} = m), do: m

  defp parse_mark(map) when is_map(map) do
    map = Map.new(map, fn {k, v} -> {atomize(k), v} end)

    %MarkInput{
      target_type: atomize(Map.get(map, :target_type)),
      target_id: Map.get(map, :target_id),
      intent: atomize(Map.get(map, :intent)),
      text: Map.get(map, :text),
      confidence: atomize(Map.get(map, :confidence)),
      source: atomize(Map.get(map, :source)),
      data: Map.get(map, :data, %{})
    }
  end
end
