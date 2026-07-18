defmodule Ecrits.ToolbarMenu do
  @moduledoc """
  Embedded render model for one quick-toolbar popover menu (anchor trigger +
  popover panel). Gathers the per-menu identity and styling the editor surface
  used to pass as parallel component attributes.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :id, :string
    field :label, :string
    field :title, :string
    field :trigger_class, {:array, :string}, default: []
    field :menu_class, {:array, :string}, default: []
  end

  def new(attrs \\ %{}) do
    menu = %__MODULE__{}
    changeset = changeset(menu, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: menu
  end

  def changeset(%__MODULE__{} = menu, attrs) do
    menu
    |> cast(attrs, [:id, :label, :title, :trigger_class, :menu_class])
    |> validate_required([:id, :label, :trigger_class, :menu_class])
  end
end
