defmodule Contract.Export.HWPXRealContractTest do
  @moduledoc """
  Round-trip validation of `Contract.Export.HWPX` against a real published
  Korean legal document.

  Source: `test/fixtures/hwpx/real_contract.hwpx` — 산업통상자원부 고시
  제2020-93호 (전력기술관리법 운영요령). A real, gazetted government legal
  notice with article-numbered structure (제N장 / 제N조) that mirrors the
  shape of Korean standard contracts.

  Pipeline this exercise:

  1. Load the projection fixture
     (`test/fixtures/hwpx/expected_projection.exs`) — a hand-curated slice
     of the source's first three chapters plus one representative 5×3
     table.
  2. Render via `Contract.Export.HWPX.render/2`.
  3. Pipe the output through pyhwpxlib (third-party HWPX reader) for both
     `--mode strict` (OWPML schema) and `--mode compat` (Hancom-tolerant)
     validation.
  4. Extract text from both source and rendered, compute Jaccard
     similarity, and assert ≥ 0.95.
  5. Assert that `<hp:cellSz width="…"/>` values in the rendered HWPX
     exactly match the column widths declared in the projection (within
     a 10% HWP-unit tolerance, as the spec advises).

  Tagged `:external_hwpx` — runs only with
  `mix test --include external_hwpx`. The validator binary is configured at
  `config :contract, :hwpx_validator` (see `config/test.exs`).
  """

  use ExUnit.Case, async: true

  @moduletag :external_hwpx

  alias Contract.Export.HWPX

  @fixture_dir Path.expand("../../fixtures/hwpx", __DIR__)
  @source_hwpx Path.join(@fixture_dir, "real_contract.hwpx")
  @projection_exs Path.join(@fixture_dir, "expected_projection.exs")

  setup_all do
    cmd = Application.fetch_env!(:contract, :hwpx_validator)

    unless cmd && File.exists?(cmd) do
      flunk("""
      External HWPX validator not found at `#{cmd}`.

      Install with:
          python3 -m venv ~/.venvs/hwpx
          ~/.venvs/hwpx/bin/pip install pyhwpxlib

      Then either set `HWPX_VALIDATOR_CMD` or run via the sprite where the
      binary lives at `/home/sprite/.venvs/hwpx/bin/pyhwpxlib`.
      """)
    end

    unless File.exists?(@source_hwpx) do
      flunk("Source HWPX fixture missing: #{@source_hwpx}")
    end

    unless File.exists?(@projection_exs) do
      flunk("Projection fixture missing: #{@projection_exs}")
    end

    {state, _} = Code.eval_file(@projection_exs)
    {:ok, rendered} = HWPX.render(state)

    rendered_path = Path.join(System.tmp_dir!(), "real_contract_rendered.hwpx")
    File.write!(rendered_path, rendered)

    on_exit(fn -> File.rm(rendered_path) end)

    {source_text, 0} = System.cmd(cmd, ["text", @source_hwpx])
    {rendered_text, 0} = System.cmd(cmd, ["text", rendered_path])

    %{
      validator: cmd,
      state: state,
      rendered_bytes: rendered,
      rendered_path: rendered_path,
      source_text: source_text,
      rendered_text: rendered_text
    }
  end

  test "rendered HWPX passes both strict (OWPML) and compat (Hancom) validation",
       %{validator: cmd, rendered_path: path} do
    {output, status} = System.cmd(cmd, ["validate", "--mode", "both", path], stderr_to_stdout: true)
    assert status == 0, "validate --mode both exited #{status}\nOutput:\n#{output}"

    # `validate --mode both` prints "Compat (Hancom OK): ✅ PASS" and
    # "Strict (OWPML spec): ✅ PASS" lines. Assert both:
    assert output =~ "Compat (Hancom OK): ✅ PASS",
           "Compat validation failed:\n#{output}"

    assert output =~ "Strict (OWPML spec): ✅ PASS",
           "Strict validation failed:\n#{output}"
  end

  test "extracted text Jaccard similarity > 0.95 against source slice",
       %{source_text: source_text, rendered_text: rendered_text} do
    # The projection captures only paragraphs from the title through the 6th
    # sub-item of 제15조, plus one 5×3 table (paragraph index 394 in the
    # source). Build the corresponding source slice for a fair Jaccard.
    source_slice = build_source_slice(source_text)

    similarity = jaccard_char_bigrams(source_slice, rendered_text)

    assert similarity > 0.95,
           "Jaccard similarity #{similarity} below 0.95 threshold.\n" <>
             "Source slice length: #{String.length(source_slice)}\n" <>
             "Rendered length: #{String.length(rendered_text)}"
  end

  test "table cellSz widths preserved within ±10% of projection's column_widths",
       %{state: state, rendered_path: rendered_path} do
    # Extract declared widths from the projection's table node.
    table_node =
      state.projection.nodes
      |> Map.values()
      |> Enum.find(fn n -> Map.get(n, :kind) == :table end)

    assert table_node, "Projection fixture must contain at least one :table node"
    expected_widths = get_in(table_node, [:attrs, :column_widths])
    assert is_list(expected_widths) and length(expected_widths) > 0,
           "Table node must declare :column_widths"

    # Pull cellSz widths from the rendered section0.xml.
    section_xml = unzip_member(rendered_path, "Contents/section0.xml")
    rendered_widths = Regex.scan(~r/cellSz width="(\d+)"/, section_xml)

    assert length(rendered_widths) >= length(expected_widths),
           "Expected at least #{length(expected_widths)} cellSz entries; got #{length(rendered_widths)}"

    # The first row's <hp:cellSz> entries should correspond to the
    # `column_widths` list. Take the first N rendered widths.
    actual_first_row =
      rendered_widths
      |> Enum.take(length(expected_widths))
      |> Enum.map(fn [_full, w] -> String.to_integer(w) end)

    tolerance = 0.10

    actual_first_row
    |> Enum.zip(expected_widths)
    |> Enum.with_index()
    |> Enum.each(fn {{actual, expected}, idx} ->
      delta = abs(actual - expected) / max(expected, 1)

      assert delta <= tolerance,
             "Column #{idx} width drift: expected #{expected}, got #{actual} (#{Float.round(delta * 100, 2)}% off)"
    end)
  end

  test "rendering the projection twice produces byte-identical HWPX",
       %{state: state, rendered_bytes: first} do
    {:ok, second} = HWPX.render(state)
    assert first == second, "Deterministic render expected; got diverging bytes"
  end

  test "every projection heading emits a paraPrIDRef in the expected band",
       %{state: state, rendered_path: rendered_path} do
    headings =
      state.projection.nodes
      |> Map.values()
      |> Enum.filter(fn n -> Map.get(n, :kind) == :heading end)

    assert length(headings) >= 5,
           "Projection should have at least 5 heading nodes; got #{length(headings)}"

    section_xml = unzip_member(rendered_path, "Contents/section0.xml")

    # Writer maps heading level → paraPrIDRef in [2..7] band (heading 1 → 2,
    # heading 2 → 3, …). At least one para from the heading band must appear
    # per distinct level used by the projection.
    distinct_levels =
      headings
      |> Enum.map(fn n -> get_in(n, [:attrs, :level]) || 1 end)
      |> Enum.uniq()

    Enum.each(distinct_levels, fn level ->
      band_id = 2 + (level - 1)

      assert section_xml =~ ~s(paraPrIDRef="#{band_id}"),
             "Expected paraPrIDRef=\"#{band_id}\" for heading level #{level} not found in section0"
    end)
  end

  test "source fixture parses cleanly through pyhwpxlib info", %{validator: cmd} do
    {output, status} = System.cmd(cmd, ["info", @source_hwpx], stderr_to_stdout: true)

    assert status == 0, "pyhwpxlib info on source fixture failed:\n#{output}"
    # Sanity: source HWPX has at least one section and non-zero text length.
    assert output =~ ~r/Sections:\s*\d+/
    assert output =~ ~r/Text:\s*\d+/
  end

  # ---- helpers ------------------------------------------------------------

  # The projection captures a slice of the source: title → 제15조 sub-item 6,
  # plus the 5×3 인원배치 table. Reconstruct that slice from the full source
  # text so the Jaccard comparison is fair.
  #
  # All offsets are BYTE offsets (UTF-8) — the source contains multi-byte
  # Hangul codepoints, so we use `:binary.part/3` rather than
  # `String.slice/2` (which is grapheme-indexed).
  defp build_source_slice(source_text) do
    title_marker = "전력기술관리법 운영요령\n제1장"
    para_end_marker = "6. 발주자 또는 시행사의 귀책사유로 공사가 중단 또는 지연되어 감리원이 추가 배치되는 경우"
    table_start_marker = "구분\t규    모\t감리원배치"

    title_idx = idx_or_zero(source_text, title_marker)
    para_end_idx = idx_or_zero(source_text, para_end_marker)
    para_end_line = next_newline_after(source_text, para_end_idx)

    para_slice =
      :binary.part(source_text, title_idx, para_end_line + 1 - title_idx)

    tbl_idx = idx_or_zero(source_text, table_start_marker)

    tbl_end_line =
      Enum.reduce(1..5, tbl_idx, fn _i, acc ->
        next_newline_after(source_text, acc + 1)
      end)

    tbl_slice = :binary.part(source_text, tbl_idx, tbl_end_line + 1 - tbl_idx)

    para_slice <> tbl_slice
  end

  defp idx_or_zero(text, marker) do
    case :binary.match(text, marker) do
      :nomatch -> 0
      {idx, _len} -> idx
    end
  end

  defp next_newline_after(text, from) do
    remaining = max(byte_size(text) - from, 0)

    case :binary.match(text, "\n", scope: {from, remaining}) do
      :nomatch -> byte_size(text) - 1
      {idx, _len} -> idx
    end
  end

  # Char-bigram Jaccard similarity (whitespace-collapsed). Robust for
  # Korean text where word tokenization is unreliable.
  defp jaccard_char_bigrams(a, b) do
    set_a = char_bigrams(a)
    set_b = char_bigrams(b)
    inter = MapSet.intersection(set_a, set_b) |> MapSet.size()
    union = MapSet.union(set_a, set_b) |> MapSet.size()

    if union == 0, do: 0.0, else: inter / union
  end

  defp char_bigrams(text) do
    collapsed = String.replace(text, ~r/\s+/, " ") |> String.trim()
    graphemes = String.graphemes(collapsed)

    graphemes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(&Enum.join/1)
    |> MapSet.new()
  end

  # Read a member file out of an HWPX (zip) at `path`. Returns its bytes as
  # a binary; flunks if the member is missing.
  defp unzip_member(path, member) do
    member_charlist = String.to_charlist(member)
    {:ok, zip} = :zip.zip_open(String.to_charlist(path), [:memory])

    result =
      case :zip.zip_get(member_charlist, zip) do
        {:ok, {^member_charlist, bin}} -> bin
        other -> flunk("Could not extract #{member}: #{inspect(other)}")
      end

    :zip.zip_close(zip)
    result
  end
end
