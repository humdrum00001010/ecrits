defmodule Contract.Agent.DocumentSupervisor do
  @moduledoc """
  DynamicSupervisor for document-scoped agent runtimes.
  """

  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_document(args) do
    DynamicSupervisor.start_child(__MODULE__, {Contract.Agent.Document, args})
  end
end
