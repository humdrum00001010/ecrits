defmodule Contract.Repo.Migrations.CreateAgentRuns do
  use Ecto.Migration

  def change do
    create table(:agent_runs, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:document_id, :binary_id)
      add(:triggered_by_action_id, :binary_id)

      add(:status, :string, null: false, default: "running")
      add(:turn_index, :integer, null: false, default: 0)
      add(:previous_response_id, :string)
      add(:message, :text)

      timestamps(type: :utc_datetime)
    end

    create(index(:agent_runs, [:document_id]))
    create(index(:agent_runs, [:status]))
  end
end
