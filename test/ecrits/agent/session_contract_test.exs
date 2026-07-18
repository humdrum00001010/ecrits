defmodule Ecrits.Agent.SessionContractTest do
  use ExUnit.Case, async: true

  alias Ecrits.AcpAgent.Session
  alias Ecrits.Agent.SessionContract

  test "the ACP session implements the core session contract" do
    Code.ensure_loaded!(Session)
    callbacks = SessionContract.behaviour_info(:callbacks)

    assert Enum.all?(callbacks, fn {function, arity} ->
             function_exported?(Session, function, arity)
           end)
  end
end
