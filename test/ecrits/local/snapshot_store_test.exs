defmodule Ecrits.Local.SnapshotStoreTest do
  use ExUnit.Case, async: true

  alias Ecrits.Local.FS
  alias Ecrits.Local.SnapshotStore
  alias Ecrits.Local.Workspace

  test "snapshot storage is an ephemeral compatibility no-op" do
    root = tmp_root()

    assert :ok = SnapshotStore.put(root, "doc-1", 1, %{"body" => "one"})
    assert :ok = SnapshotStore.put(root, "doc-1", 2, %{"body" => "two"})

    assert {:error, :not_found} = SnapshotStore.get(root, "doc-1", 1)
    assert {:ok, []} = SnapshotStore.list(root, "doc-1")
    assert {:ok, nil} = SnapshotStore.latest(root, "doc-1")
    refute File.exists?(Path.join(root, ".ecrits"))
  end

  test "checkpoint returns current file contents without persisting metadata" do
    root = tmp_root()

    assert {:ok, workspace} = Workspace.init(root)
    assert :ok = FS.write(root, "docs/a.txt", "before")

    assert {:ok, checkpoint} =
             Workspace.checkpoint(workspace, "docs/a.txt", %{reason: "pre-save"})

    assert :ok = FS.write(root, "docs/a.txt", "after")

    assert checkpoint["path"] == "docs/a.txt"
    assert checkpoint["reason"] == "pre-save"
    assert checkpoint["content_encoding"] == "base64"
    assert checkpoint["byte_size"] == byte_size("before")
    assert Base.decode64!(checkpoint["content"]) == "before"

    assert {:ok, []} = SnapshotStore.list_checkpoints(root, "docs/a.txt")

    assert {:ok, "after"} = FS.read(root, "docs/a.txt")
    refute File.exists?(Path.join(root, ".ecrits"))
  end

  defp tmp_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-local-snapshot-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
