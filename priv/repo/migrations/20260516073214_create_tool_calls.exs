defmodule Contract.Repo.Migrations.CreateToolCalls do
  @moduledoc """
  SPEC.md v0.5 §7.9 — ToolCall.

  Persistent per-call audit row for tools invoked inside an AgentRun.
  Used for audit, replay, UI display, legal evidence traceability.
  """
  use Ecto.Migration

  def change do
    create_if_not_exists table(:tool_calls, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:agent_run_id, :binary_id, null: false)

      add(:name, :string, null: false)
      add(:arguments, :map, null: false, default: %{})
      add(:result, :map, null: false, default: %{})

      add(:status, :string, null: false, default: "pending")

      add(:started_at, :utc_datetime)
      add(:completed_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:tool_calls, [:agent_run_id]))
    create_if_not_exists(index(:tool_calls, [:name]))
    create_if_not_exists(index(:tool_calls, [:status]))
  end
end
