defmodule Ecrits.PathFSWorkspaceTest do
  use ExUnit.Case, async: true

  alias Ecrits.FS
  alias Ecrits.Path, as: WorkspacePath
  alias Ecrits.Workspace

  test "path boundary rejects absolute, traversal, metadata, and symlink paths" do
    root = tmp_root()

    outside =
      Path.join(System.tmp_dir!(), "ecrits-outside-#{System.unique_integer([:positive])}")

    link = Path.join(root, "linked")

    File.mkdir_p!(root)
    File.write!(outside, "outside")
    on_exit(fn -> File.rm(outside) end)

    assert {:error, :absolute_path} = WorkspacePath.join(root, outside)
    assert {:error, :path_traversal} = WorkspacePath.join(root, "../outside.txt")
    assert {:error, :metadata_path} = WorkspacePath.join(root, ".ecrits/config.json")

    assert :ok = File.ln_s(outside, link)
    assert {:error, {:symlink, ^link}} = WorkspacePath.join(root, "linked")
    assert {:error, {:symlink, ^link}} = FS.read(root, "linked")
  end

  test "fs writes atomically and lists without .ecrits metadata" do
    root = tmp_root()

    assert {:ok, workspace} = Workspace.init(root)
    assert :ok = Workspace.write_file(workspace, "docs/a.txt", "first")
    assert :ok = Workspace.write_file(workspace, "docs/a.txt", "second")

    assert {:ok, "second"} = Workspace.read_file(workspace, "docs/a.txt")

    assert {:ok, root_entries} = Workspace.list(workspace)
    assert Enum.map(root_entries, & &1.name) == ["docs"]
    refute File.exists?(Path.join(root, ".ecrits"))

    assert {:ok, doc_entries} = Workspace.list(workspace, "docs")
    assert [%{name: "a.txt", path: "docs/a.txt", type: :file}] = doc_entries

    doc_dir_names = File.ls!(Path.join(root, "docs"))
    refute Enum.any?(doc_dir_names, &String.contains?(&1, ".tmp-"))
  end

  test "fs lists directories first, then files, sorted by name" do
    root = tmp_root()

    assert {:ok, workspace} = Workspace.init(root)
    assert :ok = Workspace.write_file(workspace, "z-file.hwp", "z")
    assert :ok = Workspace.write_file(workspace, "A-file.hwp", "a")
    assert :ok = Workspace.write_file(workspace, "docs/zeta.hwp", "zeta")
    assert :ok = Workspace.write_file(workspace, "Alpha/nested.hwp", "alpha")
    assert :ok = Workspace.write_file(workspace, "beta/nested.hwp", "beta")

    assert {:ok, root_entries} = Workspace.list(workspace)

    assert Enum.map(root_entries, &{&1.type, &1.name}) == [
             {:directory, "Alpha"},
             {:directory, "beta"},
             {:directory, "docs"},
             {:file, "A-file.hwp"},
             {:file, "z-file.hwp"}
           ]
  end

  test "workspace server starts under supervisor with configured root only" do
    root = tmp_root()
    name = :"ecrits_workspace_#{System.unique_integer([:positive])}"

    assert Workspace.children([]) == []
    assert [{Ecrits.Workspace.Server, opts}] = Workspace.children(root: root, name: name)
    assert opts[:root] == root

    start_supervised!({Ecrits.Workspace.Server, root: root, name: name})

    assert Ecrits.Workspace.Server.root(name) == Path.expand(root)
    refute File.exists?(Path.join(root, ".ecrits"))
  end

  defp tmp_root do
    root = Path.join(System.tmp_dir!(), "ecrits-fs-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
