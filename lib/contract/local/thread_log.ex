defmodule Contract.Local.ThreadLog do
  @moduledoc """
  Append-only thread event log in `.contract/threads`.
  """

  alias Contract.Local.Metadata

  @doc """
  Append one thread event.
  """
  @spec append(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def append(root, thread_id, event) when is_binary(thread_id) and is_map(event) do
    Metadata.append_jsonl(root, thread_path(thread_id), Map.put(event, "thread_id", thread_id))
  end

  @doc """
  Read thread events.
  """
  @spec list(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list(root, thread_id) when is_binary(thread_id) do
    Metadata.read_jsonl(root, thread_path(thread_id))
  end

  defp thread_path(thread_id) do
    Path.join("threads", "#{thread_id}.jsonl")
  end
end
