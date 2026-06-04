defmodule Ecrits.Doc.ToolsTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Tools
  alias Ecrits.Test.FakeEhwpRuntime

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)

    {:ok, pool} = start_supervised({Pool, name: nil})

    on_exit(fn -> restore(:ehwp, :runtime, prev) end)
    {:ok, pool: pool}
  end

  defp ctx(pool), do: %{pool: pool}

  describe "tool catalog" do
    test "exposes the common doc.* surface with schemas and risk levels" do
      names = Tools.tools() |> Enum.map(&(&1["namespace"] <> "." <> &1["name"]))

      for n <- ~w(doc.list doc.open doc.outline doc.read doc.find doc.get doc.set
                  doc.edit doc.apply_style doc.save) do
        assert n in names, "expected #{n} in tool catalog"
      end

      for tool <- Tools.tools() do
        assert is_map(tool["inputSchema"])
        assert tool["risk"] in ["read", "write"]
      end
    end

    test "read tools are read risk, write tools are write risk" do
      by_name = Map.new(Tools.tools(), &{&1["namespace"] <> "." <> &1["name"], &1["risk"]})
      assert by_name["doc.read"] == "read"
      assert by_name["doc.find"] == "read"
      assert by_name["doc.list"] == "read"
      assert by_name["doc.set"] == "write"
      assert by_name["doc.edit"] == "write"
      assert by_name["doc.save"] == "write"
    end
  end

  describe "doc.open + doc.list" do
    test "opens a document and lists it", %{pool: pool} do
      assert {:ok, %{"document" => doc_id, "kind" => "hwp"}} =
               Tools.call(ctx(pool), "doc.open", %{
                 "path" => "contract.hwp",
                 "open_opts" => [__text__: "제1조\n제2조 본문"]
               })

      assert {:ok, %{"documents" => docs}} = Tools.call(ctx(pool), "doc.list", %{})
      assert Enum.any?(docs, &(&1["document"] == doc_id))
      entry = Enum.find(docs, &(&1["document"] == doc_id))
      assert entry["kind"] == "hwp"
      assert entry["revision"] == 0
      assert entry["backing"] == "server"
    end
  end

  describe "doc.read / doc.find / doc.outline" do
    setup %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "contract.hwp",
          "open_opts" => [__text__: "제1조 (목적)\n제2조 (계약기간)\n제3조 (대금지급)"]
        })

      {:ok, doc_id: doc_id}
    end

    test "doc.read returns text", %{pool: pool, doc_id: doc_id} do
      assert {:ok, %{"text" => text}} =
               Tools.call(ctx(pool), "doc.read", %{"document" => doc_id})

      assert text =~ "제2조"
    end

    test "doc.find returns matches with opaque refs", %{pool: pool, doc_id: doc_id} do
      assert {:ok, %{"matches" => [m | _]}} =
               Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "pattern" => "제2조"})

      assert String.starts_with?(m["ref"], "hwp:")
    end

    test "doc.outline returns a paragraph tree", %{pool: pool, doc_id: doc_id} do
      assert {:ok, %{"outline" => outline}} =
               Tools.call(ctx(pool), "doc.outline", %{"document" => doc_id})

      assert outline["type"] == "document"
      assert is_list(outline["children"])
    end
  end

  describe "doc.edit replace_text (the supported write path)" do
    test "applies and bumps revision through the editor", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "c.hwp",
          "open_opts" => [__text__: "제2조 본문"]
        })

      assert {:ok, result} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "ARTICLE2"},
                 "base_revision" => 0
               })

      assert result["ok"] == true
      assert result["revision"] == 1

      assert {:ok, %{"text" => text}} = Tools.call(ctx(pool), "doc.read", %{"document" => doc_id})
      assert text =~ "ARTICLE2"
    end

    test "surfaces a conflict from the editor as a structured error", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "c.hwp",
          "open_opts" => [__text__: "제2조 본문"]
        })

      {:ok, _} =
        Tools.call(ctx(pool), "doc.edit", %{
          "document" => doc_id,
          "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "AA"},
          "base_revision" => 0
        })

      assert {:error, %{"conflict" => true, "current_revision" => 1, "snapshot" => snap}} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "BB"},
                 "base_revision" => 0
               })

      assert is_map(snap)
    end
  end

  describe "honest capability errors (headless NIF gaps)" do
    setup %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "c.hwp",
          "open_opts" => [__text__: "제1조 본문"]
        })

      {:ok, doc_id: doc_id}
    end

    test "doc.set is not supported yet", %{pool: pool, doc_id: doc_id} do
      assert {:error, %{"not_supported" => true}} =
               Tools.call(ctx(pool), "doc.set", %{
                 "document" => doc_id,
                 "ref" => "hwp:s0/p0",
                 "props" => %{"Bold" => false}
               })
    end

    test "doc.save is not supported yet", %{pool: pool, doc_id: doc_id} do
      assert {:error, %{"not_supported" => true}} =
               Tools.call(ctx(pool), "doc.save", %{"document" => doc_id})
    end

    test "doc.edit insert_text is not supported yet", %{pool: pool, doc_id: doc_id} do
      assert {:error, %{"not_supported" => true}} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "insert_text", "ref" => "hwp:s0/p0", "text" => "x"}
               })
    end
  end

  describe "dispatch errors" do
    test "unknown tool", %{pool: pool} do
      assert {:error, {:unknown_tool, "doc.bogus"}} = Tools.call(ctx(pool), "doc.bogus", %{})
    end

    test "unknown document", %{pool: pool} do
      assert {:error, %{"error" => "not_found"}} =
               Tools.call(ctx(pool), "doc.read", %{"document" => "ghost"})
    end

    test "missing required document arg", %{pool: pool} do
      assert {:error, _} = Tools.call(ctx(pool), "doc.read", %{})
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
