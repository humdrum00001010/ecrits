defmodule Ecrits.EditorSurfaceState.DocumentViewport do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :scroll_top, :integer, default: 0
    field :scroll_left, :integer, default: 0
  end

  def changeset(viewport, attrs) do
    viewport
    |> cast(attrs, [:scroll_top, :scroll_left])
    |> validate_number(:scroll_top, greater_than_or_equal_to: 0)
    |> validate_number(:scroll_left, greater_than_or_equal_to: 0)
  end
end
