defmodule Ecrits.MarkdownEditorState do
  @moduledoc "Embedded state model for the Markdown editor."

  use Ecto.Schema

  import Ecto.Changeset

  alias __MODULE__.Text
  alias __MODULE__.Transition

  @primary_key false
  @views [:preview, :source]
  @max_source_bytes 50_000_000

  embedded_schema do
    field :document_id, :string
    field :source, :string, default: ""
    field :dirty?, :boolean, default: false
    field :selection_start, :integer, default: 0
    field :selection_end, :integer, default: 0
    field :view, Ecto.Enum, values: @views, default: :preview
  end

  @type t :: %__MODULE__{}

  def new(attrs \\ %{}), do: apply_attrs(%__MODULE__{}, attrs)

  def changeset(%__MODULE__{} = state, attrs) when is_map(attrs) do
    state
    |> cast(attrs, [
      :document_id,
      :source,
      :dirty?,
      :selection_start,
      :selection_end,
      :view
    ])
    |> validate_length(:document_id, max: 500)
    |> validate_change(:source, fn :source, source ->
      if byte_size(source) <= @max_source_bytes,
        do: [],
        else: [source: "must be at most #{@max_source_bytes} bytes"]
    end)
    |> validate_number(:selection_start, greater_than_or_equal_to: 0)
    |> validate_number(:selection_end, greater_than_or_equal_to: 0)
    |> normalize_selection()
  end

  def selection(attrs, fallback_start, fallback_end) when is_map(attrs) do
    changeset =
      {%{}, %{start: :integer, end: :integer}}
      |> cast(attrs, [:start, :end])
      |> validate_number(:start, greater_than_or_equal_to: 0)
      |> validate_number(:end, greater_than_or_equal_to: 0)

    if changeset.valid? do
      {:ok,
       %{
         selection_start: get_field(changeset, :start, fallback_start),
         selection_end: get_field(changeset, :end, fallback_end)
       }}
    else
      :error
    end
  end

  defdelegate load(state, document_id, source), to: Transition

  def put_source(state, source, dirty? \\ true),
    do: Transition.put_source(state, source, dirty?)

  defdelegate put_selection(state, attrs), to: Transition
  defdelegate toggle_view(state), to: Transition
  defdelegate view?(state, view), to: Transition
  defdelegate apply_toolbar_command(state, command), to: Transition
  defdelegate mark_saved(state), to: Transition

  defp apply_attrs(state, attrs) do
    changeset = changeset(state, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: state
  end

  defp normalize_selection(changeset) do
    source = get_field(changeset, :source, "")
    limit = Text.utf16_length(source)
    start = get_field(changeset, :selection_start, 0) |> min(limit)
    stop = get_field(changeset, :selection_end, 0) |> min(limit)

    changeset
    |> put_change(:selection_start, min(start, stop))
    |> put_change(:selection_end, max(start, stop))
  end
end
