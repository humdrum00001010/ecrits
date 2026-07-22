defmodule Ecrits.Doc.Op.Shape do
  @moduledoc "Typed shape operations with string-keyed engine property extensions."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.Doc.Op.Dispatcher

  @primary_key false
  @fields [
    :op,
    :ref,
    :at,
    :page,
    :name,
    :service,
    :x,
    :y,
    :w,
    :h,
    :width,
    :height,
    :style,
    :value,
    :data,
    :spacing,
    :font_size,
    :color,
    :shape_type,
    :props,
    :kind,
    :section,
    :paragraph,
    :offset,
    :control,
    :cell,
    :cell_para,
    :sub_paragraph,
    :sub_control,
    :container_type,
    :cell_path
  ]

  embedded_schema do
    field :op, Ecto.Enum, values: [:insert_shape, :set_geometry]

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
      :insert_shape -> validate_insert_shape(changeset)
      :set_geometry -> validate_geometry(changeset)
      _other -> changeset
    end
  end

  defp validate_insert_shape(changeset) do
    if is_binary(get_field(changeset, :page)) do
      cond do
        not is_binary(get_field(changeset, :name)) or get_field(changeset, :name) == "" ->
          add_error(
            changeset,
            :name,
            "insert_shape (slide) requires a \"name\" — the new shape's ref becomes page[<page>]/shape[<name>]"
          )

        not Enum.all?([:x, :y, :w, :h], &is_integer(get_field(changeset, &1))) ->
          add_error(
            changeset,
            :x,
            "insert_shape (slide) requires integer \"x\", \"y\", \"w\", \"h\" in 1/100 mm; use the deck's actual slide size from doc.render, not a hardcoded canvas"
          )

        true ->
          changeset
      end
    else
      cond do
        is_nil(get_field(changeset, :ref)) ->
          add_error(
            changeset,
            :ref,
            "insert_shape requires a \"ref\" (from doc.find) saying where to insert"
          )

        not is_integer(get_field(changeset, :width)) or
            not is_integer(get_field(changeset, :height)) ->
          add_error(
            changeset,
            :width,
            "insert_shape requires integer \"width\" and \"height\" (HWPUNIT, e.g. 8504 ≈ 3cm)"
          )

        true ->
          changeset
      end
    end
  end

  defp validate_geometry(changeset) do
    cond do
      not is_binary(get_field(changeset, :ref)) or get_field(changeset, :ref) == "" ->
        add_error(
          changeset,
          :ref,
          "set_geometry requires a shape \"ref\" (page[<page>]/shape[<name>]) to move/resize"
        )

      not Enum.any?([:x, :y, :w, :h], &is_integer(get_field(changeset, &1))) ->
        add_error(
          changeset,
          :x,
          "set_geometry requires at least one integer of \"x\", \"y\", \"w\", \"h\" (1/100 mm)"
        )

      true ->
        changeset
    end
  end
end
