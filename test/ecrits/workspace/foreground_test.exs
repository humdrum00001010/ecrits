defmodule Ecrits.Workspace.ForegroundTest do
  use ExUnit.Case, async: true

  alias Ecrits.Workspace.Foreground

  test "casts durable fields and keeps settings runtime-only" do
    attrs = %{
      agent_id: "agent-1",
      provider: "codex",
      owner_session_id: "browser-1",
      settings: [access_control: "ask"]
    }

    assert {:ok, %Foreground{settings: [access_control: "ask"]} = foreground} =
             Foreground.cast(attrs)

    refute Map.has_key?(Foreground.dump_durable(foreground), "settings")
  end

  test "requires stable agent and owner ids" do
    assert {:error, %Ecto.Changeset{}} = Foreground.cast(%{provider: "codex"})
  end
end
