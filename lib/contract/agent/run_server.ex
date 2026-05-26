defmodule Contract.Agent.RunServer do
  @moduledoc """
  Stale compatibility namespace for the retired per-run runtime.

  Agent runtime ownership now lives in `Contract.Agent.Document`, one
  process per `{user_id, document_id}` scope. This module intentionally
  keeps only explicit stale API failures and lookup shims for older call
  sites that still need to find the document runtime during migration.
  """

  use GenServer
  require Logger

  def child_spec(args) do
    %{
      id: {__MODULE__, args[:run_id]},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(args) do
    _ = Keyword.fetch!(args, :run_id)
    {:error, stale_runtime_entrypoint()}
  end

  @impl true
  def init(_args), do: {:stop, stale_runtime_entrypoint()}

  @spec via(Ecto.UUID.t()) :: {:via, Registry, {atom(), Ecto.UUID.t()}}
  def via(run_id), do: {:via, Registry, {Contract.Agent.Document.RunRegistry, run_id}}

  def whereis(run_id) do
    Logger.warning(
      "Contract.Agent.RunServer.whereis/1 is stale for #{inspect(run_id)}; " <>
        "use Contract.Agent.Document.whereis/1"
    )

    Contract.Agent.Document.whereis(run_id)
  end

  @doc """
  Returns the active `{run_id, pid}` for the `(user_id, document_id)` scope,
  or `nil` if no run is active.
  """
  @spec whereis_for_scope(binary() | nil, binary() | nil) :: {binary(), pid()} | nil
  def whereis_for_scope(user_id, document_id)
      when is_binary(user_id) and is_binary(document_id) do
    Logger.warning(
      "Contract.Agent.RunServer.whereis_for_scope/2 is stale for " <>
        "#{inspect({user_id, document_id})}; use Contract.Agent.Document.whereis_for_scope/2"
    )

    Contract.Agent.Document.whereis_for_scope(user_id, document_id)
  end

  def whereis_for_scope(_user_id, _document_id), do: nil

  def get_run(_run_id), do: {:error, stale_runtime_entrypoint()}

  def cancel(_run_id), do: {:error, stale_runtime_entrypoint()}

  defp stale_runtime_entrypoint do
    {:stale_runtime_entrypoint, __MODULE__, Contract.Agent.Document}
  end
end
