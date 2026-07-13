defmodule Ecrits.EditorSurfaceState.DocumentTab do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :id, :string
    field :name, :string
    field :path, :string
  end

  def changeset(tab, attrs) do
    tab
    |> cast(attrs, [:id, :name, :path])
    |> validate_required([:id, :name, :path])
    |> validate_length(:id, max: 500)
    |> validate_length(:name, max: 500)
    |> validate_length(:path, max: 4_096)
  end
end
