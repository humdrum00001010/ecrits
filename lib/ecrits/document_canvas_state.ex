defmodule Ecrits.DocumentCanvasState do
  @moduledoc "Embedded transmission model for a browser document canvas."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.EditorSurfaceState
  alias Ecrits.EditorSurfaceState.DocumentSpec
  alias Ecrits.MarkdownEditorState

  @primary_key false

  embedded_schema do
    field :document_id, :string
    field :document_path, :string
    field :document_format, :string
    field :bytes_url, :string
    field :page_count, :integer, default: 0
    field :scroll_top, :integer, default: 0
    field :scroll_left, :integer, default: 0
    field :mirror?, :boolean, default: false
    field :preview_turn_id, :string
    field :preview_text, :string, default: ""
    field :preview_delta_count, :integer, default: 0
    field :preview_highlights, :string, default: "[]"
    field :preview_steps, :string, default: "[]"
    # The editor surface carries sanitized `Phoenix.HTML.safe()` preview
    # content. This field is render-only and is deliberately omitted from the
    # JSON client payload, so preserve the safe value rather than coercing it.
    field :markdown_preview_html, :any, virtual: true, default: ""
    embeds_one :spec, DocumentSpec, on_replace: :delete
    embeds_one :markdown_editor, MarkdownEditorState, on_replace: :delete
  end

  def new(attrs \\ %{}) do
    state = %__MODULE__{}
    changeset = changeset(state, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: state
  end

  def from_editor_surface(%EditorSurfaceState{} = surface) do
    new(%{
      document_id: surface.document && surface.document.id,
      document_path: surface.document_path,
      document_format: surface.document && surface.document.format,
      bytes_url: surface.hwp_bytes_url,
      page_count: surface.hwp_page_count,
      scroll_top: (surface.document_viewport && surface.document_viewport.scroll_top) || 0,
      scroll_left: (surface.document_viewport && surface.document_viewport.scroll_left) || 0,
      spec: surface.document_spec,
      markdown_editor: surface.markdown_editor,
      markdown_preview_html: surface.markdown_preview_html
    })
  end

  def encode(%__MODULE__{} = state), do: state |> client_payload() |> Jason.encode!()

  def client_payload(%__MODULE__{} = state) do
    document_path = state.document_path || spec_path(state.spec)

    %{
      documentId: state.document_id,
      documentPath: document_path,
      scrollTop: state.scroll_top,
      scrollLeft: state.scroll_left,
      documentName: spec_name(state.spec, document_path),
      contractTypeKey: state.spec && state.spec.key,
      localDocumentId: state.document_id,
      localDocumentFormat: state.document_format,
      bytesUrl: state.bytes_url,
      editorMirror: state.mirror?,
      previewTurnId: state.preview_turn_id,
      previewText: state.preview_text,
      previewDeltaCount: state.preview_delta_count,
      previewHighlights: state.preview_highlights,
      previewSteps: state.preview_steps,
      markdownEditor: markdown_editor_payload(state.markdown_editor)
    }
  end

  def changeset(%__MODULE__{} = state, attrs) when is_map(attrs) do
    attrs = relation_params(attrs)

    state
    |> cast(attrs, [
      :document_id,
      :document_path,
      :document_format,
      :bytes_url,
      :page_count,
      :scroll_top,
      :scroll_left,
      :mirror?,
      :preview_turn_id,
      :preview_text,
      :preview_delta_count,
      :preview_highlights,
      :preview_steps,
      :markdown_preview_html
    ])
    |> cast_embed(:spec, with: &DocumentSpec.changeset/2)
    |> cast_embed(:markdown_editor, with: &MarkdownEditorState.changeset/2)
    |> validate_required([:document_id, :document_format])
    |> validate_length(:document_id, max: 500)
    |> validate_length(:document_path, max: 4_096)
    |> validate_length(:document_format, max: 20)
    |> validate_length(:bytes_url, max: 8_192)
    |> validate_length(:preview_turn_id, max: 500)
    |> validate_number(:page_count, greater_than_or_equal_to: 0)
    |> validate_number(:scroll_top, greater_than_or_equal_to: 0)
    |> validate_number(:scroll_left, greater_than_or_equal_to: 0)
    |> validate_number(:preview_delta_count, greater_than_or_equal_to: 0)
  end

  defp relation_params(attrs) do
    attrs
    |> deep_params()
    |> default_embed(:markdown_editor, %{})
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

  defp spec_path(%{template_hwp_path: path}) when is_binary(path) and path != "", do: path
  defp spec_path(%{template_hwpx_path: path}) when is_binary(path) and path != "", do: path
  defp spec_path(_spec), do: nil

  defp spec_name(%{name: name}, _path) when is_binary(name) and name != "", do: name
  defp spec_name(_spec, path) when is_binary(path), do: Path.basename(path)
  defp spec_name(_spec, _path), do: "document"

  defp markdown_editor_payload(%MarkdownEditorState{} = editor) do
    %{
      selectionStart: editor.selection_start,
      selectionEnd: editor.selection_end,
      view: editor.view
    }
  end

  defp markdown_editor_payload(_editor), do: nil
end
