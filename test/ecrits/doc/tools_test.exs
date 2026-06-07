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

  describe "tool catalog" do
    test "exposes the common doc.* surface with schemas and risk levels" do
      names = Tools.tools() |> Enum.map(&(&1["namespace"] <> "." <> &1["name"]))

      for n <- ~w(doc.context doc.list doc.open doc.create doc.read doc.find
                  doc.get doc.set doc.edit doc.save) do
        assert n in names, "expected #{n} in tool catalog"
      end

      # The consolidated surface is exactly ten tools; the former doc.inspect and
      # doc.apply_style are folded into doc.get / doc.set.
      assert "doc.inspect" not in names
      assert "doc.apply_style" not in names
      assert length(names) == 10

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

    test "the create tool schema advertises the `from` clone param" do
      create = Enum.find(Tools.tools(), &(&1["name"] == "create"))
      assert Map.has_key?(create["inputSchema"]["properties"], "from")
      assert create["description"] =~ "format of" or create["description"] =~ "CLONE"
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
      assert {:ok, %{"active_document" => nil}} = Tools.call(ctx(pool), "doc.context", %{})

      # Each caller's own `active_doc` wins.
      assert {:ok, %{"active_document" => ^b}} =
               Tools.call(%{pool: pool, agent_id: "x", active_doc: b}, "doc.context", %{})

      assert {:ok, %{"active_document" => ^a}} =
               Tools.call(%{pool: pool, agent_id: "y", active_doc: a}, "doc.context", %{})
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
      assert {:ok, %{"active_document" => ^a}} =
               Tools.call(agent_ctx(pool, path, "agent-1", a), "doc.context", %{})

      assert {:ok, %{"active_document" => ^b}} =
               Tools.call(agent_ctx(pool, path, "agent-2", b), "doc.context", %{})

      # An agent with no bound doc sees none.
      assert {:ok, %{"active_document" => nil}} =
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
                 "op" => %{"op" => "replace_text", "query" => "제2조", "replacement" => "제3조"},
                 "base_revision" => 0
               })

      # A different agent is fenced out.
      assert {:error, %{"error" => "forbidden", "document" => ^doc_id, "owned_by" => owned}} =
               Tools.call(agent_ctx(pool, path, "intruder", doc_id), "doc.edit", %{
                 "document" => doc_id,
                 "op" => %{"op" => "replace_text", "query" => "제3조", "replacement" => "X"},
                 "base_revision" => 1
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
                 "op" => %{"op" => "replace_text", "query" => "제1조", "replacement" => "제1조 (목적)"},
                 "base_revision" => 0
               })

      assert Session.owner(path, doc_id) == "fg"
    end

    test "a bare pool-only context has no ownership fence + legacy open reuse", %{pool: pool} do
      {:ok, %{"document" => doc_id}} =
        Tools.call(ctx(pool), "doc.open", %{"path" => "legacy.hwp", "open_opts" => [__text__: "x"]})

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
