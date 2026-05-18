defmodule Contract.Export.HTMLTest do
  use ExUnit.Case, async: true

  alias Contract.Export.HTML
  alias Contract.Runtime.State

  # --------------------------------------------------------------------------
  # helpers
  # --------------------------------------------------------------------------

  defp empty_state do
    %State{
      document_id: "doc-0000-0000-0000-000000000001",
      revision: 0,
      projection: State.empty_projection()
    }
  end

  defp state_with_nodes(nodes_list, extra \\ %{}) do
    nodes = Map.new(nodes_list, fn n -> {n.id, n} end)
    order = Enum.map(nodes_list, & &1.id)

    %State{
      document_id: "doc-0000-0000-0000-000000000001",
      revision: 0,
      projection:
        Map.merge(
          %{State.empty_projection() | nodes: nodes, node_order: order},
          extra
        )
    }
  end

  # --------------------------------------------------------------------------
  # 1. shape + magic
  # --------------------------------------------------------------------------

  test "render/2 returns {:ok, binary} for an empty projection" do
    assert {:ok, bin} = HTML.render(empty_state())
    assert is_binary(bin)
    assert byte_size(bin) > 0
  end

  test "output starts with <!doctype html>" do
    {:ok, html} = HTML.render(empty_state())
    assert String.starts_with?(html, "<!doctype html>")
  end

  test "contains the required HTML5 head elements" do
    {:ok, html} = HTML.render(empty_state())
    assert html =~ ~s(<meta charset="utf-8">)
    assert html =~ "<title>"
    assert html =~ "</html>"
  end

  # --------------------------------------------------------------------------
  # 2. Floki parse (we already depend on lazy_html in test). lazy_html parses
  #    fragments; we use it via `LazyHTML.from_document/1` for a quick
  #    well-formedness check.
  # --------------------------------------------------------------------------

  test "render output parses cleanly with LazyHTML" do
    {:ok, html} = HTML.render(empty_state())
    parsed = LazyHTML.from_document(html)
    # A successful parse returns a non-nil document.
    assert parsed != nil
  end

  # --------------------------------------------------------------------------
  # 3. Determinism
  # --------------------------------------------------------------------------

  test "render is deterministic: same projection (state + raw map) yields byte-identical output" do
    state = empty_state()
    {:ok, a} = HTML.render(state)
    {:ok, b} = HTML.render(state)
    {:ok, from_proj} = HTML.render(state.projection)

    assert a == b
    assert a == from_proj
  end

  # --------------------------------------------------------------------------
  # 4. UTF-8 Korean round-trip
  # --------------------------------------------------------------------------

  test "Korean content survives byte-exact" do
    korean = "계약서 — 갑은 을에게 100만원을 지급한다."

    state = state_with_nodes([%{id: "p1", kind: :paragraph, content: korean}])
    {:ok, html} = HTML.render(state)

    assert html =~ korean
    # The bytes for the Korean string must literally appear in the output.
    assert :binary.match(html, korean) != :nomatch
  end

  # --------------------------------------------------------------------------
  # 5. XSS / escaping
  # --------------------------------------------------------------------------

  test "angle brackets and ampersands in content are escaped" do
    state =
      state_with_nodes([
        %{id: "p1", kind: :paragraph, content: ~s|<script>alert("x")</script> & co|}
      ])

    {:ok, html} = HTML.render(state)

    refute html =~ "<script>alert"
    assert html =~ "&lt;script&gt;"
    assert html =~ "&amp; co"
  end

  # --------------------------------------------------------------------------
  # 6. Headings render with correct level
  # --------------------------------------------------------------------------

  test "heading nodes render <hN> for levels 1..6 and clamp out-of-range levels to <h6>" do
    nodes =
      for level <- 1..6 do
        %{id: "h#{level}", kind: :heading, content: "Heading #{level}", attrs: %{level: level}}
      end

    {:ok, html} = HTML.render(state_with_nodes(nodes))

    for level <- 1..6 do
      assert html =~ "<h#{level}>Heading #{level}</h#{level}>"
    end

    # Out-of-range clamps to <h6>.
    {:ok, clamped} =
      HTML.render(
        state_with_nodes([%{id: "h", kind: :heading, content: "X", attrs: %{level: 99}}])
      )

    assert clamped =~ "<h6>X</h6>"
  end

  # --------------------------------------------------------------------------
  # 7. Lists
  # --------------------------------------------------------------------------

  test "list with list_item children renders as <ul><li>...</li></ul>" do
    nodes = [
      %{id: "li1", kind: :list_item, content: "alpha"},
      %{id: "li2", kind: :list_item, content: "beta"},
      %{id: "ul", kind: :list, children: ["li1", "li2"]}
    ]

    nodes_map = Map.new(nodes, fn n -> {n.id, n} end)

    state = %State{
      revision: 0,
      projection: %{State.empty_projection() | nodes: nodes_map, node_order: ["ul"]}
    }

    {:ok, html} = HTML.render(state)
    assert html =~ "<ul><li>alpha</li><li>beta</li></ul>"
  end

  # --------------------------------------------------------------------------
  # 8. Tables
  # --------------------------------------------------------------------------

  test "table with cells renders rows + cols" do
    nodes = [
      %{id: "c11", kind: :cell, content: "A1"},
      %{id: "c12", kind: :cell, content: "B1"},
      %{id: "c21", kind: :cell, content: "A2"},
      %{id: "c22", kind: :cell, content: "B2"},
      %{
        id: "t",
        kind: :table,
        children: ["c11", "c12", "c21", "c22"],
        attrs: %{rows: 2, cols: 2}
      }
    ]

    nodes_map = Map.new(nodes, fn n -> {n.id, n} end)

    state = %State{
      revision: 0,
      projection: %{State.empty_projection() | nodes: nodes_map, node_order: ["t"]}
    }

    {:ok, html} = HTML.render(state)
    assert html =~ "<table>"
    assert html =~ "<tr><td>A1</td><td>B1</td></tr>"
    assert html =~ "<tr><td>A2</td><td>B2</td></tr>"
  end

  # --------------------------------------------------------------------------
  # 9. Field refs resolve from projection.fields
  # --------------------------------------------------------------------------

  test "field_ref node renders the resolved field value" do
    nodes_map = %{
      "f1" => %{id: "f1", kind: :field_ref, attrs: %{field_id: "party_a"}}
    }

    fields = %{"party_a" => %{id: "party_a", value: "갑"}}

    state = %State{
      revision: 0,
      projection: %{
        State.empty_projection()
        | nodes: nodes_map,
          node_order: ["f1"],
          fields: fields
      }
    }

    {:ok, html} = HTML.render(state)
    assert html =~ ~s(data-field-id="party_a")
    assert html =~ "갑"
  end

  # --------------------------------------------------------------------------
  # 10. Title from projection.title
  # --------------------------------------------------------------------------

  test "projection.title becomes the <title> and the H1 heading" do
    state =
      state_with_nodes([%{id: "p", kind: :paragraph, content: "x"}], %{
        title: "서비스 제공 계약서"
      })

    {:ok, html} = HTML.render(state)
    assert html =~ "<title>서비스 제공 계약서</title>"
    assert html =~ "<h1 class=\"contract-title\">서비스 제공 계약서</h1>"
  end

  test "missing title falls back to Untitled" do
    {:ok, html} = HTML.render(empty_state())
    assert html =~ "<title>Untitled</title>"
  end

  # --------------------------------------------------------------------------
  # 11. ContractTypes smoke — every shipped TOML renders with an empty
  #      projection of that type without raising or returning {:error, _}.
  # --------------------------------------------------------------------------

  test "every ContractType renders against an empty-projection state" do
    {:ok, specs} = Contract.ContractTypes.list()
    refute Enum.empty?(specs), "expected at least one ContractType fixture"

    for spec <- specs do
      state = %State{
        revision: 0,
        projection: %{
          State.empty_projection()
          | type_key: spec.key,
            title: spec.name_ko || spec.name_en
        }
      }

      assert {:ok, html} = HTML.render(state), "type=#{spec.key} failed"
      assert is_binary(html) and byte_size(html) > 0
    end
  end

  # --------------------------------------------------------------------------
  # 12. 5-paragraph fixture for the report
  # --------------------------------------------------------------------------

  test "5-paragraph projection produces 5 <p> elements with content" do
    nodes =
      for i <- 1..5 do
        %{id: "p#{i}", kind: :paragraph, content: "Paragraph #{i} body."}
      end

    {:ok, html} = HTML.render(state_with_nodes(nodes, %{title: "Five-paragraph fixture"}))

    count = html |> String.split("<p>") |> length() |> Kernel.-(1)
    # The 5 body paragraphs (NB: title h1 is an <h1>, not a <p>).
    assert count == 5

    for i <- 1..5 do
      assert html =~ "Paragraph #{i} body."
    end
  end
end
