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
          font_size_pt: 10.04,
          font_family: "Noto Sans",
          line_spacing: 1.5,
          named_style: "Heading 1",
          table_context: true
        },
        "active"
      )

    assert toolbar.bold
    assert toolbar.bullets
    assert toolbar.alignment == "left"
    assert toolbar.font_size_pt == 10.04
    assert toolbar.font_family == "Noto Sans"
    assert toolbar.line_spacing == 1.5
    assert toolbar.named_style == "Heading 1"
    assert toolbar.table_context

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

    assert {:ok, %{command: "font-family-set", family: "Noto Sans"}} =
             EditorToolbar.command(
               EditorToolbar.new(),
               "font-family-set",
               %{family: "Noto Sans"},
               document
             )

    assert {:ok, %{command: "line-spacing-set", spacing: 1.5}} =
             EditorToolbar.command(
               EditorToolbar.new(),
               "line-spacing-set",
               %{spacing: "1.5"},
               document
             )

    assert :error =
             EditorToolbar.command(
               EditorToolbar.new(),
               "line-spacing-set",
               %{spacing: "1.25"},
               document
             )

    assert {:ok, %{command: "named-style-set", style: "heading-2"}} =
             EditorToolbar.command(
               EditorToolbar.new(),
               "named-style-set",
               %{style: "heading-2"},
               document
             )

    assert {:ok, %{command: "table-insert", rows: 3, cols: 4}} =
             EditorToolbar.command(
               EditorToolbar.new(),
               "table-insert",
               %{rows: "3", cols: "4"},
               document
             )

    assert :error =
             EditorToolbar.command(
               EditorToolbar.new(),
               "table-insert",
               %{rows: "0", cols: "4"},
               document
             )
  end

  test "value commands remain owned by the embedded toolbar state" do
    toolbar =
      EditorToolbar.new()
      |> EditorToolbar.remember_command("font-family-set", %{family: "Noto Serif"})
      |> EditorToolbar.remember_command("line-spacing-set", %{spacing: 2.0})
      |> EditorToolbar.remember_command("named-style-set", %{style: "quote"})

    assert toolbar.font_family == "Noto Serif"
    assert toolbar.line_spacing == 2.0
    assert toolbar.named_style == "quote"
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
