defmodule Ecrits.AgentTest do
  use ExUnit.Case, async: true

  alias Ecrits.Agent
  alias Ecrits.Agent.Dialog

  test "dialog items are validated by their bounded item schemas" do
    assert_raise ArgumentError, fn ->
      Agent.new_dialog!(%{
        turn_id: "turn-invalid-tool",
        items: [%{role: :tool, status: :completed}]
      })
    end
  end

  test "dialog dump/load preserves polymorphic item order and metadata" do
    dialog =
      Agent.new_dialog!(%{
        turn_id: "turn-1",
        user: "inspect files",
        agent: "done",
        items: [
          %{role: :user, body: "inspect files"},
          %{role: :thinking, body: "Plan command", segment: 0},
          %{
            role: :tool,
            name: "Bash",
            status: :completed,
            input: "pwd",
            output: "/tmp",
            provider_metadata: %{request_id: "req-1"}
          },
          %{role: :agent, body: "done"}
        ]
      })

    assert %Dialog{} = dialog

    restored =
      dialog
      |> Agent.dump_dialog()
      |> Jason.encode!()
      |> Jason.decode!()
      |> Agent.load_dialog!()

    assert %Dialog{turn_id: "turn-1", user: "inspect files", agent: "done"} = restored
    assert Enum.map(restored.items, &Map.fetch!(&1, :role)) == [:user, :thinking, :tool, :agent]

    assert Map.fetch!(Enum.at(restored.items, 2), "provider_metadata") == %{
             "request_id" => "req-1"
           }
  end

  test "legacy dialog maps are normalized without reordering items" do
    legacy = %{
      "turn_id" => "legacy-turn",
      "user" => "hello",
      "agent" => "hi",
      "items" => [
        %{"role" => "user", "body" => "hello"},
        %{"role" => "agent", "body" => "hi", "status" => "sent"}
      ]
    }

    assert %Dialog{items: [%{role: :user}, %{role: :agent, status: :sent}]} =
             Agent.load_dialog!(legacy)
  end

  test "preview upsert compacts every matching legacy descriptor at the first position" do
    old = preview_item("old")
    duplicate = preview_item("duplicate")
    replacement = preview_item("replacement")

    items = [
      %{role: :user, body: "edit it"},
      old,
      %{role: :thinking, body: "working"},
      duplicate,
      %{role: :agent, body: "done"}
    ]

    assert [
             %{role: :user},
             %{role: :edit_preview, summary: "replacement"},
             %{role: :thinking},
             %{role: :agent}
           ] = Agent.upsert_dialog_item(items, replacement, "turn-preview")
  end

  test "dialog normalization compacts persisted duplicate preview descriptors" do
    dialogs = [
      %{
        turn_id: "turn-preview",
        user: "edit it",
        agent: "done",
        items: [
          %{role: :user, body: "edit it"},
          preview_item("old"),
          %{role: :thinking, body: "working"},
          preview_item("latest"),
          %{role: :agent, body: "done"}
        ]
      }
    ]

    assert [
             %Dialog{
               items: [
                 %{role: :user},
                 %{role: :edit_preview, summary: "latest"},
                 %{role: :thinking},
                 %{role: :agent}
               ]
             }
           ] = Agent.normalize_dialogs!(dialogs)
  end

  test "preview identity replaces snapshot retries for the same turn edit and document" do
    first = preview_item("first")

    next_snapshot =
      first
      |> put_in([:preview_snapshot, :id], "snapshot-next")
      |> Map.put(:summary, "next snapshot")

    next_turn = %{first | turn_id: "turn-next"}

    final_retry =
      first
      |> put_in([:preview_snapshot, :id], "snapshot-final")
      |> Map.put(:summary, "latest retry")

    items =
      []
      |> Agent.upsert_dialog_item(first, "turn-preview")
      |> Agent.upsert_dialog_item(next_snapshot, "turn-preview")
      |> Agent.upsert_dialog_item(next_turn, "turn-preview")
      |> Agent.upsert_dialog_item(final_retry, "turn-preview")

    assert Enum.map(items, & &1.summary) == [
             "latest retry",
             "first"
           ]

    assert Enum.map(items, &Agent.edit_preview_identity(&1, "turn-preview")) == [
             {"turn-preview", "edit-preview", "document-preview"},
             {"turn-next", "edit-preview", "document-preview"}
           ]

    assert hd(items).preview_snapshot.id == "snapshot-final"
  end

  defp preview_item(summary) do
    %{
      role: :edit_preview,
      status: :sent,
      turn_id: "turn-preview",
      edit_id: "edit-preview",
      document_id: "document-preview",
      preview_snapshot: %{id: "snapshot-preview", document_id: "document-preview"},
      summary: summary
    }
  end
end
