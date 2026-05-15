defmodule Contract.Export.HWPXExternalValidatorTest do
  @moduledoc """
  External-oracle validation of `Contract.Export.HWPX` output.

  Pipes our generated HWPX through a real third-party HWPX parser
  (`pyhwpxlib`, available on PyPI: https://pypi.org/project/pyhwpxlib/).
  If a foreign parser accepts our bytes — and especially if its strict
  OWPML validator passes — that's far stronger evidence of correctness
  than our own `:xmerl_scan` self-check, which only verifies XML
  well-formedness, not OWPML schema compliance.

  These tests are tagged `:external_hwpx` and excluded from the default
  `mix test` run. Enable via:

      mix test --include external_hwpx test/contract/export/hwpx_external_validator_test.exs

  The validator binary is configured at `config :contract, :hwpx_validator`
  (see `config/test.exs`) and can be overridden via the
  `HWPX_VALIDATOR_CMD` env var.

  ## Validator subcommands used

    * `info <file>` — parse + print section/paragraph/line counts.
    * `text [-f markdown] <file>` — extract text or markdown.
    * `validate --mode strict <file>` — OWPML schema compliance.

  All shell out via `System.cmd/3`; no new Elixir deps.
  """

  use ExUnit.Case, async: true

  @moduletag :external_hwpx

  alias Contract.Export.HWPX
  alias Contract.Runtime.State

  # --------------------------------------------------------------------------
  # Helpers
  # --------------------------------------------------------------------------

  setup do
    cmd = Application.fetch_env!(:contract, :hwpx_validator)

    unless cmd && File.exists?(cmd) do
      flunk("""
      External HWPX validator not found at `#{cmd}`.

      Install with:
          python3 -m venv ~/.venvs/hwpx
          ~/.venvs/hwpx/bin/pip install pyhwpxlib

      Or set HWPX_VALIDATOR_CMD to a different path.
      """)
    end

    on_exit(fn -> :ok end)
    %{cmd: cmd}
  end

  defp state_with_nodes(nodes_list, opts \\ []) do
    nodes = Map.new(nodes_list, fn n -> {n.id, n} end)
    order = Keyword.get(opts, :order, Enum.map(nodes_list, & &1.id))

    %State{
      document_id: "doc-0000-0000-0000-000000000099",
      revision: 0,
      projection: %{
        State.empty_projection()
        | nodes: nodes,
          node_order: order
      }
    }
  end

  defp render_to_tmpfile!(state) do
    {:ok, bin} = HWPX.render(state)
    path = Path.join(System.tmp_dir!(), "hwpx_ext_#{System.unique_integer([:positive])}.hwpx")
    File.write!(path, bin)
    path
  end

  defp run_validator(cmd, args) do
    # stderr_to_stdout so the assertion message has both streams on failure.
    {out, status} = System.cmd(cmd, args, stderr_to_stdout: true)
    {status, out}
  end

  # --------------------------------------------------------------------------
  # 1. Smoke — 1-paragraph round-trip
  # --------------------------------------------------------------------------

  test "external parser accepts a 1-paragraph HWPX (info exit 0)", %{cmd: cmd} do
    state =
      state_with_nodes([
        %{id: "p1", kind: :paragraph, content: "Hello, world."}
      ])

    path = render_to_tmpfile!(state)
    {status, out} = run_validator(cmd, ["info", path])

    assert status == 0,
           "external parser rejected our HWPX (exit #{status}). Output:\n#{out}"

    # Sanity: the parser saw our content.
    assert out =~ "Hello, world."

    File.rm!(path)
  end

  # --------------------------------------------------------------------------
  # 2. 5-paragraph — parser sees 5 lines / paragraphs
  # --------------------------------------------------------------------------

  test "external parser extracts 5 lines from a 5-paragraph HWPX", %{cmd: cmd} do
    nodes =
      for i <- 1..5 do
        %{id: "p#{i}", kind: :paragraph, content: "Paragraph #{i}."}
      end

    state = state_with_nodes(nodes)
    path = render_to_tmpfile!(state)

    {status, info_out} = run_validator(cmd, ["info", path])
    assert status == 0, "info exit #{status}: #{info_out}"

    # `pyhwpxlib info` prints e.g. "Text: NN characters, M lines".
    assert info_out =~ ~r/5 lines/,
           "expected 5 lines in info output; got:\n#{info_out}"

    # And the text extractor should produce each paragraph on its own line.
    {text_status, text_out} = run_validator(cmd, ["text", path])
    assert text_status == 0
    lines = text_out |> String.split("\n", trim: true)
    assert length(lines) == 5

    Enum.each(1..5, fn i ->
      assert Enum.any?(lines, &(&1 == "Paragraph #{i}.")),
             "expected `Paragraph #{i}.` as a line; got:\n#{text_out}"
    end)

    File.rm!(path)
  end

  # --------------------------------------------------------------------------
  # 3. Korean content round-trip (UTF-8)
  # --------------------------------------------------------------------------

  test "Korean paragraph content survives the external parser", %{cmd: cmd} do
    korean = "이 계약은 갑과 을 사이에 체결된다"

    state =
      state_with_nodes([
        %{id: "p1", kind: :paragraph, content: korean}
      ])

    path = render_to_tmpfile!(state)

    {status, text_out} = run_validator(cmd, ["text", path])
    assert status == 0, "text exit #{status}: #{text_out}"

    assert text_out =~ korean,
           "external parser lost UTF-8 Korean content; got:\n#{inspect(text_out)}"

    # And the markdown extractor too.
    {md_status, md_out} = run_validator(cmd, ["text", "-f", "markdown", path])
    assert md_status == 0
    assert md_out =~ korean

    File.rm!(path)
  end

  # --------------------------------------------------------------------------
  # 4. Korean heading content
  # --------------------------------------------------------------------------

  test "Korean heading content is recognized by the external parser", %{cmd: cmd} do
    heading = "제1조 (목적)"

    state =
      state_with_nodes([
        %{id: "h", kind: :heading, content: heading, attrs: %{level: 1}}
      ])

    path = render_to_tmpfile!(state)

    {status, text_out} = run_validator(cmd, ["text", path])
    assert status == 0, "text exit #{status}: #{text_out}"

    assert text_out =~ heading,
           "external parser lost heading content; got:\n#{inspect(text_out)}"

    File.rm!(path)
  end

  # --------------------------------------------------------------------------
  # 5. Table — parser accepts a 2×2 table
  # --------------------------------------------------------------------------

  test "external parser accepts a 2x2 table HWPX", %{cmd: cmd} do
    cell_ids = ["c1", "c2", "c3", "c4"]

    cells =
      cell_ids
      |> Enum.with_index(1)
      |> Enum.map(fn {id, idx} -> %{id: id, kind: :cell, content: "Cell #{idx}"} end)

    table = %{id: "T", kind: :table, attrs: %{rows: 2, cols: 2}, children: cell_ids}

    state = state_with_nodes([table | cells], order: ["T"])
    path = render_to_tmpfile!(state)

    {status, out} = run_validator(cmd, ["info", path])

    assert status == 0,
           "external parser rejected our 2x2 table HWPX (exit #{status}). Output:\n#{out}"

    # All four cell strings should appear in the extracted text.
    {text_status, text_out} = run_validator(cmd, ["text", path])
    assert text_status == 0

    Enum.each(1..4, fn i ->
      assert text_out =~ "Cell #{i}",
             "missing `Cell #{i}` in extracted text:\n#{text_out}"
    end)

    File.rm!(path)
  end

  # --------------------------------------------------------------------------
  # 6. Strict OWPML validation (bonus — pyhwpxlib's strict mode)
  # --------------------------------------------------------------------------

  test "strict OWPML validation passes on a typical document", %{cmd: cmd} do
    state =
      state_with_nodes([
        %{id: "h", kind: :heading, content: "제1조 (목적)", attrs: %{level: 1}},
        %{id: "p1", kind: :paragraph, content: "이 계약은 갑과 을 사이에 체결된다"},
        %{id: "p2", kind: :paragraph, content: "Second clause."}
      ])

    path = render_to_tmpfile!(state)

    {status, out} = run_validator(cmd, ["validate", "--mode", "strict", path])

    assert status == 0,
           "strict OWPML validation failed (exit #{status}). Output:\n#{out}"

    # pyhwpxlib's strict mode prints `Result: ✅ VALID` on success.
    assert out =~ "VALID",
           "expected `VALID` in strict-mode validator output; got:\n#{out}"

    File.rm!(path)
  end
end
