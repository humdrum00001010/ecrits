defmodule Contract.Projects.Project do
  @moduledoc """
  Project container above documents.

  Documents remain the primary truth. A project owns metadata and links to
  documents through `project_documents`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Projects.ProjectDocument

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "contract_projects" do
    field :owner_id, :binary_id
    field :title, :string
    field :counterparty, :string
    field :status, :string, default: "active"
    field :metadata, :map, default: %{}

    has_many :project_documents, ProjectDocument, foreign_key: :project_id
    has_many :documents, through: [:project_documents, :document]

    timestamps(type: :utc_datetime)
  end

  @castable [:title, :counterparty, :status, :metadata]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, @castable)
    |> validate_required([:owner_id, :title, :status])
    |> validate_length(:title, min: 1, max: 300)
    |> validate_length(:counterparty, max: 300)
    |> validate_length(:status, min: 1, max: 80)
  end
end
