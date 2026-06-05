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

  describe "doc.read 30-paragraph hard cap (the user's explicit limit)" do
    test "a single doc.read returns at most 30 paragraphs + a continuation cursor", %{pool: pool} do
      text = 1..100 |> Enum.map_join("\n", &"para #{&1}")

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "big.hwp", "open_opts" => [__text__: text]})

      assert {:ok, page0} = Tools.call(ctx(pool), "doc.read", %{"document" => doc_id})
      assert page0["size"] == 30
      assert page0["total"] == 100
      assert page0["next_at"] == 30
      assert page0["capped"] == 30
      assert length(page0["paragraphs"]) == 30

      # Paging with the cursor advances and stays within the cap.
      assert {:ok, page1} =
               Tools.call(ctx(pool), "doc.read", %{"document" => doc_id, "at" => page0["next_at"]})

      assert page1["size"] == 30
      assert page1["at"] == 30
    end

    test "an oversized explicit size is clamped to 30", %{pool: pool} do
      text = 1..80 |> Enum.map_join("\n", &"para #{&1}")

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "big.hwp", "open_opts" => [__text__: text]})

      assert {:ok, page} =
               Tools.call(ctx(pool), "doc.read", %{
                 "document" => doc_id,
                 "at" => 0,
                 "size" => 999
               })

      assert page["size"] == 30
    end

    test "the read tool schema advertises the cap" do
      read = Enum.find(Tools.tools(), &(&1["name"] == "read"))
      assert read["inputSchema"]["properties"]["size"]["maximum"] == 30
      assert read["description"] =~ "30"
    end
  end

  describe "doc.inspect — reflective property-IR" do
    setup %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "c.hwp",
          "open_opts" => [__text__: "제1조 (목적)\n제2조 (계약기간)\n제3조 (대금지급)"]
        })

      {:ok, doc_id: doc_id}
    end

    test "document inspect returns native property names + children", %{pool: pool, doc_id: doc_id} do
      assert {:ok, info} = Tools.call(ctx(pool), "doc.inspect", %{"document" => doc_id})
      assert info["type"] == "document"
      assert is_list(info["children"])
    end

    test "char-ref inspect lists native props (Bold etc.)", %{pool: pool, doc_id: doc_id} do
      {:ok, %{"matches" => [m | _]}} =
        Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "pattern" => "제2조"})

      assert {:ok, info} =
               Tools.call(ctx(pool), "doc.inspect", %{"document" => doc_id, "ref" => m["ref"]})

      assert "Bold" in info["properties"]
    end
  end

  describe "doc.get / doc.set round-trip surface (property IR)" do
    setup %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "c.hwp",
          "open_opts" => [__text__: "제2조 본문"]
        })

      {:ok, doc_id: doc_id}
    end

    test "get + set route through the property-IR but are honestly capability-gated", %{
      pool: pool,
      doc_id: doc_id
    } do
      assert {:error, %{"not_supported" => true}} =
               Tools.call(ctx(pool), "doc.get", %{
                 "document" => doc_id,
                 "ref" => "hwp:s0/p0",
                 "props" => ["Bold"]
               })

      assert {:error, %{"not_supported" => true}} =
               Tools.call(ctx(pool), "doc.set", %{
                 "document" => doc_id,
                 "ref" => "hwp:s0/p0",
                 "props" => %{"Bold" => false}
               })
    end
  end

  describe "doc.context — active document + cursor" do
    test "reports the available active-doc state (cursor wiring is a server-side TODO)", %{
      pool: pool
    } do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "c.hwp",
          "open_opts" => [__text__: "제1조 본문"]
        })

      assert {:ok, ctx_result} = Tools.call(ctx(pool), "doc.context", %{})
      assert ctx_result["active_document"] == doc_id
      assert ctx_result["cursor"] == nil
      assert ctx_result["selection"] == nil
      assert ctx_result["cursor_reporting"] == "todo:browser_wiring"
    end

    test "context + inspect are exposed in the tool catalog as read tools" do
      by_name = Map.new(Tools.tools(), &{&1["namespace"] <> "." <> &1["name"], &1["risk"]})
      assert by_name["doc.context"] == "read"
      assert by_name["doc.inspect"] == "read"
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
