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

    test "NEVER returns more than the 30-paragraph cap in one call" do
      # 100-paragraph document; a single read must return at most 30 paragraphs.
      text = 1..100 |> Enum.map_join("\n", &"para #{&1}")
      {:ok, handle} = Rhwp.open("big.hwp", __text__: text)
      on_exit(fn -> Rhwp.close(handle) end)

      assert Rhwp.read_paragraph_cap() == 30

      assert {:ok, result} = Rhwp.read(handle, [])
      assert result.size == 30
      assert length(result.paragraphs) == 30
      assert result.total == 100
      assert result.at == 0
      assert result.next_at == 30
      # The chunk text contains exactly 30 paragraphs.
      assert length(String.split(result.text, "\n")) == 30
    end

    test "caps an explicit oversized size request at 30" do
      text = 1..100 |> Enum.map_join("\n", &"para #{&1}")
      {:ok, handle} = Rhwp.open("big.hwp", __text__: text)
      on_exit(fn -> Rhwp.close(handle) end)

      assert {:ok, result} = Rhwp.read(handle, at: 0, size: 1000)
      assert result.size == 30
    end

    test "pages through the document via next_at until the end" do
      text = 1..70 |> Enum.map_join("\n", &"para #{&1}")
      {:ok, handle} = Rhwp.open("big.hwp", __text__: text)
      on_exit(fn -> Rhwp.close(handle) end)

      assert {:ok, p0} = Rhwp.read(handle, at: 0)
      assert p0.size == 30 and p0.next_at == 30

      assert {:ok, p1} = Rhwp.read(handle, at: p0.next_at)
      assert p1.size == 30 and p1.next_at == 60
      assert hd(p1.paragraphs) == "para 31"

      assert {:ok, p2} = Rhwp.read(handle, at: p1.next_at)
      # last page: only 10 paragraphs remain, cursor is nil (end reached).
      assert p2.size == 10
      assert p2.next_at == nil
      assert List.last(p2.paragraphs) == "para 70"
    end
  end

  describe "inspect/2 — reflective property-IR discovery" do
    test "document inspect reports type, interfaces, and children", %{handle: handle} do
      assert {:ok, info} = Rhwp.inspect(handle, nil)
      assert info.type == "document"
      assert "Container" in info.interfaces
      assert is_list(info.children)
      assert length(info.children) >= 3
    end

    test "paragraph inspect reports NATIVE property names (Bold/FontSize/...)", %{handle: handle} do
      ref = Ecrits.Doc.Rhwp.Ref.encode(%{kind: :paragraph, sec: 0, para: 1})
      assert {:ok, info} = Rhwp.inspect(handle, ref)
      assert info.type == "paragraph"
      assert "Bold" in info.properties
      assert "FontSize" in info.properties
      assert "Alignment" in info.properties
    end

    test "char-run inspect reports char native props", %{handle: handle} do
      ref = Ecrits.Doc.Rhwp.Ref.encode(%{kind: :char, sec: 0, para: 1, off: 0, len: 3})
      assert {:ok, info} = Rhwp.inspect(handle, ref)
      assert info.type == "char_run"
      assert "Bold" in info.properties
      assert "Italic" in info.properties
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

  describe "edit/2 — replace_text routes to the native NIF" do
    test "replaces text and is observable on the next read", %{handle: handle} do
      assert {:ok, applied} =
               Rhwp.edit(
                 handle,
                 %{op: "replace_text", query: "제2조", replacement: "ARTICLE_TWO"}
               )

      assert is_map(applied)
      assert {:ok, %{text: text}} = Rhwp.read(handle, [])
      assert text =~ "ARTICLE_TWO"
      refute text =~ "제2조"
    end

    test "insert_text applies through the headless runtime", %{handle: handle} do
      assert {:ok, %{op: "insert_text"}} =
               Rhwp.edit(handle, %{op: "insert_text", ref: "hwp:s0/p1", text: "x"})

      assert {:ok, %{text: text}} = Rhwp.read(handle, [])
      assert text =~ "x"
    end

    test "split applies through the headless runtime", %{handle: handle} do
      assert {:ok, %{op: "split"}} = Rhwp.edit(handle, %{op: "split", ref: "hwp:s0/p1"})
    end
  end

  describe "set/3 — property edit" do
    test "char/paragraph property edits return the runtime capability error", %{
      handle: handle
    } do
      assert {:error, %{kind: "unsupported", message: msg}} =
               Rhwp.set(handle, "hwp:s0/p1", %{"Bold" => false})

      assert msg =~ "set_properties"
    end
  end

  describe "get/3 — property read" do
    test "property read returns the runtime capability error", %{handle: handle} do
      assert {:error, {:unsupported_query, "get_properties"}} =
               Rhwp.get(handle, "hwp:s0/p1", ["Bold"])
    end
  end

  describe "save/2" do
    test "export to bytes succeeds", %{handle: handle} do
      assert {:ok, %{"bytes" => bytes}} = Rhwp.save(handle, [])
      assert bytes > 0
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
