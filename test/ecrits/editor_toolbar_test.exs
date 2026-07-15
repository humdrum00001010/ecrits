defmodule Ecrits.EditorToolbarTest do
  use ExUnit.Case, async: true

  alias Ecrits.EditorToolbar

  test "engine state is accepted only for the active document when its changeset is valid" do
    toolbar =
      EditorToolbar.new()
      |> EditorToolbar.put_engine_state(
        %{
          document_id: "active",
          bold: true,
          bullets: true,
          alignment: "left",
          font_size_pt: 10.04
        },
        "active"
      )

    assert toolbar.bold
    assert toolbar.bullets
    assert toolbar.alignment == "left"
    assert toolbar.font_size_pt == 10.04

    assert EditorToolbar.put_engine_state(
             toolbar,
             %{document_id: "active", alignment: "invalid"},
             "active"
           ) == toolbar

    assert EditorToolbar.put_engine_state(toolbar, %{document_id: "stale", bold: false}, "active") ==
             toolbar
  end

  test "commands validate values and serialize active document identity" do
    document = %{id: "active", format: "hwpx"}

    assert {:ok, %{command: "font-size-set", document_id: "active", size: 12.5}} =
             EditorToolbar.command(
               EditorToolbar.new(),
               "font-size-set",
               %{size: "12.5"},
               document
             )

    assert :error =
             EditorToolbar.command(EditorToolbar.new(), "font-size-set", %{size: 999}, document)

    assert {:ok, %{command: "text-color", color: "#AABBCC"}} =
             EditorToolbar.command(
               EditorToolbar.new(),
               "text-color",
               %{color: "#AABBCC"},
               document
             )

    assert {:ok, %{command: "bullets", document_id: "active"}} =
             EditorToolbar.command(EditorToolbar.new(), "bullets", %{}, document)

    assert {:ok, %{command: "numbering", document_id: "active"}} =
             EditorToolbar.command(EditorToolbar.new(), "numbering", %{}, document)
  end

  test "shortcut payloads are mapped on the server" do
    assert EditorToolbar.shortcut_command(%{key: "b", meta_key: true}) == "bold"

    assert EditorToolbar.shortcut_command(%{
             key: "e",
             ctrl_key: true,
             shift_key: true
           }) == "align-center"

    assert EditorToolbar.shortcut_command(%{key: "s", meta_key: true}) == nil
  end
end
