defmodule Ecrits.DocumentSessionTest do
  use ExUnit.Case, async: false

  alias Ecrits.Document

  test "opens, reads, checkpoints, saves, and closes local document session" do
    root = tmp_root()
    path = Path.join([root, "docs", "a.hwpx"])
    before = fixture_hwpx()
    draft = fixture_hwpx()
    after_bytes = fixture_hwpx()

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, before)

    assert {:ok, doc} = Document.open(root, "docs/a.hwpx")
    assert {:ok, ^before} = Document.read(doc)

    assert {:ok, checkpointed, checkpoint_meta} =
             Document.checkpoint(doc, draft, %{reason: "agent"})

    assert checkpoint_meta["kind"] == "checkpoint"
    assert {:ok, ^draft} = Document.read(checkpointed)
    assert File.read!(path) == before

    assert {:ok, saved, save_meta} = Document.save(checkpointed, after_bytes, %{reason: "save"})
    assert save_meta["kind"] == "save"
    assert {:ok, ^after_bytes} = Document.read(saved)
    assert File.read!(path) == after_bytes

    refute File.exists?(Path.join(root, ".ecrits"))

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
        "ecrits-document-session-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp fixture_hwpx do
    File.read!("test/fixtures/hwpx/real_contract.hwpx")
  end
end
