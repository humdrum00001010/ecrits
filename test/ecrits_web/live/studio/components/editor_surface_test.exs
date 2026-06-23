defmodule EcritsWeb.Live.Studio.Components.EditorSurfaceTest do
  use EcritsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EcritsWeb.Live.Studio.Components.EditorSurface

  test "document tab close marks the tab hidden before pushing the LiveView close callback" do
    html =
      render_component(&EditorSurface.local_document/1,
        shell_id: "local-rhwp-shell",
        toolbar_id: "local-rhwp-toolbar",
        frame_id: "local-rhwp-editor-frame",
        document: nil,
        document_path: nil,
        document_loading?: false,
        open_documents: [%{id: "07-hwp", name: "07_공문.hwp", path: "07_공문.hwp"}],
        active_document_id: "07-hwp",
        dirty_document_ids: MapSet.new(),
        hwp_pages: [],
        hwp_page_count: 0
      )

    close =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="document-tab-close"]))
      |> Enum.to_list()
      |> List.first()

    assert close
    assert close |> LazyHTML.attribute("type") == ["button"]
    assert close |> LazyHTML.attribute("href") == []

    phx_click = close |> LazyHTML.attribute("phx-click") |> List.first()
    assert phx_click =~ "set_attr"
    assert phx_click =~ "hidden"
    assert phx_click =~ "tab_close"
    assert phx_click =~ "07-hwp"

    assert String.split(phx_click, "set_attr") |> List.last() =~ "push"
  end

  test "embedded document renders a mirror office surface with preview metadata" do
    html =
      render_component(&EditorSurface.embedded_document/1,
        id: "agent-preview",
        canvas_id: "agent-preview-canvas",
        document: %{id: "doc-1", name: "calc.xlsx", relative_path: "calc.xlsx", format: "xlsx"},
        document_path: "calc.xlsx",
        hwp_bytes_url: "/local/document-bytes?document=doc-1",
        href: "/workspace/calc.xlsx",
        status: :running,
        preview_text: "Draft text",
        delta_count: 2
      )

    fragment = LazyHTML.from_fragment(html)

    preview =
      fragment
      |> LazyHTML.query(~s([data-role="editor-preview"]))
      |> Enum.to_list()
      |> List.first()

    assert preview
    assert preview |> LazyHTML.attribute("data-document-id") == ["doc-1"]
    assert preview |> LazyHTML.attribute("data-preview-delta-count") == ["2"]

    office =
      fragment
      |> LazyHTML.query(~s([data-component="canvas-local-office-wasm"]))
      |> Enum.to_list()
      |> List.first()

    assert office
    assert office |> LazyHTML.attribute("data-document-id") == ["doc-1"]
    assert office |> LazyHTML.attribute("data-editor-mirror") == ["true"]
    assert office |> LazyHTML.attribute("data-preview-text") == ["Draft text"]

    assert fragment |> LazyHTML.query(~s([data-role="editor-preview-open"])) |> Enum.to_list() !=
             []
  end
end
