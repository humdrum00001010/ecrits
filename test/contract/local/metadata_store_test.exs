defmodule Contract.Local.MetadataStoreTest do
  use ExUnit.Case, async: true

  alias Contract.Local.DocumentRegistry
  alias Contract.Local.IndexStore
  alias Contract.Local.Metadata
  alias Contract.Local.OperationLog
  alias Contract.Local.ThreadLog

  test "metadata JSON and JSONL primitives add schema_version" do
    root = tmp_root()

    assert :ok = Metadata.write_json(root, "custom/state.json", %{title: "Lease"})
    assert {:ok, state} = Metadata.read_json(root, "custom/state.json")
    assert state["schema_version"] == Metadata.schema_version()
    assert state["title"] == "Lease"

    assert :ok = Metadata.append_jsonl(root, "logs/events.jsonl", %{event: "created"})
    assert :ok = Metadata.append_jsonl(root, "logs/events.jsonl", %{event: "updated"})

    assert {:ok, events} = Metadata.read_jsonl(root, "logs/events.jsonl")
    assert Enum.map(events, & &1["event"]) == ["created", "updated"]
    assert Enum.all?(events, &(&1["schema_version"] == Metadata.schema_version()))
  end

  test "registry, thread log, operation log, and index store use hidden metadata" do
    root = tmp_root()

    assert :ok = DocumentRegistry.put(root, "doc-1", %{path: "docs/a.txt", title: "A"})
    assert {:ok, doc} = DocumentRegistry.get(root, "doc-1")
    assert doc["id"] == "doc-1"
    assert doc["schema_version"] == Metadata.schema_version()

    assert {:ok, [listed]} = DocumentRegistry.list(root)
    assert listed["path"] == "docs/a.txt"

    assert :ok = ThreadLog.append(root, "thread-1", %{role: "user", text: "hello"})
    assert :ok = ThreadLog.append(root, "thread-1", %{role: "assistant", text: "hi"})
    assert {:ok, messages} = ThreadLog.list(root, "thread-1")
    assert Enum.map(messages, & &1["role"]) == ["user", "assistant"]

    assert :ok = OperationLog.append(root, "doc-1", %{op: "replace", revision: 1})
    assert {:ok, [operation]} = OperationLog.list(root, "doc-1")
    assert operation["document_id"] == "doc-1"
    assert operation["revision"] == 1

    assert :ok =
             IndexStore.put(root, "documents_by_title", %{entries: [%{id: "doc-1", title: "A"}]})

    assert {:ok, index} = IndexStore.get(root, "documents_by_title")
    assert index["name"] == "documents_by_title"
    assert [%{"id" => "doc-1"}] = index["entries"]

    assert {:ok, []} = Contract.Local.FS.list(root)
  end

  defp tmp_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "contract-local-metadata-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
