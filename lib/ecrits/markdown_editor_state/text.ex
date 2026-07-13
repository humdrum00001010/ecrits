defmodule Ecrits.MarkdownEditorState.Text do
  @moduledoc false

  def utf16_length(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> Enum.reduce(0, fn codepoint, length ->
      length + if(codepoint > 0xFFFF, do: 2, else: 1)
    end)
  end

  def slice_utf16(value, start, length)
      when is_binary(value) and is_integer(start) and is_integer(length) do
    start_byte = utf16_byte_offset(value, max(start, 0))
    stop_byte = utf16_byte_offset(value, max(start + length, 0))
    binary_part(value, start_byte, max(stop_byte - start_byte, 0))
  end

  defp utf16_byte_offset(value, target) do
    value
    |> String.to_charlist()
    |> Enum.reduce_while({0, 0}, fn codepoint, {units, bytes} ->
      next_units = units + if(codepoint > 0xFFFF, do: 2, else: 1)

      if next_units > target do
        {:halt, {units, bytes}}
      else
        {:cont, {next_units, bytes + byte_size(<<codepoint::utf8>>)}}
      end
    end)
    |> elem(1)
  end
end
