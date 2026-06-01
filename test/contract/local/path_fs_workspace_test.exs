defmodule Contract.Local.PathFSWorkspaceTest do
  use ExUnit.Case, async: true

  alias Contract.Local.FS
  alias Contract.Local.Path, as: LocalPath
  alias Contract.Local.Workspace

  test "path boundary rejects absolute, traversal, metadata, and symlink paths" do
    root = tmp_root()

    outside =
      Path.join(System.tmp_dir!(), "contract-local-outside-#{System.unique_integer([:positive])}")

    link = Path.join(root, "linked")

    File.mkdir_p!(root)
    File.write!(outside, "outside")
    on_exit(fn -> File.rm(outside) end)

    assert {:error, :absolute_path} = LocalPath.join(root, outside)
    assert {:error, :path_traversal} = LocalPath.join(root, "../outside.txt")
    assert {:error, :metadata_path} = LocalPath.join(root, ".contract/config.json")

    assert :ok = File.ln_s(outside, link)
    assert {:error, {:symlink, ^link}} = LocalPath.join(root, "linked")
    assert {:error, {:symlink, ^link}} = FS.read(root, "linked")
  end

  test "fs writes atomically and lists without .contract metadata" do
    root = tmp_root()

    assert {:ok, workspace} = Workspace.init(root)
    assert :ok = Workspace.write_file(workspace, "docs/a.txt", "first")
    assert :ok = Workspace.write_file(workspace, "docs/a.txt", "second")

    assert {:ok, "second"} = Workspace.read_file(workspace, "docs/a.txt")

    assert {:ok, root_entries} = Workspace.list(workspace)
    assert Enum.map(root_entries, & &1.name) == ["docs"]

    assert {:ok, doc_entries} = Workspace.list(workspace, "docs")
    assert [%{name: "a.txt", path: "docs/a.txt", type: :file}] = doc_entries

    doc_dir_names = File.ls!(Path.join(root, "docs"))
    refute Enum.any?(doc_dir_names, &String.contains?(&1, ".tmp-"))
  end

  test "workspace server starts under supervisor with configured root only" do
    root = tmp_root()
    name = :"contract_local_workspace_#{System.unique_integer([:positive])}"

    assert Workspace.children([]) == []
    assert [{Contract.Local.Workspace.Server, opts}] = Workspace.children(root: root, name: name)
    assert opts[:root] == root

    start_supervised!({Contract.Local.Workspace.Server, root: root, name: name})

    assert Contract.Local.Workspace.Server.root(name) == Path.expand(root)
    assert File.dir?(Path.join(root, ".contract"))
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "contract-local-fs-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
