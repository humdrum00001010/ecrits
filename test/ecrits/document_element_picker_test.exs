defmodule Ecrits.DocumentElementPickerTest do
  use ExUnit.Case, async: true

  alias Ecrits.DocumentElementPicker

  test "pick transitions cast, validate, and deduplicate server state" do
    picker =
      DocumentElementPicker.new()
      |> DocumentElementPicker.toggle()
      |> DocumentElementPicker.toggle_pick(%{
        document: String.duplicate("d", 600),
        type: "paragraph",
        ref: "[0,1,0]",
        text: String.duplicate("t", 300),
        rects: [%{pageIndex: 0, x: 1.5, ignored: "value"}]
      })

    assert picker.enabled?
    assert picker.picks == []

    picker =
      DocumentElementPicker.toggle_pick(picker, %{
        document: "doc.hwpx",
        type: "paragraph",
        ref: "[0,1,0]",
        text: "selected text",
        rects: [%{pageIndex: 0, x: 1.5}]
      })

    assert [pick] = picker.picks
    assert pick.document == "doc.hwpx"
    assert pick.text == "selected text"
    assert pick.rects == [%{pageIndex: 0, x: 1.5}]

    picker = DocumentElementPicker.put_enabled(picker, false)
    refute picker.enabled?
    assert [^pick] = picker.picks

    assert DocumentElementPicker.toggle_pick(picker, %{document: pick.document, ref: pick.ref}).picks ==
             []
  end

  test "compact picks are allowlisted, bounded, and deduplicated" do
    picks = [
      %{document: "doc.hwp", type: "paragraph", ref: "p1", text: "one", ir: %{secret: 1}},
      %{"document" => "doc.hwp", "type" => "paragraph", "ref" => "p1", "text" => "two"},
      %{document: "doc.hwp", type: "paragraph", ref: "", text: "", hint: ""}
    ]

    assert [pick] = DocumentElementPicker.compact_picks(picks)

    assert pick == %{
             "document" => "doc.hwp",
             "type" => "paragraph",
             "ref" => "p1",
             "text" => "one",
             "hint" => ""
           }
  end
end
