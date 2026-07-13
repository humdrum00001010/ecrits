defmodule Ecrits.EditorToolbar do
  @moduledoc "Embedded state model for the active document toolbar."

  use Ecto.Schema

  import Ecto.Changeset

  alias __MODULE__.Transition

  @primary_key false
  @toggle_commands ~w(bold italic underline strikethrough)
  @alignment_commands ~w(align-left align-center align-right align-justify)
  @commands @toggle_commands ++ @alignment_commands
  @alignments ~w(left center right justify)
  @max_image_base64_bytes 28_000_000

  embedded_schema do
    field :document_id, :string
    field :bold, :boolean, default: false
    field :italic, :boolean, default: false
    field :underline, :boolean, default: false
    field :strikethrough, :boolean, default: false
    field :alignment, :string, default: "left"
    field :font_size_pt, :float
    field :text_color, :string, default: "#e11d48"
    field :highlight_color, :string, default: "#fde047"
  end

  @type t :: %__MODULE__{}

  def new(attrs \\ %{}), do: apply_attrs(%__MODULE__{}, attrs)

  def changeset(%__MODULE__{} = toolbar, attrs) when is_map(attrs) do
    toolbar
    |> cast(attrs, [
      :document_id,
      :bold,
      :italic,
      :underline,
      :strikethrough,
      :alignment,
      :font_size_pt,
      :text_color,
      :highlight_color
    ])
    |> validate_length(:document_id, max: 500)
    |> validate_inclusion(:alignment, @alignments)
    |> validate_number(:font_size_pt, greater_than: 0, less_than_or_equal_to: 400)
    |> validate_format(:text_color, ~r/\A#[0-9a-f]{3}([0-9a-f]{3})?\z/i)
    |> validate_format(:highlight_color, ~r/\A#[0-9a-f]{3}([0-9a-f]{3})?\z/i)
  end

  def command_changeset(command) do
    {%{}, %{command: :string}}
    |> cast(%{command: command}, [:command])
    |> validate_required([:command])
    |> validate_inclusion(:command, @commands ++ ~w(font-size-set text-color highlight image))
  end

  def font_size_changeset(attrs) do
    {%{}, %{size: :float}}
    |> cast(attrs, [:size])
    |> validate_required([:size])
    |> validate_number(:size, greater_than: 0, less_than_or_equal_to: 400)
  end

  def color_changeset(attrs) do
    {%{}, %{color: :string}}
    |> cast(attrs, [:color])
    |> validate_required([:color])
    |> validate_format(:color, ~r/\A#[0-9a-f]{3}([0-9a-f]{3})?\z/i)
  end

  def image_changeset(attrs) do
    {%{},
     %{
       image_base64: :string,
       mime_type: :string,
       file_name: :string,
       extension: :string,
       natural_width_px: :integer,
       natural_height_px: :integer
     }}
    |> cast(attrs, [
      :image_base64,
      :mime_type,
      :file_name,
      :extension,
      :natural_width_px,
      :natural_height_px
    ])
    |> validate_required([:image_base64, :mime_type, :natural_width_px, :natural_height_px])
    |> validate_length(:image_base64, max: @max_image_base64_bytes)
    |> validate_format(:mime_type, ~r/\Aimage\/[a-z0-9.+-]+\z/i)
    |> validate_length(:file_name, max: 255)
    |> validate_format(:file_name, ~r/\A[^\\\/]+\z/)
    |> validate_length(:extension, max: 12)
    |> validate_format(:extension, ~r/\A[a-zA-Z0-9]+\z/)
    |> validate_number(:natural_width_px, greater_than: 0)
    |> validate_number(:natural_height_px, greater_than: 0)
  end

  def identity_changeset(document_id, format) do
    {%{}, %{document_id: :string, format: :string}}
    |> cast(%{document_id: document_id, format: format}, [:document_id, :format])
    |> validate_required([:document_id])
    |> validate_length(:document_id, max: 500)
    |> validate_length(:format, max: 20)
  end

  def shortcut_changeset(attrs) do
    {%{},
     %{
       meta_key: :boolean,
       ctrl_key: :boolean,
       shift_key: :boolean,
       alt_key: :boolean,
       key: :string
     }}
    |> cast(attrs, [:meta_key, :ctrl_key, :shift_key, :alt_key, :key])
  end

  defdelegate reset(toolbar), to: Transition
  defdelegate put_engine_state(toolbar, attrs, active_document_id), to: Transition
  defdelegate command(toolbar, command, attrs, document), to: Transition
  defdelegate shortcut_command(attrs), to: Transition

  defp apply_attrs(toolbar, attrs) do
    changeset = changeset(toolbar, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: toolbar
  end
end
