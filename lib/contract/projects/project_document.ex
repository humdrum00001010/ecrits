defmodule Contract.Projects.ProjectDocument do
  @moduledoc """
  Join row linking a project to a document.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Contract.Documents.Document
  alias Contract.Projects.Project

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "project_documents" do
    belongs_to :project, Project
    belongs_to :document, Document

    field :role, :string, default: "primary"
    field :status, :string, default: "active"
    field :required, :boolean, default: true
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @castable [:role, :status, :required, :metadata]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(project_document, attrs) do
    project_document
    |> cast(attrs, @castable)
    |> validate_required([:project_id, :document_id, :role, :status, :required])
    |> validate_length(:role, min: 1, max: 80)
    |> validate_length(:status, min: 1, max: 80)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:document_id)
    |> unique_constraint([:project_id, :document_id],
      name: :project_documents_project_id_document_id_index
    )
  end
end
