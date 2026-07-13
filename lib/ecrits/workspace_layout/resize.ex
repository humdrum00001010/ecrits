defmodule Ecrits.WorkspaceLayout.Resize do
  @moduledoc """
  Embedded resize transaction and boundary changesets for pointer measurements.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @viewport_min 1_024

  embedded_schema do
    field :panel, Ecto.Enum, values: [:file_tree, :chat_rail]
    field :start_x, :integer
    field :start_width, :integer
    field :viewport_width, :integer
  end

  def changeset(%__MODULE__{} = resize, attrs) when is_map(attrs) do
    resize
    |> cast(integer_params(attrs, [:start_x, :start_width, :viewport_width]), [
      :panel,
      :start_x,
      :start_width,
      :viewport_width
    ])
    |> validate_required([:panel, :start_x, :start_width, :viewport_width])
    |> validate_number(:start_width, greater_than: 0)
    |> validate_number(:viewport_width, greater_than: 0)
    |> update_change(:viewport_width, &max(&1, @viewport_min))
  end

  def build(attrs) when is_map(attrs) do
    changeset = changeset(%__MODULE__{}, attrs)
    if changeset.valid?, do: {:ok, apply_changes(changeset)}, else: :error
  end

  def measurement(attrs, fallback_viewport) when is_map(attrs) do
    changeset =
      {%{}, %{x: :integer, viewport_width: :integer}}
      |> cast(integer_params(attrs, [:x, :viewport_width]), [:x, :viewport_width])
      |> validate_required([:x])
      |> validate_number(:viewport_width, greater_than: 0)

    if changeset.valid? do
      {:ok, get_change(changeset, :x),
       max(get_change(changeset, :viewport_width, fallback_viewport), @viewport_min)}
    else
      :error
    end
  end

  def boundary_width(value, fallback, minimum, maximum) do
    case integer_value(value) do
      nil -> fallback
      width -> width |> max(minimum) |> min(maximum)
    end
  end

  def param(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))

  defp integer_params(attrs, keys) do
    Enum.reduce(keys, attrs, fn key, params ->
      case integer_value(param(params, key)) do
        nil ->
          params

        value ->
          string_key = Atom.to_string(key)
          target_key = if Map.has_key?(params, string_key), do: string_key, else: key
          Map.put(params, target_key, value)
      end
    end)
  end

  defp integer_value(value) do
    changeset =
      {%{}, %{value: :float}}
      |> cast(%{value: value}, [:value])

    if changeset.valid? do
      case get_change(changeset, :value) do
        nil -> nil
        number -> round(number)
      end
    end
  end
end
