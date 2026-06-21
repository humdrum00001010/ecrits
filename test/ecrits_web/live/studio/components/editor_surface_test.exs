defmodule EcritsWeb.Live.Studio.Components.EditorSurfaceTest do
  use EcritsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EcritsWeb.Live.Studio.Components.EditorSurface

  test "document tab close has a native href fallback and LiveView close push" do
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
        tab_close_hrefs: %{"07-hwp" => "/workspace?path=/tmp/ecrits&provider=codex"},
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
    assert close |> LazyHTML.attribute("href") == ["/workspace?path=/tmp/ecrits&provider=codex"]
    assert close |> LazyHTML.attribute("role") == ["button"]

    phx_click = close |> LazyHTML.attribute("phx-click") |> List.first()
    assert phx_click =~ "hide"
    assert phx_click =~ "tab_close"
    assert phx_click =~ "07-hwp"
  end
end
