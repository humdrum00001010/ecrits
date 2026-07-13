defmodule Ecrits.EditorSurfaceStateTest do
  use ExUnit.Case, async: true

  alias Ecrits.DocumentElementPicker
  alias Ecrits.EditorSurfaceState
  alias Ecrits.WorkspaceLayout

  test "the editor surface crosses HEEx as one validated embedded model" do
    state =
      EditorSurfaceState.new(%{
        active_document_id: "doc-1",
        dirty_document_ids: MapSet.new(["doc-1"]),
        document_element_picker: DocumentElementPicker.new(%{enabled?: true}),
        workspace_layout: WorkspaceLayout.new(%{editor_fullscreen?: true}),
        hwp_page_count: -4
      })

    assert state.active_document_id == "doc-1"
    assert state.dirty_document_ids == ["doc-1"]
    assert state.document_element_picker.enabled?
    assert state.workspace_layout.editor_fullscreen?
    assert state.hwp_page_count == 0
  end

  test "Ecto casting rejects malformed state attrs" do
    state =
      EditorSurfaceState.new(%{
        "open_documents" => "not-a-list",
        "document_loading?" => "true",
        "active_document_id" => 123,
        "unknown" => "ignored"
      })

    assert state.open_documents == []
    refute state.document_loading?
    assert state.active_document_id == nil
    refute Map.has_key?(state, :unknown)
  end

  test "document path derivation belongs to the sanitizer boundary" do
    state =
      EditorSurfaceState.new(%{
        document: %{id: "notes", format: "md", relative_path: "notes/readme.md"}
      })

    assert state.document_path == "notes/readme.md"
  end
end
