defmodule Ecrits.Doc.ToolsTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Tools
  alias Ecrits.Fuse.DocFs
  alias Ecrits.Fuse.DocMount
  alias Ecrits.Fuse.OpenDocs
  alias Ecrits.Test.FakeEhwpRuntime
  alias Ecrits.Workspace.Session

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)

    {:ok, pool} = start_supervised({Pool, name: nil})
    # A unique per-test workspace path keys the `Workspace.Session` that holds
    # per-agent ownership (invariant 2) since Phase 3. Started lazily by the
    # ownership calls; killed on exit.
    path = Path.join(System.tmp_dir!(), "ws_tools_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if pid = Session.whereis(path), do: Process.exit(pid, :kill)
      restore(:ehwp, :runtime, prev)
    end)

    {:ok, pool: pool, path: path}
  end

  defp ctx(pool), do: %{pool: pool}

  # Absolute scratch path for docs a test SAVES — a bare relative path would
  # resolve against CWD and litter the repo root (c.hwp & friends). The file,
  # if written, is removed when the test exits.
  defp tmp_doc_path(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ecrits_tools_test_#{System.unique_integer([:positive])}_#{name}"
      )

    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
    path
  end

  describe "tool catalog" do
    test "exposes the common doc.* surface with schemas and risk levels" do
      names = Tools.tools() |> Enum.map(&(&1["namespace"] <> "." <> &1["name"]))

      for n <- ~w(doc.context doc.list doc.open doc.open_doc doc.close_doc
                  doc.create doc.read doc.find doc.get doc.set doc.edit
                  doc.save doc.render) do
        assert n in names, "expected #{n} in tool catalog"
      end

      # The consolidated surface is thirteen tools: the original doc.* surface,
      # doc.render, plus the VFS mount-control pair doc.open_doc/doc.close_doc.
      # The former doc.inspect and doc.apply_style are folded into doc.get /
      # doc.set.
      assert "doc.read_table" not in names
      assert "doc.inspect" not in names
      assert "doc.apply_style" not in names
      assert length(names) == 13

      find_schema = Enum.find(Tools.tools(), &(&1["name"] == "find"))["inputSchema"]
      assert "formula_cell" in get_in(find_schema, ["properties", "type", "enum"])

      create_tool = Enum.find(Tools.tools(), &(&1["name"] == "create"))
      assert create_tool["description"] =~ "doc.open never creates files"
      assert create_tool["description"] =~ "explicitly asks for a new/output document"
      assert create_tool["description"] =~ "never for read-only read/inspect/summarize tasks"
      assert create_tool["annotations"] == %{"readOnlyHint" => false}

      open_doc_tool = Enum.find(Tools.tools(), &(&1["name"] == "open_doc"))
      assert open_doc_tool["description"] =~ "primary editing surface"
      refute open_doc_tool["description"] =~ "JSONL"

      close_doc_tool = Enum.find(Tools.tools(), &(&1["name"] == "close_doc"))
      assert close_doc_tool["description"] =~ "explicit unmount requests only"
      assert close_doc_tool["description"] =~ "closing mid-turn removes the file"

      for tool <- Tools.tools() do
        assert is_map(tool["inputSchema"])
        assert tool["risk"] in ["read", "write"]
      end
    end

    test "MCP initialization does not inject authoring recipes" do
      {:ok, state} = Ecrits.Doc.MCPServer.init([])

      assert {:ok, initialized, _state} = Ecrits.Doc.MCPServer.handle_initialize(%{}, state)
      refute Map.has_key?(initialized, :instructions)
    end

    test "read tools are read risk, write tools are write risk" do
      by_name = Map.new(Tools.tools(), &{&1["namespace"] <> "." <> &1["name"], &1["risk"]})
      assert by_name["doc.read"] == "read"
      assert by_name["doc.find"] == "read"
      assert by_name["doc.list"] == "read"
      assert by_name["doc.open_doc"] == "read"
      assert by_name["doc.close_doc"] == "read"
      assert by_name["doc.set"] == "write"
      assert by_name["doc.edit"] == "write"
      assert by_name["doc.save"] == "write"
    end

    test "doc.edit insert_picture schema exposes image source and sizing fields" do
      edit = Enum.find(Tools.tools(), &(&1["namespace"] <> "." <> &1["name"] == "doc.edit"))
      props = get_in(edit, ["inputSchema", "properties", "op", "properties"])

      assert props["src"]["type"] == "string"
      assert props["src"]["description"] =~ "insert_picture"
      assert props["ref"]["description"] =~ "sheet[Sheet1]/cell[A1]"
      assert props["width"]["description"] =~ "insert_picture"
      assert props["height"]["description"] =~ "insert_picture"
      assert props["w"]["description"] =~ "insert_picture"
      assert props["h"]["description"] =~ "insert_picture"
      assert props["name"]["description"] =~ "XLSX"
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
      assert entry["backing"] == "server"
    end
  end

  describe "doc.create {from} — clone a template" do
    test "byte-copies a template file to the new path and opens the clone", %{pool: pool} do
      dir = Path.join(System.tmp_dir!(), "ecrits_clone_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      source = Path.join(dir, "template.hwp")
      clone = Path.join(dir, "nested/clone.hwp")
      bytes = :crypto.strong_rand_bytes(2048)
      File.write!(source, bytes)
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, %{"document" => doc_id, "kind" => "hwp", "cloned_from" => ^source}} =
               Tools.call(ctx(pool), "doc.create", %{"path" => clone, "from" => source})

      # The clone is a BYTE-IDENTICAL copy (inherits all of the template's bytes,
      # hence all of its formatting), written even into a not-yet-existing dir.
      assert File.read!(clone) == bytes
      # And it is opened as an editable doc whose save target is `clone` (it shows
      # up in the open-documents list — there is no global active to set anymore).
      assert {:ok, %{"documents" => docs}} = Tools.call(ctx(pool), "doc.list", %{})
      assert Enum.any?(docs, &(&1["document"] == doc_id))

      assert {:ok, info} = Pool.info(pool, doc_id)
      assert info.path == clone
    end

    test "resolves `from` as an already-open document id", %{pool: pool} do
      dir = Path.join(System.tmp_dir!(), "ecrits_clone_id_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      source = Path.join(dir, "open_template.hwp")
      clone = Path.join(dir, "clone_from_id.hwp")
      bytes = :crypto.strong_rand_bytes(1024)
      File.write!(source, bytes)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, %{"document" => template_id}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => source})

      assert {:ok, %{"document" => clone_id, "cloned_from" => ^source}} =
               Tools.call(ctx(pool), "doc.create", %{"path" => clone, "from" => template_id})

      assert clone_id != template_id
      assert File.read!(clone) == bytes
    end

    test "an unknown template (not an open id, not a file) is a structured error", %{pool: pool} do
      assert {:error, %{"error" => "template_not_found", "from" => "/no/such/template.hwp"}} =
               Tools.call(ctx(pool), "doc.create", %{
                 "path" => Path.join(System.tmp_dir!(), "x.hwp"),
                 "from" => "/no/such/template.hwp"
               })
    end

    test "without `from` it still routes to the blank-create path (regression)", %{pool: pool} do
      # The `from` branch must not disturb the blank path: a create with no `from`
      # goes straight to Pool.create (blank engine template), exactly as before.
      # The in-process fake runtime has no engine `new/0`, so the blank path
      # surfaces the engine's create-unsupported error here — the point is that
      # the NO-`from` call reaches Pool.create unchanged (not the clone branch).
      result =
        Tools.call(ctx(pool), "doc.create", %{
          "path" => Path.join(System.tmp_dir!(), "blank_#{System.unique_integer()}.hwp")
        })

      case result do
        {:ok, %{"document" => doc_id}} ->
          assert {:ok, %{"documents" => docs}} = Tools.call(ctx(pool), "doc.list", %{})
          assert Enum.any?(docs, &(&1["document"] == doc_id))

        {:error, %{"error" => err}} ->
          # Reached the blank engine-create path (no clone/template error).
          assert err =~ "create_unsupported" or err =~ "open_failed"
          refute err =~ "template_not_found"
      end
    end

    test "blank create infers Office kind from .pptx path instead of writing HWP bytes",
         %{pool: pool} do
      path = Path.join(System.tmp_dir!(), "scratch_#{System.unique_integer()}.pptx")
      File.rm(path)
      on_exit(fn -> File.rm(path) end)

      # A no-deck .pptx create routes to the Office factory-blank path (the
      # IR-direct from-scratch authoring seed), never the HWP engine. With the
      # UNO arm built it yields a real blank pptx on disk; without it, a
      # structured office create error — in neither case HWP bytes.
      case Tools.call(ctx(pool), "doc.create", %{"path" => path}) do
        {:ok, %{"kind" => "pptx", "path" => ^path}} ->
          assert {:ok, "PK" <> _} = File.read(path)

        {:error, %{"error" => err}} ->
          assert err =~ "create_failed" or err =~ "create_unsupported"
          refute File.exists?(path)
      end
    end

    test "the create tool schema advertises the `from` clone param" do
      create = Enum.find(Tools.tools(), &(&1["name"] == "create"))
      assert Map.has_key?(create["inputSchema"]["properties"], "from")
      assert create["description"] =~ "clones"
    end
  end

  describe "doc.read / doc.find" do
    setup %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "contract.hwp",
          "open_opts" => [__text__: "제1조 (목적)\n제2조 (계약기간)\n제3조 (대금지급)"]
        })

      {:ok, doc_id: doc_id}
    end

    test "doc.read clarifies a doc.find anchor", %{pool: pool, doc_id: doc_id} do
      {:ok, %{"matches" => [match | _]}} =
        Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "pattern" => "제2조"})

      assert {:ok, %{"target" => target, "elements" => elements, "text" => text}} =
               Tools.call(ctx(pool), "doc.read", %{
                 "document" => doc_id,
                 "ref" => match["ref"],
                 "nearby" => %{"before" => 1, "after" => 1}
               })

      assert text =~ "제2조"
      assert target["text"] =~ "제2조"
      assert text == target["text"]
      refute text =~ "제1조"
      refute text =~ "제3조"
      assert length(elements) == 3
    end

    test "doc.read accepts a text-match span ref and resolves to its paragraph", %{
      pool: pool,
      doc_id: doc_id
    } do
      assert {:ok, %{"ref" => ref, "resolved_ref" => resolved_ref, "target" => target}} =
               Tools.call(ctx(pool), "doc.read", %{
                 "document" => doc_id,
                 "ref" => "hwp:s0/p1/c0+3",
                 "nearby" => %{"before" => 0, "after" => 0}
               })

      assert ref == "hwp:s0/p1/c0+3"
      assert resolved_ref != ref
      assert target["text"] =~ "제2조"
    end

    test "doc.read rejects missing ref", %{pool: pool, doc_id: doc_id} do
      assert {:error, %{"error" => "invalid_params"}} =
               Tools.call(ctx(pool), "doc.read", %{"document" => doc_id})
    end

    test "doc.find returns matches with opaque refs", %{pool: pool, doc_id: doc_id} do
      assert {:ok, %{"matches" => [m | _]}} =
               Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "pattern" => "제2조"})

      assert is_binary(m["ref"])
    end

    test "doc.find returns a canonical ref immediately before a generic cell marker", %{
      pool: pool
    } do
      text = "Approved by Alex [[STAMP]] on file"

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "stamp-marker.hwp",
          "open_opts" => [
            __text__: text,
            __elements__: [
              %{
                "type" => "paragraph",
                "text" => text,
                "ref" => %{
                  "section" => 0,
                  "paragraph" => 78,
                  "offset" => 0,
                  "cell" => %{
                    "parentParaIndex" => 78,
                    "controlIndex" => 0,
                    "cellIndex" => 3,
                    "cellParaIndex" => 3
                  }
                }
              }
            ]
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "pattern" => text,
                 "type" => "paragraph",
                 "marker" => "[[STAMP]]"
               })

      assert match["text"] == text
      assert match["marker"] == "[[STAMP]]"
      assert match["marker_offset"] == 17

      assert Jason.decode!(match["before_marker_ref"]) == %{
               "section" => 0,
               "paragraph" => 78,
               "offset" => 17,
               "cellPath" => [
                 %{"controlIndex" => 0, "cellIndex" => 3, "cellParaIndex" => 3}
               ]
             }
    end

    test "doc.find returns a canonical ref before a non-cell marker", %{pool: pool} do
      text = "Place the seal before <SEAL> in this paragraph"

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "paragraph-marker.hwp",
          "open_opts" => [
            __text__: text,
            __elements__: [
              %{
                "type" => "paragraph",
                "text" => text,
                "ref" => %{"section" => 2, "paragraph" => 14, "offset" => 0}
              }
            ]
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "pattern" => text,
                 "type" => "paragraph",
                 "marker" => "<SEAL>"
               })

      assert match["marker_offset"] == 22

      assert Jason.decode!(match["before_marker_ref"]) == %{
               "section" => 2,
               "paragraph" => 14,
               "offset" => 22
             }
    end

    test "doc.find canonicalizes a live HWP cell ref at a Unicode marker offset", %{pool: pool} do
      text = "수급사업자 한빛 (인)"

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "native-cell-marker.hwp",
          "open_opts" => [
            __text__: text,
            __elements__: [
              %{
                "type" => "paragraph",
                "text" => text,
                "ref" => "hwp:s0/p77/tbl0/cell3/cp3/c0+18"
              }
            ]
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "pattern" => text,
                 "type" => "paragraph",
                 "marker" => "(인)"
               })

      assert match["marker_offset"] == 9

      assert Jason.decode!(match["before_marker_ref"]) == %{
               "section" => 0,
               "paragraph" => 77,
               "offset" => 9,
               "cellPath" => [
                 %{"controlIndex" => 0, "cellIndex" => 3, "cellParaIndex" => 3}
               ]
             }
    end

    test "doc.find canonicalizes a live HWP non-cell char ref", %{pool: pool} do
      text = "한글 도장 <SEAL>"

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "native-paragraph-marker.hwp",
          "open_opts" => [
            __text__: text,
            __elements__: [
              %{
                "type" => "paragraph",
                "text" => text,
                "ref" => "hwp:s2/p14/c0+12"
              }
            ]
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "pattern" => text,
                 "type" => "paragraph",
                 "marker" => "<SEAL>"
               })

      assert match["marker_offset"] == 6

      assert Jason.decode!(match["before_marker_ref"]) == %{
               "section" => 2,
               "paragraph" => 14,
               "offset" => 6
             }
    end

    test "doc.find adds a native HWP char ref base offset to its marker offset", %{pool: pool} do
      text = "계약"

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "native-offset-paragraph-marker.hwp",
          "open_opts" => [
            __text__: text,
            __elements__: [
              %{
                "type" => "paragraph",
                "text" => text,
                "ref" => "hwp:s0/p41/c5+2"
              }
            ]
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "pattern" => text,
                 "type" => "paragraph",
                 "marker" => "약"
               })

      assert match["marker_offset"] == 1

      assert Jason.decode!(match["before_marker_ref"]) == %{
               "section" => 0,
               "paragraph" => 41,
               "offset" => 6
             }
    end

    test "doc.find adds a native HWP cell ref base offset to its marker offset", %{pool: pool} do
      text = "서명"

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "native-offset-cell-marker.hwp",
          "open_opts" => [
            __text__: text,
            __elements__: [
              %{
                "type" => "paragraph",
                "text" => text,
                "ref" => "hwp:s0/p77/tbl0/cell3/cp3/c10+2"
              }
            ]
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "pattern" => text,
                 "type" => "paragraph",
                 "marker" => "명"
               })

      assert match["marker_offset"] == 1

      assert Jason.decode!(match["before_marker_ref"]) == %{
               "section" => 0,
               "paragraph" => 77,
               "offset" => 11,
               "cellPath" => [
                 %{"controlIndex" => 0, "cellIndex" => 3, "cellParaIndex" => 3}
               ]
             }
    end

    test "doc.find counts decomposed Unicode in native HWP codepoint offsets", %{pool: pool} do
      text = "e\u0301A"

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "native-decomposed-marker.hwp",
          "open_opts" => [
            __text__: text,
            __elements__: [
              %{
                "type" => "paragraph",
                "text" => text,
                "ref" => "hwp:s0/p0/c0+3"
              }
            ]
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "pattern" => text,
                 "type" => "paragraph",
                 "marker" => "A"
               })

      assert match["marker_offset"] == 2

      assert Jason.decode!(match["before_marker_ref"]) == %{
               "section" => 0,
               "paragraph" => 0,
               "offset" => 2
             }
    end

    test "case-insensitive native marker lookup keeps offsets in the original text", %{pool: pool} do
      text = "İA"

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "native-casefold-marker.hwp",
          "open_opts" => [
            __text__: text,
            __elements__: [
              %{
                "type" => "paragraph",
                "text" => text,
                "ref" => "hwp:s0/p0/c0+2"
              }
            ]
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "pattern" => text,
                 "type" => "paragraph",
                 "marker" => "a",
                 "case_sensitive" => false
               })

      assert match["marker_offset"] == 1

      assert Jason.decode!(match["before_marker_ref"]) == %{
               "section" => 0,
               "paragraph" => 0,
               "offset" => 1
             }
    end

    test "doc.find rejects a malformed live HWP ref instead of deriving a marker ref", %{
      pool: pool
    } do
      text = "수급사업자 한빛 (인)"

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "malformed-native-marker.hwp",
          "open_opts" => [
            __text__: text,
            __elements__: [
              %{
                "type" => "paragraph",
                "text" => text,
                "ref" => "hwp:s0/p77/tbl0/cellx/cp3/c0+18"
              }
            ]
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "pattern" => text,
                 "type" => "paragraph",
                 "marker" => "(인)"
               })

      refute Map.has_key?(match, "marker")
      refute Map.has_key?(match, "marker_found")
      refute Map.has_key?(match, "marker_offset")
      refute Map.has_key?(match, "before_marker_ref")
    end

    test "doc.find returns bounded snippets for long matches", %{pool: pool} do
      text =
        String.duplicate("Intro ", 40) <>
          "Private Timer Clock" <>
          String.duplicate(" tail", 40)

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "long-find.hwp",
          "open_opts" => [__text__: text]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "pattern" => "Private Timer Clock"
               })

      assert match["text"] =~ "Private Timer Clock"
      assert match["text_truncated"] == true
      refute Map.has_key?(match, "text_length")
      assert String.length(match["text"]) <= 54
      refute match["text"] == text
    end

    test "doc.find supports batched patterns", %{pool: pool, doc_id: doc_id} do
      assert {:ok, %{"results" => [first, second]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "patterns" => ["제1조", "제3조"]
               })

      assert [%{} | _] = first["matches"]
      assert [%{} | _] = second["matches"]
    end

    test "doc.find batched patterns walk structural elements once", %{pool: pool} do
      {:ok, doc_id} =
        Pool.open(pool, "batched.hwp",
          kind: :hwp,
          open_opts: [__text__: "alpha\nbeta\ngamma alpha", owner: self()]
        )

      assert {:ok, %{"results" => [first, second, third]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "patterns" => ["alpha", "beta", "missing"],
                 "limit" => 10
               })

      assert length(first["matches"]) == 2
      assert length(second["matches"]) == 1
      assert third["matches"] == []
      assert_receive {:fake_ehwp_query, "elements"}
      refute_receive {:fake_ehwp_query, "elements"}, 50
    end

    test "doc.find type fillable includes party underline paragraphs", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "signature.hwp",
          "open_opts" => [
            __text__: "---------------(이하 ‘원사업자’)와 ------------(이하 ‘수급사업자’)는 계약한다."
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "type" => "fillable"})

      assert match["text"] =~ "원사업자"
    end

    test "doc.find type fillable includes colon inline unit blanks", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "inline_blank.hwp",
          "open_opts" => [
            __text__: "거. 이행거절을 위한 기성금 등의 미지급 횟수 :    회 미지급"
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "type" => "fillable"})

      assert match["text"] =~ "미지급 횟수"
      assert match["fillable_kind"] == "inline_gap"
    end

    test "doc.find type fillable does not reflag padded filled values", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "filled_inline_blank.hwp",
          "open_opts" => [
            __text__:
              "◇ 계약기간  :     2025년 2월 12일부터 2026년 3월 12일까지\n" <>
                "거. 이행거절을 위한 기성금 등의 미지급 횟수 :    회 미지급"
          ]
        })

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "type" => "fillable"})

      assert match["text"] =~ "미지급 횟수"
      assert match["fillable_kind"] == "inline_gap"
    end
  end

  describe "document arg aliases — tools accept what picks/agents provide (#32)" do
    setup %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "drafts/service_contract.hwp",
          "open_opts" => [__text__: "제1조 (목적)\n제2조 (계약기간)"]
        })

      {:ok, doc_id: doc_id}
    end

    test "doc.read resolves relative-path / basename / active aliases", %{
      pool: pool,
      doc_id: doc_id
    } do
      for doc_alias <- ["drafts/service_contract.hwp", "service_contract.hwp", "active"] do
        ctx = ctx(pool) |> Map.put(:active_doc, doc_id)

        assert {:ok, %{"text" => text}} =
                 Tools.call(ctx, "doc.read", %{
                   "document" => doc_alias,
                   "ref" => "hwp:s0/p0/c0+3"
                 }),
               "alias #{inspect(doc_alias)} should resolve to #{doc_id}"

        assert text =~ "제1조"
      end
    end

    test "doc.find resolves the basename alias", %{pool: pool} do
      assert {:ok, %{"matches" => [m | _]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => "service_contract.hwp",
                 "pattern" => "제1조"
               })

      assert is_binary(m["ref"])
    end

    test "an unknown document fails with the open-document catalog (one-step self-correction)",
         %{pool: pool, doc_id: doc_id} do
      assert {:error,
              %{"error" => "document_not_found", "open_documents" => docs, "document" => bogus}} =
               Tools.call(ctx(pool), "doc.read", %{
                 "document" => "stale-viewer-id",
                 "ref" => "hwp:s0/p0/c0+0"
               })

      assert bogus == "stale-viewer-id"
      assert Enum.any?(docs, &(&1["document"] == doc_id))
      assert Enum.any?(docs, &(&1["path"] =~ "service_contract.hwp"))
    end
  end

  describe "path-first document arg — a path works open, closed, or never opened (#34)" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "ws_pathfirst_#{System.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(root, "drafts"))
      File.write!(Path.join(root, "drafts/retainer.hwp"), "fake-hwp-bytes")
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, root: root}
    end

    test "a workspace-relative path auto-opens a NEVER-opened document", %{
      pool: pool,
      root: root
    } do
      ctx = ctx(pool) |> Map.put(:session_path, root)

      assert {:ok, %{"text" => text}} =
               Tools.call(ctx, "doc.read", %{
                 "document" => "drafts/retainer.hwp",
                 "ref" => "hwp:s0/p0/c0+0"
               })

      assert is_binary(text)

      # It is now pooled (subsequent calls hit the same live model).
      assert {:ok, %{"documents" => docs}} = Tools.call(ctx, "doc.list", %{})
      assert Enum.any?(docs, &(&1["path"] =~ "drafts/retainer.hwp"))
    end

    test "a CLOSED document reopens by its path (same id again)", %{pool: pool, root: root} do
      ctx = ctx(pool) |> Map.put(:session_path, root)
      abs = Path.join(root, "drafts/retainer.hwp")

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx, "doc.open", %{"path" => abs, "open_opts" => [__text__: "제1조 (목적)"]})

      :ok = Pool.close(pool, doc_id)

      assert {:ok, %{"matches" => _}} =
               Tools.call(ctx, "doc.find", %{
                 "document" => "drafts/retainer.hwp",
                 "pattern" => "제"
               })

      # Deterministic (path, kind) id: the reopened doc carries the SAME id.
      assert {:ok, %{"documents" => docs}} = Tools.call(ctx, "doc.list", %{})
      assert Enum.any?(docs, &(&1["document"] == doc_id))
    end

    test "a stale id after close fails with the catalog — the path IS the stable handle", %{
      pool: pool,
      root: root
    } do
      ctx = ctx(pool) |> Map.put(:session_path, root)
      abs = Path.join(root, "drafts/retainer.hwp")

      {:ok, %{"document" => doc_id}} = Tools.call(ctx, "doc.open", %{"path" => abs})
      :ok = Pool.close(pool, doc_id)

      assert {:error, %{"error" => "document_not_found"}} =
               Tools.call(ctx, "doc.read", %{"document" => doc_id, "ref" => "hwp:s0/p0/c0+0"})
    end

    test "a path outside the workspace root is refused, not auto-opened", %{
      pool: pool,
      root: root
    } do
      ctx = ctx(pool) |> Map.put(:session_path, root)

      outside = Path.join(System.tmp_dir!(), "outside_#{System.unique_integer([:positive])}.hwp")
      File.write!(outside, "x")
      on_exit(fn -> File.rm(outside) end)

      assert {:error, %{"error" => "document_not_found"}} =
               Tools.call(ctx, "doc.read", %{"document" => outside, "ref" => "hwp:s0/p0/c0+0"})
    end

    test "a non-document file extension is not auto-opened", %{pool: pool, root: root} do
      ctx = ctx(pool) |> Map.put(:session_path, root)
      File.write!(Path.join(root, "notes.txt"), "plain text")

      assert {:error, %{"error" => "document_not_found"}} =
               Tools.call(ctx, "doc.read", %{"document" => "notes.txt", "ref" => "hwp:s0/p0/c0+0"})
    end
  end

  describe "doc.edit replace_text (the supported write path)" do
    test "applies through the editor", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "c.hwp",
          "open_opts" => [__text__: "제2조 본문"]
        })

      assert {:ok, result} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "ARTICLE2"}
               })

      assert result["ok"] == true

      assert {:ok, %{"matches" => [_ | _]}} =
               Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "pattern" => "ARTICLE2"})
    end

    test "native edit defers canonical bytes without invalidating the mounted ACP pre-image", %{
      path: root
    } do
      File.mkdir_p!(root)
      source = Path.join(root, "native-fallback.hwp")
      File.write!(source, "fake-hwp-bytes")
      mount_name = "native-fallback.hwp"
      projected_name = "/#{mount_name}.jsonl"

      ctx = %{
        pool: Pool,
        agent_id: "native-fallback-agent",
        instance_id: "native-fallback-instance",
        turn_id: "native-fallback-turn",
        session_path: root,
        read_only: false
      }

      on_exit(fn ->
        _ = Pool.close_by_path(source)
        OpenDocs.close(root, mount_name)
        File.rm_rf(root)
      end)

      assert {:ok, %{"document" => doc_id}} =
               Tools.call(ctx, "doc.open", %{
                 "path" => source,
                 "open_opts" => [__text__: "제2조 본문"]
               })

      OpenDocs.open(root, mount_name, source_path: source)
      OpenDocs.cache_committed(root, mount_name, "ACP_PRE_IMAGE")

      socket = Exfuse.Socket.new(DocMount.mount_point(root), %{root: root})

      assert {:reply, "ACP_PRE_IMAGE", socket} =
               DocFs.handle_event(
                 :read,
                 %{path: projected_name, offset: 0, size: 1_024},
                 socket
               )

      assert {:error, _reason} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제2조"}
               })

      assert {:ok, "ACP_PRE_IMAGE"} = OpenDocs.committed(root, mount_name)

      assert {:ok, %{"native" => [%{"ok" => false, "replaced" => 0}]}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{
                   "op" => "replace_text",
                   "query" => "없는 문구",
                   "replacement" => "NOOP"
                 }
               })

      assert {:ok, "ACP_PRE_IMAGE"} = OpenDocs.committed(root, mount_name)

      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{
                   "op" => "replace_text",
                   "query" => "제2조",
                   "replacement" => "ARTICLE2"
                 }
               })

      assert {:ok, "ACP_PRE_IMAGE"} = OpenDocs.committed(root, mount_name)

      assert {:ok,
              %{
                accepted_bytes: "ACP_PRE_IMAGE",
                bytes: canonical_bytes,
                agent_id: "native-fallback-agent",
                instance_id: "native-fallback-instance",
                turn_id: "native-fallback-turn"
              }} = OpenDocs.pending_canonical(root, mount_name)

      assert canonical_bytes =~ "ARTICLE2"

      assert {:reply, "ACP_PRE_IMAGE", socket} =
               DocFs.handle_event(
                 :read,
                 %{path: projected_name, offset: 0, size: 1_024 * 1_024},
                 socket
               )

      assert %{published: [^mount_name], pending: []} =
               DocFs.flush_canonical(root,
                 agent_id: "native-fallback-agent",
                 mounted?: false
               )

      assert {:reply, refreshed, _socket} =
               DocFs.handle_event(
                 :read,
                 %{path: projected_name, offset: 0, size: 1_024 * 1_024},
                 socket
               )

      assert refreshed == canonical_bytes
      assert refreshed =~ "ARTICLE2"
    end

    test "returns native write details for no-op replacements", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "c.hwp",
          "open_opts" => [__text__: "제2조 본문"]
        })

      assert {:ok, _} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "AA"}
               })

      assert {:ok, %{"ok" => true, "native" => [%{"ok" => false, "replaced" => 0}]}} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "BB"}
               })
    end

    test "batch replace_text folds multiline replacement instead of failing", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "multiline-replace.hwp",
          "open_opts" => [__text__: "PLACEHOLDER"]
        })

      assert {:ok, %{"applied" => 1, "failed" => 0} = result} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => doc_id,
                 "ops" => [
                   %{
                     "op" => "replace_text",
                     "query" => "PLACEHOLDER",
                     "replacement" => "첫째 줄\n둘째 줄"
                   }
                 ],
                 "verbose" => true
               })

      refute Map.has_key?(result, "failed_results")

      assert {:ok, %{"matches" => [_]}} =
               Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "pattern" => "첫째 줄 둘째 줄"})
    end

    test "batch edit rejects retired metadata before applying any operation", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "batch-revision-metadata.hwp",
          "open_opts" => [__text__: "A B"]
        })

      assert {:error, %{"error" => "invalid_op", "message" => message}} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => doc_id,
                 "ops" => [
                   %{
                     "op" => "replace_text",
                     "query" => "A",
                     "replacement" => "AA",
                     "base_revision" => 7
                   },
                   %{
                     "op" => "replace_text",
                     "query" => "B",
                     "replacement" => "BB",
                     "current_version" => 8
                   }
                 ],
                 "verbose" => true
               })

      assert message =~ "base_revision"

      assert {:ok, %{"matches" => [_]}} =
               Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "pattern" => "A B"})
    end

    test "batch edit with any failed op returns a tool error", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "partial-batch.hwp",
          "open_opts" => [__text__: "A B"]
        })

      assert {:error, %{"ok" => false, "applied" => 1, "failed" => 1} = result} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => doc_id,
                 "ops" => [
                   %{"op" => "replace_text", "query" => "A", "replacement" => "AA"},
                   %{"op" => "replace_text", "query" => "B"}
                 ],
                 "verbose" => true
               })

      assert [%{"error" => %{"error" => error}}] = result["failed_results"]
      assert error =~ "invalid_op"

      assert {:ok, %{"matches" => [_]}} =
               Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "pattern" => "AA"})
    end
  end

  describe "write capabilities" do
    setup %{pool: pool} do
      # Absolute tmp path: "doc.save writes bytes" persists this doc, and a
      # bare relative path would land the artifact in the repo root CWD.
      path = tmp_doc_path("c.hwp")

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => path,
          "open_opts" => [__text__: "제1조 본문"]
        })

      {:ok, doc_id: doc_id}
    end

    test "doc.set returns runtime capability error", %{pool: pool, doc_id: doc_id} do
      assert {:error, %{kind: "unsupported", message: msg}} =
               Tools.call(ctx(pool), "doc.set", %{
                 "document" => doc_id,
                 "ref" => "hwp:s0/p0",
                 "props" => %{"Bold" => false}
               })

      assert msg =~ ~r/(apply_char_format|set_properties)/
    end

    test "doc.save writes bytes", %{pool: pool, doc_id: doc_id} do
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx(pool), "doc.save", %{"document" => doc_id})
    end

    test "doc.save accepts an open document path", %{pool: pool} do
      path = tmp_doc_path("save-by-path.hwp")

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => path,
          "open_opts" => [__text__: "저장 경로"]
        })

      assert {:ok, %{id: ^doc_id}} = Pool.info_by_path(pool, path)

      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx(pool), "doc.save", %{"document" => path})
    end

    test "doc.save resolves workspace-relative document paths", %{pool: pool} do
      root = Path.join(System.tmp_dir!(), "ws_save_path_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      ctx = %{
        pool: pool,
        session_path: root,
        agent_id: "agent",
        instance_id: "agent-instance",
        turn_id: "agent-turn",
        read_only: false
      }

      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx, "doc.open", %{
          "path" => "viewed.hwp",
          "open_opts" => [__text__: "상대 경로 저장"]
        })

      absolute_path = Path.join(root, "viewed.hwp")
      assert {:ok, %{id: ^doc_id}} = Pool.info_by_path(pool, absolute_path)

      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx, "doc.save", %{"document" => "viewed.hwp"})

      assert File.exists?(absolute_path)
    end

    test "doc.save ignores legacy validate and returns ok only", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => tmp_doc_path("validate_inline_blank.hwp"),
          "open_opts" => [
            __text__: "거. 이행거절을 위한 기성금 등의 미지급 횟수 :    회 미지급"
          ]
        })

      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx(pool), "doc.save", %{"document" => doc_id, "validate" => true})
    end

    test "doc.save schema has no validation output mode" do
      save = Enum.find(Tools.tools(), &(&1["name"] == "save"))
      props = save["inputSchema"]["properties"]

      assert Map.keys(props) |> Enum.sort() == ["document", "path"]
    end

    test "doc.edit insert_text succeeds", %{pool: pool, doc_id: doc_id} do
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "insert_text", "ref" => "hwp:s0/p0", "text" => "x"}
               })
    end
  end

  describe "doc.read anchor-neighborhood surface" do
    test "the read tool schema has no paging knobs" do
      read = Enum.find(Tools.tools(), &(&1["name"] == "read"))
      props = read["inputSchema"]["properties"]

      assert read["inputSchema"]["required"] == ["document", "ref"]
      assert props |> Map.keys() |> Enum.sort() == ["document", "include", "nearby", "ref"]
    end
  end

  describe "doc.get — reflective property-IR (inspect folded in)" do
    setup %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "c.hwp",
          "open_opts" => [__text__: "제1조 (목적)\n제2조 (계약기간)\n제3조 (대금지급)"]
        })

      {:ok, doc_id: doc_id}
    end

    test "doc.get on a char ref returns type + settable names + children", %{
      pool: pool,
      doc_id: doc_id
    } do
      {:ok, %{"matches" => [m | _]}} =
        Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "pattern" => "제2조"})

      assert {:ok, info} =
               Tools.call(ctx(pool), "doc.get", %{"document" => doc_id, "ref" => m["ref"]})

      assert info["type"] == "char_run"
      # Settable native-property names (the old doc.inspect vocabulary).
      assert "Bold" in info["settable"]
      assert is_list(info["children"])
      # Live values are best-effort: present when readable, nil when the engine
      # can't read them yet. Either way the discovery surface is intact.
      assert Map.has_key?(info, "values")
    end

    test "doc.get on a paragraph ref lists paragraph settable props", %{
      pool: pool,
      doc_id: doc_id
    } do
      ref = Ecrits.Doc.Rhwp.Ref.encode(%{kind: :paragraph, sec: 0, para: 1})

      assert {:ok, info} =
               Tools.call(ctx(pool), "doc.get", %{"document" => doc_id, "ref" => ref})

      assert info["type"] == "paragraph"
      assert "Alignment" in info["settable"]
    end
  end

  describe "doc.context — current document" do
    test "reports the calling context's active doc (per-caller, not a global active)", %{
      pool: pool
    } do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "c.hwp",
          "open_opts" => [__text__: "제1조 본문"]
        })

      # The active doc is per-CALLER (`ctx.active_doc`) since Phase 3 — there is no
      # global active. A ctx that names its active doc surfaces it as current_document.
      ctx = %{pool: pool, agent_id: "fg", active_doc: doc_id}
      assert {:ok, ctx_result} = Tools.call(ctx, "doc.context", %{})
      assert Map.keys(ctx_result) == ["current_document"]

      assert ctx_result["current_document"] == %{
               "document" => doc_id,
               "name" => "c.hwp",
               "path" => "c.hwp",
               "kind" => "hwp",
               "backing" => "server",
               "active" => true
             }
    end

    test "each caller sees its OWN active doc, independent of what is open", %{pool: pool} do
      {:ok, %{"document" => a}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "a.hwp", "open_opts" => [__text__: "x"]})

      {:ok, %{"document" => b}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "b.hwp", "open_opts" => [__text__: "y"]})

      # A bare ctx names no active doc → none reported (no global active to infer).
      assert {:ok, %{"current_document" => nil} = bare_context} =
               Tools.call(ctx(pool), "doc.context", %{})

      assert Map.keys(bare_context) == ["current_document"]

      # Each caller's own `active_doc` wins.
      assert {:ok, %{"current_document" => current_b} = context_b} =
               Tools.call(%{pool: pool, agent_id: "x", active_doc: b}, "doc.context", %{})

      assert Map.keys(context_b) == ["current_document"]
      assert current_b["document"] == b
      assert current_b["name"] == "b.hwp"

      assert {:ok, %{"current_document" => current_a} = context_a} =
               Tools.call(%{pool: pool, agent_id: "y", active_doc: a}, "doc.context", %{})

      assert Map.keys(context_a) == ["current_document"]
      assert current_a["document"] == a
      assert current_a["name"] == "a.hwp"
    end

    test "falls back to explicit current document path when no pool id is active", %{pool: pool} do
      assert {:ok, ctx_result} =
               Tools.call(
                 %{
                   pool: pool,
                   agent_id: "fg",
                   active_doc: nil,
                   document_path: "drafts/current.hwpx"
                 },
                 "doc.context",
                 %{}
               )

      assert Map.keys(ctx_result) == ["current_document"]

      assert ctx_result["current_document"] == %{
               "document" => "drafts/current.hwpx",
               "name" => "current.hwpx",
               "kind" => "hwpx",
               "path" => "drafts/current.hwpx",
               "backing" => nil,
               "active" => true
             }
    end

    test "context + get are exposed in the tool catalog as read tools" do
      by_name = Map.new(Tools.tools(), &{&1["namespace"] <> "." <> &1["name"], &1["risk"]})
      assert by_name["doc.context"] == "read"
      assert by_name["doc.get"] == "read"
    end
  end

  # Per-agent MCP isolation + the open/ownership invariants. An "agent context" is
  # a ctx map carrying `:agent_id` + `:active_doc` + `:session_path` (the
  # workspace `Session` that holds ownership since Phase 3); a bare `%{pool: pool}`
  # keeps the legacy pool-only behaviour the rest of the suite relies on.
  describe "per-agent context (isolation + invariants)" do
    defp agent_ctx(pool, path, agent_id, active_doc \\ nil),
      do: %{
        pool: pool,
        agent_id: agent_id,
        instance_id: "#{agent_id}-instance",
        turn_id: "#{agent_id}-turn",
        active_doc: active_doc,
        session_path: path
      }

    test "doc.context returns THIS agent's OWN active doc (there is no global active)", %{
      pool: pool,
      path: path
    } do
      {:ok, %{"document" => a}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "a.hwp", "open_opts" => [__text__: "x"]})

      {:ok, %{"document" => b}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "b.hwp", "open_opts" => [__text__: "y"]})

      # Each agent sees ONLY its own bound doc — there is no global active to leak.
      assert {:ok, %{"current_document" => current_a} = context_a} =
               Tools.call(agent_ctx(pool, path, "agent-1", a), "doc.context", %{})

      assert Map.keys(context_a) == ["current_document"]
      assert current_a["document"] == a
      assert current_a["name"] == "a.hwp"

      assert {:ok, %{"current_document" => current_b} = context_b} =
               Tools.call(agent_ctx(pool, path, "agent-2", b), "doc.context", %{})

      assert Map.keys(context_b) == ["current_document"]
      assert current_b["document"] == b
      assert current_b["name"] == "b.hwp"

      # An agent with no bound doc sees none.
      assert {:ok, %{"current_document" => nil}} =
               Tools.call(agent_ctx(pool, path, "agent-3", nil), "doc.context", %{})
    end

    test "doc.open of an ALREADY-OPEN doc FAILS with already_open + held_by (invariant 1)", %{
      pool: pool,
      path: path
    } do
      # agent-1 opens it (and so owns it).
      assert {:ok, %{"document" => doc_id}} =
               Tools.call(agent_ctx(pool, path, "agent-1"), "doc.open", %{
                 "path" => "shared.hwp",
                 "open_opts" => [__text__: "제1조"]
               })

      # agent-1 re-opening the SAME doc fails (held by self).
      assert {:error, %{"error" => "already_open", "document" => ^doc_id, "held_by" => held}} =
               Tools.call(agent_ctx(pool, path, "agent-1"), "doc.open", %{"path" => "shared.hwp"})

      assert held["kind"] == "self"

      # agent-2 cannot grab it either — held_by names the other agent.
      assert {:error, %{"error" => "already_open", "document" => ^doc_id, "held_by" => held2}} =
               Tools.call(agent_ctx(pool, path, "agent-2"), "doc.open", %{"path" => "shared.hwp"})

      assert held2 == %{"kind" => "agent", "agent_id" => "agent-1"}
    end

    test "doc.edit is :forbidden when another agent owns the doc (invariant 2)", %{
      pool: pool,
      path: path
    } do
      {:ok, %{"document" => doc_id}} =
        Tools.call(agent_ctx(pool, path, "owner"), "doc.open", %{
          "path" => "owned.hwp",
          "open_opts" => [__text__: "제2조 (계약기간) 본문"]
        })

      # The owner can edit.
      assert {:ok, %{"ok" => true}} =
               Tools.call(agent_ctx(pool, path, "owner", doc_id), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "제3조"}
               })

      assert {:server, editor} = Pool.route(pool, doc_id)

      assert %{owner: %{agent_id: "owner", instance_id: "owner-instance", turn_id: "owner-turn"}} =
               Ecrits.Doc.Editor.dirty_snapshot(editor)

      # A different agent is fenced out.
      assert {:error, %{"error" => "forbidden", "document" => ^doc_id, "owned_by" => owned}} =
               Tools.call(agent_ctx(pool, path, "intruder", doc_id), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제3조", "replacement" => "X"}
               })

      assert owned == %{"agent_id" => "owner"}
    end

    test "doc.set is fenced before another agent can property-write the document", %{
      pool: pool,
      path: path
    } do
      {:ok, %{"document" => doc_id}} =
        Tools.call(agent_ctx(pool, path, "owner"), "doc.open", %{
          "path" => "owned-set.hwp",
          "open_opts" => [__text__: "제1조"]
        })

      assert {:error, %{"error" => "forbidden", "document" => ^doc_id}} =
               Tools.call(agent_ctx(pool, path, "intruder", doc_id), "doc.set", %{
                 "document" => doc_id,
                 "ref" => "hwp:s0/p0",
                 "props" => %{"Bold" => true}
               })
    end

    test "agent writes with a partial turn identity fail closed", %{pool: pool, path: path} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "partial-turn.hwp",
          "open_opts" => [__text__: "제1조"]
        })

      partial_ctx = %{
        pool: pool,
        agent_id: "agent",
        instance_id: "instance",
        session_path: path,
        active_doc: doc_id,
        read_only: false
      }

      assert {:error, %{"error" => "invalid_params", "message" => message}} =
               Tools.call(partial_ctx, "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "insert_text", "ref" => "hwp:s0/p0", "text" => "x"}
               })

      assert message =~ "instance_id and turn_id"
    end

    test "doc.edit of an UNOWNED (human-opened) doc lazily claims it and succeeds", %{
      pool: pool,
      path: path
    } do
      # Opened WITHOUT an agent (the LiveView/human path) — no owner recorded.
      {:ok, doc_id} = Pool.open(pool, "viewed.hwp", kind: :hwp, open_opts: [__text__: "제1조 본문"])
      assert Session.owner(path, doc_id) == nil

      # The single foreground agent edits it (the critical path) — allowed, and it
      # claims ownership lazily.
      assert {:ok, %{"ok" => true}} =
               Tools.call(agent_ctx(pool, path, "fg", doc_id), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제1조", "replacement" => "제1조 (목적)"}
               })

      assert Session.owner(path, doc_id) == "fg"
    end

    test "a bare pool-only context has no ownership fence + legacy open reuse", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "legacy.hwp",
          "open_opts" => [__text__: "x"]
        })

      # Legacy reuse: re-open returns the SAME id, no already_open error.
      assert {:ok, %{"document" => ^doc_id}} =
               Tools.call(ctx(pool), "doc.open", %{"path" => "legacy.hwp"})

      # A bare ctx sets no active doc, so doc.context reports no current doc.
      assert {:ok, %{"current_document" => nil}} = Tools.call(ctx(pool), "doc.context", %{})
    end
  end

  describe "dispatch errors" do
    test "unknown tool", %{pool: pool} do
      assert {:error, {:unknown_tool, "doc.bogus"}} = Tools.call(ctx(pool), "doc.bogus", %{})
    end

    test "unknown document", %{pool: pool} do
      # #32: the miss is structured — it names the unknown id and carries the
      # open-document catalog so the agent self-corrects without doc.context.
      assert {:error,
              %{"error" => "document_not_found", "document" => "ghost", "open_documents" => []}} =
               Tools.call(ctx(pool), "doc.read", %{"document" => "ghost", "ref" => "ghost-ref"})
    end

    test "missing required document arg", %{pool: pool} do
      assert {:error, _} = Tools.call(ctx(pool), "doc.read", %{})
    end
  end

  # Access-control guards (security review #1): the doc.* tools run server-side
  # and bypass the agent CLI sandbox, so they must honour the workspace access
  # setting themselves. `read_only: true` ⟺ the agent's sandbox == "read-only";
  # `session_path` is the workspace root that confines caller-supplied paths.
  describe "access control: read-only session" do
    # ctx mirroring a read-only agent (session_path set, read_only true).
    defp ro_ctx(pool, root),
      do: %{
        pool: pool,
        agent_id: "ro",
        instance_id: "ro-instance",
        turn_id: "ro-turn",
        session_path: root,
        read_only: true
      }

    defp rw_ctx(pool, root),
      do: %{
        pool: pool,
        agent_id: "rw",
        instance_id: "rw-instance",
        turn_id: "rw-turn",
        session_path: root,
        read_only: false
      }

    setup do
      root = Path.join(System.tmp_dir!(), "ws_ac_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root}
    end

    test "refuses doc.create with a read_only error", %{pool: pool, root: root} do
      assert {:error, %{"error" => "read_only", "message" => msg}} =
               Tools.call(ro_ctx(pool, root), "doc.create", %{
                 "path" => Path.join(root, "new.hwp")
               })

      assert msg =~ "read-only"
    end

    test "refuses doc.save with a read_only error", %{pool: pool, root: root} do
      # Open a doc as a writable agent first so a doc id exists to target.
      {:ok, %{"document" => doc_id}} =
        Tools.call(rw_ctx(pool, root), "doc.open", %{
          "path" => Path.join(root, "saveme.hwp"),
          "open_opts" => [__text__: "x"]
        })

      assert {:error, %{"error" => "read_only"}} =
               Tools.call(ro_ctx(pool, root), "doc.save", %{"document" => doc_id})
    end

    test "refuses doc.edit with a read_only error", %{pool: pool, root: root} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(rw_ctx(pool, root), "doc.open", %{
          "path" => Path.join(root, "editme.hwp"),
          "open_opts" => [__text__: "제1조"]
        })

      assert {:error, %{"error" => "read_only"}} =
               Tools.call(ro_ctx(pool, root), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제1조", "replacement" => "X"}
               })
    end

    test "refuses doc.set with a read_only error", %{pool: pool, root: root} do
      assert {:error, %{"error" => "read_only"}} =
               Tools.call(ro_ctx(pool, root), "doc.set", %{
                 "ref" => "hwp:foo",
                 "props" => %{"bold" => true}
               })
    end

    test "still allows reads (doc.read / doc.find / doc.context)", %{pool: pool, root: root} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(rw_ctx(pool, root), "doc.open", %{
          "path" => Path.join(root, "readme.hwp"),
          "open_opts" => [__text__: "제1조 (목적)\n제2조 (기간)"]
        })

      {:ok, %{"matches" => [match | _]}} =
        Tools.call(ro_ctx(pool, root), "doc.find", %{"document" => doc_id, "pattern" => "제2조"})

      assert {:ok, %{"text" => text}} =
               Tools.call(ro_ctx(pool, root), "doc.read", %{
                 "document" => doc_id,
                 "ref" => match["ref"]
               })

      assert text =~ "제2조"

      assert {:ok, %{"matches" => [_ | _]}} =
               Tools.call(ro_ctx(pool, root), "doc.find", %{
                 "document" => doc_id,
                 "pattern" => "제1조"
               })

      assert {:ok, _} = Tools.call(ro_ctx(pool, root), "doc.context", %{})
    end
  end

  describe "access control: workspace path confinement" do
    setup do
      root = Path.join(System.tmp_dir!(), "ws_pc_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root}
    end

    defp ws_ctx(pool, root),
      do: %{
        pool: pool,
        agent_id: "ws",
        instance_id: "ws-instance",
        turn_id: "ws-turn",
        session_path: root,
        read_only: false
      }

    test "doc.create OUTSIDE the workspace root is refused", %{pool: pool, root: root} do
      outside = Path.join(System.tmp_dir!(), "outside_#{System.unique_integer([:positive])}.hwp")

      assert {:error, %{"error" => "outside_workspace", "workspace_root" => reported}} =
               Tools.call(ws_ctx(pool, root), "doc.create", %{"path" => outside})

      assert reported == Path.expand(root)
      refute File.exists?(outside)
    end

    test "a `..`-escape path is refused even if it lexically starts with the root",
         %{pool: pool, root: root} do
      # `<root>/../<sibling>` expands OUTSIDE root — the guard must expand before
      # comparing, not do a raw prefix check.
      escape = Path.join(root, "../escape_#{System.unique_integer([:positive])}.hwp")

      assert {:error, %{"error" => "outside_workspace"}} =
               Tools.call(ws_ctx(pool, root), "doc.create", %{"path" => escape})

      refute File.exists?(Path.expand(escape))
    end

    test "doc.open OUTSIDE the workspace root is refused", %{pool: pool, root: root} do
      outside =
        Path.join(System.tmp_dir!(), "outside_open_#{System.unique_integer([:positive])}.hwp")

      File.write!(outside, "x")
      on_exit(fn -> File.rm_rf(outside) end)

      assert {:error, %{"error" => "outside_workspace"}} =
               Tools.call(ws_ctx(pool, root), "doc.open", %{"path" => outside})
    end

    test "doc.open_doc accepts nested workspace-relative documents", %{pool: pool, root: root} do
      previous_vfs = Application.get_env(:ecrits, :doc_vfs)
      Application.put_env(:ecrits, :doc_vfs, enabled: false)

      on_exit(fn ->
        restore(:ecrits, :doc_vfs, previous_vfs)
        OpenDocs.close(root, "drafts%2Fnested.hwp")
      end)

      File.mkdir_p!(Path.join(root, "drafts"))
      abs = Path.join(root, "drafts/nested.hwp")
      File.write!(abs, "fake-hwp-bytes")

      assert {:ok,
              result = %{
                "opened" => "drafts/nested.hwp",
                "mount_name" => "drafts%2Fnested.hwp",
                "projected" => "drafts%2Fnested.hwp.jsonl",
                "path" => ^abs,
                "mounted_at" => nil,
                "vfs_enabled" => false
              }} =
               Tools.call(ws_ctx(pool, root), "doc.open_doc", %{"path" => "drafts/nested.hwp"})

      assert %{
               "version" => 2,
               "kind" => "jsonl_projection",
               "available" => false,
               "addressing" => "nested_payload_position",
               "format" => %{
                 "encoding" => "one_json_value_one_paragraph_group_per_line",
                 "line_addressing" => %{
                   "locate" => "line_based_search_finds_the_target_paragraph_group_line",
                   "edit" =>
                     "replace_whole_lines_keeping_one_paragraph_group_per_line_and_the_trailing_comma",
                   "newlines" =>
                     "raw_newlines_are_reserved_record_separators_content_newlines_stay_escaped"
                 },
                 "structure" => ["sections", "paragraphs", "payloads"],
                 "commit" => %{
                   "mode" => "same_directory_temp_then_rename",
                   "target_path" => nil,
                   "temp_path" => nil,
                   "temp_scope" => "mounted_projection_directory_only",
                   "external_temp" => false,
                   "rename" => "same_filesystem_atomic",
                   "unsupported_structural_change" => %{
                     "committed" => false,
                     "errno" => "EINVAL"
                   }
                 }
               },
               "preserve" => ["payload_type", "unknown_fields", "nested_order"],
               "payloads" => %{
                 "text" => %{"edit" => true},
                 "table" => %{
                   "insert" => %{
                     "required" => ["type", "cells"],
                     "mode" => "insert_compact_payload_node",
                     "preserve_existing_payloads" => true
                   }
                 },
                 "picture" => %{
                   "insert" => false,
                   "route" => "native_fallback"
                 }
               },
               "operations" => %{
                 "set_text" => %{
                   "target_types" => ["paragraph", "char", "cell"],
                   "field" => "text",
                   "mode" => "in_place",
                   "select" => "type_and_current_text",
                   "reuse_blank_payloads" => true
                 },
                 "insert_table" => %{
                   "container" => "existing_paragraph_payload_array",
                   "at" => "after_existing_anchor_payload",
                   "action" => "insert_new_payload_node",
                   "replace_container" => false,
                   "insert_paragraph_arrays" => false,
                   "copy_expanded_table_payloads" => false,
                   "node" => %{
                     "type" => "table",
                     "cells" => "string_matrix",
                     "header" => "boolean_optional"
                   }
                 }
               },
               "native_fallbacks" => %{
                 "insert_picture" => %{
                   "tool" => "doc.edit",
                   "reason" => "unrepresentable",
                   "supported_placement" => "picture_at_exact_existing_marker",
                   "derive_from" => "current_engine_ref_after_primary_commit",
                   "resolve_ref" => %{
                     "tool" => "doc.find",
                     "when" => "after_primary_commit",
                     "arguments" => %{
                       "document" => %{
                         "from" => "doc.open_doc.document"
                       },
                       "type" => "paragraph",
                       "pattern" => %{
                         "from" => "copy_exact_committed_target_paragraph_text"
                       },
                       "marker" => %{
                         "from" => "existing_literal_immediately_after_picture",
                         "must_already_exist" => true,
                         "create_placeholder" => false
                       },
                       "case_sensitive" => true,
                       "limit" => 1
                     },
                     "select" => "unique_exact_text_match_containing_existing_marker",
                     "use" => "match.before_marker_ref_verbatim",
                     "manual_ref_derivation" => false
                   },
                   "op" => %{
                     "op" => "insert_picture",
                     "src" => "absolute_file_path",
                     "ref" => "json_string",
                     "ref_value" => %{
                       "section" => "non_negative_integer",
                       "paragraph" => "non_negative_integer",
                       "offset" => "non_negative_character_index",
                       "cellPath" => "optional_nonempty_canonical_cell_path"
                     }
                   },
                   "derive_ref_from_doc_find_match" => true,
                   "fallback" => %{
                     "attempted" => "vfs",
                     "reason" => "unrepresentable",
                     "detail" => "describe_the_exact_existing_marker_picture_placement",
                     "mounted_at" => "exact_value_returned_by_doc.open_doc"
                   }
                 }
               }
             } = result["surface"]

      assert OpenDocs.source_path(root, "drafts%2Fnested.hwp") == {:ok, abs}
      assert OpenDocs.writable?(root)

      assert {:ok, _result} =
               Tools.call(%{ws_ctx(pool, root) | read_only: true}, "doc.open_doc", %{
                 "path" => "drafts/nested.hwp"
               })

      refute OpenDocs.writable?(root)
    end

    test "doc.open_doc resolves a bare filename to the active nested document",
         %{pool: pool, root: root} do
      previous_vfs = Application.get_env(:ecrits, :doc_vfs)
      Application.put_env(:ecrits, :doc_vfs, enabled: false)

      on_exit(fn ->
        restore(:ecrits, :doc_vfs, previous_vfs)
        OpenDocs.close(root, "drafts%2Factive.hwp")
      end)

      File.mkdir_p!(Path.join(root, "drafts"))
      abs = Path.join(root, "drafts/active.hwp")
      File.write!(abs, "fake-hwp-bytes")

      ctx =
        ws_ctx(pool, root)
        |> Map.put(:document_path, "drafts/active.hwp")
        |> Map.put(:active_doc, "d_current")

      assert {:ok,
              %{
                "opened" => "drafts/active.hwp",
                "document" => "d_current",
                "mount_name" => "drafts%2Factive.hwp",
                "path" => ^abs
              }} = Tools.call(ctx, "doc.open_doc", %{"path" => "active.hwp"})

      assert OpenDocs.source_path(root, "drafts%2Factive.hwp") == {:ok, abs}
    end

    test "doc.create/open INSIDE the workspace root works (incl. nested dirs)",
         %{pool: pool, root: root} do
      inside = Path.join(root, "sub/dir/inside.hwp")

      # A blank create may surface an engine create-unsupported error from the fake
      # runtime, but it must NOT be the outside_workspace gate — the in-workspace
      # path passes confinement. Use a clone (which writes real bytes) to assert
      # an in-workspace write actually succeeds end-to-end.
      source = Path.join(root, "tmpl.hwp")
      File.write!(source, :crypto.strong_rand_bytes(512))

      assert {:ok, %{"document" => doc_id}} =
               Tools.call(ws_ctx(pool, root), "doc.create", %{
                 "path" => inside,
                 "from" => source
               })

      assert File.exists?(inside)

      # The clone opened as an editable doc whose save target is the in-workspace
      # path (no regression in the normal in-workspace write flow).
      assert {:ok, %{path: ^inside}} = Pool.info(pool, doc_id)
    end

    test "no session_path (legacy pool-only ctx) leaves paths unconstrained",
         %{pool: pool} do
      # The legacy bare-pool ctx has no :session_path; confine_path is a passthrough
      # so an absolute path anywhere still opens (preserving pre-isolation behaviour).
      anywhere = Path.join(System.tmp_dir!(), "legacy_#{System.unique_integer([:positive])}.hwp")

      assert {:ok, %{"document" => _}} =
               Tools.call(%{pool: pool}, "doc.open", %{
                 "path" => anywhere,
                 "open_opts" => [__text__: "x"]
               })
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
