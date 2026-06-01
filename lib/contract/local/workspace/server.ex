defmodule Contract.Local.Workspace.Server do
  @moduledoc """
  Supervised holder for one local workspace.
  """

  use GenServer

  alias Contract.Local.Workspace

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec workspace(GenServer.server()) :: Workspace.t()
  def workspace(server \\ __MODULE__) do
    GenServer.call(server, :workspace)
  end

  @spec root(GenServer.server()) :: String.t()
  def root(server \\ __MODULE__) do
    GenServer.call(server, :root)
  end

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :root) do
      {:ok, root} ->
        case Workspace.init(root) do
          {:ok, workspace} -> {:ok, workspace}
          {:error, reason} -> {:stop, reason}
        end

      :error ->
        {:stop, :missing_root}
    end
  end

  @impl true
  def handle_call(:workspace, _from, workspace) do
    {:reply, workspace, workspace}
  end

  def handle_call(:root, _from, %Workspace{root: root} = workspace) do
    {:reply, root, workspace}
  end
end
