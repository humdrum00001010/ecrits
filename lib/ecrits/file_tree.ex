defmodule Ecrits.FileTree do
  @moduledoc "Embedded application state for the local workspace file tree."

  use Ecto.Schema

  import Ecto.Changeset

  alias __MODULE__.Transition

  @primary_key false
  @max_path_length 4_096

  embedded_schema do
    field :nodes, {:array, :map}, default: []
    field :expanded_paths, {:array, :string}, default: []
    field :selected_path, :string
  end

  @type t :: %__MODULE__{}

  def new(attrs \\ %{}), do: apply_attrs(%__MODULE__{}, attrs)

  def changeset(%__MODULE__{} = file_tree, attrs) when is_map(attrs) do
    file_tree
    |> cast(attrs, [:nodes, :expanded_paths, :selected_path])
    |> validate_length(:selected_path, max: @max_path_length)
    |> validate_change(:expanded_paths, &validate_paths/2)
    |> validate_change(:nodes, &validate_nodes/2)
  end

  defdelegate put_nodes(file_tree, nodes), to: Transition
  defdelegate select(file_tree, path), to: Transition
  defdelegate toggle(file_tree, path), to: Transition

  def expanded?(%__MODULE__{} = file_tree, path) when is_binary(path) do
    path in file_tree.expanded_paths
  end

  def expanded_path_set(%__MODULE__{} = file_tree) do
    MapSet.new(file_tree.expanded_paths)
  end

  defp apply_attrs(file_tree, attrs) do
    changeset = changeset(file_tree, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: file_tree
  end

  defp validate_paths(:expanded_paths, paths) do
    if Enum.all?(paths, &(is_binary(&1) and String.length(&1) <= @max_path_length)) do
      []
    else
      [expanded_paths: "must contain only valid workspace paths"]
    end
  end

  defp validate_nodes(:nodes, nodes) do
    if Enum.all?(nodes, &valid_node?/1) do
      []
    else
      [nodes: "must contain valid file tree nodes"]
    end
  end

  defp valid_node?(node) when is_map(node) do
    type = Map.get(node, :type, Map.get(node, "type"))
    name = Map.get(node, :name, Map.get(node, "name"))
    path = Map.get(node, :path, Map.get(node, "path"))
    children = Map.get(node, :children, Map.get(node, "children", []))

    type in [:file, :directory, "file", "directory"] and
      valid_path?(name) and valid_path?(path) and is_list(children) and
      Enum.all?(children, &valid_node?/1)
  end

  defp valid_node?(_node), do: false

  defp valid_path?(path), do: is_binary(path) and String.length(path) <= @max_path_length
end
