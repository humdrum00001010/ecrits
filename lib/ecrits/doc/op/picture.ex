defmodule Ecrits.Doc.Op.Picture do
  @moduledoc "Typed picture insertion transport."

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
    :props
  ]

  embedded_schema do
    field :op, Ecto.Enum, values: [:insert_picture]

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
    |> validate_slide_picture()
  end

  def dump(%__MODULE__{} = operation), do: Dispatcher.dump_fields(operation, @fields)

  defp validate_slide_picture(changeset) do
    if is_binary(get_field(changeset, :page)) do
      cond do
        not is_binary(get_field(changeset, :src) || get_field(changeset, :path)) ->
          add_error(
            changeset,
            :src,
            "insert_picture (slide) requires \"src\" — the image file path to embed"
          )

        not is_binary(get_field(changeset, :name)) or get_field(changeset, :name) == "" ->
          add_error(
            changeset,
            :name,
            "insert_picture (slide) requires a \"name\" — the ref becomes page[<page>]/shape[<name>]"
          )

        not Enum.all?([:x, :y, :w, :h], &is_integer(get_field(changeset, &1))) ->
          add_error(
            changeset,
            :x,
            "insert_picture (slide) requires integer \"x\", \"y\", \"w\", \"h\" in 1/100 mm"
          )

        true ->
          changeset
      end
    else
      changeset
    end
  end
end
