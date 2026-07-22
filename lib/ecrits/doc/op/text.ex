defmodule Ecrits.Doc.Op.Text do
  @moduledoc "Typed text, paragraph, note, equation, and delete operations."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.Doc.Op.Dispatcher

  @primary_key false
  @verbs ~w(insert_text delete_range replace_text insert_paragraph delete_paragraph split merge
            set_cell insert_footnote insert_endnote insert_equation delete_node)a
  @fields [
    :op,
    :ref,
    :at,
    :text,
    :query,
    :replacement,
    :count,
    :script,
    :index,
    :style,
    :value,
    :value_type,
    :formula,
    :from,
    :to,
    :data,
    :spacing,
    :font_size,
    :color,
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
    :bullet_id,
    :props
  ]

  embedded_schema do
    field :op, Ecto.Enum, values: @verbs

    for field_name <- @fields -- [:op] do
      field field_name, :any, virtual: true
    end

    field :extensions, :map, virtual: true, default: %{}
    field :present_fields, :any, virtual: true, default: []
  end

  def changeset(%__MODULE__{} = operation, attrs) do
    operation
    |> cast(Dispatcher.params(attrs, @fields), @fields ++ [:extensions, :present_fields],
      empty_values: []
    )
    |> validate_operation()
  end

  def dump(%__MODULE__{} = operation), do: Dispatcher.dump_fields(operation, @fields)

  defp validate_operation(changeset) do
    case get_field(changeset, :op) do
      :replace_text -> validate_replace_text(changeset)
      :insert_text -> validate_insert_text(changeset)
      :set_cell -> validate_set_cell(changeset)
      :delete_range -> require_ref(changeset, "delete_range")
      :insert_equation -> validate_insert_equation(changeset)
      _other -> changeset
    end
  end

  defp validate_replace_text(changeset) do
    cond do
      not is_binary(get_field(changeset, :query)) or get_field(changeset, :query) == "" ->
        add_error(changeset, :query, "replace_text requires a non-empty string \"query\"")

      not is_binary(get_field(changeset, :replacement)) ->
        add_error(
          changeset,
          :replacement,
          "replace_text requires a string \"replacement\" (the field is \"replacement\", not \"text\"/\"new\"; to delete text use delete_range)"
        )

      true ->
        update_change(changeset, :replacement, &single_paragraph_text/1)
    end
  end

  defp validate_insert_text(changeset) do
    cond do
      is_nil(get_field(changeset, :ref)) ->
        add_error(
          changeset,
          :ref,
          "insert_text requires a \"ref\" (from doc.find) saying where to insert"
        )

      not is_binary(get_field(changeset, :text)) or get_field(changeset, :text) == "" ->
        add_error(changeset, :text, "insert_text requires a non-empty string \"text\"")

      true ->
        changeset
    end
  end

  defp validate_set_cell(changeset) do
    cond do
      is_nil(get_field(changeset, :ref)) ->
        add_error(
          changeset,
          :ref,
          "set_cell requires a CELL \"ref\" (from doc.find, addressing a table cell) saying which cell to fill"
        )

      not is_binary(get_field(changeset, :text)) ->
        add_error(
          changeset,
          :text,
          "set_cell requires a string \"text\" — the cell's new content. Newlines (\\n) split it into one cell paragraph per line; each line inherits the cell's existing paragraph/char formatting."
        )

      true ->
        changeset
    end
  end

  defp require_ref(changeset, verb) do
    if is_nil(get_field(changeset, :ref)) do
      add_error(
        changeset,
        :ref,
        "#{verb} requires a \"ref\" (from doc.find) saying what to delete"
      )
    else
      changeset
    end
  end

  defp validate_insert_equation(changeset) do
    cond do
      is_nil(get_field(changeset, :ref)) ->
        add_error(
          changeset,
          :ref,
          "insert_equation requires a \"ref\" (from doc.find) saying where to insert"
        )

      not is_binary(get_field(changeset, :script)) or get_field(changeset, :script) == "" ->
        add_error(
          changeset,
          :script,
          "insert_equation requires a non-empty string \"script\" (HWP equation markup, e.g. \"x^2 + y^2 = z^2\")"
        )

      true ->
        changeset
    end
  end

  defp single_paragraph_text(text) do
    text
    |> String.replace(~r/\R+/u, " ")
    |> String.replace(~r/[ \t]{2,}/u, " ")
    |> String.trim()
  end
end
