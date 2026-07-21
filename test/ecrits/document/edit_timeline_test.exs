defmodule Ecrits.Document.EditTimelineTest do
  use ExUnit.Case, async: true

  alias Ecrits.Document.EditTimeline

  test "a candidate for the same edit replaces the prior candidate revision" do
    timeline = EditTimeline.new("turn-1", "document-1")

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:candidate, "edit-1", "revision-a", [highlight(2, "old")])
             )

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:candidate, "edit-1", "revision-b", [highlight(2, "new")])
             )

    assert %{edit_id: "edit-1", revision: "revision-b", phase: :candidate} =
             EditTimeline.current(timeline)

    assert EditTimeline.highlights(timeline) == []
  end

  test "separate committed edits retain all stable highlights in document order" do
    timeline = EditTimeline.new("turn-1", "document-1")

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:committed, "edit-1", "revision-a", [highlight(3, "later")])
             )

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:committed, "edit-2", "revision-b", [
                 highlight(1, "earlier"),
                 highlight(3, "later")
               ])
             )

    assert Enum.map(EditTimeline.highlights(timeline), & &1["label"]) == [
             "earlier",
             "later"
           ]

    assert %{edit_id: "edit-2", revision: "revision-b", phase: :committed} =
             EditTimeline.current(timeline)
  end

  test "rejection removes only the exact candidate and restores the prior commit" do
    timeline = EditTimeline.new("turn-1", "document-1")

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:committed, "edit-0", "revision-0", [highlight(0, "saved")])
             )

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:candidate, "edit-1", "revision-a", [highlight(1, "draft")])
             )

    assert {:stale, same_timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:rejected, "edit-1", "revision-other", [])
             )

    assert same_timeline == timeline
    assert %{edit_id: "edit-1", phase: :candidate} = EditTimeline.current(timeline)

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:rejected, "edit-1", "revision-a", [])
             )

    assert %{edit_id: "edit-0", revision: "revision-0", phase: :committed} =
             EditTimeline.current(timeline)

    assert Enum.map(EditTimeline.highlights(timeline), & &1["label"]) == ["saved"]
  end

  test "a stale snapshot completion cannot replace the latest committed edit" do
    timeline = EditTimeline.new("turn-1", "document-1")

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:committed, "edit-1", "revision-a", [highlight(0, "first")])
             )

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:committed, "edit-2", "revision-b", [highlight(1, "second")])
             )

    stale_snapshot =
      event(:snapshot_ready, "edit-1", "revision-a", [])
      |> Map.put(:preview_snapshot, %{id: "snapshot-a"})

    assert {:ok, timeline} = EditTimeline.apply_event(timeline, stale_snapshot)

    assert %{edit_id: "edit-2", revision: "revision-b", preview_snapshot: nil} =
             EditTimeline.current(timeline)

    mismatched_snapshot = %{stale_snapshot | revision: "revision-other"}
    assert {:stale, ^timeline} = EditTimeline.apply_event(timeline, mismatched_snapshot)
  end

  test "rapid commits retain both edit facts when the first snapshot finishes last" do
    timeline = EditTimeline.new("turn-1", "document-1")

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:committed, "edit-1", "revision-a", [highlight(0, "text")])
             )

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:committed, "edit-2", "revision-b", [highlight(2, "table")])
             )

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:snapshot_ready, "edit-2", "revision-b", [])
               |> Map.put(:preview_snapshot, %{id: "snapshot-b"})
             )

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:snapshot_ready, "edit-1", "revision-a", [])
               |> Map.put(:preview_snapshot, %{id: "snapshot-a"})
             )

    assert Enum.map(EditTimeline.highlights(timeline), & &1["label"]) == ["text", "table"]

    assert %{edit_id: "edit-2", preview_snapshot: %{id: "snapshot-b"}} =
             EditTimeline.current(timeline)
  end

  test "visible highlights sort a candidate together with committed edits" do
    timeline = EditTimeline.new("turn-1", "document-1")

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:committed, "edit-1", "revision-a", [highlight(8, "committed-later")])
             )

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:candidate, "edit-2", "revision-b", [highlight(2, "candidate-earlier")])
             )

    assert Enum.map(EditTimeline.visible_highlights(timeline), & &1["label"]) == [
             "candidate-earlier",
             "committed-later"
           ]
  end

  test "opaque Office refs use deterministic natural document ordering" do
    timeline = EditTimeline.new("turn-1", "document-1")

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:committed, "edit-1", "revision-a", [
                 office_highlight("page[10]/shape[2]", "page-ten")
               ])
             )

    assert {:ok, timeline} =
             EditTimeline.apply_event(
               timeline,
               event(:committed, "edit-2", "revision-b", [
                 office_highlight("page[2]/shape[11]", "page-two-shape-eleven"),
                 office_highlight("page[2]/shape[3]", "page-two-shape-three")
               ])
             )

    assert Enum.map(EditTimeline.highlights(timeline), & &1["label"]) == [
             "page-two-shape-three",
             "page-two-shape-eleven",
             "page-ten"
           ]
  end

  defp event(phase, edit_id, revision, highlights) do
    %{
      phase: phase,
      turn_id: "turn-1",
      edit_id: edit_id,
      document_id: "document-1",
      path: "/tmp/document.hwpx",
      revision: revision,
      ops: [],
      sets: [],
      highlights: highlights,
      preview_snapshot: nil,
      preview_snapshot_error: nil,
      agent_id: "agent-1",
      instance_id: "instance-1"
    }
  end

  defp highlight(paragraph, label) do
    %{
      "op" => "replace_text",
      "label" => label,
      "ref" => %{"section" => 0, "paragraph" => paragraph, "offset" => 0}
    }
  end

  defp office_highlight(ref, label) do
    %{
      "op" => "replace_text",
      "label" => label,
      "ref" => ref
    }
  end
end
