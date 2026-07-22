defmodule Ecrits.Workspace.TurnFinalizationStateTest do
  use ExUnit.Case, async: true

  alias Ecrits.Workspace.TurnFinalizationState
  alias Ecrits.Workspace.TurnFinalizationState.Active

  test "casts coherent queue state and a runtime active record" do
    key = {"agent-1", "instance-1", "turn-1"}
    ref = Process.monitor(self())

    assert {:ok,
            %TurnFinalizationState{
              queue: [^key],
              active: %Active{key: ^key, pid: pid, ref: ^ref, attempts: 1}
            }} =
             TurnFinalizationState.cast(%{
               finalizations: %{key => %{status: :queued, attempts: 0}},
               order: [],
               queue: [key],
               waiters: %{},
               active: %{key: key, pid: self(), ref: ref, attempts: 1}
             })

    assert pid == self()
    Process.demonitor(ref, [:flush])
  end

  test "drops queue keys missing from finalizations" do
    key = {"agent-1", "instance-1", "turn-1"}

    assert {:ok, %TurnFinalizationState{queue: []}} =
             TurnFinalizationState.cast(%{finalizations: %{}, queue: [key]})
  end
end
