defmodule Ecrits.Doc.AutoSaveTest do
  @moduledoc """
  Turn-completion auto-save safety net (Pool + Editor layer).

  The doc-editing agent may stall/stop BEFORE its final `doc.save`, leaving
  in-memory edits that never reach disk. On agent-turn completion the workspace
  enumerates `Pool.dirty_docs/1` and `Editor.save/2`s each one, so the artifact
  persists autonomously. These tests exercise that exact path WITHOUT the
  LiveView: dirty tracking, the Pool's conservative dirty+has-path+server-backed
  predicate, the disk write, and idempotency.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Pool
  alias Ecrits.Test.FakeEhwpRuntime

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.put_env(:ehwp, :runtime, FakeEhwpRuntime)

    {:ok, pool} = start_supervised({Pool, name: nil})

    dir = Path.join(System.tmp_dir!(), "ecrits_auto_save_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      restore(:ehwp, :runtime, prev)
      File.rm_rf(dir)
    end)

    {:ok, pool: pool, dir: dir}
  end

  # The turn-end auto-save, reproduced exactly as `WorkspaceLive` runs it: the
  # set of docs Pool deems persistable, each saved via the owning Editor.
  defp run_turn_end_auto_save(pool, format \\ :hwp) do
    docs = Pool.dirty_docs(pool)

    saved =
      Enum.flat_map(docs, fn %{editor: editor, path: path} ->
        case Editor.save(editor, format: format, path: path) do
          :ok -> [path]
          {:ok, _} -> [path]
          {:error, _} -> []
        end
      end)

    {docs, saved}
  end

  describe "dirty tracking on the Editor" do
    test "a freshly-opened doc with no edits is NOT dirty", %{pool: pool, dir: dir} do
      path = Path.join(dir, "clean.hwp")
      {:ok, id} = Pool.open(pool, path, kind: :hwp, open_opts: [__text__: "제1조"])

      assert {:server, editor} = Pool.route(pool, id)
      assert Editor.dirty?(editor) == false
      assert %{dirty: false} = Editor.info(editor)
    end

    test "applying an edit marks the doc dirty", %{pool: pool, dir: dir} do
      path = Path.join(dir, "edited.hwp")
      {:ok, id} = Pool.open(pool, path, kind: :hwp, open_opts: [__text__: "제1조 (목적)"])
      {:server, editor} = Pool.route(pool, id)

      assert {:ok, _} =
               Editor.apply(
                 editor,
                 %{op: "replace_text", query: "제1조", replacement: "ARTICLE-1"}
               )

      assert Editor.dirty?(editor) == true
      assert %{dirty: true} = Editor.info(editor)
    end

    test "a successful save marks the doc clean again",
         %{pool: pool, dir: dir} do
      path = Path.join(dir, "saved.hwp")
      {:ok, id} = Pool.open(pool, path, kind: :hwp, open_opts: [__text__: "제1조"])
      {:server, editor} = Pool.route(pool, id)

      {:ok, _} = Editor.apply(editor, %{op: "replace_text", query: "제1조", replacement: "X"})
      assert Editor.dirty?(editor)

      assert {:ok, _} = Editor.save(editor, format: :hwp, path: path)
      refute Editor.dirty?(editor)
      assert %{dirty: false} = Editor.info(editor)
    end
  end

  describe "Pool.dirty_docs/1 predicate" do
    test "lists only server-backed docs that are dirty AND have a save path",
         %{pool: pool, dir: dir} do
      dirty_path = Path.join(dir, "dirty.hwp")
      clean_path = Path.join(dir, "clean.hwp")

      {:ok, dirty_id} = Pool.open(pool, dirty_path, kind: :hwp, open_opts: [__text__: "제1조"])
      {:ok, _clean_id} = Pool.open(pool, clean_path, kind: :hwp, open_opts: [__text__: "제9조"])

      {:server, dirty_editor} = Pool.route(pool, dirty_id)

      {:ok, _} =
        Editor.apply(dirty_editor, %{op: "replace_text", query: "제1조", replacement: "Y"})

      entries = Pool.dirty_docs(pool)
      assert [%{id: ^dirty_id, path: ^dirty_path, kind: :hwp, editor: ^dirty_editor}] = entries
    end

    test "a doc with no edits never appears", %{pool: pool, dir: dir} do
      path = Path.join(dir, "pristine.hwp")
      {:ok, _} = Pool.open(pool, path, kind: :hwp, open_opts: [__text__: "제1조"])
      assert Pool.dirty_docs(pool) == []
    end
  end

  describe "turn-end auto-save (the safety net)" do
    test "persists an unsaved edited doc to disk and clears its dirty flag",
         %{pool: pool, dir: dir} do
      path = Path.join(dir, "worksheet.hwp")

      # A cloned/created worksheet: open with template text, agent edits it...
      {:ok, id} =
        Pool.open(pool, path, kind: :hwp, open_opts: [__text__: "TEMPLATE-제1조 (목적)"])

      {:server, editor} = Pool.route(pool, id)

      {:ok, _} =
        Editor.apply(editor, %{op: "replace_text", query: "TEMPLATE", replacement: "FILLED"})

      # ...but the turn STALLS before doc.save: nothing on disk yet.
      refute File.exists?(path)
      assert Editor.dirty?(editor)

      # Turn-end auto-save fires.
      {docs, saved} = run_turn_end_auto_save(pool)
      assert [%{id: ^id}] = docs
      assert saved == [path]

      # The artifact persisted autonomously: the file on disk reflects the edit.
      assert File.exists?(path)
      assert {:ok, bytes} = File.read(path)
      assert bytes =~ "FILLED"
      refute bytes =~ "TEMPLATE"

      # And the doc is no longer dirty.
      refute Editor.dirty?(editor)

      # Re-opening reads the edited content back (round-trips through disk).
      assert {:ok, %{text: text}} = Editor.read(editor)
      assert text =~ "FILLED"
    end

    test "a turn that already doc.save'd leaves nothing to persist (no redundant write)",
         %{pool: pool, dir: dir} do
      path = Path.join(dir, "already_saved.hwp")
      {:ok, id} = Pool.open(pool, path, kind: :hwp, open_opts: [__text__: "제1조"])
      {:server, editor} = Pool.route(pool, id)

      {:ok, _} =
        Editor.apply(editor, %{op: "replace_text", query: "제1조", replacement: "SAVED"})

      assert {:ok, _} = Editor.save(editor, format: :hwp, path: path)
      mtime_before = File.stat!(path).mtime

      # Turn ends: the agent already saved, so the pool reports nothing dirty.
      {docs, saved} = run_turn_end_auto_save(pool)
      assert docs == []
      assert saved == []

      # File untouched by the safety net.
      assert File.stat!(path).mtime == mtime_before
    end

    test "a doc the agent never edited is not auto-written", %{pool: pool, dir: dir} do
      path = Path.join(dir, "untouched.hwp")
      {:ok, _id} = Pool.open(pool, path, kind: :hwp, open_opts: [__text__: "제1조"])

      {docs, saved} = run_turn_end_auto_save(pool)
      assert docs == []
      assert saved == []
      refute File.exists?(path)
    end

    test "is idempotent — running the auto-save twice does not re-write a clean doc",
         %{pool: pool, dir: dir} do
      path = Path.join(dir, "idempotent.hwp")
      {:ok, id} = Pool.open(pool, path, kind: :hwp, open_opts: [__text__: "제1조"])
      {:server, editor} = Pool.route(pool, id)
      {:ok, _} = Editor.apply(editor, %{op: "replace_text", query: "제1조", replacement: "Z"})

      {_docs, saved1} = run_turn_end_auto_save(pool)
      assert saved1 == [path]
      refute Editor.dirty?(editor)

      # Second pass: the doc is clean -> no-op.
      {docs2, saved2} = run_turn_end_auto_save(pool)
      assert docs2 == []
      assert saved2 == []
    end
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
