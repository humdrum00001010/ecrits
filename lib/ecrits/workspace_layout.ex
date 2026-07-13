defmodule Ecrits.WorkspaceLayout do
  @moduledoc "Embedded state model for the workspace layout."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.WorkspaceLayout.Resize
  alias __MODULE__.Transition

  @primary_key false
  @file_tree_min 220
  @file_tree_max 520
  @chat_min 280
  @chat_max 720

  embedded_schema do
    field :file_tree_width, :integer, default: 260
    field :chat_rail_width, :integer, default: 340
    field :file_tree_collapsed?, :boolean, default: false
    field :editor_fullscreen?, :boolean, default: false
    embeds_one :drag, Resize, on_replace: :delete
  end

  @type t :: %__MODULE__{}

  def new(attrs \\ %{}), do: apply_attrs(%__MODULE__{}, attrs)

  def changeset(%__MODULE__{} = layout, attrs) when is_map(attrs) do
    layout
    |> cast(attrs, [
      :file_tree_width,
      :chat_rail_width,
      :file_tree_collapsed?,
      :editor_fullscreen?
    ])
    |> update_change(:file_tree_width, &clamp(&1, @file_tree_min, @file_tree_max))
    |> update_change(:chat_rail_width, &clamp(&1, @chat_min, @chat_max))
    |> validate_number(:file_tree_width,
      greater_than_or_equal_to: @file_tree_min,
      less_than_or_equal_to: @file_tree_max
    )
    |> validate_number(:chat_rail_width,
      greater_than_or_equal_to: @chat_min,
      less_than_or_equal_to: @chat_max
    )
  end

  defdelegate toggle_file_tree(layout), to: Transition
  defdelegate toggle_editor_fullscreen(layout), to: Transition
  defdelegate begin_resize(layout, attrs), to: Transition
  defdelegate resize(layout, attrs), to: Transition
  defdelegate finish_resize(layout), to: Transition
  defdelegate file_tree_render_width(layout), to: Transition
  defdelegate grid_style(layout), to: Transition

  def encode(%__MODULE__{} = layout) do
    Jason.encode!(%{
      fileTreeWidth: file_tree_render_width(layout),
      chatRailWidth: layout.chat_rail_width,
      fileTreeCollapsed: layout.file_tree_collapsed?,
      editorFullscreen: layout.editor_fullscreen?
    })
  end

  defp apply_attrs(layout, attrs) do
    changeset = changeset(layout, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: layout
  end

  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)
end
