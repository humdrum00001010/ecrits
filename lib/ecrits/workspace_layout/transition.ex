defmodule Ecrits.WorkspaceLayout.Transition do
  @moduledoc false

  import Ecto.Changeset

  alias Ecrits.WorkspaceLayout
  alias Ecrits.WorkspaceLayout.Resize

  @file_tree_collapsed 40
  @file_tree_min 220
  @file_tree_max 520
  @chat_min 280
  @chat_max 720
  @editor_min 360

  def toggle_file_tree(%WorkspaceLayout{} = layout) do
    layout
    |> transition(%{file_tree_collapsed?: not layout.file_tree_collapsed?})
    |> finish_resize()
  end

  def toggle_editor_fullscreen(%WorkspaceLayout{} = layout) do
    transition(layout, %{editor_fullscreen?: not layout.editor_fullscreen?})
  end

  def begin_resize(%WorkspaceLayout{} = layout, attrs) when is_map(attrs) do
    panel = Resize.param(attrs, :panel)

    start_width =
      case panel do
        value when value in [:file_tree, "file_tree"] ->
          Resize.boundary_width(
            Resize.param(attrs, :panel_width),
            layout.file_tree_width,
            @file_tree_min,
            @file_tree_max
          )

        value when value in [:chat_rail, "chat_rail"] ->
          Resize.boundary_width(
            Resize.param(attrs, :panel_width),
            layout.chat_rail_width,
            @chat_min,
            @chat_max
          )

        _ ->
          nil
      end

    case Resize.build(%{
           panel: panel,
           start_x: Resize.param(attrs, :x),
           start_width: start_width,
           viewport_width: Resize.param(attrs, :viewport_width)
         }) do
      {:ok, drag} -> put_drag(layout, drag)
      :error -> layout
    end
  end

  def begin_resize(%WorkspaceLayout{} = layout, _attrs), do: layout
  def resize(%WorkspaceLayout{drag: nil} = layout, _attrs), do: layout

  def resize(%WorkspaceLayout{drag: %Resize{} = drag} = layout, attrs) when is_map(attrs) do
    case Resize.measurement(attrs, drag.viewport_width) do
      {:ok, x, viewport_width} -> resize_to(layout, drag, x, viewport_width)
      :error -> layout
    end
  end

  def resize(%WorkspaceLayout{} = layout, _attrs), do: layout
  def finish_resize(%WorkspaceLayout{} = layout), do: put_drag(layout, nil)

  def file_tree_render_width(%WorkspaceLayout{file_tree_collapsed?: true}),
    do: @file_tree_collapsed

  def file_tree_render_width(%WorkspaceLayout{file_tree_width: width}), do: width

  def grid_style(%WorkspaceLayout{} = layout) do
    "--workspace-file-tree-width: #{file_tree_render_width(layout)}px; " <>
      "--workspace-chat-rail-width: #{layout.chat_rail_width}px; " <>
      "--workspace-editor-z: 0; --workspace-agent-rail-z: 30"
  end

  defp resize_to(layout, %Resize{panel: :file_tree} = drag, x, viewport_width) do
    max_width =
      max(
        @file_tree_min,
        min(@file_tree_max, viewport_width - layout.chat_rail_width - @editor_min)
      )

    layout
    |> transition(%{
      file_tree_width: clamp(drag.start_width + x - drag.start_x, @file_tree_min, max_width)
    })
    |> put_drag(%{drag | viewport_width: viewport_width})
  end

  defp resize_to(layout, %Resize{panel: :chat_rail} = drag, x, viewport_width) do
    max_width =
      max(
        @chat_min,
        min(@chat_max, viewport_width - file_tree_render_width(layout) - @editor_min)
      )

    layout
    |> transition(%{
      chat_rail_width: clamp(drag.start_width - (x - drag.start_x), @chat_min, max_width)
    })
    |> put_drag(%{drag | viewport_width: viewport_width})
  end

  defp transition(layout, attrs) do
    changeset = WorkspaceLayout.changeset(layout, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: layout
  end

  defp put_drag(layout, drag) do
    layout
    |> change()
    |> put_embed(:drag, drag)
    |> apply_changes()
  end

  defp clamp(value, minimum, maximum), do: value |> max(minimum) |> min(maximum)
end
