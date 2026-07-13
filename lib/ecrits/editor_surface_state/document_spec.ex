defmodule Ecrits.EditorSurfaceState.DocumentSpec do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :key, :string
    field :name, :string
    field :template_hwp_path, :string
    field :template_hwpx_path, :string
  end

  def changeset(spec, attrs) do
    spec
    |> cast(attrs, [:key, :name, :template_hwp_path, :template_hwpx_path])
    |> validate_required([:key, :name])
    |> validate_length(:key, max: 200)
    |> validate_length(:name, max: 500)
    |> validate_length(:template_hwp_path, max: 4_096)
    |> validate_length(:template_hwpx_path, max: 4_096)
  end
end
