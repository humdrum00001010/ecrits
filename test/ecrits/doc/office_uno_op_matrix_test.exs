defmodule Ecrits.Doc.OfficeUnoOpMatrixTest do
  @moduledoc """
  Per-verb matrix for the OFFICE SERVER arm (#31): every `doc.edit` verb driven
  through `Tools.call` against the real libreofficex UNO NIF, asserting the
  model effect and (for the docx leg) a save → reopen round-trip.

  Companion to `op_matrix_audit_test.exs` (which pins that every verb HAS a
  disposition); this file is the *positive* leg for the office-server column.
  Skips green when the UNO arm is unavailable, like office_native_test.exs.
  """
  use ExUnit.Case, async: false

  alias Ecrits.Doc.Pool
  alias Ecrits.Doc.Tools

  @docx_fixture Path.expand("../../fixtures/office/table.docx", __DIR__)
  @pptx_fixture Path.expand("../../fixtures/office/slides.pptx", __DIR__)
  @img_fixture Path.expand("../../../priv/static/images/landing/hero.png", __DIR__)

  setup do
    if uno_available?() do
      {:ok, pool} = start_supervised({Pool, name: nil})

      tmp =
        Path.join(System.tmp_dir!(), "office_matrix_#{System.unique_integer([:positive])}.docx")

      File.cp!(@docx_fixture, tmp)

      tmp_pptx =
        Path.join(System.tmp_dir!(), "office_matrix_#{System.unique_integer([:positive])}.pptx")

      File.cp!(@pptx_fixture, tmp_pptx)

      on_exit(fn ->
        File.rm(tmp)
        File.rm(tmp_pptx)
      end)

      {:ok, ctx: %{pool: pool}, docx: tmp, pptx: tmp_pptx, native: true}
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

  test "docx server arm: every Writer-applicable verb applies and persists", context do
    unless context[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping office op matrix (docx)")
    else
      ctx = context.ctx

      assert {:ok, %{"document" => doc}} =
               Tools.call(ctx, "doc.open", %{"path" => context.docx, "kind" => "docx"})

      # ── text + paragraph structure ─────────────────────────────────
      assert_ok(
        "insert_paragraph A",
        edit(ctx, doc, %{"op" => "insert_paragraph", "ref" => "end", "text" => "MATRIX_PARA_A"})
      )

      assert_ok(
        "insert_paragraph B",
        edit(ctx, doc, %{"op" => "insert_paragraph", "ref" => "end", "text" => "MATRIX_PARA_B"})
      )

      {:ok, %{"matches" => pb}} =
        Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "MATRIX_PARA_B"})

      assert [%{"ref" => pb_ref} | _] = pb

      assert_ok(
        "insert_text",
        edit(ctx, doc, %{"op" => "insert_text", "ref" => pb_ref, "text" => "_TAIL"})
      )

      assert_ok(
        "replace_text (ref-scoped)",
        edit(ctx, doc, %{
          "op" => "replace_text",
          "ref" => pb_ref,
          "query" => "MATRIX_PARA_B_TAIL",
          "replacement" => "MATRIX_PARA_B2"
        })
      )

      assert_ok("split", edit(ctx, doc, %{"op" => "split", "ref" => pb_ref, "at" => 6}))
      pb_next = "p" <> Integer.to_string(para_index(pb_ref) + 1)
      assert_ok("merge", edit(ctx, doc, %{"op" => "merge", "ref" => pb_next}))
      assert_ok("delete_range", edit(ctx, doc, %{"op" => "delete_range", "ref" => pb_ref}))

      assert_ok(
        "delete_paragraph",
        edit(ctx, doc, %{"op" => "delete_paragraph", "ref" => pb_ref})
      )

      # ── table structure ─────────────────────────────────────────────
      assert_ok(
        "insert_table",
        edit(ctx, doc, %{
          "op" => "insert_table",
          "ref" => "end",
          "rows" => 2,
          "cols" => 2,
          "name" => "MX"
        })
      )

      assert_ok(
        "set_cell",
        edit(ctx, doc, %{"op" => "set_cell", "ref" => "tbl[MX]/cell[A1]", "text" => "MX_CELL_A1"})
      )

      assert_ok(
        "insert_table_row (derived from cell)",
        edit(ctx, doc, %{"op" => "insert_table_row", "ref" => "tbl[MX]/cell[B2]", "below" => true})
      )

      assert_ok(
        "insert_table_column",
        edit(ctx, doc, %{
          "op" => "insert_table_column",
          "ref" => "tbl[MX]",
          "col" => 1,
          "right" => true
        })
      )

      assert_ok(
        "delete_table_row",
        edit(ctx, doc, %{"op" => "delete_table_row", "ref" => "tbl[MX]", "row" => 2})
      )

      assert_ok(
        "delete_table_column",
        edit(ctx, doc, %{"op" => "delete_table_column", "ref" => "tbl[MX]", "col" => 2})
      )

      assert_ok(
        "merge_cells",
        edit(ctx, doc, %{
          "op" => "merge_cells",
          "ref" => "tbl[MX]",
          "start_row" => 0,
          "start_col" => 0,
          "end_row" => 0,
          "end_col" => 1
        })
      )

      assert_ok(
        "split_cell",
        edit(ctx, doc, %{"op" => "split_cell", "ref" => "tbl[MX]/cell[A2]", "cols" => 2})
      )

      # ── notes, equation, picture, columns ──────────────────────────
      assert_ok(
        "insert_footnote",
        edit(ctx, doc, %{"op" => "insert_footnote", "ref" => "end", "text" => "MX_FOOT"})
      )

      assert_ok(
        "insert_endnote",
        edit(ctx, doc, %{"op" => "insert_endnote", "ref" => "end", "text" => "MX_END"})
      )

      assert_ok(
        "insert_equation",
        edit(ctx, doc, %{"op" => "insert_equation", "ref" => "end", "script" => "x^2 + y^2 = z^2"})
      )

      assert_ok(
        "insert_picture (inline)",
        edit(ctx, doc, %{
          "op" => "insert_picture",
          "ref" => "end",
          "src" => @img_fixture,
          "w" => 3000,
          "name" => "MXIMG"
        })
      )

      assert_ok(
        "set_geometry (img)",
        edit(ctx, doc, %{"op" => "set_geometry", "ref" => "img[MXIMG]", "w" => 2000})
      )

      assert_ok(
        "delete_node (img)",
        edit(ctx, doc, %{"op" => "delete_node", "ref" => "img[MXIMG]"})
      )

      # set_columns over a fresh footnote-free tail range
      assert_ok(
        "col para A",
        edit(ctx, doc, %{"op" => "insert_paragraph", "ref" => "end", "text" => "MX_COLS_A"})
      )

      assert_ok(
        "col para B",
        edit(ctx, doc, %{"op" => "insert_paragraph", "ref" => "end", "text" => "MX_COLS_B"})
      )

      {:ok, %{"matches" => ca}} =
        Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "MX_COLS_A"})

      {:ok, %{"matches" => cb}} =
        Tools.call(ctx, "doc.find", %{"document" => doc, "pattern" => "MX_COLS_B"})

      assert_ok(
        "set_columns",
        edit(ctx, doc, %{
          "op" => "set_columns",
          "count" => 2,
          "from" => hd(ca)["ref"],
          "to" => hd(cb)["ref"]
        })
      )

      # ── persistence: save → reopen, structure survives ─────────────
      assert {:ok, _} = Tools.call(ctx, "doc.save", %{"document" => doc})

      assert {:ok, %{"document" => doc2}} =
               Tools.call(ctx, "doc.open", %{"path" => context.docx, "kind" => "docx"})

      {:ok, %{"matches" => cells}} =
        Tools.call(ctx, "doc.find", %{"document" => doc2, "pattern" => "", "all" => true})

      mx = Enum.filter(cells, &String.starts_with?(&1["ref"] || "", "tbl[MX]/cell["))
      # 2x2 +row +col -row -col, A1:B1 merged (-1), A2 split (+1) => 4 cells
      assert length(mx) == 4, "expected 4 tbl[MX] cells after reopen, got: #{inspect(mx)}"
      assert Enum.any?(cells, &((&1["text"] || "") =~ "MX_CELL_A1"))
    end
  end

  test "pptx server arm: slide verbs apply (insert_slide/shape/picture, set_geometry, delete_node)",
       context do
    unless context[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping office op matrix (pptx)")
    else
      ctx = context.ctx

      assert {:ok, %{"document" => doc}} =
               Tools.call(ctx, "doc.open", %{"path" => context.pptx, "kind" => "pptx"})

      assert_ok("insert_slide", edit(ctx, doc, %{"op" => "insert_slide", "name" => "mxslide"}))

      assert_ok(
        "insert_shape",
        edit(ctx, doc, %{
          "op" => "insert_shape",
          "page" => "mxslide",
          "service" => "com.sun.star.drawing.RectangleShape",
          "name" => "mxrect",
          "x" => 1000,
          "y" => 1000,
          "w" => 8000,
          "h" => 4000,
          "text" => "MX_SHAPE",
          "FillColor" => 4_886_754
        })
      )

      assert_ok(
        "set_geometry (shape)",
        edit(ctx, doc, %{
          "op" => "set_geometry",
          "ref" => "page[mxslide]/shape[mxrect]",
          "x" => 2000
        })
      )

      assert_ok(
        "insert_picture (slide)",
        edit(ctx, doc, %{
          "op" => "insert_picture",
          "page" => "mxslide",
          "name" => "mximg",
          "src" => @img_fixture,
          "x" => 10_000,
          "y" => 1000,
          "w" => 6000,
          "h" => 6000
        })
      )

      assert_ok(
        "delete_node (shape)",
        edit(ctx, doc, %{"op" => "delete_node", "ref" => "page[mxslide]/shape[mxrect]"})
      )

      assert_ok(
        "delete_node (slide)",
        edit(ctx, doc, %{"op" => "delete_node", "ref" => "page[mxslide]"})
      )
    end
  end

  test "office arm rejections are PRECISE capability errors, never silent", context do
    unless context[:native] do
      IO.puts("\n[skip] LibreOffice UNO arm unavailable; skipping office rejection tests")
    else
      ctx = context.ctx

      assert {:ok, %{"document" => doc}} =
               Tools.call(ctx, "doc.open", %{"path" => context.docx, "kind" => "docx"})

      # HWP-form insert_shape (no page) → guidance error naming the slide form
      assert {:error, err} =
               edit(ctx, doc, %{
                 "op" => "insert_shape",
                 "ref" => "p0",
                 "width" => 100,
                 "height" => 100
               })

      assert inspect(err) =~ "page"

      # table op on a non-table ref → precise "needs a table ref" from the engine
      assert {:error, err2} =
               edit(ctx, doc, %{"op" => "insert_table_row", "ref" => "p0", "row" => 0})

      assert inspect(err2) =~ "table ref"
    end
  end

  defp para_index("p" <> n), do: String.to_integer(n)

  defp uno_available? do
    case Ecrits.Doc.Office.open(@docx_fixture, kind: :docx) do
      {:ok, handle} ->
        Ecrits.Doc.Office.close(handle)
        true

      {:error, _} ->
        false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end
end
