defmodule Ecrits.Doc.PoolTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Test.FakeEhwpRuntime

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)

    {:ok, pool} = start_supervised({Pool, name: nil})

    on_exit(fn -> restore(:ehwp, :runtime, prev) end)
    {:ok, pool: pool}
  end

  describe "open/3 + list/1" do
    test "opens an hwp document into the pool", %{pool: pool} do
      assert {:ok, doc_id} =
               Pool.open(pool, "contract.hwp", kind: :hwp, open_opts: [__text__: "제1조\n제2조"])

      assert is_binary(doc_id)

      assert [entry] = Pool.list(pool)
      assert entry.id == doc_id
      assert entry.kind == :hwp
      assert entry.path == "contract.hwp"
      assert entry.revision == 0
      assert entry.backing == :server
    end

    test "rejects unsupported kinds (office is deferred)", %{pool: pool} do
      assert {:error, {:unsupported_kind, :office}} =
               Pool.open(pool, "report.pptx", kind: :office)
    end

    test "two documents get independent editors (parallel docs)", %{pool: pool} do
      {:ok, a} = Pool.open(pool, "a.hwp", kind: :hwp, open_opts: [__text__: "제1조"])
      {:ok, b} = Pool.open(pool, "b.hwp", kind: :hwp, open_opts: [__text__: "제9조"])

      refute a == b
      assert {:server, pid_a} = Pool.route(pool, a)
      assert {:server, pid_b} = Pool.route(pool, b)
      refute pid_a == pid_b
    end
  end

  describe "with_doc/3 — serial delegation" do
    test "delegates an editor function for the given document", %{pool: pool} do
      {:ok, doc_id} =
        Pool.open(pool, "contract.hwp", kind: :hwp, open_opts: [__text__: "제2조 본문"])

      assert {:ok, %{text: text}} =
               Pool.with_doc(pool, doc_id, fn editor ->
                 Ecrits.Doc.Editor.read(editor)
               end)

      assert text =~ "제2조"
    end

    test "returns error for an unknown document", %{pool: pool} do
      assert {:error, :not_found} = Pool.with_doc(pool, "nope", fn _ -> :x end)
    end
  end

  describe "route/2" do
    test "server-backed documents route to their editor pid", %{pool: pool} do
      {:ok, doc_id} = Pool.open(pool, "c.hwp", kind: :hwp, open_opts: [__text__: "x"])
      assert {:server, pid} = Pool.route(pool, doc_id)
      assert is_pid(pid)
    end

    test "unknown document is not routable", %{pool: pool} do
      assert {:error, :not_found} = Pool.route(pool, "ghost")
    end
  end

  describe "close/2" do
    test "removes a document from the pool", %{pool: pool} do
      {:ok, doc_id} = Pool.open(pool, "d.hwp", kind: :hwp, open_opts: [__text__: "x"])
      assert :ok = Pool.close(pool, doc_id)
      assert Pool.list(pool) == []
      assert {:error, :not_found} = Pool.route(pool, doc_id)
    end
  end

  describe "default-name convenience API (design spec: Pool.open(path))" do
    setup do
      # The default-named pool is started by the application supervision tree.
      # The `open(path, opts)` / `list()` / `route(id)` (no explicit pool)
      # arities must resolve to it without the two-defaults arg ambiguity.
      assert is_pid(Process.whereis(Ecrits.Doc.Pool))
      doc_id = "default.hwp"
      on_exit(fn -> Pool.close(Ecrits.Doc.Pool, doc_id) end)
      {:ok, doc_id: doc_id}
    end

    test "Pool.open(path, opts) targets the default-named pool", %{doc_id: path} do
      assert {:ok, doc_id} =
               Pool.open(path, kind: :hwp, open_opts: [__text__: "제2조 본문"])

      assert is_binary(doc_id)
      assert Enum.any?(Pool.list(), &(&1.id == doc_id))
      assert {:server, pid} = Pool.route(doc_id)
      assert is_pid(pid)
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
