defmodule Ecrits.Workspace.TurnOwnerTest do
  use ExUnit.Case, async: true

  alias Ecrits.Workspace.TurnOwner

  test "validates pids, monitor reference, and status" do
    owner_ref = Process.monitor(self())

    assert {:ok,
            %TurnOwner{
              owner_pid: owner_pid,
              owner_ref: ^owner_ref,
              task_pid: task_pid,
              status: :active
            }} =
             TurnOwner.cast(%{
               owner_pid: self(),
               owner_ref: owner_ref,
               task_pid: self(),
               status: :active
             })

    assert owner_pid == self()
    assert task_pid == self()
    Process.demonitor(owner_ref, [:flush])
  end

  test "rejects invalid runtime ownership values" do
    assert {:error, %Ecto.Changeset{}} =
             TurnOwner.cast(%{owner_pid: "pid", owner_ref: "ref", task_pid: self()})
  end
end
