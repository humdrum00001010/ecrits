defmodule Ecrits.MarkdownEditorStateTest do
  use ExUnit.Case, async: true

  alias Ecrits.MarkdownEditorState

  test "selection attributes are cast and validated before server text transitions" do
    state =
      MarkdownEditorState.new()
      |> MarkdownEditorState.load("doc", "a bold z")
      |> MarkdownEditorState.put_selection(%{"start" => 2, "end" => 6})
      |> MarkdownEditorState.apply_toolbar_command("bold")

    assert state.source == "a **bold** z"
    assert state.selection_start == 4
    assert state.selection_end == 8
    assert state.dirty?
  end

  test "an already wrapped selection is unwrapped on the server" do
    state =
      MarkdownEditorState.new()
      |> MarkdownEditorState.load("doc", "a **bold** z")
      |> MarkdownEditorState.put_selection(%{start: 4, end: 8})
      |> MarkdownEditorState.apply_toolbar_command("bold")

    assert state.source == "a bold z"
    assert state.selection_start == 2
    assert state.selection_end == 6
  end

  test "browser UTF-16 selection offsets remain correct around emoji" do
    state =
      MarkdownEditorState.new()
      |> MarkdownEditorState.load("doc", "A😀B")
      |> MarkdownEditorState.put_selection(%{"start" => 1, "end" => 3})
      |> MarkdownEditorState.apply_toolbar_command("bold")

    assert state.source == "A**😀**B"
    assert state.selection_start == 3
    assert state.selection_end == 5
  end

  test "view and saved state are explicit transitions" do
    state = MarkdownEditorState.new()

    assert MarkdownEditorState.toggle_view(state).view == :source

    refute state
           |> MarkdownEditorState.put_source("changed")
           |> MarkdownEditorState.mark_saved()
           |> Map.get(:dirty?)
  end
end
