defmodule Ecrits.Doc.OpSchemaTest do
  use ExUnit.Case, async: true

  test "every advertised verb dispatches to exactly one Ecto schema" do
    for verb <- Ecrits.Doc.Op.verbs() do
      module = Ecrits.Doc.Op.Dispatcher.schema_for(verb)
      assert is_atom(module)
      assert Code.ensure_loaded?(module)
      assert function_exported?(module, :changeset, 2)
    end
  end

  test "shape extensions stay string keyed" do
    assert {:ok, op} =
             Ecrits.Doc.Op.normalize(%{
               "op" => "insert_shape",
               "page" => "summary",
               "name" => "title",
               "x" => 100,
               "y" => 100,
               "w" => 1_000,
               "h" => 500,
               "CharHeight" => 32
             })

    assert op.op == "insert_shape"
    assert op["CharHeight"] == 32
  end
end
