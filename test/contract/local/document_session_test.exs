defmodule Contract.Local.DocumentSessionTest do
  use ExUnit.Case, async: false

  alias Contract.Local.Document
  alias Contract.Local.SnapshotStore

  test "opens, reads, checkpoints, saves, and closes local document session" do
    root = tmp_root()
    path = Path.join([root, "docs", "a.hwpx"])
    before = fixture_hwpx()
    draft = fixture_hwpx()
    after_bytes = fixture_hwpx()

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, before)

    assert {:ok, doc} = Document.open(root, "docs/a.hwpx")
    assert doc.revision == 0
    assert {:ok, ^before} = Document.read(doc)

    assert {:ok, checkpointed, checkpoint_meta} =
             Document.checkpoint(doc, draft, %{reason: "agent"})

    assert checkpointed.revision == 1
    assert checkpoint_meta["kind"] == "checkpoint"
    assert {:ok, ^before} = Document.read(checkpointed)
    assert File.read!(path) == before

    assert {:ok, saved, save_meta} = Document.save(checkpointed, after_bytes, %{reason: "save"})
    assert saved.revision == 2
    assert save_meta["kind"] == "save"
    assert {:ok, ^after_bytes} = Document.read(saved)
    assert File.read!(path) == after_bytes

    assert {:ok, latest} = SnapshotStore.latest(root, saved.id)
    assert latest["revision"] == 2
    assert latest["projection"]["sha256"] == Document.sha256(after_bytes)

    pid = Document.whereis(saved.id)
    assert is_pid(pid)
    ref = Process.monitor(pid)
    assert :ok = Document.close(saved)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert Document.whereis(saved.id) == nil
  end

  defp tmp_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "contract-local-document-session-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp fixture_hwpx do
    File.read!("test/fixtures/hwpx/real_contract.hwpx")
  end
end
