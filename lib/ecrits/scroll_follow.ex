defmodule Ecrits.ScrollFollow do
  @moduledoc "Embedded state model for server-owned scroll-follow behavior."

  use Ecto.Schema

  import Ecto.Changeset

  alias __MODULE__.Transition

  @primary_key false

  embedded_schema do
    field :pinned?, :boolean, default: true
    field :threshold, :integer, default: 80
  end

  def new(attrs \\ %{}), do: apply_attrs(%__MODULE__{}, attrs)

  def changeset(%__MODULE__{} = state, attrs) when is_map(attrs) do
    state
    |> cast(attrs, [:pinned?, :threshold])
    |> validate_number(:threshold, greater_than_or_equal_to: 0, less_than_or_equal_to: 1_000)
  end

  def distance_changeset(attrs) when is_map(attrs) do
    {%{}, %{distance: :float}}
    |> cast(attrs, [:distance])
    |> validate_required([:distance])
  end

  defdelegate observe(state, attrs), to: Transition

  def encode(%__MODULE__{} = state) do
    Jason.encode!(%{pinned: state.pinned?, threshold: state.threshold})
  end

  defp apply_attrs(state, attrs) do
    changeset = changeset(state, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: state
  end
end
