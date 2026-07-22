defmodule Ecrits.Doc.Op.Layout do
  @moduledoc "Typed column-layout and slide insertion operations."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.Doc.Op.Dispatcher

  @primary_key false
  @fields [
    :op,
    :ref,
    :count,
    :gap,
    :spacing,
    :column_type,
    :same_width,
    :page,
    :name,
    :index,
    :props,
    :section,
    :paragraph,
    :offset
  ]

  embedded_schema do
    field :op, Ecto.Enum, values: [:set_columns, :insert_slide]

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
      :set_columns ->
        if is_integer(get_field(changeset, :count)) and get_field(changeset, :count) > 0 do
          changeset
        else
          add_error(
            changeset,
            :count,
            "set_columns requires an integer \"count\" > 0 (the number of columns)"
          )
        end

      :insert_slide ->
        if is_binary(get_field(changeset, :name)) and get_field(changeset, :name) != "" do
          changeset
        else
          add_error(
            changeset,
            :name,
            "insert_slide requires a \"name\" — the new slide's ref becomes page[<name>]"
          )
        end

      _other ->
        changeset
    end
  end
end
