defmodule Ecrits.Fuse.OpenDocsLifecycleTest do
  use ExUnit.Case, async: true

  alias Ecrits.Fuse.OpenDocs.Lifecycle

  test "builds and validates clean committed state" do
    assert {:ok,
            %Lifecycle{
              bytes: "projection",
              dirty_owner: nil,
              generation: 4,
              in_flight: nil,
              pending: nil
            }} = Lifecycle.cast(%{bytes: "projection", generation: 4})
  end

  test "rejects a negative generation" do
    assert {:error, %Ecto.Changeset{}} =
             Lifecycle.cast(%{bytes: "projection", generation: -1})
  end
end
