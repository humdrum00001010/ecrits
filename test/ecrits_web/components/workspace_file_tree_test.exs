defmodule EcritsWeb.Components.WorkspaceFileTreeTest do
  use EcritsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ecrits.FileTree
  alias EcritsWeb.Components.WorkspaceFileTree

  test "renders openable file rows as LiveView event controls" do
    html =
      render_component(&WorkspaceFileTree.tree/1,
        id: "local-file-tree",
        state:
          FileTree.new(%{
            nodes: [%{type: :file, name: "template.hwp", path: "template.hwp"}]
          })
      )

    fragment = LazyHTML.from_fragment(html)
    rows = fragment |> LazyHTML.query(~s([data-role="repo-browser-row"])) |> Enum.to_list()

    assert [row] = rows
    assert row |> LazyHTML.attribute("phx-click") == ["workspace.document.open"]
    assert row |> LazyHTML.attribute("phx-value-path") == ["template.hwp"]
    assert row |> LazyHTML.attribute("aria-selected") == ["false"]
    refute row |> LazyHTML.attribute("data-bytes-url") |> Enum.any?()
    refute row |> LazyHTML.attribute("data-node-path") |> Enum.any?()
    refute row |> LazyHTML.attribute("data-phx-link") |> Enum.any?()
    refute row |> LazyHTML.attribute("href") |> Enum.any?()
  end

  test "renders unique Korean document rows with document icons" do
    html =
      render_component(&WorkspaceFileTree.tree/1,
        id: "local-file-tree",
        state:
          FileTree.new(%{
            nodes: [
              %{type: :file, name: "template.hwp", path: "template.hwp"},
              %{type: :file, name: "각주_본문_검증.hwp", path: "각주_본문_검증.hwp"},
              %{type: :file, name: "수면과_건강_설명글.hwp", path: "수면과_건강_설명글.hwp"},
              %{type: :file, name: "각주_본문_검증.hwp", path: "각주_본문_검증.hwp"}
            ]
          })
      )

    fragment = LazyHTML.from_fragment(html)
    rows = fragment |> LazyHTML.query(~s([data-role="repo-browser-row"])) |> Enum.to_list()

    assert Enum.count(rows) == 3
    assert fragment |> LazyHTML.query("#local-file-node-template-hwp") |> Enum.any?()

    korean_rows =
      rows
      |> Enum.filter(fn row ->
        row
        |> LazyHTML.attribute("phx-value-path")
        |> List.first()
        |> String.contains?(".hwp")
      end)
      |> Enum.reject(fn row ->
        row |> LazyHTML.attribute("phx-value-path") |> List.first() == "template.hwp"
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
