defmodule Ecrits.EditorSurfaceState do
  @moduledoc "Embedded transmission model for the local document editor surface."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.DocumentElementPicker
  alias Ecrits.DocumentSearch
  alias Ecrits.EditorToolbar
  alias Ecrits.MarkdownEditorState
  alias Ecrits.WorkspaceLayout
  alias __MODULE__.Document
  alias __MODULE__.DocumentSpec
  alias __MODULE__.DocumentTab
  alias __MODULE__.DocumentViewport
  alias __MODULE__.Transition

  @primary_key false
  @scalar_fields [
    :document_path,
    :document_loading?,
    :canvas_id,
    :hwp_bytes_url,
    :save_state,
    :active_document_id,
    :dirty_document_ids,
    :hwp_page_count,
    :markdown_preview_html
  ]

  embedded_schema do
    embeds_one :document, __MODULE__.Document, on_replace: :delete
    field :document_path, :string
    embeds_one :document_viewport, __MODULE__.DocumentViewport, on_replace: :delete
    field :document_loading?, :boolean, default: false
    embeds_one :document_spec, __MODULE__.DocumentSpec, on_replace: :delete
    field :canvas_id, :string
    field :hwp_bytes_url, :string
    field :save_state, :string
    embeds_many :open_documents, __MODULE__.DocumentTab, on_replace: :delete
    field :active_document_id, :string
    field :dirty_document_ids, {:array, :string}, default: []
    field :hwp_page_count, :integer, default: 0
    # Markdown preview rendering is already sanitized and wrapped as
    # `Phoenix.HTML.safe()`. Keep that value intact across the embedded UI
    # state boundary instead of rejecting the safe tuple as a string and
    # silently falling back to an empty EditorSurfaceState.
    field :markdown_preview_html, :any, virtual: true, default: ""

    embeds_one :document_element_picker, Ecrits.DocumentElementPicker, on_replace: :delete

    embeds_one :editor_toolbar, Ecrits.EditorToolbar, on_replace: :delete
    embeds_one :document_search, Ecrits.DocumentSearch, on_replace: :delete
    embeds_one :markdown_editor, Ecrits.MarkdownEditorState, on_replace: :delete
    embeds_one :workspace_layout, Ecrits.WorkspaceLayout, on_replace: :delete
  end

  @type t :: %__MODULE__{}

  def new(attrs \\ %{}), do: apply_attrs(%__MODULE__{}, attrs)

  def changeset(%__MODULE__{} = state, attrs) when is_map(attrs) do
    attrs = relation_params(attrs)

    state
    |> cast(attrs, @scalar_fields)
    |> update_change(:hwp_page_count, &max(&1, 0))
    |> validate_number(:hwp_page_count, greater_than_or_equal_to: 0)
    |> validate_length(:document_path, max: 4_096)
    |> validate_length(:canvas_id, max: 4_096)
    |> validate_length(:hwp_bytes_url, max: 4_096)
    |> validate_length(:save_state, max: 4_096)
    |> validate_length(:active_document_id, max: 4_096)
    |> cast_embed(:document, with: &Document.changeset/2)
    |> cast_embed(:document_viewport, with: &DocumentViewport.changeset/2)
    |> cast_embed(:document_spec, with: &DocumentSpec.changeset/2)
    |> cast_embed(:open_documents, with: &DocumentTab.changeset/2)
    |> cast_embed(:document_element_picker, with: &DocumentElementPicker.changeset/2)
    |> cast_embed(:editor_toolbar, with: &EditorToolbar.changeset/2)
    |> cast_embed(:document_search, with: &DocumentSearch.changeset/2)
    |> cast_embed(:markdown_editor, with: &MarkdownEditorState.changeset/2)
    |> cast_embed(:workspace_layout, with: &WorkspaceLayout.changeset/2)
    |> put_derived_document_path()
  end

  def apply_attrs(%__MODULE__{} = state, attrs) do
    changeset = changeset(state, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: state
  end

  defdelegate replace(state, attrs), to: Transition

  defp put_derived_document_path(changeset) do
    case get_field(changeset, :document_path) do
      path when is_binary(path) and path != "" ->
        changeset

      _other ->
        case get_field(changeset, :document) do
          %{relative_path: path} when is_binary(path) ->
            put_change(changeset, :document_path, path)

          _document ->
            changeset
        end
    end
  end

  defp relation_params(attrs) do
    attrs
    |> deep_params()
    |> default_embed(:document_element_picker, %{})
    |> default_embed(:editor_toolbar, %{})
    |> default_embed(:document_search, %{})
    |> default_embed(:markdown_editor, %{})
    |> default_embed(:workspace_layout, %{})
  end

  defp default_embed(attrs, key, default) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> attrs
      Map.has_key?(attrs, string_key) -> attrs
      Enum.all?(Map.keys(attrs), &is_binary/1) -> Map.put(attrs, string_key, default)
      true -> Map.put(attrs, key, default)
    end
  end

  defp deep_params(%MapSet{} = values), do: MapSet.to_list(values)

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
