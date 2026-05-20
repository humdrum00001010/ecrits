defmodule Contract.ContractTypes.DocumentType do
  @moduledoc """
  Admin-managed document type row.

  Documents belong to one document type via `documents.document_type_id`.
  Standard-contract defaults, including the RHWP matching book, live here
  because they are shared by every document of that type.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "document_types" do
    field :key, :string
    field :family, :string, default: "other"
    field :name_en, :string
    field :name_ko, :string
    field :version, :string, default: "legacy"
    field :source, :string, default: "custom"
    field :source_url, :string
    field :template_hwp_path, :string
    field :template_hwpx_path, :string
    field :spec, :map, default: %{}
    field :default_matching_book, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(document_type, attrs) do
    document_type
    |> cast(attrs, [
      :key,
      :family,
      :name_en,
      :name_ko,
      :version,
      :source,
      :source_url,
      :template_hwp_path,
      :template_hwpx_path,
      :spec,
      :default_matching_book
    ])
    |> validate_required([:key, :family, :name_en, :version, :source])
    |> validate_length(:key, min: 1, max: 120)
    |> validate_length(:name_en, min: 1, max: 300)
    |> unique_constraint(:key)
  end
end
