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
  """

  # The structural edit verbs the HWP engine (ehwp apply_op EditOp) actually
  # supports. Keep this in sync with the NIF's enum — advertising a verb the NIF
  # rejects (e.g. the old insert_node/move_node, which never existed there) just
  # produces bad_ops_json. `insert_table` creates a new R×C table from scratch.
  @verbs ~w(insert_text delete_range replace_text insert_paragraph delete_paragraph
            split merge insert_table insert_table_row delete_table_row
            insert_table_column delete_table_column merge_cells split_cell
            delete_node insert_picture)

  @doc "The full set of recognised op verbs."
  @spec verbs() :: [String.t()]
  def verbs, do: @verbs

  @doc """
  Normalise a string- or atom-keyed op map into an atom-keyed map with a
  validated `:op` discriminator.
  """
  @spec normalize(map()) :: {:ok, map()} | {:error, term()}
  def normalize(op) when is_map(op) do
    case fetch(op, :op) do
      {:ok, verb} when is_binary(verb) ->
        if verb in @verbs do
          validate(verb, atomize(op) |> Map.put(:op, verb))
        else
          {:error, {:unknown_op, verb}}
        end

      {:ok, verb} when is_atom(verb) ->
        normalize(Map.put(op, :op, Atom.to_string(verb)))

      :error ->
        {:error, {:invalid_op, "missing \"op\" discriminator"}}
    end
  end

  def normalize(_op), do: {:error, {:invalid_op, "op must be a map"}}

  # Per-verb validation. The dangerous case is `replace_text` with a missing or
  # non-string `replacement` (e.g. the agent put the new text under `text`/`new`):
  # the browser would then substitute the empty string and silently DELETE the
  # match. Reject that here with an actionable message so the agent corrects the
  # field instead of corrupting the document. To delete text the agent must use
  # `delete_range`. A multi-paragraph (newline-bearing) replacement is also
  # rejected — one paragraph per op (the renderer keeps a paragraph on one line).
  defp validate("replace_text", %{} = op) do
    cond do
      not is_binary(op[:query]) or op[:query] == "" ->
        {:error, {:invalid_op, "replace_text requires a non-empty string \"query\""}}

      not is_binary(op[:replacement]) ->
        {:error,
         {:invalid_op,
          "replace_text requires a string \"replacement\" (the field is \"replacement\", not \"text\"/\"new\"; to delete text use delete_range)"}}

      String.contains?(op[:replacement], "\n") ->
        {:error,
         {:invalid_op,
          "replace_text \"replacement\" must be a single paragraph (no newlines); use one op per paragraph or \"split\""}}

      true ->
        {:ok, op}
    end
  end

  defp validate("insert_text", %{} = op) do
    cond do
      is_nil(op[:ref]) ->
        {:error, {:invalid_op, "insert_text requires a \"ref\" (from doc.find) saying where to insert"}}

      not is_binary(op[:text]) or op[:text] == "" ->
        {:error, {:invalid_op, "insert_text requires a non-empty string \"text\""}}

      true ->
        # `\n` in text is ALLOWED and meaningful: the backend expands it into one
        # paragraph per line (insert + split), so the agent can author multi-
        # paragraph bodies (e.g. each contract clause on its own line) in one call.
        {:ok, op}
    end
  end

  defp validate("delete_range", %{} = op) do
    if is_nil(op[:ref]) do
      {:error, {:invalid_op, "delete_range requires a \"ref\" (from doc.find) saying what to delete"}}
    else
      {:ok, op}
    end
  end

  defp validate(_verb, op), do: {:ok, op}

  defp fetch(map, key) when is_atom(key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.get(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp atomize(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), v}
      {k, v} -> {k, v}
    end)
  end
end
