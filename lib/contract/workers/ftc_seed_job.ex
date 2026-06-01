defmodule Contract.Workers.FtcSeedJob do
  @moduledoc """
  Retired FTC DB seed worker kept as a compile stub.
  """

  @system_user_id "00000000-0000-0000-0000-00000000c0de"

  def new(args) when is_map(args), do: %{worker: __MODULE__, args: args}
  def perform(_job), do: {:error, :db_retired}

  @doc "Stable id of the synthetic system user that owns the templates matter."
  @spec system_user_id() :: binary()
  def system_user_id, do: @system_user_id
end
