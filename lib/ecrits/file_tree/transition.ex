defmodule Ecrits.FileTree.Transition do
  @moduledoc false

  import Ecto.Changeset

  alias Ecrits.FileTree

  def put_nodes(%FileTree{} = file_tree, nodes) when is_list(nodes) do
    transition(file_tree, %{nodes: nodes})
  end

  def select(%FileTree{} = file_tree, path) when is_binary(path) or is_nil(path) do
    transition(file_tree, %{selected_path: path})
  end

  def toggle(%FileTree{} = file_tree, path) when is_binary(path) do
    expanded_paths =
      if path in file_tree.expanded_paths do
        List.delete(file_tree.expanded_paths, path)
      else
        [path | file_tree.expanded_paths]
      end

    transition(file_tree, %{expanded_paths: expanded_paths})
  end

  defp transition(file_tree, attrs) do
    changeset = FileTree.changeset(file_tree, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: file_tree
  end
end
