defmodule Ecrits.Doc.Op.Table do
  @moduledoc "Typed table structure operations."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.Doc.Op.Dispatcher

  @primary_key false
  @verbs ~w(insert_table insert_table_row delete_table_row insert_table_column
            delete_table_column merge_cells split_cell)a
  @fields [
    :op,
    :ref,
    :at,
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
    :section,
    :paragraph,
    :offset,
    :control,
    :cell,
    :cell_para,
    :sub_paragraph,
    :sub_control,
    :container_type,
    :cell_path,
    :style_id,
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
    cast(operation, Dispatcher.params(attrs, @fields), @fields ++ [:extensions, :present_fields],
      empty_values: []
    )
  end

  def dump(%__MODULE__{} = operation), do: Dispatcher.dump_fields(operation, @fields)
end
