defmodule Ecrits.Doc.ToolsTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Tools
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

      for n <- ~w(doc.context doc.list doc.open doc.create doc.read doc.find
                  doc.get doc.set doc.edit doc.save doc.render) do
        assert n in names, "expected #{n} in tool catalog"
      end

      # The consolidated surface is eleven tools (ten + doc.render, the visual
      # feedback loop); the former doc.inspect and doc.apply_style are folded
      # into doc.get / doc.set. The authoring guide is NOT a tool — it is the
      # MCP server's `instructions` (one global copy per session).
      assert "doc.read_table" not in names
      assert "doc.inspect" not in names
      assert "doc.apply_style" not in names
      assert length(names) == 11

      for tool <- Tools.tools() do
        assert is_map(tool["inputSchema"])
        assert tool["risk"] in ["read", "write"]
      end
    end

    test "the authoring guide is the server instructions — one global copy, any entry point" do
      # Sessions that never touch doc.create (open an existing deck, or a path
      # auto-open) still get the design lessons: they ride the MCP initialize
      # `instructions`, once per session.
      instructions = Tools.instructions()
      assert instructions =~ "28000x15750"
      assert instructions =~ "FillColor"
      assert instructions =~ "insert_paragraph"

      {:ok, state} = Ecrits.Doc.MCPServer.init([])

      assert {:ok, %{instructions: ^instructions}, _state} =
               Ecrits.Doc.MCPServer.handle_initialize(%{}, state)
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
      assert {:ok, %{"documents" => docs}} = Tools.call(ctx(pool), "doc.context", %{})
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
          assert {:ok, %{"documents" => docs}} = Tools.call(ctx(pool), "doc.context", %{})
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

    test "doc.find supports batched patterns", %{pool: pool, doc_id: doc_id} do
      assert {:ok, %{"results" => [first, second]}} =
               Tools.call(ctx(pool), "doc.find", %{
                 "document" => doc_id,
                 "patterns" => ["제1조", "제3조"]
               })

      assert [%{} | _] = first["matches"]
      assert [%{} | _] = second["matches"]
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
                 "document" => "local-stale-viewer-id",
                 "ref" => "hwp:s0/p0/c0+0"
               })

      assert bogus == "local-stale-viewer-id"
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

    test "batch edit applies all ops when revision metadata is present", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "batch-revision-metadata.hwp",
          "open_opts" => [__text__: "A B"]
        })

      assert {:ok, %{"applied" => 2, "failed" => 0} = result} =
               Tools.call(ctx(pool), "doc.edit", %{
                 "document" => doc_id,
                 "base_revision" => 7,
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

      refute Map.has_key?(result, "failed_results")

      assert {:ok, %{"matches" => [_]}} =
               Tools.call(ctx(pool), "doc.find", %{"document" => doc_id, "pattern" => "AA BB"})
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

      assert msg =~ "set_properties"
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

      ctx = %{pool: pool, session_path: root, agent_id: "agent", read_only: false}

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

  describe "doc.context — active document + cursor" do
    test "reports the calling context's active doc (per-caller, not a global active)", %{
      pool: pool
    } do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{
          "path" => "c.hwp",
          "open_opts" => [__text__: "제1조 본문"]
        })

      # The active doc is per-CALLER (`ctx.active_doc`) since Phase 3 — there is no
      # global active. A ctx that names its active doc surfaces it; the cursor
      # wiring is still a server-side TODO.
      ctx = %{pool: pool, agent_id: "fg", active_doc: doc_id}
      assert {:ok, ctx_result} = Tools.call(ctx, "doc.context", %{})
      assert ctx_result["active_document"] == doc_id
      assert ctx_result["current_document"]["document"] == doc_id
      assert ctx_result["current_document"]["name"] == "c.hwp"
      assert ctx_result["current_document"]["path"] == "c.hwp"
      assert ctx_result["current_document"]["kind"] == "hwp"
      assert ctx_result["current_document"]["backing"] == "server"
      assert ctx_result["cursor"] == nil
      assert ctx_result["selection"] == nil
      assert ctx_result["cursor_reporting"] == "todo:browser_wiring"
    end

    test "each caller sees its OWN active doc, independent of what is open", %{pool: pool} do
      {:ok, %{"document" => a}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "a.hwp", "open_opts" => [__text__: "x"]})

      {:ok, %{"document" => b}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "b.hwp", "open_opts" => [__text__: "y"]})

      # A bare ctx names no active doc → none reported (no global active to infer).
      assert {:ok, %{"active_document" => nil, "current_document" => nil}} =
               Tools.call(ctx(pool), "doc.context", %{})

      # Each caller's own `active_doc` wins.
      assert {:ok, %{"active_document" => ^b, "current_document" => current_b}} =
               Tools.call(%{pool: pool, agent_id: "x", active_doc: b}, "doc.context", %{})

      assert current_b["document"] == b
      assert current_b["name"] == "b.hwp"

      assert {:ok, %{"active_document" => ^a, "current_document" => current_a}} =
               Tools.call(%{pool: pool, agent_id: "y", active_doc: a}, "doc.context", %{})
    end

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

      assert ctx_result["active_document"] == nil

      assert ctx_result["current_document"] == %{
               "document" => "drafts/current.hwpx",
               "name" => "current.hwpx",
               "kind" => "hwpx",
               "path" => "drafts/current.hwpx",
               "backing" => nil,
               "active" => true
             }

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
      do: %{pool: pool, agent_id: agent_id, active_doc: active_doc, session_path: path}

    test "doc.context returns THIS agent's OWN active doc (there is no global active)", %{
      pool: pool,
      path: path
    } do
      {:ok, %{"document" => a}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "a.hwp", "open_opts" => [__text__: "x"]})

      {:ok, %{"document" => b}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "b.hwp", "open_opts" => [__text__: "y"]})

      # Each agent sees ONLY its own bound doc — there is no global active to leak.
      assert {:ok, %{"active_document" => ^a, "current_document" => current_a}} =
               Tools.call(agent_ctx(pool, path, "agent-1", a), "doc.context", %{})

      assert current_a["document"] == a
      assert current_a["name"] == "a.hwp"

      assert {:ok, %{"active_document" => ^b, "current_document" => current_b}} =
               Tools.call(agent_ctx(pool, path, "agent-2", b), "doc.context", %{})

      # An agent with no bound doc sees none.
      assert {:ok, %{"active_document" => nil, "current_document" => nil}} =
      assert current_b["document"] == b
      assert current_b["name"] == "b.hwp"

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

      # A different agent is fenced out.
      assert {:error, %{"error" => "forbidden", "document" => ^doc_id, "owned_by" => owned}} =
               Tools.call(agent_ctx(pool, path, "intruder", doc_id), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제3조", "replacement" => "X"}
               })

      assert owned == %{"agent_id" => "owner"}
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

      # A bare ctx sets no active doc, so doc.context reports none (no global active).
      assert {:ok, %{"active_document" => nil}} = Tools.call(ctx(pool), "doc.context", %{})
    end
  end

  describe "dispatch errors" do
    test "unknown tool", %{pool: pool} do
      assert {:error, {:unknown_tool, "doc.bogus"}} = Tools.call(ctx(pool), "doc.bogus", %{})
    end

    test "unknown document", %{pool: pool} do
      # #32: the miss is structured — it names the unknown id and carries the
      # open-document catalog so the agent self-corrects without doc_context.
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
      do: %{pool: pool, agent_id: "ro", session_path: root, read_only: true}

    defp rw_ctx(pool, root),
      do: %{pool: pool, agent_id: "rw", session_path: root, read_only: false}

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
      do: %{pool: pool, agent_id: "ws", session_path: root, read_only: false}

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
