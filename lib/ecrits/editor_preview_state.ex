defmodule Ecrits.EditorPreviewState do
  @moduledoc "Embedded transmission model for an editor preview card."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.DocumentCanvasState
  alias Ecrits.EditorSurfaceState.Document

  @primary_key false
  @statuses [:running, :sent, :failed, :cancelled, :committed]

  embedded_schema do
    embeds_one :document, Document, on_replace: :delete
    field :document_path, :string
    field :canvas_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :running
    embeds_one :canvas, DocumentCanvasState, on_replace: :delete
  end

  def new(attrs \\ %{}) do
    state = %__MODULE__{}
    changeset = changeset(state, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: state
  end

  def encode(%__MODULE__{} = state) do
    Jason.encode!(%{
      documentId: state.document.id,
      documentPath: state.document_path,
      deltaCount: state.canvas.preview_delta_count,
      revisionCount: state.canvas.preview_revision_count,
      status: state.status,
      mode: "embedded-editor"
    })
  end

  def changeset(%__MODULE__{} = state, attrs) when is_map(attrs) do
    attrs = deep_params(attrs)

    state
    |> cast(attrs, [:document_path, :canvas_id, :status])
    |> cast_embed(:document, with: &Document.changeset/2, required: true)
    |> cast_embed(:canvas, with: &DocumentCanvasState.changeset/2, required: true)
    |> validate_required([:canvas_id])
    |> validate_length(:document_path, max: 4_096)
    |> validate_length(:canvas_id, max: 500)
    |> put_derived_document_path()
  end

  defp put_derived_document_path(changeset) do
    case get_field(changeset, :document_path) do
      path when is_binary(path) and path != "" ->
        changeset

      _path ->
        case get_field(changeset, :document) do
          %{relative_path: path} when is_binary(path) ->
            put_change(changeset, :document_path, path)

          _document ->
            changeset
        end
    end
  end

  defp deep_params(%_module{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.delete(:__meta__)
    |> deep_params()
  end

  defp deep_params(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, deep_params(value)} end)
  end

  defp deep_params(list) when is_list(list), do: Enum.map(list, &deep_params/1)
  defp deep_params(value), do: value
end
