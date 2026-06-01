defmodule Contract.Repo.Migrations.CreateChatThreads do
  @moduledoc """
  SPEC.md v0.5 §7.2 — ChatThread.

  Foundation wave. No business logic populates this yet; later waves
  attach threads to Documents and persist agent messages.
  """
  use Ecto.Migration

  def change do
    create_if_not_exists table(:chat_threads, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:owner_id, :binary_id, null: false)
      add(:document_id, :binary_id)

      add(:title, :text)
      add(:messages, {:array, :map}, null: false, default: [])
      add(:last_message_at, :utc_datetime)
      add(:status, :string, null: false, default: "active")

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(index(:chat_threads, [:owner_id]))
    create_if_not_exists(index(:chat_threads, [:document_id]))
    create_if_not_exists(index(:chat_threads, [:last_message_at]))
  end
end
