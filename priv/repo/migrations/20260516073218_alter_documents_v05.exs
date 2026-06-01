defmodule Contract.Repo.Migrations.AlterDocumentsV05 do
  @moduledoc """
  SPEC.md v0.5 §7.1 — add `state_snapshot` and `current_revision` to the
  `documents` table.

  `state_snapshot` is the materialized document state at
  `current_revision`. Both are populated by Session.Reducer once W4 lands.
  Foundation wave leaves both empty / 0 by default.

  matter_id is NOT dropped here — Wave 4 handles the Matter removal.
  """
  use Ecto.Migration

  def change do
    alter table(:documents) do
      add_if_not_exists(:state_snapshot, :map, null: false, default: %{})
      add_if_not_exists(:current_revision, :integer, null: false, default: 0)
    end
  end
end
