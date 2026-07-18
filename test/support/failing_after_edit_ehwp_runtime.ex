defmodule Ecrits.Test.FailingAfterEditEhwpRuntime do
  @moduledoc false

  @table __MODULE__

  def reset(fail_at) when is_integer(fail_at) and fail_at > 0 do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :public, :set])
      _table -> :ets.delete_all_objects(@table)
    end

    :ets.insert(@table, [{:count, 0}, {:fail_at, fail_at}])
    :ok
  end

  def apply_op(handle, ops, bins) do
    count = :ets.update_counter(@table, :count, {2, 1}, {:count, 0})
    fail_at = :ets.lookup_element(@table, :fail_at, 2)

    if count == fail_at do
      {:error, {0, :forced_later_apply_failure, "forced later apply failure"}}
    else
      Ehwp.Runtime.apply_op(handle, ops, bins)
    end
  end

  defdelegate query(handle, query), to: Ehwp.Runtime
  defdelegate export(handle, format), to: Ehwp.Runtime
  defdelegate close(handle), to: Ehwp.Runtime
end
