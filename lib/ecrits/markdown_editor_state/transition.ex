defmodule Ecrits.MarkdownEditorState.Transition do
  @moduledoc false

  import Ecto.Changeset

  alias Ecrits.MarkdownEditorState
  alias Ecrits.MarkdownEditorState.Text

  @views [:preview, :source]

  def load(%MarkdownEditorState{} = state, document_id, source) do
    transition(
      state,
      %{
        document_id: document_id,
        source: source,
        dirty?: false,
        selection_start: 0,
        selection_end: 0,
        view: :preview
      },
      require: [:document_id, :source]
    )
  end

  def put_source(%MarkdownEditorState{} = state, source, dirty?) do
    transition(state, %{source: source, dirty?: state.dirty? or dirty? == true})
  end

  def put_selection(%MarkdownEditorState{} = state, attrs) when is_map(attrs) do
    case MarkdownEditorState.selection(attrs, state.selection_start, state.selection_end) do
      {:ok, selection} -> transition(state, selection)
      :error -> state
    end
  end

  def put_selection(%MarkdownEditorState{} = state, _attrs), do: state

  def toggle_view(%MarkdownEditorState{} = state) do
    next = if state.view == :preview, do: :source, else: :preview
    transition(state, %{view: next})
  end

  def view?(%MarkdownEditorState{view: view}, view) when view in @views, do: true
  def view?(%MarkdownEditorState{}, _view), do: false

  def apply_toolbar_command(%MarkdownEditorState{} = state, command) do
    case command do
      "bold" -> toggle_wrap(state, "**", "**", "bold")
      "italic" -> toggle_wrap(state, "*", "*", "italic")
      "strikethrough" -> toggle_wrap(state, "~~", "~~", "strikethrough")
      _ -> state
    end
  end

  def mark_saved(%MarkdownEditorState{} = state), do: transition(state, %{dirty?: false})

  defp toggle_wrap(state, prefix, suffix, fallback) do
    start = state.selection_start
    stop = state.selection_end
    selected = Text.slice_utf16(state.source, start, stop - start)
    selected = if selected == "", do: fallback, else: selected

    cond do
      String.starts_with?(selected, prefix) and String.ends_with?(selected, suffix) and
          Text.utf16_length(selected) >=
            Text.utf16_length(prefix) + Text.utf16_length(suffix) ->
        inner =
          Text.slice_utf16(
            selected,
            Text.utf16_length(prefix),
            Text.utf16_length(selected) - Text.utf16_length(prefix) -
              Text.utf16_length(suffix)
          )

        replace_range(state, start, stop, inner, start, start + Text.utf16_length(inner))

      start >= Text.utf16_length(prefix) and
        Text.slice_utf16(
          state.source,
          start - Text.utf16_length(prefix),
          Text.utf16_length(prefix)
        ) ==
          prefix and
          Text.slice_utf16(state.source, stop, Text.utf16_length(suffix)) == suffix ->
        next_start = start - Text.utf16_length(prefix)

        replace_range(
          state,
          next_start,
          stop + Text.utf16_length(suffix),
          selected,
          next_start,
          next_start + Text.utf16_length(selected)
        )

      true ->
        text = prefix <> selected <> suffix

        replace_range(
          state,
          start,
          stop,
          text,
          start + Text.utf16_length(prefix),
          start + Text.utf16_length(prefix) + Text.utf16_length(selected)
        )
    end
  end

  defp replace_range(state, start, stop, replacement, selection_start, selection_end) do
    prefix = Text.slice_utf16(state.source, 0, start)

    suffix =
      Text.slice_utf16(
        state.source,
        stop,
        Text.utf16_length(state.source) - stop
      )

    transition(state, %{
      source: prefix <> replacement <> suffix,
      dirty?: true,
      selection_start: selection_start,
      selection_end: selection_end
    })
  end

  defp transition(state, attrs, opts \\ []) do
    changeset = MarkdownEditorState.changeset(state, attrs)
    changeset = validate_required(changeset, Keyword.get(opts, :require, []))
    if changeset.valid?, do: apply_changes(changeset), else: state
  end
end
