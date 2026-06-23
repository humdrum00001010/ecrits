defmodule EcritsWeb.Components.LocalFileTreeTest do
  use EcritsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EcritsWeb.Components.LocalFileTree

  test "renders openable file rows as plain href fallbacks" do
    html =
      render_component(&LocalFileTree.tree/1,
        id: "local-file-tree",
        nodes: [
          %{type: :file, name: "template.hwp", path: "template.hwp"}
        ],
        expanded_paths: MapSet.new(),
        selected_path: nil,
        open_paths: %{"template.hwp" => "/workspace?path=/tmp/ecrits&document=template.hwp"}
      )

    fragment = LazyHTML.from_fragment(html)
    rows = fragment |> LazyHTML.query(~s([data-role="repo-browser-row"])) |> Enum.to_list()

    assert [row] = rows
    assert row |> LazyHTML.attribute("href") |> List.first() =~ "/workspace?"
    refute row |> LazyHTML.attribute("data-phx-link") |> Enum.any?()
    refute row |> LazyHTML.attribute("phx-click") |> Enum.any?()
  end

  test "renders unique Korean document rows with document icons" do
    html =
      render_component(&LocalFileTree.tree/1,
        id: "local-file-tree",
        nodes: [
          %{type: :file, name: "template.hwp", path: "template.hwp"},
          %{type: :file, name: "각주_본문_검증.hwp", path: "각주_본문_검증.hwp"},
          %{type: :file, name: "수면과_건강_설명글.hwp", path: "수면과_건강_설명글.hwp"},
          %{type: :file, name: "각주_본문_검증.hwp", path: "각주_본문_검증.hwp"}
        ],
        expanded_paths: MapSet.new(),
        selected_path: nil
      )

    fragment = LazyHTML.from_fragment(html)
    rows = fragment |> LazyHTML.query(~s([data-role="repo-browser-row"])) |> Enum.to_list()

    assert Enum.count(rows) == 3
    assert fragment |> LazyHTML.query("#local-file-node-template-hwp") |> Enum.any?()

    korean_rows =
      rows
      |> Enum.filter(fn row ->
        row
        |> LazyHTML.attribute("data-node-path")
        |> List.first()
        |> String.contains?(".hwp")
      end)
      |> Enum.reject(fn row ->
        row |> LazyHTML.attribute("data-node-path") |> List.first() == "template.hwp"
      end)

    ids = Enum.map(korean_rows, fn row -> row |> LazyHTML.attribute("id") |> List.first() end)

    assert Enum.count(korean_rows) == 2
    assert Enum.uniq(ids) == ids
    assert Enum.all?(ids, &String.starts_with?(&1, "local-file-node-hwp-"))

    for row <- korean_rows do
      assert row |> LazyHTML.query(".hero-document-check") |> Enum.any?()
    end
  end
end
