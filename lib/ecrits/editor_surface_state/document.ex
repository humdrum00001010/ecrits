defmodule Ecrits.EditorSurfaceState.Document do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :id, :string
    field :workspace_root, :string
    field :relative_path, :string
    field :path, :string
    field :format, :string
    field :byte_size, :integer
    field :sha256, :string
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [:id, :workspace_root, :relative_path, :path, :format, :byte_size, :sha256])
    |> validate_required([:id, :relative_path, :format])
    |> validate_length(:id, max: 500)
    |> validate_length(:relative_path, max: 4_096)
    |> validate_length(:path, max: 4_096)
    |> validate_length(:format, max: 20)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
  end
end
