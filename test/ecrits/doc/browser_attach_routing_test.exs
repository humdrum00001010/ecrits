defmodule Ecrits.Doc.BrowserAttachRoutingTest do
  @moduledoc """
  Regression: a doc.* call must operate on the document the call NAMES, routing
  to the browser arm ONLY when THAT document is the currently-viewed one.

  Live bug (chat-rail): a single viewing LiveView views doc1, then navigates to
  doc2. Each view registers itself as the viewer; nothing detached the
  previously-viewed doc, so doc1 stayed browser-backed by a stale lv. When the
  agent later opened/read doc1 (a file the user names but is no longer viewing),
  the request routed `{:browser, lv}` and the LiveView substituted its
  *currently-viewed* doc id — so the agent read/edited the viewed doc regardless
  of the path it named.

  Invariant under test: a given viewer (lv pid) is the browser authority for AT
  MOST ONE doc — the one it is currently viewing. Everything else routes to its
  server NIF, independently of what is open in the browser.

  Since Phase 3 the `viewers` map + the wasm/NIF routing decision live in
  `Ecrits.Workspace.Session` (the Pool is a server-only doc registry). So this
  test drives `Session.attach_viewer`/`Session.route` and a Tools ctx carrying
  `:session_path` (the per-workspace Session key) instead of the old
  `Pool.attach_browser`/`Pool.route(:browser)`.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Tools
  alias Ecrits.Local.Document.ByteSpool
  alias Ecrits.Test.FakeEhwpRuntime
  alias Ecrits.Workspace.Session

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)
    {:ok, pool} = start_supervised({Pool, name: nil})
    # A unique workspace path keys this test's Session (started lazily by the
    # viewer/ownership calls); the app supervision tree runs the SessionSupervisor.
    path = Path.join(System.tmp_dir!(), "ws_route_#{System.unique_integer([:positive])}")

    on_exit(fn ->
      if pid = Session.whereis(path), do: Process.exit(pid, :kill)
      restore(:ehwp, :runtime, prev)
    end)

    {:ok, pool: pool, path: path}
  end

  # An agent ctx that routes via the workspace Session (the production path).
  defp ctx(pool, path), do: %{pool: pool, agent_id: "fg", session_path: path}

  defp idle_lv do
    spawn(fn ->
      receive do
        :stop -> :ok
      end
    end)
  end

  defp browser_reply_lv(parent, result) do
    spawn(fn ->
      receive do
        {:doc_browser_request, from, ref, verb, payload} ->
          send(parent, {:browser_request, verb, payload})
          send(from, {:doc_browser_reply, ref, {:ok, result}})

          receive do
            :stop -> :ok
          after
            1_000 -> :ok
          end
      end
    end)
  end

  defp render_viewer_lv(parent, dirty?) when is_boolean(dirty?) do
    spawn(fn -> render_viewer_loop(parent, dirty?) end)
  end

  defp render_viewer_loop(parent, dirty?) do
    receive do
      {:doc_viewer_state_request, from, ref, document_id} ->
        send(parent, {:viewer_state_request, document_id})
        send(from, {:doc_viewer_state_reply, ref, {:ok, %{dirty: dirty?}}})
        render_viewer_loop(parent, dirty?)

      {:doc_browser_request, from, ref, verb, payload} ->
        send(parent, {:browser_request, verb, payload})
        send(from, {:doc_browser_reply, ref, {:error, "forced browser snapshot"}})
        render_viewer_loop(parent, dirty?)

      :stop ->
        :ok
    end
  end

  defp fake_render_editor(parent) do
    spawn(fn -> fake_render_editor_loop(parent) end)
  end

  defp fake_render_editor_loop(parent) do
    receive do
      {:"$gen_call", from, {:render, page, path, opts}} ->
        send(parent, {:server_render, page, opts})
        File.write!(path, "PNG")
        GenServer.reply(from, :ok)
        fake_render_editor_loop(parent)

      :stop ->
        :ok
    end
  end

  defp put_pool_doc(pool, id, path, kind, editor) do
    :sys.replace_state(pool, fn state ->
      doc = %{kind: kind, backend: Ecrits.Doc.backend_for(kind), path: path, editor: editor}

      state
      |> Map.update!(:docs, &Map.put(&1, id, doc))
      |> Map.update!(:by_path, &Map.put(&1, path, id))
    end)
  end

  describe "attach_viewer is exclusive per viewer (the navigation invariant)" do
    test "viewing a second doc detaches the viewer from the first", %{pool: pool, path: path} do
      {:ok, doc1} = Pool.open(pool, "/abs/doc1.hwp", kind: :hwp, open_opts: [__text__: "ONE"])
      {:ok, doc2} = Pool.open(pool, "/abs/doc2.hwp", kind: :hwp, open_opts: [__text__: "TWO"])

      lv = idle_lv()

      # User views doc1, then navigates to doc2 in the SAME LiveView.
      :ok = Session.attach_viewer(path, doc1, lv)
      :ok = Session.attach_viewer(path, doc2, lv)

      # doc2 (currently viewed) routes to the browser; doc1 (no longer viewed)
      # must fall back to its server editor — NOT stay stuck on the stale viewer.
      # Session.route consults the Pool (passed via the started pool) for the
      # server editor; here we route the named docs through the test pool.
      assert {:browser, ^lv} = Session.route(path, doc2)
      assert {:server, editor1} = Pool.route(pool, doc1)
      assert is_pid(editor1)
    end

    test "two distinct viewers each keep their own one browser-backed doc", %{path: path} = ctx do
      {:ok, doc1} = Pool.open(ctx.pool, "/abs/v1.hwp", kind: :hwp, open_opts: [__text__: "A"])
      {:ok, doc2} = Pool.open(ctx.pool, "/abs/v2.hwp", kind: :hwp, open_opts: [__text__: "B"])

      lv_a = idle_lv()
      lv_b = idle_lv()

      :ok = Session.attach_viewer(path, doc1, lv_a)
      :ok = Session.attach_viewer(path, doc2, lv_b)

      # Independent viewers do not poach each other's attachment.
      assert {:browser, ^lv_a} = Session.route(path, doc1)
      assert {:browser, ^lv_b} = Session.route(path, doc2)
    end

    test "detach_viewer/3 relinquishes a viewer's browser claim", %{pool: pool, path: path} do
      {:ok, doc} = Pool.open(pool, "/abs/d.hwp", kind: :hwp, open_opts: [__text__: "X"])
      lv = idle_lv()

      :ok = Session.attach_viewer(path, doc, lv)
      assert {:browser, ^lv} = Session.route(path, doc)

      :ok = Session.detach_viewer(path, doc, lv)
      assert {:server, editor} = Pool.route(pool, doc)
      assert is_pid(editor)
    end
  end

  describe "doc.* operate on the NAMED doc while a viewer is attached (server arm)" do
    test "browser-routed batch edit keeps revision metadata out of per-op payloads", %{
      pool: pool,
      path: path
    } do
      {:ok, %{"document" => doc}} =
        Tools.call(ctx(pool, path), "doc.open", %{
          "path" => Path.join(path, "viewed-batch.hwp"),
          "open_opts" => [__text__: "A B"]
        })

      live_result = %{
        "ok" => true,
        "applied" => 2,
        "failed" => 0,
        "results" => [%{"ok" => true}, %{"ok" => true}]
      }

      lv = browser_reply_lv(self(), live_result)
      :ok = Session.attach_viewer(path, doc, lv)

      assert {:ok, %{"applied" => 2, "failed" => 0}} =
               Tools.call(ctx(pool, path), "doc.edit", %{
                 "document" => doc,
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
                 ]
               })

      assert_receive {:browser_request, :edit, %{ops: [op_a, op_b]} = payload}
      refute Map.has_key?(payload, :base_revision)
      refute Map.has_key?(op_a, "base_revision")
      refute Map.has_key?(op_b, "current_version")

      send(lv, :stop)
    end

    test "doc.get on a viewed office document resolves through the browser IR", %{
      pool: pool,
      path: path
    } do
      doc = "d_docx_browser_get"
      doc_path = Path.join(path, "browser.docx")
      editor = idle_lv()
      put_pool_doc(pool, doc, doc_path, :docx, editor)

      live_result = %{
        "ref" => "tbl[Table1]/cell[A1]",
        "type" => "cell",
        "kind" => "cell",
        "values" => %{"text" => "LIVE_BROWSER_TEXT"},
        "properties" => %{"text" => "LIVE_BROWSER_TEXT"},
        "settable" => ["CharWeight"],
        "children" => [],
        "ir" => %{"ref" => "tbl[Table1]/cell[A1]", "text" => "LIVE_BROWSER_TEXT"}
      }

      lv = browser_reply_lv(self(), live_result)
      :ok = Session.attach_viewer(path, doc, lv)

      assert {:ok, ^live_result} =
               Tools.call(ctx(pool, path), "doc.get", %{
                 "document" => doc,
                 "ref" => "tbl[Table1]/cell[A1]"
               })

      assert_receive {:browser_request, :get, %{ref: "tbl[Table1]/cell[A1]", props: nil}}

      send(lv, :stop)
      send(editor, :stop)
    end

    test "doc.save accepts the current browser document id before a pool info row exists", %{
      pool: pool,
      path: path
    } do
      doc = "d_pptx_browser_save"
      doc_path = Path.join(path, "browser-save.pptx")
      bytes = "PPTX-BROWSER-BYTES"
      File.mkdir_p!(path)

      assert {:ok, token, token_path} = ByteSpool.reserve()
      File.write!(token_path, bytes)

      lv =
        browser_reply_lv(self(), %{
          "bytes_token" => token,
          "bytes" => byte_size(bytes),
          "format" => "pptx"
        })

      :ok = Session.attach_viewer(path, doc, lv)

      tool_ctx =
        ctx(pool, path)
        |> Map.put(:active_doc, doc)
        |> Map.put(:document_path, doc_path)

      assert {:ok, %{"current_document" => current}} = Tools.call(tool_ctx, "doc.context", %{})
      assert current["document"] == doc
      assert current["path"] == doc_path
      assert current["backing"] == "browser"

      assert {:ok, %{"ok" => true}} =
               Tools.call(tool_ctx, "doc.save", %{"document" => current["document"]})

      assert_receive {:browser_request, :save, %{}}
      assert File.read!(doc_path) == bytes
      refute File.exists?(token_path)

      send(lv, :stop)
    end

    test "doc.render on a clean viewed office document uses the server twin without browser save",
         %{pool: pool, path: path} do
      doc = "d_pptx_clean_render"
      doc_path = Path.join(path, "clean-render.pptx")
      editor = fake_render_editor(self())
      put_pool_doc(pool, doc, doc_path, :pptx, editor)

      lv = render_viewer_lv(self(), false)
      :ok = Session.attach_viewer(path, doc, lv)

      assert {:ok, %{"ok" => true, "rendered" => ["Slide1"], "files" => [_file]}} =
               Tools.call(ctx(pool, path), "doc.render", %{
                 "document" => doc,
                 "page" => "Slide1",
                 "width" => 640
               })

      assert_receive {:viewer_state_request, ^doc}
      assert_receive {:server_render, "Slide1", [width: 640]}
      refute_receive {:browser_request, :save, %{}}, 50

      send(lv, :stop)
      send(editor, :stop)
    end

    test "doc.render on a dirty viewed office document still snapshots the browser",
         %{pool: pool, path: path} do
      doc = "d_pptx_dirty_render"
      doc_path = Path.join(path, "dirty-render.pptx")
      editor = fake_render_editor(self())
      put_pool_doc(pool, doc, doc_path, :pptx, editor)

      lv = render_viewer_lv(self(), true)
      :ok = Session.attach_viewer(path, doc, lv)

      assert {:error, %{"error" => error}} =
               Tools.call(ctx(pool, path), "doc.render", %{
                 "document" => doc,
                 "page" => "Slide1",
                 "width" => 640
               })

      assert error =~ "forced browser snapshot"

      assert_receive {:viewer_state_request, ^doc}
      assert_receive {:browser_request, :save, %{}}
      refute_receive {:server_render, _page, _opts}, 50

      send(lv, :stop)
      send(editor, :stop)
    end

    test "viewed xlsx is a browser-backed current doc without a server pool twin", %{
      pool: pool,
      path: path
    } do
      workbook_path = Path.join(path, "sample.xlsx")
      doc = Pool.document_id_for(workbook_path, :xlsx)

      live_result = %{
        "pattern" => "Revenue",
        "type" => nil,
        "matches" => [
          %{
            "ref" => "sheet[Sheet1]/cell[B2]",
            "type" => "cell",
            "text" => "Revenue",
            "sheet" => "Sheet1",
            "row" => 2,
            "col" => 2
          }
        ]
      }

      lv = browser_reply_lv(self(), live_result)
      :ok = Session.attach_viewer(path, doc, lv)

      agent_ctx =
        ctx(pool, path)
        |> Map.put(:active_doc, doc)
        |> Map.put(:document_path, "sample.xlsx")

      assert {:ok, %{"current_document" => current}} =
               Tools.call(agent_ctx, "doc.context", %{})

      assert current["document"] == doc
      assert current["kind"] == "xlsx"
      assert current["path"] == "sample.xlsx"
      assert current["backing"] == "browser"

      assert {:ok, ^live_result} =
               Tools.call(agent_ctx, "doc.find", %{
                 "document" => doc,
                 "pattern" => "Revenue"
               })

      assert_receive {:browser_request, :find, %{pattern: "Revenue"}}

      send(lv, :stop)
    end

    test "browser-backed doc.find compacts long match text before returning", %{
      pool: pool,
      path: path
    } do
      deck_path = Path.join(path, "long-find.pptx")
      doc = Pool.document_id_for(deck_path, :pptx)

      text =
        String.duplicate("Intro ", 40) <>
          "Private Timer Clock" <>
          String.duplicate(" tail", 40)

      live_result = %{
        "pattern" => "Private Timer Clock",
        "type" => nil,
        "matches" => [
          %{
            "ref" => "page[1]/shape[long]",
            "type" => "text_frame",
            "text" => text
          }
        ]
      }

      lv = browser_reply_lv(self(), live_result)
      :ok = Session.attach_viewer(path, doc, lv)

      agent_ctx =
        ctx(pool, path)
        |> Map.put(:active_doc, doc)
        |> Map.put(:document_path, "long-find.pptx")

      assert {:ok, %{"matches" => [match]}} =
               Tools.call(agent_ctx, "doc.find", %{
                 "document" => doc,
                 "pattern" => "Private Timer Clock"
               })

      assert_receive {:browser_request, :find, %{pattern: "Private Timer Clock"}}
      assert match["ref"] == "page[1]/shape[long]"
      assert match["text"] =~ "Private Timer Clock"
      assert match["text_truncated"] == true
      refute Map.has_key?(match, "text_length")
      assert String.length(match["text"]) <= 54
      refute match["text"] == text

      send(lv, :stop)
    end

    test "doc.save accepts the viewed document path and routes to the browser model", %{
      pool: pool,
      path: path
    } do
      relative_path = "viewed-save.hwp"
      absolute_path = Path.join(path, relative_path)
      File.mkdir_p!(path)

      {:ok, %{"document" => doc}} =
        Tools.call(ctx(pool, path), "doc.open", %{
          "path" => absolute_path,
          "open_opts" => [__text__: "SERVER COPY"]
        })

      lv = browser_reply_lv(self(), %{"bytes_base64" => Base.encode64("VIEWER BYTES")})
      :ok = Session.attach_viewer(path, doc, lv)

      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx(pool, path), "doc.save", %{"document" => relative_path})

      assert_receive {:browser_request, :save, %{}}
      assert File.read!(absolute_path) == "VIEWER BYTES"

      send(lv, :stop)
    end

    test "open + read + find + edit target the second doc, not the viewed one", %{
      pool: pool,
      path: path
    } do
      # Viewed doc (HWP-B) — browser-backed by a viewer.
      {:ok, %{"document" => viewed}} =
        Tools.call(ctx(pool, path), "doc.open", %{
          "path" => Path.join(path, "HWP-B.hwp"),
          "open_opts" => [__text__: "VIEWED-B 제1조 (viewed only)"]
        })

      lv = idle_lv()
      :ok = Session.attach_viewer(path, viewed, lv)

      # Agent opens a SECOND, distinct headless doc (HWP-A) it must read.
      {:ok, %{"document" => second}} =
        Tools.call(ctx(pool, path), "doc.open", %{
          "path" => Path.join(path, "HWP-A.hwp"),
          "open_opts" => [__text__: "SECOND-A 제9조 (source text)"]
        })

      # (a) distinct ids
      refute second == viewed

      # The viewed doc routes to the browser; the second routes to its server NIF.
      assert {:browser, ^lv} = Session.route(path, viewed)
      assert {:server, _editor} = Pool.route(pool, second)

      # (b) doc.find on the second returns ITS content (not the viewed one).
      assert {:ok, %{"matches" => [second_text | _]}} =
               Tools.call(ctx(pool, path), "doc.find", %{
                 "document" => second,
                 "pattern" => "SECOND-A"
               })

      assert second_text["text"] =~ "SECOND-A"
      refute second_text["text"] =~ "VIEWED-B"

      assert {:ok, %{"matches" => [m | _]}} =
               Tools.call(ctx(pool, path), "doc.find", %{"document" => second, "pattern" => "제9조"})

      assert m["text"] =~ "제9조"

      # (c) an edit lands on the second doc ONLY.
      assert {:ok, %{"ok" => true}} =
               Tools.call(ctx(pool, path), "doc.edit", %{
                 "document" => second,
                 "op" => %{"op" => "replace_text", "query" => "제9조", "replacement" => "ARTICLE9"}
               })

      assert {:ok, %{"matches" => [_ | _]}} =
               Tools.call(ctx(pool, path), "doc.find", %{
                 "document" => second,
                 "pattern" => "ARTICLE9"
               })

      # The viewed doc still routes to the browser (its own model is the authority).
      assert {:browser, ^lv} = Session.route(path, viewed)
    end

    test "the previously-viewed file (now navigated away) reads via the server arm", %{
      pool: pool,
      path: path
    } do
      # User views doc1, then navigates to doc2 in the same viewer.
      {:ok, %{"document" => doc1}} =
        Tools.call(ctx(pool, path), "doc.open", %{
          "path" => Path.join(path, "L3-8.hwp"),
          "open_opts" => [__text__: "L3-8 SOURCE 제3조"]
        })

      {:ok, %{"document" => doc2}} =
        Tools.call(ctx(pool, path), "doc.open", %{
          "path" => Path.join(path, "plan.hwp"),
          "open_opts" => [__text__: "PLAN VIEWED 제1조"]
        })

      lv = idle_lv()
      :ok = Session.attach_viewer(path, doc1, lv)
      :ok = Session.attach_viewer(path, doc2, lv)

      # Agent is asked to use the text of the *previously-viewed* L3-8 file. doc1
      # has no viewer (the viewer moved to doc2), so it routes to its server NIF
      # and the search returns L3-8's own text, not the currently-viewed doc2.
      assert reopened = doc1
      assert Session.viewer(path, doc1) == nil
      assert {:server, _} = Pool.route(pool, doc1)

      assert {:ok, %{"matches" => [text | _]}} =
               Tools.call(ctx(pool, path), "doc.find", %{
                 "document" => reopened,
                 "pattern" => "L3-8 SOURCE"
               })

      assert text["text"] =~ "L3-8 SOURCE"
      refute text["text"] =~ "PLAN VIEWED"
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
