defmodule Ecrits.Doc.Read.Nearby do
  @moduledoc "Typed `doc.read` neighborhood options shared by server and browser readers."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields [:before, :after, :row, :column, :headers]

  embedded_schema do
    field :before, :integer, default: 2
    field :after, :integer, default: 2
    field :row, :boolean, default: true
    field :column, :boolean, default: false
    field :headers, :boolean, default: true
  end

  @type t :: %__MODULE__{}

  @spec cast(term()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(attrs) do
    attrs = if is_map(attrs), do: attrs, else: %{}

    params = %{
      before: bounded(field(attrs, :before), 2),
      after: bounded(field(attrs, :after), 2),
      row: field(attrs, :row) != false,
      column: field(attrs, :column) == true,
      headers: field(attrs, :headers) != false
    }

    %__MODULE__{}
    |> Ecto.Changeset.cast(params, @fields)
    |> apply_action(:insert)
  end

  @spec cast!(term()) :: t()
  def cast!(attrs) do
    case cast(attrs) do
      {:ok, nearby} -> nearby
      {:error, changeset} -> raise ArgumentError, inspect(changeset.errors)
    end
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = nearby) do
    %{
      "before" => nearby.before,
      "after" => nearby.after,
      "row" => nearby.row,
      "column" => nearby.column,
      "headers" => nearby.headers
    }
  end

  defp field(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp bounded(value, _default) when is_integer(value) and value >= 0, do: min(value, 10)
  defp bounded(_value, default), do: default
end
