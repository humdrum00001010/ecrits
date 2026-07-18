defmodule Ecrits.Test.FailingEditEhwpRuntime do
  @moduledoc false

  defdelegate open(path_or_binary, opts), to: Ehwp.Runtime

  def apply_op(_handle, _ops, _bins),
    do: {:error, {0, :forced_apply_failure, "forced apply failure"}}

  defdelegate query(handle, query), to: Ehwp.Runtime
  defdelegate export(handle, format), to: Ehwp.Runtime
  defdelegate close(handle), to: Ehwp.Runtime
end
