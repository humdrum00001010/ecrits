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

  describe "apply/2" do
    test "applies an edit and marks the document dirty", %{editor: editor} do
      assert {:ok, applied} =
               Editor.apply(editor, %{op: "replace_text", query: "제2조", replacement: "X2"})

      assert applied.op == "replace_text"
      assert applied.invalidated == []
      assert applied.native == [%{"ok" => true, "replaced" => 1}]
      assert Editor.dirty?(editor)

      assert {:ok, %{text: text}} = Editor.read(editor, [])
      assert text =~ "X2"
    end

    test "serializes multiple writes through the editor mailbox", %{editor: editor} do
      assert {:ok, _} =
               Editor.apply(editor, %{op: "replace_text", query: "제2조", replacement: "AA"})

      assert {:ok, _} =
               Editor.apply(editor, %{op: "replace_text", query: "제3조", replacement: "BB"})

      assert {:ok, %{text: text}} = Editor.read(editor, [])
      assert text =~ "AA"
      assert text =~ "BB"
    end
  end

  describe "broadcast" do
    test "subscribers receive an :applied event after apply", %{editor: editor} do
      :ok = Editor.subscribe(editor)

      assert {:ok, _} =
               Editor.apply(editor, %{op: "replace_text", query: "제1조", replacement: "Z1"})

      assert_receive {:doc_applied, %{op: %{op: "replace_text"}}}
    end
  end

  describe "history" do
    test "records applied ops in order", %{editor: editor} do
      {:ok, _} = Editor.apply(editor, %{op: "replace_text", query: "제1조", replacement: "Z1"})
      {:ok, _} = Editor.apply(editor, %{op: "replace_text", query: "제2조", replacement: "Z2"})

      history = Editor.history(editor)
      assert length(history) == 2
      assert Enum.map(history, & &1.op.replacement) == ["Z1", "Z2"]
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
