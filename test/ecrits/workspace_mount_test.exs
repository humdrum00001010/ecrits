defmodule Ecrits.WorkspaceMountTest do
  use ExUnit.Case, async: true

  alias Ecrits.WorkspaceMount

  test "is an embedded schema with a changeset-backed path" do
    changeset = WorkspaceMount.changeset(WorkspaceMount.new(), %{"path" => "  /tmp/work  "})

    assert %Ecto.Changeset{data: %WorkspaceMount{}} = changeset
    assert Ecto.Changeset.get_change(changeset, :path) == "/tmp/work"
  end

  @tag :tmp_dir
  test "path casting and filesystem validation are outside the LiveView", %{tmp_dir: tmp_dir} do
    state = WorkspaceMount.new(%{path: "  #{tmp_dir}  "})

    assert state.path == tmp_dir
    assert WorkspaceMount.validate_path(state) == {:ok, Path.expand(tmp_dir)}
  end

  test "picker transitions validate browser results and errors" do
    state = WorkspaceMount.new() |> WorkspaceMount.start_picker()

    assert state.picker_busy?
    assert state.error == nil

    state = WorkspaceMount.picker_failed(state, :cancelled)

    refute state.picker_busy?
    assert state.error == "Folder selection canceled."
  end

  test "blank submissions are rejected by the validation module" do
    state = WorkspaceMount.new() |> WorkspaceMount.submit("  ")

    assert WorkspaceMount.validate_path(state) ==
             {:error, {:invalid_path, "Choose a workspace folder."}}
  end
end
