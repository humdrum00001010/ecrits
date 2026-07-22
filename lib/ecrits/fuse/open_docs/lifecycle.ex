defmodule Ecrits.Fuse.OpenDocs.Lifecycle do
  @moduledoc "Typed committed and pending lifecycle state for one opened projection."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields [:bytes, :dirty_owner, :generation, :in_flight, :pending]

  embedded_schema do
    field :bytes, :binary
    field :dirty_owner, :any, virtual: true
    field :generation, :integer, default: 0
    field :in_flight, :any, virtual: true
    field :pending, :any, virtual: true
  end

  @type t :: %__MODULE__{}

  @spec cast(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(attrs) when is_map(attrs) do
    params =
      Map.new(@fields, fn field ->
        {field, Map.get(attrs, field, Map.get(attrs, Atom.to_string(field)))}
      end)

    %__MODULE__{}
    |> Ecto.Changeset.cast(params, @fields, empty_values: [])
    |> validate_required([:bytes])
    |> validate_number(:generation, greater_than_or_equal_to: 0)
    |> validate_change(:dirty_owner, &validate_optional_map/2)
    |> validate_change(:in_flight, &validate_optional_map/2)
    |> validate_change(:pending, &validate_optional_map/2)
    |> apply_action(:insert)
  end

  @spec cast!(map()) :: t()
  def cast!(attrs) do
    case cast(attrs) do
      {:ok, lifecycle} -> lifecycle
      {:error, changeset} -> raise ArgumentError, inspect(changeset.errors)
    end
  end

  defp validate_optional_map(_field, nil), do: []
  defp validate_optional_map(_field, value) when is_map(value), do: []
  defp validate_optional_map(field, _value), do: [{field, "must be a map or nil"}]
end
