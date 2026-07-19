defmodule Ecrits.Doc.ProjectionStaleCharEchoTest do
  @moduledoc """
  Regression for the take5 contract rehearsal failure (turn e02f570a): within a
  turn the mounted VFS keeps serving the agent's accepted raw projection while
  the engine normalizes applied aggregate edits — derived range ops merge char
  runs and reassign read-only run ids. The next write-back from that stale raw
  view used to be rejected with `{:invalid_property, "charShapeId"}`, bricking
  every later commit of the turn (payment table, schedule, signature skipped).
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Projection

  @fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)

  setup do
    {:ok, native: Ehwp.available?()}
  end

  test "multi-commit turn survives engine run-merge normalization", tags do
    if not tags.native do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping stale char echo write_back e2e")
    else
      path =
        Path.join(
          System.tmp_dir!(),
          "stale_char_echo_#{System.unique_integer([:positive])}.hwpx"
        )

      File.cp!(@fixture, path)
      on_exit(fn -> File.rm(path) end)

      {:ok, pristine} = Projection.project_file(path)
      doc0 = decode(pristine)

      # A paragraph spanning several native char runs: the aggregate commit
      # below derives range ops that make the engine merge its runs.
      {multi_text, run_count} = first_multi_run_paragraph(doc0)
      assert run_count >= 2

      # A different single-run paragraph standing in for the later label edit.
      label_text = first_single_run_paragraph(doc0, multi_text)

      # Commit 1: aggregate-only paragraph edit (the agent's usual move — the
      # raw view's char runs are left untouched).
      merged_text = "이 조항은 데모 회귀 검증을 위해 병합 재작성되었다."
      raw1 = doc0 |> update_aggregate_text(multi_text, merged_text) |> encode()
      assert {:ok, %{applied: applied1}} = Projection.write_back(path, raw1)
      assert applied1 >= 1

      # Commit 2: the agent re-sends its own accepted raw unchanged. The char
      # layer is now a stale pre-merge echo of canonical state; this used to
      # return {:error, {:invalid_property, "charShapeId"}}.
      assert {:ok, %{applied: 0}} = Projection.write_back(path, raw1)

      # Commit 3: a fresh edit elsewhere on top of the stale raw still lands.
      label_replacement = label_text <> " 미기재"
      raw2 = raw1 |> decode() |> update_aggregate_text(label_text, label_replacement) |> encode()
      assert {:ok, %{applied: applied3}} = Projection.write_back(path, raw2)
      assert applied3 >= 1

      {:ok, final} = Projection.project_file(path)
      assert final =~ merged_text
      assert final =~ label_replacement
    end
  end

  # Regression for the take14 contract demo (2026-07-19): after a large
  # committed fill, the agent's client applied its table-insert patch to a
  # full-file base READ BEFORE that commit. Committing such a stale base would
  # silently revert the whole fill, so the differ must reject it as structural
  # — and the same insert restaged from a fresh reread must land. This is the
  # contract behind the surface's on_einval recovery guidance.
  test "a stale full-file base composed before the last commit is rejected, a fresh reread lands",
       tags do
    if not tags.native do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping stale-base write_back e2e")
    else
      path =
        Path.join(
          System.tmp_dir!(),
          "stale_base_#{System.unique_integer([:positive])}.hwpx"
        )

      File.cp!(@fixture, path)
      on_exit(fn -> File.rm(path) end)

      {:ok, pristine} = Projection.project_file(path)
      doc0 = decode(pristine)

      {multi_text, run_count} = first_multi_run_paragraph(doc0)
      assert run_count >= 2
      anchor_text = first_single_run_paragraph(doc0, multi_text)

      # Commit 1: the big fill (aggregate edit whose application merges runs).
      merged_text = "이 조항은 스테일 베이스 회귀 검증을 위해 병합 재작성되었다."
      raw1 = doc0 |> update_aggregate_text(multi_text, merged_text) |> encode()
      assert {:ok, %{applied: applied1}} = Projection.write_back(path, raw1)
      assert applied1 >= 1

      table = %{
        "type" => "table",
        "cells" => [["단계", "금액"], ["착수", "26,400,000"]]
      }

      # The client patches its PRE-commit base: committing it would revert
      # commit 1, so the write must fail closed.
      stale = doc0 |> insert_table_after(anchor_text, table) |> encode()
      assert {:error, {:structural_change, detail}} = Projection.write_back(path, stale)
      # The detail names the concrete offender (which node/what mismatched);
      # the tuple tag itself carries the "structural" classification.
      assert is_binary(detail) and detail != ""

      # The recovery the surface prescribes: reread, restage the same change.
      {:ok, current} = Projection.project_file(path)
      fresh = current |> decode() |> insert_table_after(anchor_text, table) |> encode()
      assert {:ok, %{applied: applied2}} = Projection.write_back(path, fresh)
      assert applied2 >= 1

      {:ok, final} = Projection.project_file(path)
      assert final =~ merged_text
      assert final =~ "26,400,000"
    end
  end

  defp insert_table_after(doc, anchor_text, table) do
    for section <- doc do
      for paragraph <- section do
        anchored? =
          Enum.any?(
            paragraph,
            &(&1["type"] == "paragraph" and &1["text"] == anchor_text)
          )

        if anchored?, do: paragraph ++ [table], else: paragraph
      end
    end
  end

  # The projection is one JSON value laid out one-group-per-line (#460);
  # decode the whole binary, and keep the single-line encode on the write side
  # to pin that legacy-shaped agent writes stay accepted.
  defp decode(bytes), do: Jason.decode!(bytes)

  defp encode(doc), do: Jason.encode!(doc) <> "\n"

  defp first_multi_run_paragraph(doc) do
    doc
    |> paragraph_groups()
    |> Enum.find_value(fn {text, chars} ->
      if length(chars) >= 2 and length(Enum.uniq(chars)) >= 2, do: {text, length(chars)}
    end)
  end

  defp first_single_run_paragraph(doc, exclude_text) do
    doc
    |> paragraph_groups()
    |> Enum.find_value(fn {text, chars} ->
      if length(chars) == 1 and text not in ["", exclude_text] and
           String.length(text) > 10,
         do: text
    end)
  end

  defp paragraph_groups(doc) do
    for section <- doc,
        para <- section,
        p = Enum.find(para, &(&1["type"] == "paragraph")),
        p != nil,
        is_binary(p["text"]) do
      chars =
        para
        |> Enum.filter(&(&1["type"] == "char"))
        |> Enum.map(& &1["charShapeId"])

      {p["text"], chars}
    end
  end

  defp update_aggregate_text(doc, old_text, new_text) do
    for section <- doc do
      for paragraph <- section do
        for node <- paragraph do
          if node["type"] == "paragraph" and node["text"] == old_text do
            Map.put(node, "text", new_text)
          else
            node
          end
        end
      end
    end
  end
end
