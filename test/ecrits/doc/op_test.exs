defmodule Ecrits.Doc.OpTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.Op

  describe "normalize/1" do
    test "accepts string-keyed insert_text op" do
      assert {:ok, op} =
               Op.normalize(%{"op" => "insert_text", "ref" => "hwp:s0/p1", "text" => "hi"})

      assert op.op == "insert_text"
      assert op.ref == "hwp:s0/p1"
      assert op.text == "hi"
    end

    test "accepts atom-keyed op" do
      assert {:ok, op} = Op.normalize(%{op: "delete_range", ref: "hwp:s0/p1", count: 3})
      assert op.op == "delete_range"
      assert op.count == 3
    end

    test "rejects retired metadata instead of silently ignoring it" do
      assert {:error, {:invalid_op, message}} =
               Op.normalize(%{
                 "op" => "insert_text",
                 "ref" => "hwp:s0/p1",
                 "text" => "hi",
                 "base_revision" => 12
               })

      assert message =~ "base_revision"
      assert message =~ "current document state"
    end

    test "keeps arbitrary raw engine property keys as strings" do
      assert {:ok, op} =
               Op.normalize(%{
                 "op" => "insert_shape",
                 "page" => "summary",
                 "name" => "title",
                 "x" => 100,
                 "y" => 100,
                 "w" => 1_000,
                 "h" => 500,
                 "CharHeight" => 32
               })

      assert op["CharHeight"] == 32
    end

    test "normalizes the internal signature overlay transport key" do
      assert {:ok, op} =
               Op.normalize(%{
                 "op" => "insert_picture",
                 "ref" => "hwp:s0/p76/tbl0/cell3/cp3/c0+21",
                 "src" => "/tmp/signature.png",
                 "overlay_marker_length" => 3
               })

      assert op.overlay_marker_length == 3
      refute Map.has_key?(op, "overlay_marker_length")
    end

    test "replace_text folds multiline replacement into one paragraph" do
      assert {:ok, op} =
               Op.normalize(%{
                 "op" => "replace_text",
                 "query" => "PLACEHOLDER",
                 "replacement" => "첫째 줄\n둘째 줄"
               })

      assert op.replacement == "첫째 줄 둘째 줄"
    end

    test "rejects op without an op discriminator" do
      assert {:error, _} = Op.normalize(%{"ref" => "hwp:s0/p1"})
    end

    test "rejects unknown op verb" do
      assert {:error, {:unknown_op, "frobnicate"}} =
               Op.normalize(%{"op" => "frobnicate", "ref" => "x"})
    end

    test "knows the full verb vocabulary from the design" do
      verbs =
        ~w(insert_text delete_range replace_text insert_paragraph delete_paragraph split merge
           insert_table insert_table_row delete_table_row insert_table_column delete_table_column
           merge_cells split_cell delete_node insert_picture set_cell insert_equation
           insert_footnote insert_endnote insert_shape set_columns insert_slide set_geometry)

      for verb <- verbs do
        assert verb in Op.verbs()
      end

      assert Enum.sort(Op.verbs()) == Enum.sort(verbs)
    end

    test "accepts set_cell with a cell ref and multi-line text" do
      assert {:ok, op} =
               Op.normalize(%{
                 "op" => "set_cell",
                 "ref" => "hwp:s0/p0/tbl2/cell3/cp0/c0+5",
                 "text" => "① Sleep is important.\n수면은 중요하다."
               })

      assert op.op == "set_cell"
      assert op.ref == "hwp:s0/p0/tbl2/cell3/cp0/c0+5"
      assert op.text == "① Sleep is important.\n수면은 중요하다."
    end

    test "set_cell allows empty text (clears the cell) but requires a string" do
      assert {:ok, _} =
               Op.normalize(%{
                 "op" => "set_cell",
                 "ref" => "hwp:s0/p0/tbl0/cell0/cp0/c0+0",
                 "text" => ""
               })

      assert {:error, {:invalid_op, msg}} =
               Op.normalize(%{"op" => "set_cell", "ref" => "hwp:s0/p0/tbl0/cell0/cp0/c0+0"})

      assert msg =~ "text"
    end

    test "set_cell requires a ref" do
      assert {:error, {:invalid_op, msg}} =
               Op.normalize(%{"op" => "set_cell", "text" => "x"})

      assert msg =~ "ref"
    end

    test "set_cell is part of the verb vocabulary" do
      assert "set_cell" in Op.verbs()
    end
  end
end
