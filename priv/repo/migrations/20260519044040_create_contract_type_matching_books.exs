defmodule Contract.Repo.Migrations.CreateContractTypeMatchingBooks do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:contract_type_matching_books, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:type_key, :string, null: false)
      add(:matching_book, :map, null: false, default: %{})

      timestamps(type: :utc_datetime)
    end

    create_if_not_exists(unique_index(:contract_type_matching_books, [:type_key]))
  end
end
