defmodule Ecrits.Doc.RhwpOpMatrixTest do
  @moduledoc """
  Per-verb matrix for the HWP SERVER arm (#31): every `doc.edit` verb driven
  through `Tools.call` against the real ehwp NIF, asserting model effects via
  doc.find and a save → reopen round-trip. The two Office-only verbs
  (insert_slide / set_geometry) must come back as ERRORS, not silent no-ops.

  Companion to `op_matrix_audit_test.exs`; this is the positive leg for the
  hwp-server column. Skips green when the NIF is not loaded.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Tools

  @fixture Path.expand("../../fixtures/hwpx/real_contract.hwpx", __DIR__)
  @img_fixture Path.expand("../../../priv/static/images/landing/hero.png", __DIR__)

  setup do
    prev = Application.get_env(:ehwp, :runtime)
    Application.delete_env(:ehwp, :runtime)
    {:ok, _} = Application.ensure_all_started(:ehwp)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:ehwp, :runtime)
        value -> Application.put_env(:ehwp, :runtime, value)
      end
    end)

    if Ehwp.available?() do
      {:ok, pool} = start_supervised({Pool, name: nil})

      tmp = Path.join(System.tmp_dir!(), "rhwp_matrix_#{System.unique_integer([:positive])}.hwpx")
      File.cp!(@fixture, tmp)
      on_exit(fn -> File.rm(tmp) end)

      {:ok, ctx: %{pool: pool}, path: tmp, native: true}
    else
      {:ok, native: false}
    end
  end

  defp edit(ctx, doc, op), do: Tools.call(ctx, "doc.edit", %{"document" => doc, "op" => op})

  defp assert_ok(label, result) do
    case result do
      {:ok, %{"ok" => true}} -> :ok
      other -> flunk("#{label} failed: #{inspect(other)}")
    end
  end

  # Server-arm refs are JSON-string maps; a table cell is type "cell" with a
  # nested {"cell": {cellIndex, controlIndex, parentParaIndex}} address.
  defp table_cells(ctx, doc) do
    {:ok, %{"matches" => all}} =
      Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "", "all" => true})

    Enum.filter(all, &(&1["type"] == "cell"))
  end

  test "hwp server arm: every HWP-applicable verb applies and persists", context do
    unless context[:native] do
      IO.puts("\n[skip] ehwp NIF not loaded; skipping hwp op matrix")
    else
      ctx = context.ctx

      assert {:ok, %{"document" => doc, "kind" => "hwpx"}} =
               Tools.call(ctx, "doc.open", %{"path" => context.path, "kind" => "hwpx"})

      # body anchor: end of the document body via the LAST body paragraph found
      {:ok, %{"matches" => body}} =
        Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "", "all" => true})

      paras = Enum.filter(body, &(&1["type"] == "paragraph"))
      assert paras != []
      anchor = List.last(paras)["ref"]

      # ── body text + paragraph structure ────────────────────────────
      assert_ok(
        "insert_paragraph",
        edit(ctx, doc, %{"op" => "insert_paragraph", "ref" => anchor})
      )

      assert_ok(
        "insert_text",
        edit(ctx, doc, %{"op" => "insert_text", "ref" => anchor, "text" => "HWPMX_BODY"})
      )

      assert_ok(
        "replace_text",
        edit(ctx, doc, %{
          "op" => "replace_text",
          "ref" => anchor,
          "query" => "HWPMX_BODY",
          "replacement" => "HWPMX_BODY2"
        })
      )

      assert_ok("split", edit(ctx, doc, %{"op" => "split", "ref" => anchor}))

      assert_ok(
        "merge follow-up",
        edit(ctx, doc, %{"op" => "merge", "ref" => bump_para(anchor, 1)})
      )

      assert_ok(
        "delete_range",
        edit(ctx, doc, %{"op" => "delete_range", "ref" => anchor, "count" => 1})
      )

      # ── table structure: build a 2x2, drive every structural verb ──
      before_cells = table_cells(ctx, doc)

      assert_ok(
        "insert_table",
        edit(ctx, doc, %{"op" => "insert_table", "ref" => anchor, "rows" => 2, "cols" => 2})
      )

      new_cells = table_cells(ctx, doc) -- before_cells
      assert length(new_cells) >= 4, "expected the new 2x2 table's cells in doc.find"
      cell = hd(new_cells)["ref"]

      assert_ok(
        "set_cell",
        edit(ctx, doc, %{"op" => "set_cell", "ref" => cell, "text" => "HWPMX_CELL"})
      )

      # `count` inserts N rows in ONE op — the agent's natural "add N rows"
      # shape (silently dropping it is how a live "10 rows added" claim turned
      # out to be 1 real row). 2x2 + 2 rows -> 4x2 = 8 cells.
      assert_ok(
        "insert_table_row (count: 2)",
        edit(ctx, doc, %{
          "op" => "insert_table_row",
          "ref" => cell,
          "row" => 0,
          "below" => true,
          "count" => 2
        })
      )

      assert length(table_cells(ctx, doc) -- before_cells) == 8,
             "expected count:2 to add TWO rows (4x2 grid)"

      assert_ok(
        "delete_table_row (undo one)",
        edit(ctx, doc, %{"op" => "delete_table_row", "ref" => cell, "row" => 2})
      )

      assert_ok(
        "insert_table_row",
        edit(ctx, doc, %{"op" => "insert_table_row", "ref" => cell, "row" => 0, "below" => true})
      )

      assert_ok(
        "insert_table_column",
        edit(ctx, doc, %{
          "op" => "insert_table_column",
          "ref" => cell,
          "col" => 0,
          "right" => true
        })
      )

      assert_ok(
        "delete_table_row",
        edit(ctx, doc, %{"op" => "delete_table_row", "ref" => cell, "row" => 2})
      )

      assert_ok(
        "delete_table_column",
        edit(ctx, doc, %{"op" => "delete_table_column", "ref" => cell, "col" => 2})
      )

      assert_ok(
        "merge_cells",
        edit(ctx, doc, %{
          "op" => "merge_cells",
          "ref" => cell,
          "start_row" => 0,
          "start_col" => 0,
          "end_row" => 0,
          "end_col" => 1
        })
      )

      assert_ok(
        "split_cell",
        edit(ctx, doc, %{
          "op" => "split_cell",
          "ref" => cell,
          "row" => 1,
          "col" => 0,
          "rows" => 1,
          "cols" => 2
        })
      )

      # ── objects + notes + layout ───────────────────────────────────
      assert_ok(
        "insert_picture",
        edit(ctx, doc, %{
          "op" => "insert_picture",
          "ref" => anchor,
          "src" => @img_fixture,
          "width" => 8504,
          "height" => 8504
        })
      )

      assert_ok(
        "insert_shape",
        edit(ctx, doc, %{
          "op" => "insert_shape",
          "ref" => anchor,
          "shape_type" => "rectangle",
          "width" => 8504,
          "height" => 4252
        })
      )

      assert_ok(
        "insert_equation",
        edit(ctx, doc, %{
          "op" => "insert_equation",
          "ref" => anchor,
          "script" => "x^2 + y^2 = z^2"
        })
      )

      assert_ok(
        "insert_footnote",
        edit(ctx, doc, %{"op" => "insert_footnote", "ref" => anchor, "text" => "HWPMX_FOOT"})
      )

      assert_ok(
        "insert_endnote",
        edit(ctx, doc, %{"op" => "insert_endnote", "ref" => anchor, "text" => "HWPMX_END"})
      )

      assert_ok(
        "set_columns",
        edit(ctx, doc, %{"op" => "set_columns", "ref" => anchor, "count" => 2})
      )

      # delete_node drops the WHOLE table the cell belongs to
      assert_ok("delete_node", edit(ctx, doc, %{"op" => "delete_node", "ref" => cell}))

      assert table_cells(ctx, doc) -- before_cells == [],
             "expected the matrix table to be gone after delete_node"

      # ── Office-only verbs ERROR on the hwp arm (never silent) ─────
      assert {:error, _} = edit(ctx, doc, %{"op" => "insert_slide", "name" => "nope"})
      assert {:error, _} = edit(ctx, doc, %{"op" => "set_geometry", "ref" => anchor, "x" => 1})

      # ── persistence: save → reopen, body token survives ───────────
      assert {:ok, _} = Tools.call(ctx, "doc.save", %{"document" => doc})

      assert {:ok, %{"document" => doc2}} =
               Tools.call(ctx, "doc.open", %{"path" => context.path, "kind" => "hwpx"})

      # The delete_range step above removed exactly ONE char at the anchor's
      # offset 0 — the token's leading "H" — so the persisted text is the
      # deterministic "WPMX_BODY2" (this is delete_range's positive assertion).
      assert {:ok, %{"matches" => found}} =
               Tools.call(ctx, "doc.find", %{"document" => doc2, "pattern" => "WPMX_BODY2"})

      assert found != [], "expected the edited body token to survive save/reopen"
    end
  end

  # Server-arm refs are JSON-string maps ({"section":..,"paragraph":..,..});
  # shift the paragraph index (for addressing the paragraph a `split` created).
  defp bump_para(ref, by) when is_binary(ref) do
    map = Jason.decode!(ref)
    Jason.encode!(Map.update!(map, "paragraph", &(&1 + by)))
  end
end
