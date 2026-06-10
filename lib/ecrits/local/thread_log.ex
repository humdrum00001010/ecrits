defmodule Ecrits.Local.ThreadLog do
  @moduledoc """
  Ephemeral thread log compatibility API.
  """

  @doc """
  Append one thread event.
  """
  @spec append(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def append(_root, thread_id, event) when is_binary(thread_id) and is_map(event) do
    _record = Map.put(event, "thread_id", thread_id)
    :ok
  end

  @doc """
  Read thread events.
  """
  @spec list(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(_root, thread_id) when is_binary(thread_id), do: {:ok, []}
end
