defmodule Ecrits.Agent.DurableStateTest do
  use ExUnit.Case, async: true

  alias Ecrits.Agent.{AdapterOptions, DurableState}

  test "casts JSON state and dumps the same durable shape" do
    attrs = %{
      "id" => "agent-1",
      "instance_id" => "instance-1",
      "provider_session_id" => "provider-1",
      "thread_covers_from" => 2,
      "title" => "Contract",
      "title_user_edited?" => true,
      "transcript" => [],
      "adapter_opts" => %{"model" => "gpt-5", "reasoning_effort" => "high"}
    }

    assert {:ok, %DurableState{adapter_opts: %AdapterOptions{model: "gpt-5"}} = state} =
             DurableState.cast(attrs)

    assert DurableState.dump(state) == attrs
  end

  test "rejects non-scalar persisted adapter options" do
    assert {:error, %Ecto.Changeset{}} =
             DurableState.cast(%{
               id: "agent-1",
               transcript: [],
               adapter_opts: %{model: %{unexpected: true}}
             })
  end
end
