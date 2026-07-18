defmodule Ecrits.Doc.Op do
  @moduledoc """
  Format-agnostic editing verbs for `doc.edit` (design §5).

  An op is a map discriminated by `"op"`. Format-specific vocabulary only shows
  up inside string fields (e.g. `insert_node` with `type: "page"`), never as
  bespoke schema, so the same verb set drives every engine. The owning backend
  maps each verb to its native operation and rejects ones it cannot perform.

      %{op: "insert_text",   ref, at?, text}
      %{op: "delete_range",  ref, count? | to_ref?}
      %{op: "replace_text",  ref?, query, replacement}
      %{op: "split",         ref}
      %{op: "insert_node",   parent_ref, type, at?, props?}
      %{op: "delete_node",   ref}
      %{op: "move_node",     ref, to_parent, at}
      %{op: "insert_picture", ref, src, width?, height?}
      %{op: "set_cell",      ref, text}
  """

  # The structural edit verbs the HWP engine (ehwp apply_op EditOp) actually
  # supports. Keep this in sync with the NIF's enum — advertising a verb the NIF
  # rejects (e.g. the old insert_node/move_node, which never existed there) just
  # produces bad_ops_json. `insert_table` creates a new R×C table from scratch.
  @verbs ~w(insert_text delete_range replace_text insert_paragraph delete_paragraph
            split merge insert_table insert_table_row delete_table_row
            insert_table_column delete_table_column merge_cells split_cell
            delete_node insert_picture set_cell
            insert_equation insert_footnote insert_endnote insert_shape set_columns
            insert_slide set_geometry)
  # These keys belonged to the retired optimistic-concurrency protocol. A
  # document edit always targets the Session's current model now; accepting one
  # and silently dropping it falsely suggests that the value still participates
  # in conflict resolution.
  @retired_metadata_keys ~w(base_revision base_version revision version current_revision
                            current_version stale_revision stale_version saved_revision
                            saved_version rebased)

  # Only transport/schema keys become atoms. Raw engine properties must retain
  # their supplied string keys (for example, UNO's `CharHeight` or `FillColor`),
  # and agent input must never create atoms.
  @known_op_keys [
    :op,
    :ref,
    :at,
    :text,
    :query,
    :replacement,
    :page,
    :name,
    :service,
    :x,
    :y,
    :w,
    :h,
    :src,
    :path,
    :width,
    :height,
    :bins,
    :bin_index,
    :image_base64,
    :extension,
    :natural_width_px,
    :natural_height_px,
    :description,
    :inline_in_cell,
    :overlay_marker_length,
    :rows,
    :cols,
    :cells,
    :header,
    :header_color,
    :row,
    :col,
    :count,
    :below,
    :right,
    :start_row,
    :start_col,
    :end_row,
    :end_col,
    :script,
    :index,
    :style,
    :value,
    :value_type,
    :formula,
    :from,
    :to,
    :gap,
    :data,
    :spacing,
    :font_size,
    :color,
    :shape_type,
    :column_type,
    :same_width,
    :props,
    :kind,
    :section,
    :paragraph,
    :offset,
    :length,
    :control,
    :cell,
    :cell_para,
    :sub_paragraph,
    :sub_control,
    :container_type,
    :cell_path,
    :style_id,
    :numbering_id,
    :bullet_id
  ]
  @known_op_key_by_name Map.new(@known_op_keys, &{Atom.to_string(&1), &1})

  @doc "The full set of recognised op verbs."
  @spec verbs() :: [String.t()]
  def verbs, do: @verbs

  @doc false
  @spec reject_retired_metadata(map()) :: :ok | {:error, {:invalid_op, String.t()}}
  def reject_retired_metadata(map) when is_map(map) do
    case Enum.find(Map.keys(map), &retired_metadata_key?/1) do
      nil ->
        :ok

      key ->
        {:error,
         {:invalid_op,
          "#{metadata_key_name(key)} is retired metadata; remove it and submit doc.edit against the current document state"}}
    end
  end

  def reject_retired_metadata(_), do: :ok

  @doc false
  @spec retired_metadata_key?(term()) :: boolean()
  def retired_metadata_key?(key) when is_atom(key), do: retired_metadata_key?(Atom.to_string(key))
  def retired_metadata_key?(key) when is_binary(key), do: key in @retired_metadata_keys
  def retired_metadata_key?(_key), do: false

  @doc """
  Normalise a string- or atom-keyed op map into a validated operation. Schema
  keys are atom-keyed internally; arbitrary raw engine-property keys stay
  strings.
  """
  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(op) when is_map(op) do
    with :ok <- reject_retired_metadata(op) do
      case fetch(op, :op) do
        {:ok, verb} when is_binary(verb) ->
          if verb in @verbs do
            validate(verb, op |> atomize() |> Map.put(:op, verb))
          else
            {:error, {:unknown_op, verb}}
          end

        {:ok, verb} when is_atom(verb) ->
          normalize(Map.put(op, :op, Atom.to_string(verb)))

        :error ->
          {:error, {:invalid_op, "missing \"op\" discriminator"}}
      end
    end
  end

  def normalize(_op), do: {:error, {:invalid_op, "op must be a map"}}

  # Per-verb validation. The dangerous case is `replace_text` with a missing or
  # non-string `replacement` (e.g. the agent put the new text under `text`/`new`):
  # the browser would then substitute the empty string and silently DELETE the
  # match. Reject that here with an actionable message so the agent corrects the
  # field instead of corrupting the document. To delete text the agent must use
  # `delete_range`. Newlines in `replacement` are folded to spaces because
  # `replace_text` replaces one paragraph/run; multi-paragraph authoring belongs
  # to `insert_text`/`set_cell`.
  defp validate("replace_text", %{} = op) do
    cond do
      not is_binary(op[:query]) or op[:query] == "" ->
        {:error, {:invalid_op, "replace_text requires a non-empty string \"query\""}}

      not is_binary(op[:replacement]) ->
        {:error,
         {:invalid_op,
          "replace_text requires a string \"replacement\" (the field is \"replacement\", not \"text\"/\"new\"; to delete text use delete_range)"}}

      true ->
        {:ok, Map.update!(op, :replacement, &single_paragraph_text/1)}
    end
  end

  defp validate("insert_text", %{} = op) do
    cond do
      is_nil(op[:ref]) ->
        {:error,
         {:invalid_op, "insert_text requires a \"ref\" (from doc.find) saying where to insert"}}

      not is_binary(op[:text]) or op[:text] == "" ->
        {:error, {:invalid_op, "insert_text requires a non-empty string \"text\""}}

      true ->
        # `\n` in text is ALLOWED and meaningful: the backend expands it into one
        # paragraph per line (insert + split), so the agent can author multi-
        # paragraph bodies (e.g. each contract clause on its own line) in one call.
        {:ok, op}
    end
  end

  defp validate("set_cell", %{} = op) do
    cond do
      is_nil(op[:ref]) ->
        {:error,
         {:invalid_op,
          "set_cell requires a CELL \"ref\" (from doc.find, addressing a table cell) saying which cell to fill"}}

      not is_binary(op[:text]) ->
        {:error,
         {:invalid_op,
          "set_cell requires a string \"text\" — the cell's new content. Newlines (\\n) split it into one cell paragraph per line; each line inherits the cell's existing paragraph/char formatting."}}

      true ->
        # `\n` in text is the WHOLE point: it becomes one cell paragraph per line.
        {:ok, op}
    end
  end

  defp validate("delete_range", %{} = op) do
    if is_nil(op[:ref]) do
      {:error,
       {:invalid_op, "delete_range requires a \"ref\" (from doc.find) saying what to delete"}}
    else
      {:ok, op}
    end
  end

  defp validate("insert_equation", %{} = op) do
    cond do
      is_nil(op[:ref]) ->
        {:error,
         {:invalid_op,
          "insert_equation requires a \"ref\" (from doc.find) saying where to insert"}}

      not is_binary(op[:script]) or op[:script] == "" ->
        {:error,
         {:invalid_op,
          "insert_equation requires a non-empty string \"script\" (HWP equation markup, e.g. \"x^2 + y^2 = z^2\")"}}

      true ->
        {:ok, op}
    end
  end

  # Two arms share the verb: the HWP form places a shape at a text ref
  # (ref + width/height in HWPUNIT); the Office/Impress form is IR-direct —
  # page + UNO service + name + x/y/w/h in 1/100 mm, all other keys raw UNO
  # properties passed through verbatim.
  defp validate("insert_shape", %{page: page} = op) when is_binary(page) do
    cond do
      not is_binary(op[:name]) or op[:name] == "" ->
        {:error,
         {:invalid_op,
          "insert_shape (slide) requires a \"name\" — the new shape's ref becomes page[<page>]/shape[<name>]"}}

      not (is_integer(op[:x]) and is_integer(op[:y]) and is_integer(op[:w]) and
               is_integer(op[:h])) ->
        {:error,
         {:invalid_op,
          "insert_shape (slide) requires integer \"x\", \"y\", \"w\", \"h\" in 1/100 mm; use the deck's actual slide size from doc.render, not a hardcoded canvas"}}

      true ->
        {:ok, op}
    end
  end

  defp validate("insert_shape", %{} = op) do
    cond do
      is_nil(op[:ref]) ->
        {:error,
         {:invalid_op, "insert_shape requires a \"ref\" (from doc.find) saying where to insert"}}

      not is_integer(op[:width]) or not is_integer(op[:height]) ->
        {:error,
         {:invalid_op,
          "insert_shape requires integer \"width\" and \"height\" (HWPUNIT, e.g. 8504 ≈ 3cm)"}}

      true ->
        {:ok, op}
    end
  end

  # Office/Impress form (page present): an embedded image placed like a shape.
  # The HWP form (ref + src) keeps its existing engine-side validation.
  defp validate("insert_picture", %{page: page} = op) when is_binary(page) do
    cond do
      not is_binary(op[:src] || op[:path]) ->
        {:error,
         {:invalid_op, "insert_picture (slide) requires \"src\" — the image file path to embed"}}

      not is_binary(op[:name]) or op[:name] == "" ->
        {:error,
         {:invalid_op,
          "insert_picture (slide) requires a \"name\" — the ref becomes page[<page>]/shape[<name>]"}}

      not (is_integer(op[:x]) and is_integer(op[:y]) and is_integer(op[:w]) and
               is_integer(op[:h])) ->
        {:error,
         {:invalid_op,
          "insert_picture (slide) requires integer \"x\", \"y\", \"w\", \"h\" in 1/100 mm"}}

      true ->
        {:ok, op}
    end
  end

  defp validate("set_geometry", %{} = op) do
    cond do
      not is_binary(op[:ref]) or op[:ref] == "" ->
        {:error,
         {:invalid_op,
          "set_geometry requires a shape \"ref\" (page[<page>]/shape[<name>]) to move/resize"}}

      not Enum.any?([:x, :y, :w, :h], &is_integer(op[&1])) ->
        {:error,
         {:invalid_op,
          "set_geometry requires at least one integer of \"x\", \"y\", \"w\", \"h\" (1/100 mm)"}}

      true ->
        {:ok, op}
    end
  end

  defp validate("insert_slide", %{} = op) do
    if is_binary(op[:name]) and op[:name] != "" do
      {:ok, op}
    else
      {:error,
       {:invalid_op,
        "insert_slide requires a \"name\" — the new slide's ref becomes page[<name>]"}}
    end
  end

  defp validate("set_columns", %{} = op) do
    if is_integer(op[:count]) and op[:count] > 0 do
      {:ok, op}
    else
      {:error,
       {:invalid_op, "set_columns requires an integer \"count\" > 0 (the number of columns)"}}
    end
  end

  defp validate(_verb, op), do: {:ok, op}

  defp single_paragraph_text(text) do
    text
    |> String.replace(~r/\R+/u, " ")
    |> String.replace(~r/[ \t]{2,}/u, " ")
    |> String.trim()
  end

  defp fetch(map, key) when is_atom(key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp atomize(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {Map.get(@known_op_key_by_name, k, k), v}
      {k, v} -> {k, v}
    end)
  end

  defp metadata_key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp metadata_key_name(key) when is_binary(key), do: key
  defp metadata_key_name(key), do: inspect(key)
end
