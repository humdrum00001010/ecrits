defmodule Contract.Local.Document.Supervisor do
  @moduledoc """
  Dynamic supervisor for active local document sessions.
  """

  use DynamicSupervisor

  alias Contract.Local.Document.Session

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_document(args) when is_list(args) do
    document_id = Keyword.fetch!(args, :id)

    case Session.whereis(document_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        DynamicSupervisor.start_child(__MODULE__, {Session, args})
    end
  end
end
