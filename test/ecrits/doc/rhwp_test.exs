defmodule Ecrits.Doc.RhwpTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Rhwp
  alias Ecrits.Test.FakeEhwpRuntime

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)
    on_exit(fn -> restore(:ehwp, :runtime, prev) end)

    {:ok, handle} =
      Rhwp.open("contract.hwp",
        __text__: "제1조 (목적)\n제2조 (계약기간) 본 계약의 기간은\n제3조 (대금지급)"
      )

    on_exit(fn -> Rhwp.close(handle) end)
    {:ok, handle: handle}
  end

  test "kind/0 is :hwp" do
    assert Rhwp.kind() == :hwp
  end

  describe "read/2" do
    test "returns document text and metadata", %{handle: handle} do
      assert {:ok, result} = Rhwp.read(handle, [])
      assert result.text =~ "제2조"
      assert is_integer(result.size)
    end
  end

  describe "find/3" do
    test "returns matches with opaque refs", %{handle: handle} do
      assert {:ok, [match | _]} = Rhwp.find(handle, "제2조", [])
      assert match.text =~ "제2조"
      assert is_binary(match.ref)
      assert String.starts_with?(match.ref, "hwp:")
    end

    test "empty list when not found", %{handle: handle} do
      assert {:ok, []} = Rhwp.find(handle, "존재하지않는문구", [])
    end
  end

  describe "outline/3" do
    test "builds a paragraph tree from document text", %{handle: handle} do
      assert {:ok, tree} = Rhwp.outline(handle, nil, [])
      assert tree.type == "document"
      assert is_list(tree.children)
      assert length(tree.children) >= 3

      first = hd(tree.children)
      assert first.type == "paragraph"
      assert is_binary(first.ref)
      assert {:ok, %{kind: :paragraph}} = Ecrits.Doc.Rhwp.Ref.decode(first.ref)
    end
  end

  describe "edit/3 — replace_text routes to the native NIF" do
    test "replaces text and is observable on the next read", %{handle: handle} do
      assert {:ok, applied} =
               Rhwp.edit(
                 handle,
                 %{op: "replace_text", query: "제2조", replacement: "ARTICLE_TWO"},
                 nil
               )

      assert is_map(applied)
      assert {:ok, %{text: text}} = Rhwp.read(handle, [])
      assert text =~ "ARTICLE_TWO"
      refute text =~ "제2조"
    end

    test "insert_text is not supported by the headless NIF yet", %{handle: handle} do
      assert {:error, {:not_supported, _}} =
               Rhwp.edit(handle, %{op: "insert_text", ref: "hwp:s0/p1", text: "x"}, nil)
    end

    test "split is not supported by the headless NIF yet", %{handle: handle} do
      assert {:error, {:not_supported, _}} =
               Rhwp.edit(handle, %{op: "split", ref: "hwp:s0/p1"}, nil)
    end
  end

  describe "set/4 — property edit" do
    test "char/paragraph property edits are not supported by the headless NIF yet", %{
      handle: handle
    } do
      assert {:error, {:not_supported, _}} =
               Rhwp.set(handle, "hwp:s0/p1", %{"Bold" => false}, nil)
    end
  end

  describe "get/3 — property read" do
    test "property read is not supported by the headless NIF yet", %{handle: handle} do
      assert {:error, {:not_supported, _}} = Rhwp.get(handle, "hwp:s0/p1", ["Bold"])
    end
  end

  describe "apply_style/3" do
    test "named style is not supported by the headless NIF yet", %{handle: handle} do
      assert {:error, {:not_supported, _}} = Rhwp.apply_style(handle, "hwp:s0/p1", "Heading 1")
    end
  end

  describe "save/2" do
    test "export to bytes is not supported by the headless NIF yet", %{handle: handle} do
      assert {:error, {:not_supported, _}} = Rhwp.save(handle, [])
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
