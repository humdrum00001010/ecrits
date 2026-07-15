defmodule EcritsWeb.Live.Studio.Components.EditorSurfaceTest do
  use EcritsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Ecrits.DocumentCanvasState
  alias Ecrits.EditorPreviewState
  alias Ecrits.EditorSurfaceState
  alias EcritsWeb.Live.Studio.Components.EditorSurface
  alias EcritsWeb.Live.Studio.Components.Canvas.HwpPages

  test "document tab close sends an explicit LiveView event" do
    html =
      render_local_document(
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

    assert close |> LazyHTML.attribute("phx-click") == ["workspace.document.close"]
    assert close |> LazyHTML.attribute("phx-value-id") == ["07-hwp"]

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
      render_local_document(
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
    assert "bullets" in commands
    assert "numbering" in commands
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

    # The four align commands live in one native disclosure whose face is
    # selected by the LiveView-owned toolbar state.
    menu_button =
      fragment
      |> LazyHTML.query(~s([data-role="align-menu-button"]))
      |> Enum.to_list()
      |> List.first()

    assert menu_button
    assert menu_button |> LazyHTML.tag() == ["summary"]

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
    assert menu |> LazyHTML.attribute("role") == ["menu"]

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

    for {id, label} <- [
          {"editor-toolbar-bullets", "Toggle bulleted list"},
          {"editor-toolbar-numbering", "Toggle numbered list"}
        ] do
      button = fragment |> LazyHTML.query("##{id}") |> Enum.at(0)
      assert button
      assert button |> LazyHTML.attribute("aria-label") == [label]
      assert button |> LazyHTML.attribute("data-active") == ["false"]
    end
  end

  test "HWP page scroll host is keyboard focusable outside mirror previews" do
    html =
      render_component(&HwpPages.render/1,
        id: "local-hwp-pages",
        pages: [],
        state:
          DocumentCanvasState.new(%{
            document_id: "sample-hwp",
            document_path: "sample.hwp",
            document_format: "hwp",
            spec: %{
              key: "local_hwp",
              name: "sample.hwp",
              template_hwp_path: "sample.hwp"
            }
          })
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

  test "HEEx owns the backend-neutral document search controls" do
    html =
      render_local_document(
        shell_id: "local-rhwp-shell",
        toolbar_id: "local-rhwp-toolbar",
        frame_id: "local-rhwp-editor-frame",
        document: %{id: "07-hwp", format: "hwp", relative_path: "07_공문.hwp"},
        document_path: "07_공문.hwp",
        document_spec: %{key: "local_hwp", name: "07_공문.hwp", template_hwp_path: "07_공문.hwp"},
        canvas_id: "local-rhwp-07-hwp",
        open_documents: [],
        active_document_id: "07-hwp",
        dirty_document_ids: MapSet.new(),
        hwp_pages: [],
        hwp_page_count: 0
      )

    fragment = LazyHTML.from_fragment(html)
    bar = fragment |> LazyHTML.query("form#document-search-bar") |> Enum.at(0)
    input = fragment |> LazyHTML.query("#document-search-input") |> Enum.at(0)
    counter = fragment |> LazyHTML.query("#document-search-counter") |> Enum.at(0)

    assert bar
    assert bar |> LazyHTML.attribute("role") == ["search"]
    assert bar |> LazyHTML.attribute("hidden") != []
    assert bar |> LazyHTML.attribute("phx-change") == ["document.search.query_changed"]
    assert bar |> LazyHTML.attribute("phx-submit") == ["document.search.next"]
    assert bar |> LazyHTML.attribute("phx-window-keydown") == ["document.search.close"]
    assert bar |> LazyHTML.attribute("phx-hook") == []
    assert input |> LazyHTML.attribute("type") == ["search"]
    assert input |> LazyHTML.attribute("name") == ["document_search[query]"]
    assert input |> LazyHTML.attribute("phx-debounce") == ["150"]
    assert counter |> LazyHTML.attribute("aria-live") == ["polite"]

    for {id, event} <- [
          {"document-search-prev", "document.search.previous"},
          {"document-search-next", "document.search.next"},
          {"document-search-close", "document.search.close"}
        ] do
      button = fragment |> LazyHTML.query("##{id}") |> Enum.at(0)
      assert button
      assert button |> LazyHTML.attribute("type") == ["button"]
      assert button |> LazyHTML.attribute("aria-label") != []
      assert button |> LazyHTML.attribute("phx-click") == [event]
    end

    bridge = fragment |> LazyHTML.query("#local-rhwp-shell") |> Enum.at(0)

    assert bridge |> LazyHTML.attribute("phx-hook") == [
             "EcritsWeb.Live.Studio.Components.EditorSurface.DocumentSearchBridge"
           ]

    assert bridge
           |> LazyHTML.attribute("data-search-state")
           |> List.first()
           |> Jason.decode!()
           |> Map.fetch!("open") == false
  end

  test "quick toolbar hides underline and image for markdown documents" do
    html =
      render_local_document(
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
    refute "bullets" in commands
    refute "numbering" in commands
    # The font row is not a markdown concept either.
    refute Enum.any?(commands, &String.starts_with?(&1, "font-size-"))
    refute "text-color" in commands
    refute "highlight" in commands

    refute fragment
           |> LazyHTML.query("#document-search-bar")
           |> Enum.any?()
  end

  test "embedded document renders with the browser office mirror" do
    html =
      render_component(&EditorSurface.embedded_document/1,
        id: "agent-preview",
        state:
          EditorPreviewState.new(%{
            canvas_id: "agent-preview-canvas",
            document: %{id: "doc-1", relative_path: "calc.xlsx", format: "xlsx"},
            document_path: "calc.xlsx",
            status: :running,
            canvas: %{
              document_id: "doc-1",
              document_path: "calc.xlsx",
              document_format: "xlsx",
              bytes_url: "/local/document-bytes?document=doc-1",
              mirror?: true,
              preview_text: "Draft text",
              preview_delta_count: 2
            }
          })
      )

    fragment = LazyHTML.from_fragment(html)

    preview =
      fragment
      |> LazyHTML.query(~s([data-role="editor-preview"]))
      |> Enum.to_list()
      |> List.first()

    assert preview
    [preview_state_json] = LazyHTML.attribute(preview, "data-preview-state")
    preview_state = Jason.decode!(preview_state_json)

    assert preview_state["documentId"] == "doc-1"
    assert preview_state["deltaCount"] == 2
    assert preview_state["mode"] == "embedded-editor"

    refute fragment
           |> LazyHTML.query(~s([data-role="editor-preview-image"]))
           |> Enum.any?()

    assert fragment
           |> LazyHTML.query(~s([data-component="canvas-local-office-wasm"]))
           |> Enum.any?()

    assert fragment |> LazyHTML.query(~s([data-role="editor-preview-open"])) |> Enum.to_list() !=
             []
  end

  defp render_local_document(attrs) do
    render_component(&EditorSurface.local_document/1,
      shell_id: Keyword.fetch!(attrs, :shell_id),
      toolbar_id: Keyword.fetch!(attrs, :toolbar_id),
      frame_id: Keyword.fetch!(attrs, :frame_id),
      hwp_pages: Keyword.get(attrs, :hwp_pages, []),
      state:
        attrs
        |> Keyword.drop([:shell_id, :toolbar_id, :frame_id, :hwp_pages])
        |> Map.new()
        |> EditorSurfaceState.new()
    )
  end
end
