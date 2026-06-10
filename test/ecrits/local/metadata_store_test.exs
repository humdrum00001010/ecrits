defmodule Ecrits.Local.MetadataStoreTest do
  use ExUnit.Case, async: true

  alias Ecrits.Local.DocumentRegistry
  alias Ecrits.Local.IndexStore
  alias Ecrits.Local.Metadata
  alias Ecrits.Local.OperationLog
  alias Ecrits.Local.ThreadLog

  test "metadata JSON and JSONL primitives are ephemeral compatibility shims" do
    root = tmp_root()

    assert :ok = Metadata.write_json(root, "custom/state.json", %{title: "Lease"})
    assert {:error, :not_found} = Metadata.read_json(root, "custom/state.json")

    assert :ok = Metadata.append_jsonl(root, "logs/events.jsonl", %{event: "created"})
    assert :ok = Metadata.append_jsonl(root, "logs/events.jsonl", %{event: "updated"})

    assert {:ok, []} = Metadata.read_jsonl(root, "logs/events.jsonl")
    refute File.exists?(Path.join(root, ".ecrits"))
  end

  test "registry, thread log, operation log, and index store do not persist metadata" do
    root = tmp_root()
    File.mkdir_p!(root)

    assert :ok = DocumentRegistry.put(root, "doc-1", %{path: "docs/a.txt", title: "A"})
    assert {:error, :not_found} = DocumentRegistry.get(root, "doc-1")
    assert {:ok, []} = DocumentRegistry.list(root)

    assert :ok = ThreadLog.append(root, "thread-1", %{role: "user", text: "hello"})
    assert :ok = ThreadLog.append(root, "thread-1", %{role: "assistant", text: "hi"})
    assert {:ok, []} = ThreadLog.list(root, "thread-1")

    assert :ok = OperationLog.append(root, "doc-1", %{op: "replace", step: 1})
    assert {:ok, []} = OperationLog.list(root, "doc-1")

    assert :ok =
             IndexStore.put(root, "documents_by_title", %{entries: [%{id: "doc-1", title: "A"}]})

    assert {:error, :not_found} = IndexStore.get(root, "documents_by_title")

    assert {:ok, []} = Ecrits.Local.FS.list(root)
    refute File.exists?(Path.join(root, ".ecrits"))
  end

  defp tmp_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-local-metadata-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
