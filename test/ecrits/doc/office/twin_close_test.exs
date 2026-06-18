defmodule Ecrits.Doc.Office.TwinCloseTest do
  @moduledoc """
  Closing an OFFICE document must dispose its server Pool twin AND release the
  LibreOffice `.~lock.<file>#`. The twin holds a live libreofficex UNO session;
  before `Pool.close_by_path/2` a closed tab left the session (and its on-disk
  lock) held open until an LRU eviction that never comes with few docs open — the
  user-reported "close of libre never works".

  Runs against the REAL headless UNO NIF; self-skips green when the arm is absent
  (no SDK build / no LOK install dir), exactly like `office_native_test.exs`. The
  default suite stays toolchain-free.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Editor
  alias Ecrits.Doc.Office
  alias Ecrits.Doc.Pool

  @fixture Path.expand("../../../fixtures/office/slides.pptx", __DIR__)

  setup do
    {:ok, native: uno_available?()}
  end

  test "Pool.close_by_path disposes the twin and releases its .~lock.", %{} = ctx do
    if not ctx[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping office twin-close lock test")
    else
      dir =
        Path.join(System.tmp_dir!(), "ecrits-twin-close-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      path = Path.join(dir, "close_me.pptx")
      File.cp!(@fixture, path)
      lock = Path.join(dir, ".~lock.close_me.pptx#")

      {:ok, id} = Pool.open(path, kind: :pptx)
      # Materialise the UNO session (which creates the lock) via a read, exactly
      # like a viewer/agent op would — Pool.open itself is lazy.
      Pool.with_doc(id, fn editor -> Editor.read(editor, []) end)

      assert wait_until(fn -> File.exists?(lock) end),
             "expected the libreofficex .~lock. once the session materialises"

      # The explicit close (what closing the tab now does).
      assert :ok = Pool.close_by_path(path)

      assert wait_until(fn -> not File.exists?(lock) end),
             "the .~lock.<file># must be released when the office twin is closed"

      assert {:error, :not_found} = Pool.info_by_path(path),
             "the pool twin must be gone after close"
    end
  end

  # Poll up to ~6s (the close runs Editor.terminate -> Office.close -> Instance
  # {:close} -> uno_close on the serialised office governor, which can queue).
  defp wait_until(fun, tries \\ 60)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(100)
      wait_until(fun, tries - 1)
    end
  end

  defp uno_available? do
    case Office.open(@fixture, kind: :pptx) do
      {:ok, handle} ->
        Office.close(handle)
        true

      _ ->
        false
    end
  rescue
    _ -> false
  end
end
