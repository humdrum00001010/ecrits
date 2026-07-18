defmodule Ecrits.Test.FailingRollbackEhwpRuntime do
  @moduledoc false

  alias Ecrits.Test.FakeEhwpRuntime

  @table __MODULE__

  def reset do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _table -> :ets.delete_all_objects(@table)
    end

    :ets.insert(@table, open_count: 0, fail_reopen?: true, fail_export?: true)
    :ok
  end

  def allow_reopen do
    :ets.insert(@table, fail_reopen?: false, fail_export?: false)
    :ok
  end

  def open_count, do: :ets.lookup_element(@table, :open_count, 2)

  def available?, do: true

  def open(path_or_binary, opts) when is_binary(path_or_binary) do
    count = :ets.update_counter(@table, :open_count, {2, 1}, {:open_count, 0})

    if count > 1 and :ets.lookup_element(@table, :fail_reopen?, 2) do
      {:error, :forced_rollback_open_failure}
    else
      opts =
        if File.regular?(path_or_binary) do
          Keyword.put(opts, :__text__, File.read!(path_or_binary))
        else
          opts
        end

      FakeEhwpRuntime.open(path_or_binary, opts)
    end
  end

  def open(other, opts), do: FakeEhwpRuntime.open(other, opts)

  def export(handle, format) do
    if :ets.lookup_element(@table, :fail_export?, 2),
      do: {:error, :forced_save_export_failure},
      else: FakeEhwpRuntime.export(handle, format)
  end

  defdelegate page_count(handle), to: FakeEhwpRuntime
  defdelegate profile(handle), to: FakeEhwpRuntime
  defdelegate render_page_svg(handle, page_index), to: FakeEhwpRuntime
  defdelegate read(handle, opts), to: FakeEhwpRuntime
  defdelegate find(handle, pattern, opts), to: FakeEhwpRuntime
  defdelegate write(handle, op, opts), to: FakeEhwpRuntime
  defdelegate new(opts), to: FakeEhwpRuntime
  defdelegate apply_op(handle, ops, bins), to: FakeEhwpRuntime
  defdelegate query(handle, query), to: FakeEhwpRuntime
  defdelegate close(handle), to: FakeEhwpRuntime
end
