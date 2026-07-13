defmodule Ecrits.AcpAgent.SessionSupervisor do
  @moduledoc """
  Dynamic supervisor for `Ecrits.AcpAgent.Session` (ex_mcp ACP) sessions.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(args) do
    DynamicSupervisor.start_child(__MODULE__, {Ecrits.AcpAgent.Session, args})
  end
end
