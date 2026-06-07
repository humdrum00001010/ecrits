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
    test "open + read + find + edit target the second doc, not the viewed one", %{
      pool: pool,
      path: path
    } do
      # Viewed doc (HWP-B) — browser-backed by a viewer.
      {:ok, %{"document" => viewed}} =
        Tools.call(ctx(pool, path), "doc.open", %{
          "path" => "/abs/HWP-B.hwp",
          "open_opts" => [__text__: "VIEWED-B 제1조 (viewed only)"]
        })

      lv = idle_lv()
      :ok = Session.attach_viewer(path, viewed, lv)

      # Agent opens a SECOND, distinct headless doc (HWP-A) it must read.
      {:ok, %{"document" => second}} =
        Tools.call(ctx(pool, path), "doc.open", %{
          "path" => "/abs/HWP-A.hwp",
          "open_opts" => [__text__: "SECOND-A 제9조 (source text)"]
        })

      # (a) distinct ids
      refute second == viewed

      # The viewed doc routes to the browser; the second routes to its server NIF.
      assert {:browser, ^lv} = Session.route(path, viewed)
      assert {:server, _editor} = Pool.route(pool, second)

      # (b) doc.read / doc.find on the second return ITS content (not the viewed one).
      assert {:ok, %{"text" => text}} =
               Tools.call(ctx(pool, path), "doc.read", %{"document" => second})

      assert text =~ "SECOND-A"
      refute text =~ "VIEWED-B"

      assert {:ok, %{"matches" => [m | _]}} =
               Tools.call(ctx(pool, path), "doc.find", %{"document" => second, "pattern" => "제9조"})

      assert m["text"] =~ "제9조"

      # (c) an edit lands on the second doc ONLY.
      assert {:ok, %{"ok" => true, "revision" => 1}} =
               Tools.call(ctx(pool, path), "doc.edit", %{
                 "document" => second,
                 "op" => %{"op" => "replace_text", "query" => "제9조", "replacement" => "ARTICLE9"},
                 "base_revision" => 0
               })

      assert {:ok, %{"text" => after_text}} =
               Tools.call(ctx(pool, path), "doc.read", %{"document" => second})

      assert after_text =~ "ARTICLE9"

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
          "path" => "/abs/L3-8.hwp",
          "open_opts" => [__text__: "L3-8 SOURCE 제3조"]
        })

      {:ok, %{"document" => doc2}} =
        Tools.call(ctx(pool, path), "doc.open", %{
          "path" => "/abs/plan.hwp",
          "open_opts" => [__text__: "PLAN VIEWED 제1조"]
        })

      lv = idle_lv()
      :ok = Session.attach_viewer(path, doc1, lv)
      :ok = Session.attach_viewer(path, doc2, lv)

      # Agent is asked to use the text of the *previously-viewed* L3-8 file. doc1
      # has no viewer (the viewer moved to doc2), so it routes to its server NIF
      # and the read returns L3-8's own text, not the currently-viewed doc2.
      assert reopened = doc1
      assert Session.viewer(path, doc1) == nil
      assert {:server, _} = Pool.route(pool, doc1)

      assert {:ok, %{"text" => text}} =
               Tools.call(ctx(pool, path), "doc.read", %{"document" => reopened})

      assert text =~ "L3-8 SOURCE"
      refute text =~ "PLAN VIEWED"
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
