defmodule Ecrits.WorkspaceLayoutTest do
  use ExUnit.Case, async: true

  alias Ecrits.WorkspaceLayout

  test "new casts and validates every transmitted layout attribute" do
    layout =
      WorkspaceLayout.new(%{
        "file_tree_width" => "99999",
        "chat_rail_width" => -10,
        "file_tree_collapsed?" => "true",
        "editor_fullscreen?" => "true"
      })

    assert layout.file_tree_width == 520
    assert layout.chat_rail_width == 280
    assert layout.file_tree_collapsed?
    assert layout.editor_fullscreen?
    assert layout.drag == nil
  end

  test "resize transactions reject unknown panels and malformed coordinates" do
    layout = WorkspaceLayout.new()

    assert WorkspaceLayout.begin_resize(layout, %{"panel" => "unknown", "x" => 10}) ==
             layout

    assert WorkspaceLayout.begin_resize(layout, %{
             "panel" => "file_tree",
             "x" => "not-a-number",
             "panel_width" => 260,
             "viewport_width" => 1_024
           }) == layout
  end

  test "file-tree resize is server-owned and clamped around the editor" do
    layout =
      WorkspaceLayout.new()
      |> WorkspaceLayout.begin_resize(%{
        "panel" => "file_tree",
        "x" => 100,
        "panel_width" => 260,
        "viewport_width" => 1_024
      })
      |> WorkspaceLayout.resize(%{"x" => 1_000, "viewport_width" => 1_024})

    assert layout.file_tree_width == 324
    assert layout.drag.panel == :file_tree
    assert WorkspaceLayout.finish_resize(layout).drag == nil
  end

  test "collapse and HEEx transmission are derived from validated state" do
    layout = WorkspaceLayout.new() |> WorkspaceLayout.toggle_file_tree()

    assert layout.file_tree_collapsed?
    assert WorkspaceLayout.file_tree_render_width(layout) == 40
    assert WorkspaceLayout.grid_style(layout) =~ "--workspace-file-tree-width: 40px"
    assert WorkspaceLayout.grid_style(layout) =~ "--workspace-chat-rail-width: 340px"
  end

  test "editor fullscreen is a validated server transition" do
    layout = WorkspaceLayout.new() |> WorkspaceLayout.toggle_editor_fullscreen()

    assert layout.editor_fullscreen?
    refute WorkspaceLayout.toggle_editor_fullscreen(layout).editor_fullscreen?
  end
end
