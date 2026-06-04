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

  @verbs ~w(insert_text delete_range replace_text split insert_node delete_node
            move_node insert_picture)

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
          {:ok, atomize(op) |> Map.put(:op, verb)}
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
