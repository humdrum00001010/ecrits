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

    test "rejects op without an op discriminator" do
      assert {:error, _} = Op.normalize(%{"ref" => "hwp:s0/p1"})
    end

    test "rejects unknown op verb" do
      assert {:error, {:unknown_op, "frobnicate"}} =
               Op.normalize(%{"op" => "frobnicate", "ref" => "x"})
    end

    test "knows the full verb vocabulary from the design" do
      verbs = ~w(insert_text delete_range replace_text split insert_node delete_node
                 move_node insert_picture)

      for verb <- verbs do
        assert verb in Op.verbs()
      end
    end
  end
end
