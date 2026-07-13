defmodule Ecrits.Agent.WorkspaceDocumentSessionStub do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def read(pid, args), do: GenServer.call(pid, {:read, args})
  def write(pid, args), do: GenServer.call(pid, {:write, args})
  def calls(pid), do: GenServer.call(pid, :calls)

  @impl true
  def init(opts) do
    {:ok,
     %{
       read: Keyword.get(opts, :read, {:ok, %{}}),
       write: Keyword.get(opts, :write, {:ok, %{}}),
       calls: []
     }}
  end

  @impl true
  def handle_call({:read, args}, _from, state) do
    {:reply, state.read, %{state | calls: state.calls ++ [{:read, args}]}}
  end

  def handle_call({:write, args}, _from, state) do
    {:reply, state.write, %{state | calls: state.calls ++ [{:write, args}]}}
  end

  def handle_call(:calls, _from, state) do
    {:reply, state.calls, state}
  end
end
