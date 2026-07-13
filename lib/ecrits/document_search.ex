defmodule Ecrits.DocumentSearch do
  @moduledoc "Embedded state model for search in the active document."

  use Ecto.Schema

  import Ecto.Changeset

  alias __MODULE__.Transition

  @primary_key false
  @max_query_length 500
  @actions ~w(search next prev close)

  embedded_schema do
    field :open?, :boolean, default: false
    field :document_id, :string
    field :query, :string, default: ""
    field :total, :integer
    field :index, :integer
  end

  @type t :: %__MODULE__{}

  def new(attrs \\ %{}), do: apply_attrs(%__MODULE__{}, attrs)

  def changeset(%__MODULE__{} = search, attrs) when is_map(attrs) do
    search
    |> cast(attrs, [:open?, :document_id, :query, :total, :index])
    |> validate_length(:document_id, max: 500)
    |> validate_length(:query, max: @max_query_length)
    |> validate_number(:total, greater_than_or_equal_to: 0)
    |> validate_number(:index, greater_than_or_equal_to: 0)
  end

  def result_changeset(attrs) do
    {%{}, %{document_id: :string, query: :string, total: :integer, index: :integer}}
    |> cast(attrs, [:document_id, :query, :total, :index])
    |> validate_required([:document_id, :query])
    |> validate_length(:document_id, max: 500)
    |> validate_length(:query, max: @max_query_length)
    |> validate_number(:total, greater_than_or_equal_to: 0)
    |> validate_number(:index, greater_than_or_equal_to: 0)
  end

  def command_changeset(action, format) do
    {%{}, %{action: :string, format: :string}}
    |> cast(%{action: action, format: format || ""}, [:action, :format])
    |> validate_required([:action])
    |> validate_inclusion(:action, @actions)
  end

  def encode(%__MODULE__{} = search, document) do
    Jason.encode!(%{
      open: search.open?,
      enabled: is_map(document) and document.format not in ["md", "markdown"],
      documentId: document && document.id,
      documentFormat: document && document.format
    })
  end

  defdelegate reset(search), to: Transition
  defdelegate open(search, document_id), to: Transition
  defdelegate put_query(search, query), to: Transition
  defdelegate close(search), to: Transition
  defdelegate put_result(search, attrs), to: Transition
  defdelegate command(search, action, format), to: Transition

  defp apply_attrs(search, attrs) do
    changeset = changeset(search, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: search
  end
end
