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

  alias Ecrits.Doc.Op.Dispatcher

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
          case Dispatcher.schema_for(verb) do
            nil ->
              {:error, {:unknown_op, verb}}

            module ->
              changeset = module.changeset(struct(module), Map.put(op, :op, verb))

              case Ecto.Changeset.apply_action(changeset, :insert) do
                {:ok, typed} -> {:ok, module.dump(typed)}
                {:error, invalid} -> {:error, {:invalid_op, changeset_message(invalid)}}
              end
          end

        {:ok, verb} when is_atom(verb) ->
          normalize(Map.put(op, :op, Atom.to_string(verb)))

        :error ->
          {:error, {:invalid_op, "missing \"op\" discriminator"}}
      end
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

  defp changeset_message(%Ecto.Changeset{} = changeset) do
    case changeset.errors do
      [{_field, {message, _opts}} | _rest] -> message
      [] -> "invalid operation"
    end
  end

  defp metadata_key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp metadata_key_name(key) when is_binary(key), do: key
  defp metadata_key_name(key), do: inspect(key)
end
