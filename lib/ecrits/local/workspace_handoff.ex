defmodule Ecrits.Local.WorkspaceHandoff do
  @moduledoc """
  Server-side handoff for the currently selected local workspace.

  The mount screen records the chosen folder under the Phoenix live-session id,
  and `WorkspaceLive` reads it back from `/workspace` without accepting route
  query params as application state.
  """

  use GenServer

  @name __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: @name)
  end

  @spec put_workspace_path(String.t(), String.t()) :: :ok | {:error, term()}
  def put_workspace_path(live_session_id, path)
      when is_binary(live_session_id) and live_session_id != "" and is_binary(path) and path != "" do
    call({:put_workspace_path, live_session_id, Path.expand(path)})
  end

  def put_workspace_path(_live_session_id, _path), do: {:error, :invalid_workspace_handoff}

  @spec fetch_workspace_path(String.t()) :: {:ok, String.t()} | :error | {:error, term()}
  def fetch_workspace_path(live_session_id)
      when is_binary(live_session_id) and live_session_id != "" do
    call({:fetch_workspace_path, live_session_id})
  end

  def fetch_workspace_path(_live_session_id), do: :error

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:put_workspace_path, live_session_id, path}, _from, state) do
    {:reply, :ok, Map.put(state, live_session_id, path)}
  end

  def handle_call({:fetch_workspace_path, live_session_id}, _from, state) do
    {:reply, Map.fetch(state, live_session_id), state}
  end

  defp call(message) do
    case Process.whereis(@name) do
      pid when is_pid(pid) ->
        GenServer.call(pid, message)

      nil ->
        {:error, :workspace_handoff_unavailable}
    end
  end
end
