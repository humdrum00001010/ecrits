defmodule Ecrits.Doc.Office.OpClassifyTest do
  @moduledoc """
  Pure unit coverage for the office op→wire classifier (`Ecrits.Doc.Office.classify/1`
  — the `Op.normalize` → `to_uno_op` pipeline `edit/3` runs BEFORE touching a UNO
  session). No LibreOffice/LOK toolchain needed.

  Guards the #49 typed-IR promise that a SUPPORTED verb missing its `ref` reports
  THAT — not a misleading "not supported by the UNO arm" that sends the agent
  hunting for a different verb instead of supplying the ref it has from doc.find.
  """
  use ExUnit.Case, async: true

  alias Ecrits.Doc.Office

  # These verbs require a binary `ref` but are NOT field-checked by Op.normalize,
  # so a ref-less call reaches to_uno_op and used to hit the catch-all. All six
  # apply :ok WITH a ref in office_uno_op_matrix_test (i.e. genuinely supported).
  @ref_required ~w(delete_paragraph split merge merge_cells split_cell delete_node)

  describe "a supported verb missing its ref" do
    for verb <- @ref_required do
      test "#{verb} → a clear ref-required error, never \"not supported\"" do
        assert {:error, {:invalid_op, msg}} = Office.classify(%{"op" => unquote(verb)})
        assert msg =~ ~s(requires a "ref"), "expected a ref-required message, got: #{msg}"
        assert msg =~ unquote(verb)
        refute msg =~ "not supported"
      end
    end
  end

  describe "those same verbs WITH a ref classify to a wire op" do
    test "split carries its ref through" do
      assert {:ok, wire} = Office.classify(%{"op" => "split", "ref" => "p1"})
      assert wire["op"] == "split"
      assert wire["ref"] == "p1"
    end

    test "delete_node carries its ref through" do
      assert {:ok, wire} = Office.classify(%{"op" => "delete_node", "ref" => "img[Logo]"})
      assert wire["op"] == "delete_node"
      assert wire["ref"] == "img[Logo]"
    end
  end

  describe "verbs Op.normalize already field-checks keep their specific messages" do
    test "insert_text without a ref keeps the insert_text-specific guidance" do
      assert {:error, {:invalid_op, msg}} =
               Office.classify(%{"op" => "insert_text", "text" => "hi"})

      assert msg =~ "insert_text requires"
    end
  end

  describe "an unknown verb stays an unknown_op (rejected before to_uno_op)" do
    test "frobnicate is unknown, not a ref problem" do
      assert {:error, {:unknown_op, "frobnicate"}} = Office.classify(%{"op" => "frobnicate"})
    end
  end
end
