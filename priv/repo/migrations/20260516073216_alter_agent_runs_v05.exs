defmodule Contract.Repo.Migrations.AlterAgentRunsV05 do
  @moduledoc """
  SPEC.md v0.5 §7.9 — extend the existing `agent_runs` table with the
  fields the v0.5 AgentRun schema needs.

  The legacy table (created 2026-05-15) was minimal: it tracked
  document_id, status, turn_index, previous_response_id, message. The
  v0.5 shape adds owner_id, chat_thread_id, lifecycle timestamps
  (started_at / completed_at), an error map, model name, and the set of
  tools the run was permitted to call.

  Foundation wave: columns are added permissively (no nullability
  tightening on existing columns) so legacy rows keep working. Wave 2+
  will populate the new columns.
  """
  use Ecto.Migration

  def change do
    alter table(:agent_runs) do
      add_if_not_exists(:owner_id, :binary_id)
      add_if_not_exists(:chat_thread_id, :binary_id)
      add_if_not_exists(:started_at, :utc_datetime)
      add_if_not_exists(:completed_at, :utc_datetime)
      add_if_not_exists(:error, :map)
      add_if_not_exists(:model, :string)
      add_if_not_exists(:tools_enabled, {:array, :string}, default: [])
    end

    create_if_not_exists(index(:agent_runs, [:chat_thread_id]))
    # :document_id and :status indexes already exist from the original
    # create_agent_runs migration.
  end
end
