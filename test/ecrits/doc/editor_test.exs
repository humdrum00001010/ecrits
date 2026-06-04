defmodule Ecrits.Doc.EditorTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Editor
  alias Ecrits.Test.FakeEhwpRuntime

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)
    on_exit(fn -> restore(:ehwp, :runtime, prev) end)

    {:ok, pid} =
      Editor.start_link(
        document_id: "d_#{System.unique_integer([:positive])}",
        kind: :hwp,
        backend: Ecrits.Doc.Rhwp,
        path: "contract.hwp",
        open_opts: [__text__: "제1조 (목적)\n제2조 (계약기간)\n제3조 (대금지급)"]
      )

    on_exit(fn -> if Process.alive?(pid), do: Editor.stop(pid) end)
    {:ok, editor: pid}
  end

  test "starts at revision 0", %{editor: editor} do
    assert Editor.revision(editor) == 0
  end

  describe "apply/3 — clean path (base_rev == current)" do
    test "applies, bumps revision, and reports it", %{editor: editor} do
      assert {:ok, applied} =
               Editor.apply(
                 editor,
                 %{op: "replace_text", query: "제2조", replacement: "X2"},
                 0
               )

      assert applied.revision == 1
      assert Editor.revision(editor) == 1

      assert {:ok, %{text: text}} = Editor.read(editor, [])
      assert text =~ "X2"
    end

    test "nil base_revision is treated as clean", %{editor: editor} do
      assert {:ok, applied} =
               Editor.apply(editor, %{op: "replace_text", query: "제3조", replacement: "X3"}, nil)

      assert applied.revision == 1
    end
  end

  describe "apply/3 — stale future base_rev" do
    test "rejects a base_revision greater than current", %{editor: editor} do
      assert {:error, {:stale_revision, _}} =
               Editor.apply(editor, %{op: "replace_text", query: "제2조", replacement: "X"}, 5)
    end
  end

  describe "apply/3 — rebase path (base_rev < current)" do
    test "non-overlapping edits rebase cleanly and mark rebased: true", %{editor: editor} do
      # writer A advances rev 0 -> 1 by editing 제2조
      assert {:ok, %{revision: 1}} =
               Editor.apply(editor, %{op: "replace_text", query: "제2조", replacement: "AA"}, 0)

      # writer B arrives with stale base_rev 0, but edits a *different* span (제3조)
      assert {:ok, applied} =
               Editor.apply(editor, %{op: "replace_text", query: "제3조", replacement: "BB"}, 0)

      assert applied.revision == 2
      assert applied.rebased == true

      assert {:ok, %{text: text}} = Editor.read(editor, [])
      assert text =~ "AA"
      assert text =~ "BB"
    end

    test "overlapping edits to the same span return a conflict with a snapshot", %{editor: editor} do
      assert {:ok, %{revision: 1}} =
               Editor.apply(editor, %{op: "replace_text", query: "제2조", replacement: "AA"}, 0)

      # writer B targets the *same* span with the now-stale base_rev
      assert {:error, {:conflict, current_revision, snapshot}} =
               Editor.apply(editor, %{op: "replace_text", query: "제2조", replacement: "BB"}, 0)

      assert current_revision == 1
      assert is_map(snapshot)
      assert snapshot.revision == 1
      # state did not advance on conflict
      assert Editor.revision(editor) == 1
    end
  end

  describe "broadcast" do
    test "subscribers receive an :applied event after a clean apply", %{editor: editor} do
      :ok = Editor.subscribe(editor)

      assert {:ok, %{revision: 1}} =
               Editor.apply(editor, %{op: "replace_text", query: "제1조", replacement: "Z1"}, 0)

      assert_receive {:doc_applied, %{revision: 1, op: %{op: "replace_text"}}}
    end
  end

  describe "history / revoke" do
    test "history records applied ops with revisions", %{editor: editor} do
      {:ok, _} = Editor.apply(editor, %{op: "replace_text", query: "제1조", replacement: "Z1"}, 0)
      {:ok, _} = Editor.apply(editor, %{op: "replace_text", query: "제2조", replacement: "Z2"}, 1)

      history = Editor.history(editor)
      assert length(history) == 2
      assert Enum.map(history, & &1.revision) == [1, 2]
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
