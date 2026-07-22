defmodule Ecrits.Doc.Op.Dispatcher do
  @moduledoc "Bounded discriminator and shared transport helpers for document operation schemas."

  alias Ecrits.Doc.Op.{Layout, Picture, Shape, Table, Text}

  @known_keys ~w(
    op ref at text query replacement page name service x y w h src path width height bins
    bin_index image_base64 extension natural_width_px natural_height_px description
    inline_in_cell overlay_marker_length rows cols cells header header_color row col count below
    right start_row start_col end_row end_col script index style value value_type formula from to
    gap data spacing font_size color shape_type column_type same_width props kind section paragraph
    offset length control cell cell_para sub_paragraph sub_control container_type cell_path style_id
    numbering_id bullet_id
  )a
  @known_key_by_name Map.new(@known_keys, &{Atom.to_string(&1), &1})

  @text_verbs ~w(insert_text delete_range replace_text insert_paragraph delete_paragraph split merge
                 set_cell insert_footnote insert_endnote insert_equation delete_node)
  @table_verbs ~w(insert_table insert_table_row delete_table_row insert_table_column
                  delete_table_column merge_cells split_cell)

  @spec schema_for(String.t()) :: module() | nil
  def schema_for(verb) when verb in @text_verbs, do: Text
  def schema_for(verb) when verb in @table_verbs, do: Table
  def schema_for("insert_picture"), do: Picture
  def schema_for(verb) when verb in ["insert_shape", "set_geometry"], do: Shape
  def schema_for(verb) when verb in ["set_columns", "insert_slide"], do: Layout
  def schema_for(_verb), do: nil

  @doc false
  def params(attrs, fields) do
    field_set = MapSet.new(fields)
    field_names = MapSet.new(fields, &Atom.to_string/1)

    {params, present_fields} =
      Enum.reduce(fields, {%{}, []}, fn field, {params, present} ->
        case fetch(attrs, field) do
          {:ok, value} -> {Map.put(params, field, value), [field | present]}
          :error -> {params, present}
        end
      end)

    extensions =
      attrs
      |> Enum.reject(fn {key, _value} ->
        key in [:__struct__, :__meta__, :extensions, :present_fields] or
          MapSet.member?(field_set, key) or MapSet.member?(field_names, key)
      end)
      |> Map.new(fn
        {key, value} when is_binary(key) -> {Map.get(@known_key_by_name, key, key), value}
        pair -> pair
      end)

    params
    |> Map.put(:extensions, extensions)
    |> Map.put(:present_fields, present_fields)
  end

  @doc false
  def dump_fields(item, fields) do
    present = MapSet.new(item.present_fields)

    known =
      Enum.reduce(fields, %{}, fn field, dumped ->
        value = Map.fetch!(item, field)

        cond do
          field == :op and is_atom(value) -> Map.put(dumped, :op, Atom.to_string(value))
          is_nil(value) and not MapSet.member?(present, field) -> dumped
          true -> Map.put(dumped, field, value)
        end
      end)

    Map.merge(item.extensions, known)
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end
end
