defmodule Contract.Repo.Migrations.ChangeV05Shape do
  use Ecto.Migration

  def up do
    drop_if_exists(index(:changes, [:matter_id]))
    drop_if_exists(index(:changes, [:document_id, :applied_revision]))

    rename(table(:changes), :action_kind, to: :command_kind)
    rename(table(:changes), :applied_revision, to: :result_revision)
    rename(table(:changes), :ops, to: :payload)
    rename(table(:changes), :inverse_ops, to: :inverse)

    alter table(:changes) do
      add(:chat_thread_id, :binary_id)
      add(:source_document_id, :binary_id)
      add(:source_claim_id, :binary_id)
      add(:agent_run_id, :binary_id)
      add(:field_path, {:array, :string}, default: [], null: false)
      add(:op, :string)
      remove(:matter_id)
      remove(:artifact_id)
    end

    create(index(:changes, [:document_id, :result_revision]))
    create(index(:changes, [:chat_thread_id]))
    create(index(:changes, [:source_document_id]))
    create(index(:changes, [:source_claim_id]))
    create(index(:changes, [:agent_run_id]))
  end

  def down do
    drop_if_exists(index(:changes, [:agent_run_id]))
    drop_if_exists(index(:changes, [:source_claim_id]))
    drop_if_exists(index(:changes, [:source_document_id]))
    drop_if_exists(index(:changes, [:chat_thread_id]))
    drop_if_exists(index(:changes, [:document_id, :result_revision]))

    alter table(:changes) do
      add(:matter_id, :binary_id)
      add(:artifact_id, :binary_id)
      remove(:op)
      remove(:field_path)
      remove(:agent_run_id)
      remove(:source_claim_id)
      remove(:source_document_id)
      remove(:chat_thread_id)
    end

    rename(table(:changes), :inverse, to: :inverse_ops)
    rename(table(:changes), :payload, to: :ops)
    rename(table(:changes), :result_revision, to: :applied_revision)
    rename(table(:changes), :command_kind, to: :action_kind)

    create(index(:changes, [:document_id, :applied_revision]))
    create(index(:changes, [:matter_id]))
  end
end
