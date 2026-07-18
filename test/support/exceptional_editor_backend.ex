defmodule Ecrits.Test.ExceptionalEditorBackend do
  @moduledoc false

  @behaviour Ecrits.Doc

  @impl true
  def kind, do: :hwp

  @impl true
  def open(path_or_bytes, opts) when is_binary(path_or_bytes) and is_list(opts) do
    case File.read(path_or_bytes) do
      {:ok, bytes} -> {:ok, new_handle(bytes, path_or_bytes, opts)}
      {:error, :enoent} -> {:ok, new_handle(path_or_bytes, nil, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def new(opts), do: {:ok, new_handle("", nil, opts)}

  @impl true
  def reopen(handle, bytes) when is_binary(bytes) do
    case handle.reopen_failure do
      :raise ->
        raise "injected reopen raise"

      :exit ->
        exit(:injected_reopen_exit)

      :unexpected ->
        {:unexpected_reopen, :injected}

      _other ->
        {:ok,
         new_handle(bytes, handle.path,
           observer: handle.observer,
           close_failure: handle.reopen_close_failure
         )}
    end
  end

  @impl true
  def close(handle) do
    attempt = :atomics.add_get(handle.close_attempts, 1, 1)

    case {handle.close_failure, attempt} do
      {:raise_once_before_close, 1} ->
        notify_close(handle, attempt, :raised_before_disposal)
        raise "injected close raise before disposal"

      {:raise_twice_before_close, attempt} when attempt <= 2 ->
        notify_close(handle, attempt, :raised_before_disposal)
        raise "injected close raise before disposal"

      {:raise_before_close, _attempt} ->
        notify_close(handle, attempt, :raised_before_disposal)
        raise "injected close raise before disposal"

      _other ->
        if Process.alive?(handle.agent), do: Agent.stop(handle.agent)
        notify_close(handle, attempt, :disposed)

        case handle.close_failure do
          :raise -> raise "injected close raise"
          :exit -> exit(:injected_close_exit)
          :unexpected -> {:unexpected_close, :injected}
          _other -> :ok
        end
    end
  end

  @impl true
  def read(handle, _opts), do: {:ok, %{text: text(handle)}}

  @impl true
  def find(_handle, _pattern, _opts), do: {:error, :not_supported}

  @impl true
  def outline(_handle, _ref, _opts), do: {:error, :not_supported}

  @impl true
  def inspect(_handle, _ref), do: {:error, :not_supported}

  @impl true
  def get(_handle, _ref, _props), do: {:error, :not_supported}

  @impl true
  def set(handle, _ref, props) when is_map(props) do
    Agent.update(handle.agent, &(&1 <> "|set:" <> inspect(props)))

    case exceptional_result(handle.edit_failure, :set) do
      :ok -> {:ok, %{invalidated: []}}
      other -> other
    end
  end

  @impl true
  def edit(handle, op) when is_map(op) do
    inserted = Map.get(op, :text, Map.get(op, "text", "EDIT"))
    Agent.update(handle.agent, &(&1 <> inserted))

    failure =
      case handle.edit_failure do
        :exit_on_rejected when inserted == "REJECTED_EXIT" -> :exit
        :exit_on_rejected -> nil
        mode -> mode
      end

    case exceptional_result(failure, :edit) do
      :ok -> {:ok, %{op: Map.get(op, :op, Map.get(op, "op")), invalidated: []}}
      other -> other
    end
  end

  @impl true
  def save(handle, opts) when is_list(opts) do
    path = Keyword.get(opts, :path, handle.path)
    :ok = File.write(path, text(handle))

    case exceptional_result(handle.save_failure, :save) do
      :ok -> :ok
      other -> other
    end
  end

  def export_bytes(handle, _format), do: {:ok, text(handle)}

  defp new_handle(bytes, path, opts) do
    {:ok, agent} = Agent.start(fn -> bytes end)

    %{
      agent: agent,
      path: path,
      edit_failure: Keyword.get(opts, :edit_failure),
      save_failure: Keyword.get(opts, :save_failure),
      reopen_failure: Keyword.get(opts, :reopen_failure),
      reopen_close_failure: Keyword.get(opts, :reopen_close_failure),
      close_failure: Keyword.get(opts, :close_failure),
      close_attempts: :atomics.new(1, []),
      observer: Keyword.get(opts, :observer)
    }
  end

  defp text(handle), do: Agent.get(handle.agent, & &1)

  defp exceptional_result(:raise, stage), do: raise("injected #{stage} raise")
  defp exceptional_result(:exit, stage), do: exit({:injected_exit, stage})
  defp exceptional_result(:unexpected, stage), do: {:unexpected_backend_return, stage}
  defp exceptional_result(_mode, _stage), do: :ok

  defp notify_close(%{observer: observer, agent: agent}, attempt, disposition)
       when is_pid(observer),
       do: send(observer, {:exceptional_backend_close, agent, attempt, disposition})

  defp notify_close(_handle, _attempt, _disposition), do: :ok
end
