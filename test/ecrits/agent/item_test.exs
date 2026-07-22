defmodule Ecrits.Agent.ItemTest do
  use ExUnit.Case, async: true

  alias Ecrits.Agent.Item
  alias Ecrits.Agent.Item.{EditPreview, FileActivity, Text, Tool}

  test "dispatches every transcript role to one bounded schema" do
    assert {:ok, %Text{role: :user, body: "hello"}} =
             Item.cast(%{"role" => "user", "body" => "hello"})

    assert {:ok, %Text{role: :thinking, segment: 2}} =
             Item.cast(%{role: :thinking, body: "inspect", segment: 2})

    assert {:ok, %Tool{name: "Bash", status: :completed}} =
             Item.cast(%{role: :tool, name: "Bash", status: "completed", input: "pwd"})

    assert {:ok, %FileActivity{file_operation_id: "file-1"}} =
             Item.cast(%{
               role: :file_activity,
               file_operation_id: "file-1",
               operation: "read_text_file",
               path: "contract.jsonl",
               status: :running
             })

    assert {:ok, %EditPreview{edit_id: "edit-1", document_id: "doc-1"}} =
             Item.cast(%{
               role: :edit_preview,
               turn_id: "turn-1",
               edit_id: "edit-1",
               document_id: "doc-1"
             })
  end

  test "rejects an unknown role without creating an atom" do
    assert {:error, %Ecto.Changeset{}} = Item.cast(%{"role" => "new-provider-role"})
  end

  test "dump preserves provider extension keys" do
    attrs = %{
      "role" => "tool",
      "name" => "Bash",
      "status" => "completed",
      "input" => "pwd",
      "provider_metadata" => %{"request_id" => "req-1"}
    }

    assert {:ok, item} = Item.cast(attrs)

    assert Item.dump(item) == %{
             "provider_metadata" => %{"request_id" => "req-1"},
             role: :tool,
             name: "Bash",
             status: :completed,
             input: "pwd"
           }
  end

  test "dump distinguishes an explicitly nil field from an absent field" do
    assert {:ok, item} =
             Item.cast(%{
               role: :file_activity,
               file_operation_id: "file-1",
               operation: "read_text_file",
               query: nil
             })

    assert %{query: nil} = Item.dump(item)
    refute Map.has_key?(Item.dump(item), :output)
  end
end
