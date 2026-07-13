defmodule Ecrits.FileTreeTest do
  use ExUnit.Case, async: true

  alias Ecrits.FileTree

  test "owns nodes, expansion, and selection as one embedded state" do
    nodes = [
      %{
        type: :directory,
        name: "drafts",
        path: "drafts",
        children: [%{type: :file, name: "memo.hwp", path: "drafts/memo.hwp"}]
      }
    ]

    file_tree =
      %{nodes: nodes, expanded_paths: ["drafts"], selected_path: "drafts/memo.hwp"}
      |> FileTree.new()

    assert file_tree.nodes == nodes
    assert FileTree.expanded?(file_tree, "drafts")
    assert file_tree.selected_path == "drafts/memo.hwp"
    assert FileTree.expanded_path_set(file_tree) == MapSet.new(["drafts"])
  end

  test "changeset rejects malformed tree state without a companion validator" do
    changeset =
      FileTree.changeset(%FileTree{}, %{
        nodes: [%{type: :file, name: "missing-path"}],
        expanded_paths: [String.duplicate("x", 4_097)]
      })

    refute changeset.valid?
    assert "must contain valid file tree nodes" in errors_on(changeset).nodes
    assert "must contain only valid workspace paths" in errors_on(changeset).expanded_paths
  end

  test "toggle and select transitions remain schema-backed" do
    file_tree = FileTree.new() |> FileTree.toggle("drafts") |> FileTree.select("drafts/memo.hwp")

    assert FileTree.expanded?(file_tree, "drafts")
    assert file_tree.selected_path == "drafts/memo.hwp"

    file_tree = FileTree.toggle(file_tree, "drafts")
    refute FileTree.expanded?(file_tree, "drafts")
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
