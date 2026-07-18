defmodule Ecrits.Test.FileEhwpRuntime do
  @moduledoc false

  alias Ecrits.Test.FakeEhwpRuntime

  def available?, do: true

  def open(path, opts) when is_binary(path) do
    if File.regular?(path) do
      text = File.read!(path)

      ref =
        Application.get_env(
          :ecrits,
          :file_ehwp_runtime_ref,
          "hwp:s0/p77/tbl0/cell3/cp3/c0+18"
        )

      elements =
        case Application.get_env(:ecrits, :file_ehwp_runtime_elements) do
          [_ | _] = elements ->
            elements

          _default ->
            [
              %{
                "type" => "paragraph",
                "text" => text,
                "ref" => ref
              }
            ]
        end

      FakeEhwpRuntime.open(path, Keyword.merge(opts, __text__: text, __elements__: elements))
    else
      FakeEhwpRuntime.open(path, opts)
    end
  end

  def open(other, opts), do: FakeEhwpRuntime.open(other, opts)
  defdelegate page_count(handle), to: FakeEhwpRuntime
  defdelegate profile(handle), to: FakeEhwpRuntime
  defdelegate render_page_svg(handle, page_index), to: FakeEhwpRuntime
  defdelegate read(handle, opts), to: FakeEhwpRuntime
  defdelegate find(handle, pattern, opts), to: FakeEhwpRuntime
  defdelegate write(handle, op, opts), to: FakeEhwpRuntime
  defdelegate new(opts), to: FakeEhwpRuntime
  defdelegate apply_op(handle, ops, bins), to: FakeEhwpRuntime
  defdelegate query(handle, query), to: FakeEhwpRuntime
  defdelegate export(handle, format), to: FakeEhwpRuntime
  defdelegate close(handle), to: FakeEhwpRuntime
end
