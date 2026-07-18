defmodule Ecrits.Doc.PoolTest do
  use ExUnit.Case, async: false

  alias Ecrits.Doc.{Editor, Pool}
  alias Ecrits.Test.FakeEhwpRuntime
  alias Ecrits.Test.FailingRollbackEhwpRuntime

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
      assert entry.backing == :server
    end

    test "rejects unsupported kinds (no registered backend)", %{pool: pool} do
      # docx/pptx/xlsx now route to `Ecrits.Doc.Office`; truly unregistered
      # kinds are still rejected.
      assert {:error, {:unsupported_kind, :pdf}} =
               Pool.open(pool, "report.pdf", kind: :pdf)
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

    @tag :edit_failure
    test "rollback fail-stop leaves no orphan and reopens one clean editor", %{pool: pool} do
      dir =
        Path.join(
          System.tmp_dir!(),
          "ecrits-pool-rollback-failure-#{System.unique_integer([:positive])}"
        )

      path = Path.join(dir, "contract.hwp")
      initial = "POOL_SOURCE_PREIMAGE"
      File.mkdir_p!(dir)
      File.write!(path, initial)
      on_exit(fn -> File.rm_rf(dir) end)

      :ok = FailingRollbackEhwpRuntime.reset()
      Application.put_env(:ehwp, :runtime, FailingRollbackEhwpRuntime)

      assert {:ok, document_id} = Pool.open(pool, path, kind: :hwp)
      assert {:server, original_editor} = Pool.route(pool, document_id)

      pool_state = :sys.get_state(pool)
      supervisor = pool_state.sup
      assert dynamic_child_pids(supervisor) == [original_editor]

      ref = Process.monitor(original_editor)
      owner = %{agent_id: "agent-a", instance_id: "instance-a", turn_id: "turn-a"}

      assert {:error,
              {:atomic_rollback_failed, :forced_save_export_failure,
               {:atomic_model_restore_failed, :forced_rollback_open_failure}}} =
               Editor.apply_batch_and_save(
                 original_editor,
                 [
                   {:apply,
                    %{
                      "op" => "insert_text",
                      "ref" => %{"section" => 0, "paragraph" => 0, "offset" => 0},
                      "text" => "REJECTED_POOL_EDIT"
                    }}
                 ],
                 owner: owner,
                 path: path,
                 format: :hwp
               )

      assert_receive {:DOWN, ^ref, :process, ^original_editor, _reason}, 5_000
      :ok = await_pool_drop(pool, document_id, 10)

      assert File.read!(path) == initial
      assert FailingRollbackEhwpRuntime.open_count() == 2
      assert {:error, :not_found} = Pool.route(pool, document_id)
      assert {:error, :not_found} = Pool.info_by_path(pool, path)
      assert Pool.list(pool) == []
      assert dynamic_child_pids(supervisor) == []
      assert :sys.get_state(pool).by_path == %{}

      :ok = FailingRollbackEhwpRuntime.allow_reopen()
      assert {:ok, ^document_id} = Pool.open(pool, path, kind: :hwp)
      assert {:server, reopened_editor} = Pool.route(pool, document_id)
      refute reopened_editor == original_editor
      assert dynamic_child_pids(supervisor) == [reopened_editor]
      assert FailingRollbackEhwpRuntime.open_count() == 3
      assert {:ok, %{text: ^initial}} = Editor.read(reopened_editor)
      assert Editor.dirty_snapshot(reopened_editor) == %{dirty?: false, revision: 0, owner: nil}
      assert Editor.history(reopened_editor) == []
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

  # NOTE (Phase 3): the global "active document" concept was DELETED from the
  # Pool — each agent's active doc now lives in its own AgentLive state, and the
  # per-doc viewer/ownership maps moved to `Ecrits.Workspace.Session`. The Pool is
  # now a pure server-side doc-runtime registry, so its old `set_active/active/
  # clear_active` tests were removed (see `workspace/session_test.exs` for the new
  # homes).

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

  defp dynamic_child_pids(supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
    |> Enum.sort()
  end

  defp await_pool_drop(_pool, _document_id, 0), do: {:error, :pool_drop_timeout}

  defp await_pool_drop(pool, document_id, attempts) do
    state = :sys.get_state(pool)

    if Map.has_key?(state.docs, document_id),
      do: await_pool_drop(pool, document_id, attempts - 1),
      else: :ok
  end
end
