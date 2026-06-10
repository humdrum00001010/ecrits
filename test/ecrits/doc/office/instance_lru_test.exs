defmodule Ecrits.Doc.Office.InstanceLruTest do
  @moduledoc """
  The single serializing office governor (`Ecrits.Doc.Office.Instance`) caps the
  number of simultaneously-materialised UNO documents at its budget. Opening over
  budget evicts the least-recently-used doc (save-then-close, releasing the NIF
  resource) and a later op transparently rematerialises it from disk — so an
  older doc stays editable after eviction and the office never holds more than the
  budget of live docs at once.

  Runs against the REAL headless LibreOffice UNO NIF (the app-started, default-
  named `Office.Instance`); skips green when the arm is unavailable (no SDK build
  / no LOK install dir), exactly like `office_native_test.exs`. The default suite
  stays toolchain-free.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Office
  alias Ecrits.Doc.Office.Instance

  @fixture Path.expand("../../../fixtures/office/table.docx", __DIR__)

  setup do
    {:ok, native: uno_available?()}
  end

  test "opening over the budget evicts the LRU doc + transparently reopens it",
       %{} = context do
    unless context[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping Office.Instance LRU test")
    else
      budget = Instance.budget()

      # Open budget + 1 editable copies of the fixture, each edited with a UNIQUE
      # token, so we can prove the FIRST (soon-evicted) doc keeps its edits.
      n = budget + 1

      docs =
        for i <- 1..n do
          tmp =
            Path.join(
              System.tmp_dir!(),
              "ecrits_office_lru_#{i}_#{System.unique_integer([:positive])}.docx"
            )

          File.cp!(@fixture, tmp)
          on_exit(fn -> File.rm(tmp) end)

          {:ok, handle} = Office.open(tmp, kind: :docx)
          token = "LRU_TOKEN_#{i}"

          # Edit (replace the "Region" header cell text) — dirties the doc, so its
          # eviction must save-then-close (persisting this token to disk).
          {:ok, _} =
            Office.edit(
              handle,
              %{"op" => "replace_text", "query" => "Region", "replacement" => token}
            )

          %{handle: handle, path: tmp, token: token}
        end

      # The handle is a STABLE token, so the first doc's handle is still valid even
      # after the LRU save-then-closed it. Touching it must transparently
      # rematerialise it from disk WITH its saved token — proving the eviction
      # persisted + the reopen is invisible.
      first = hd(docs)

      assert {:ok, %{text: text}} = Office.read(first.handle, [])
      assert text =~ first.token, "evicted-then-reopened doc lost its edit"

      # And it is still EDITABLE after the round-trip (a fresh op succeeds).
      assert {:ok, _} =
               Office.edit(
                 first.handle,
                 %{
                   "op" => "replace_text",
                   "query" => first.token,
                   "replacement" => first.token <> "_v2"
                 }
               )

      assert {:ok, %{text: text2}} = Office.read(first.handle, [])
      assert text2 =~ first.token <> "_v2"

      # Clean up: closing every doc disposes its UNO session through the governor.
      Enum.each(docs, fn d -> Office.close(d.handle) end)
    end
  end

  defp uno_available? do
    case Office.open(@fixture, kind: :docx) do
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
