defmodule Contract.Runtime.StateTest do
  use ExUnit.Case, async: true

  alias Contract.Runtime.State

  test "default struct has empty projection with all top-level keys" do
    s = %State{}
    assert s.revision == 0
    assert s.document_id == nil

    for key <- [:title, :type_key, :metadata, :nodes, :node_order, :fields, :marks, :refs] do
      assert Map.has_key?(s.projection, key), "projection missing key #{inspect(key)}"
    end

    assert s.projection.nodes == %{}
    assert s.projection.node_order == []
    assert s.projection.refs == %{}
  end

  test "empty_projection/0 returns the same value as the default" do
    assert %State{}.projection == State.empty_projection()
  end

  # ----------------------------------------------------------------------------
  # IR-richness (task #37): table/cell node attrs.
  # ----------------------------------------------------------------------------

  describe "IR-richness: table + cell attrs" do
    test "table_attr_keys/0 lists the canonical HWPX-grade keys" do
      keys = State.table_attr_keys()

      for k <- [:column_widths, :border_fill_id, :header_row_count, :footer_row_count] do
        assert k in keys, "expected #{inspect(k)} in table_attr_keys/0"
      end
    end

    test "cell_attr_keys/0 lists span + border + vertical_alignment + padding_* keys" do
      keys = State.cell_attr_keys()

      for k <- [
            :row_span,
            :col_span,
            :border_fill_id,
            :vertical_alignment,
            :padding_top,
            :padding_right,
            :padding_bottom,
            :padding_left
          ] do
        assert k in keys, "expected #{inspect(k)} in cell_attr_keys/0"
      end
    end

    test "a :table node round-trips with rich attrs through the projection" do
      table_id = "tbl-1"

      table = %{
        id: table_id,
        kind: :table,
        children: ["c1", "c2", "c3"],
        attrs: %{
          column_widths: [3000, 4000, 5000],
          border_fill_id: "5",
          header_row_count: 1,
          footer_row_count: 0
        }
      }

      proj =
        State.empty_projection()
        |> Map.put(:nodes, %{table_id => table})
        |> Map.put(:node_order, [table_id])

      state = %State{document_id: "d", revision: 0, projection: proj}

      stored = state.projection.nodes[table_id]
      assert stored.attrs.column_widths == [3000, 4000, 5000]
      assert stored.attrs.border_fill_id == "5"
      assert stored.attrs.header_row_count == 1
      assert stored.attrs.footer_row_count == 0
    end

    test "a :cell node carries span + padding + border_fill_id + vertical_alignment" do
      cell_id = "c1"

      cell = %{
        id: cell_id,
        kind: :cell,
        attrs: %{
          row_span: 2,
          col_span: 3,
          border_fill_id: "7",
          vertical_alignment: :center,
          padding_top: 100,
          padding_right: 200,
          padding_bottom: 300,
          padding_left: 400
        }
      }

      proj = State.empty_projection() |> Map.put(:nodes, %{cell_id => cell})
      state = %State{document_id: "d", revision: 0, projection: proj}

      a = state.projection.nodes[cell_id].attrs
      assert a.row_span == 2
      assert a.col_span == 3
      assert a.border_fill_id == "7"
      assert a.vertical_alignment == :center
      assert a.padding_top == 100
      assert a.padding_right == 200
      assert a.padding_bottom == 300
      assert a.padding_left == 400
    end

    test "absent rich attrs are simply missing — projection shape is unchanged" do
      # Additive guarantee: a table with no rich attrs still parses and stores.
      table = %{id: "t", kind: :table, children: [], attrs: %{rows: 1, cols: 1}}
      proj = State.empty_projection() |> Map.put(:nodes, %{"t" => table})
      state = %State{document_id: "d", revision: 0, projection: proj}

      attrs = state.projection.nodes["t"].attrs
      refute Map.has_key?(attrs, :column_widths)
      refute Map.has_key?(attrs, :border_fill_id)
      assert attrs.rows == 1
      assert attrs.cols == 1
    end
  end
end
