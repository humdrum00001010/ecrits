defmodule Contract.Local.SnapshotStoreTest do
  use ExUnit.Case, async: true

  alias Contract.Local.FS
  alias Contract.Local.Metadata
  alias Contract.Local.SnapshotStore
  alias Contract.Local.Workspace

  test "stores, lists, and loads latest snapshots by revision" do
    root = tmp_root()

    assert :ok = SnapshotStore.put(root, "doc-1", 1, %{"body" => "one"})
    assert :ok = SnapshotStore.put(root, "doc-1", 2, %{"body" => "two"})

    assert {:ok, first} = SnapshotStore.get(root, "doc-1", 1)
    assert first["schema_version"] == Metadata.schema_version()
    assert first["revision"] == 1
    assert first["projection"] == %{"body" => "one"}

    assert {:ok, snapshots} = SnapshotStore.list(root, "doc-1")
    assert Enum.map(snapshots, & &1["revision"]) == [1, 2]

    assert {:ok, latest} = SnapshotStore.latest(root, "doc-1")
    assert latest["revision"] == 2
  end

  test "checkpoint stores pre-save file contents as base64 metadata" do
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

    assert {:ok, [stored]} = SnapshotStore.list_checkpoints(root, "docs/a.txt")
    assert stored["id"] == checkpoint["id"]
    assert Base.decode64!(stored["content"]) == "before"

    assert {:ok, "after"} = FS.read(root, "docs/a.txt")
  end

  defp tmp_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "contract-local-snapshot-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
