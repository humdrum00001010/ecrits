defmodule Ecrits.Doc.ProjectionLineEncodingTest do
  @moduledoc """
  Board #460: the mounted projection is ONE JSON value laid out one paragraph
  group per line, so the ACP agent's line-oriented tools address it directly
  (measured: ~95% of a 411s take18 dialog was the agent byte-scanning the old
  single-line 3MB value). Raw newlines are OUR record separators — JSON string
  encoding escapes content newlines — so the framing is unforgeable, and these
  tests pin the whole contract: emit shape, round-trip acceptance of both the
  new multi-line and legacy single-line writes, CRLF tolerance, and fail-closed
  rejection of a raw newline injected inside a record.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Projection

  @fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)

  setup do
    {:ok, native: Ehwp.available?()}
  end

  test "emits one paragraph group per line and accepts its own output back", tags do
    if not tags.native do
      IO.puts("\n[skip] ehwp NIF unavailable; skipping projection line-encoding e2e")
    else
      path = tmp_copy()
      {:ok, bytes} = Projection.project_file(path)

      # Whole file is one JSON value; newlines are only inter-token whitespace.
      decoded = Jason.decode!(bytes)
      assert is_list(decoded) and decoded != []

      # Line layout: outer brackets + per-section brackets + one line per group.
      lines = bytes |> String.split("\n", trim: true)
      group_count = decoded |> Enum.map(&length/1) |> Enum.sum()
      expected = 2 + Enum.sum(Enum.map(decoded, fn groups -> 2 + length(groups) end))
      assert length(lines) == expected
      assert group_count > 100

      # Every group line (comma-stripped) is itself a valid JSON payload array.
      group_lines =
        Enum.reject(lines, fn line -> String.trim(line) in ["[", "]", "],", "[,"] end)

      assert length(group_lines) == group_count

      for line <- Enum.take(group_lines, 20) do
        assert {:ok, payloads} = line |> String.trim_trailing(",") |> Jason.decode()
        assert is_list(payloads)
      end

      # Round-trip law: writing the projection's own bytes back is a no-op.
      assert {:ok, %{applied: 0}} = Projection.write_back(path, bytes)

      # A legacy single-line full-value write stays accepted.
      single_line = Jason.encode!(decoded) <> "\n"
      assert {:ok, %{applied: 0}} = Projection.write_back(path, single_line)

      # CRLF from the agent's editor is inter-token whitespace, not a breakage.
      crlf = String.replace(bytes, "\n", "\r\n")
      assert {:ok, %{applied: 0}} = Projection.write_back(path, crlf)

      # A raw newline injected INSIDE a record breaks JSON framing and must
      # fail closed as a parse error — never a partial apply.
      [sample | _] = group_lines
      broken_line = String.slice(sample, 0, div(String.length(sample), 2)) <> "\n"

      broken =
        String.replace(
          bytes,
          sample,
          broken_line <> String.slice(sample, div(String.length(sample), 2)..-1//1)
        )

      assert {:error, {:invalid_ir_json, _fragment}} = Projection.write_back(path, broken)
    end
  end

  defp tmp_copy do
    path =
      Path.join(
        System.tmp_dir!(),
        "line_encoding_#{System.unique_integer([:positive])}.hwpx"
      )

    File.cp!(@fixture, path)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
