defmodule Contract.Repo.Migrations.CreateSlackTokens do
  use Ecto.Migration

  @moduledoc """
  Wave 6: per-user Slack OAuth tokens for the Slack-hosted MCP outbound
  surface. The `access_token` column stores the ciphertext produced by
  `Plug.Crypto.encrypt/4` keyed by the endpoint's `secret_key_base` plus a
  fixed salt (see `Contract.Integrations.Slack`). Plaintext xoxp-tokens
  never touch the column.

  Uniqueness is on `(user_id, slack_team_id)` — a user may install the
  integration against multiple Slack workspaces, but only one row per
  (user, team) pair. Re-installing the same team overwrites.
  """

  def change do
    create table(:slack_tokens, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false)
      add(:tenant_id, :binary_id, null: true)
      add(:slack_team_id, :string, null: false)
      add(:slack_user_id, :string, null: false)
      add(:access_token, :binary, null: false)
      add(:scopes, {:array, :string}, null: false, default: [])
      add(:expires_at, :utc_datetime, null: true)
      add(:raw_response, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create(index(:slack_tokens, [:user_id]))
    create(unique_index(:slack_tokens, [:user_id, :slack_team_id]))
  end
end
