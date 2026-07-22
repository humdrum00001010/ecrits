defmodule Ecrits.Doc.EditLifecycleEventTest do
  use ExUnit.Case, async: true

  alias Ecrits.Doc.EditLifecycleEvent

  test "casts string-keyed lifecycle data and defaults collections" do
    assert {:ok, event} =
             EditLifecycleEvent.cast(%{
               "phase" => "committed",
               "turn_id" => "turn-1",
               "edit_id" => "edit-1",
               "document_id" => "doc-1",
               "revision" => 7,
               "ops" => nil
             })

    assert %EditLifecycleEvent{phase: :committed, ops: [], sets: [], highlights: []} = event
    assert EditLifecycleEvent.dump(event).phase == :committed
  end

  test "rejects unknown phases" do
    assert {:error, %Ecto.Changeset{}} = EditLifecycleEvent.cast(%{phase: "future"})
  end
end
