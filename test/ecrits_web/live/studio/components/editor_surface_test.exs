defmodule EcritsWeb.Live.Studio.Components.EditorSurfaceTest do
  use EcritsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias EcritsWeb.Live.Studio.Components.EditorSurface
  alias EcritsWeb.Live.Studio.Components.Canvas.LocalHwpPages

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

    tab =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="document-tab-switch"]))
      |> Enum.to_list()
      |> List.first()

    wrapper =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="document-tab"]))
      |> Enum.to_list()
      |> List.first()

    assert wrapper |> LazyHTML.attribute("role") == ["presentation"]
    assert tab |> LazyHTML.attribute("role") == []
    assert tab |> LazyHTML.attribute("aria-pressed") == ["true"]
    assert tab |> LazyHTML.attribute("tabindex") == ["0"]

    document_controls =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#studio-document-tabs")
      |> Enum.to_list()
      |> List.first()

    assert document_controls |> LazyHTML.attribute("role") == ["group"]
  end

  test "quick toolbar exposes bold/italic/underline commands with shortcut hints for hwp" do
    html =
      render_component(&EditorSurface.local_document/1,
        shell_id: "local-rhwp-shell",
        toolbar_id: "local-rhwp-toolbar",
        frame_id: "local-rhwp-editor-frame",
        document: %{id: "07-hwp", format: "hwp", relative_path: "07_공문.hwp"},
        document_path: "07_공문.hwp",
        document_spec: %{key: "local_hwp", name: "07_공문.hwp", template_hwp_path: "07_공문.hwp"},
        canvas_id: "local-rhwp-07-hwp",
        open_documents: [%{id: "07-hwp", name: "07_공문.hwp", path: "07_공문.hwp"}],
        active_document_id: "07-hwp",
        dirty_document_ids: MapSet.new(),
        hwp_pages: [],
        hwp_page_count: 0
      )

    fragment = LazyHTML.from_fragment(html)

    commands =
      fragment
      |> LazyHTML.query(~s(#local-document-quick-toolbar [data-command]))
      |> Enum.to_list()
      |> Enum.map(&(&1 |> LazyHTML.attribute("data-command") |> List.first()))

    assert "bold" in commands
    assert "italic" in commands
    assert "underline" in commands
    assert "strikethrough" in commands
    assert "align-left" in commands
    assert "align-center" in commands
    assert "align-right" in commands
    assert "align-justify" in commands
    assert "text-color" in commands
    assert "highlight" in commands
    # The size field is the only size control — no A−/A+ stepper buttons.
    refute Enum.any?(commands, &String.starts_with?(&1, "font-size-"))

    # The font row's value controls: a size input (Enter applies) and hidden
    # native color pickers the buttons open.
    for role <- ~w(font-size-input text-color-input highlight-color-input) do
      input =
        fragment
        |> LazyHTML.query(~s(#local-document-quick-toolbar [data-role="#{role}"]))
        |> Enum.to_list()
        |> List.first()

      assert input, "missing [data-role=#{role}]"
      assert input |> LazyHTML.attribute("aria-label") != []
    end

    # The four align commands live in ONE dropdown: a menu button whose face
    # carries all four icons (JS shows the caret's alignment), and a hidden menu.
    menu_button =
      fragment
      |> LazyHTML.query(~s([data-role="align-menu-button"]))
      |> Enum.to_list()
      |> List.first()

    assert menu_button
    assert menu_button |> LazyHTML.attribute("aria-haspopup") == ["menu"]

    face_icons =
      fragment
      |> LazyHTML.query(~s([data-role="align-menu-button"] [data-align-icon]))
      |> Enum.to_list()
      |> Enum.map(&(&1 |> LazyHTML.attribute("data-align-icon") |> List.first()))

    assert face_icons == ~w(left center right justify)

    menu =
      fragment
      |> LazyHTML.query(~s([data-role="align-menu"]))
      |> Enum.to_list()
      |> List.first()

    assert menu
    assert menu |> LazyHTML.attribute("hidden") != []

    menu_items =
      fragment
      |> LazyHTML.query(~s([data-role="align-menu"] [data-command]))
      |> Enum.to_list()
      |> Enum.map(&(&1 |> LazyHTML.attribute("data-command") |> List.first()))

    assert menu_items == ~w(align-left align-center align-right align-justify)

    underline =
      fragment
      |> LazyHTML.query(~s([data-command="underline"]))
      |> Enum.to_list()
      |> List.first()

    assert underline |> LazyHTML.attribute("title") == ["Underline (⌘U)"]

    bold =
      fragment
      |> LazyHTML.query(~s([data-command="bold"]))
      |> Enum.to_list()
      |> List.first()

    assert bold |> LazyHTML.attribute("title") == ["Bold (⌘B)"]
  end

  test "HWP page scroll host is keyboard focusable outside mirror previews" do
    html =
      render_component(&LocalHwpPages.render/1,
        id: "local-hwp-pages",
        pages: [],
        page_count: 0,
        spec: %{key: "local_hwp", name: "sample.hwp", template_hwp_path: "sample.hwp"},
        document_id: "sample-hwp",
        document_path: "sample.hwp",
        local_document_format: "hwp"
      )

    editor =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="local-hwp-editor"]))
      |> Enum.to_list()
      |> List.first()

    assert editor |> LazyHTML.attribute("tabindex") == ["0"]
    assert editor |> LazyHTML.attribute("role") == ["region"]
    assert editor |> LazyHTML.attribute("aria-label") == ["Document pages"]
  end

  test "quick toolbar hides underline and image for markdown documents" do
    html =
      render_component(&EditorSurface.local_document/1,
        shell_id: "local-rhwp-shell",
        toolbar_id: "local-rhwp-toolbar",
        frame_id: "local-rhwp-editor-frame",
        document: %{id: "notes-md", format: "md", relative_path: "notes.md"},
        document_path: "notes.md",
        canvas_id: "local-rhwp-notes-md",
        open_documents: [%{id: "notes-md", name: "notes.md", path: "notes.md"}],
        active_document_id: "notes-md",
        dirty_document_ids: MapSet.new(),
        hwp_pages: [],
        hwp_page_count: 0
      )

    fragment = LazyHTML.from_fragment(html)

    commands =
      fragment
      |> LazyHTML.query(~s(#local-document-quick-toolbar [data-command]))
      |> Enum.to_list()
      |> Enum.map(&(&1 |> LazyHTML.attribute("data-command") |> List.first()))

    # Markdown keeps bold/italic/strikethrough (**/*/~~ wraps), but underline,
    # alignment and image are not markdown concepts.
    assert "bold" in commands
    assert "italic" in commands
    assert "strikethrough" in commands
    refute "underline" in commands
    refute "image" in commands
    refute Enum.any?(commands, &String.starts_with?(&1, "align-"))
    # The font row is not a markdown concept either.
    refute Enum.any?(commands, &String.starts_with?(&1, "font-size-"))
    refute "text-color" in commands
    refute "highlight" in commands
  end

  test "embedded document renders a mirror office surface with preview metadata" do
    html =
      render_component(&EditorSurface.embedded_document/1,
        id: "agent-preview",
        canvas_id: "agent-preview-canvas",
        document: %{id: "doc-1", name: "calc.xlsx", relative_path: "calc.xlsx", format: "xlsx"},
        document_path: "calc.xlsx",
        hwp_bytes_url: "/local/document-bytes?document=doc-1",
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
