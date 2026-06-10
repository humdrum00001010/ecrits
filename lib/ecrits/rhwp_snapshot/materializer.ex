defmodule Ecrits.RhwpSnapshot.Materializer do
  @moduledoc """
  Coordinates live editor materialization of RHWP snapshots.
  """

  use GenServer

  @timeout 15_000

  # Public API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def register_editor(document_id) do
    case ensure_started() do
      pid when is_pid(pid) -> GenServer.call(pid, {:register_editor, self(), document_id})
      nil -> :ok
    end
  end

  def unregister_editor(document_id) do
    case ensure_started() do
      pid when is_pid(pid) -> GenServer.call(pid, {:unregister_editor, self(), document_id})
      nil -> :ok
    end
  end

  def ensure_committed(document_id, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @timeout)
    text_events = Keyword.get(opts, :text_events, [])
    base_snapshot = Keyword.get(opts, :base_snapshot)

    case ensure_started() do
      pid when is_pid(pid) ->
        GenServer.call(
          pid,
          {:ensure_committed, document_id, timeout, text_events, base_snapshot},
          timeout + 1_000
        )

      nil ->
        {:error, :materializer_unavailable}
    end
  end

  def ack(request_id, result) do
    if pid = ensure_started() do
      GenServer.cast(pid, {:ack, self(), request_id, result})
    end

    :ok
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) -> pid
      nil -> start_supervised_child()
    end
  end

  defp start_supervised_child do
    case Supervisor.start_child(Ecrits.Supervisor, __MODULE__) do
      {:ok, pid} when is_pid(pid) -> pid
      {:error, {:already_started, pid}} when is_pid(pid) -> pid
      _ -> Process.whereis(__MODULE__)
    end
  catch
    :exit, _ -> nil
  end

  # GenServer

  @impl true
  def init(_opts) do
    {:ok,
     %{
       docs: %{},
       pids: %{},
       monitors: %{},
       monitor_refs: %{},
       requests: %{}
     }}
  end

  @impl true
  def handle_call({:register_editor, pid, document_id}, _from, state) do
    {:reply, :ok, register_pid(state, pid, document_id)}
  end

  def handle_call({:unregister_editor, pid, document_id}, _from, state) do
    state =
      state
      |> remove_editor(pid, document_id)
      |> fail_requests_for_pid(pid, document_id, :editor_unregistered)

    {:reply, :ok, state}
  end

  def handle_call(
        {:ensure_committed, document_id, timeout, text_events, base_snapshot},
        from,
        state
      ) do
    editors = Map.get(state.docs, document_id, MapSet.new())

    if MapSet.size(editors) == 0 do
      {:reply, {:error, :no_live_editor}, state}
    else
      request_id = Ecto.UUID.generate()

      payload =
        %{
          request_id: request_id,
          document_id: document_id,
          text_events: List.wrap(text_events)
        }
        |> maybe_put_base_snapshot(base_snapshot)

      Enum.each(editors, &send(&1, {:rhwp_positional_index_request, payload}))

      request = %{
        from: from,
        document_id: document_id,
        pending: editors,
        failed: MapSet.new(),
        timer_ref: Process.send_after(self(), {:request_timeout, request_id}, timeout)
      }

      {:noreply, put_in(state.requests[request_id], request)}
    end
  end

  defp maybe_put_base_snapshot(payload, %{} = base_snapshot),
    do: Map.put(payload, :base_snapshot, base_snapshot)

  defp maybe_put_base_snapshot(payload, _base_snapshot), do: payload

  @impl true
  def handle_cast({:ack, pid, request_id, result}, state) do
    case Map.fetch(state.requests, request_id) do
      {:ok, request} ->
        handle_ack(state, request_id, request, pid, result)

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:request_timeout, request_id}, state) do
    case Map.fetch(state.requests, request_id) do
      {:ok, request} ->
        {:noreply, finish_request(state, request_id, request, {:error, :timeout})}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.monitor_refs, ref) do
      {:ok, ^pid} ->
        state =
          state
          |> remove_pid(pid)
          |> fail_requests_for_pid(pid, :all, :editor_down)

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp handle_ack(state, request_id, request, pid, result) do
    cond do
      not MapSet.member?(request.pending, pid) ->
        {:noreply, state}

      match?({:ok, _}, committed_result(request_id, request, result)) ->
        {:ok, reply} = committed_result(request_id, request, result)
        {:noreply, finish_request(state, request_id, request, {:ok, reply})}

      failed_result?(result) ->
        {:noreply, record_failure(state, request_id, pid, ack_failure_reason(result))}

      true ->
        {:noreply, state}
    end
  end

  defp committed_result(request_id, request, %{status: status} = result)
       when status in [:committed, "committed"] do
    result_request_id = value(result, [:request_id, "request_id"])
    document_id = value(result, [:document_id, "document_id"])
    snapshot = value(result, [:snapshot, "snapshot"])

    if request_id_matches?(request_id, result_request_id) and document_id == request.document_id and
         is_map(snapshot) do
      {:ok, %{request_id: request_id, document_id: document_id, snapshot: snapshot}}
    else
      :error
    end
  end

  defp committed_result(request_id, request, {:ok, snapshot}) do
    document_id = value(snapshot, [:document_id, "document_id"])

    if document_id == request.document_id do
      {:ok, %{request_id: request_id, document_id: document_id, snapshot: snapshot}}
    else
      :error
    end
  end

  defp committed_result(_request_id, _request, _result), do: :error

  defp request_id_matches?(_request_id, nil), do: true
  defp request_id_matches?(request_id, request_id), do: true
  defp request_id_matches?(_request_id, _result_request_id), do: false

  defp failed_result?(%{status: status}) when status in [:failed, "failed", :error, "error"],
    do: true

  defp failed_result?({:error, _reason}), do: true
  defp failed_result?(_result), do: false

  defp ack_failure_reason({:error, reason}), do: reason

  defp ack_failure_reason(%{reason: reason}), do: reason
  defp ack_failure_reason(%{"reason" => reason}), do: reason
  defp ack_failure_reason(_result), do: :editor_failed

  defp value(map, keys) when is_map(map) do
    Enum.find_value(keys, &Map.get(map, &1))
  end

  defp value(_term, _keys), do: nil

  defp finish_request(state, request_id, request, reply) do
    Process.cancel_timer(request.timer_ref)
    GenServer.reply(request.from, reply)
    update_in(state.requests, &Map.delete(&1, request_id))
  end

  defp record_failure(state, request_id, pid, reason) do
    case Map.fetch(state.requests, request_id) do
      {:ok, request} ->
        request = %{
          request
          | pending: MapSet.delete(request.pending, pid),
            failed: MapSet.put(request.failed, {pid, reason})
        }

        if MapSet.size(request.pending) == 0 do
          finish_request(state, request_id, request, {:error, request_failure_reason(request)})
        else
          put_in(state.requests[request_id], request)
        end

      :error ->
        state
    end
  end

  defp fail_requests_for_pid(state, pid, document_id, reason) do
    state.requests
    |> Map.keys()
    |> Enum.reduce(state, fn request_id, state ->
      case Map.fetch(state.requests, request_id) do
        {:ok, request} ->
          matches_document? = document_id == :all or request.document_id == document_id

          if matches_document? and MapSet.member?(request.pending, pid) do
            record_failure(state, request_id, pid, reason)
          else
            state
          end

        :error ->
          state
      end
    end)
  end

  defp register_pid(state, pid, document_id) do
    state
    |> ensure_monitor(pid)
    |> put_editor(pid, document_id)
  end

  defp ensure_monitor(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      ref = Process.monitor(pid)

      state
      |> put_in([:monitors, pid], ref)
      |> put_in([:monitor_refs, ref], pid)
    end
  end

  defp put_editor(state, pid, document_id) do
    state
    |> update_in([:docs, document_id], fn editors ->
      (editors || MapSet.new())
      |> MapSet.put(pid)
    end)
    |> update_in([:pids, pid], fn docs ->
      (docs || MapSet.new())
      |> MapSet.put(document_id)
    end)
  end

  defp remove_editor(state, pid, document_id) do
    state
    |> update_in([:docs], &delete_set_member(&1, document_id, pid))
    |> update_in([:pids], &delete_set_member(&1, pid, document_id))
    |> maybe_demonitor(pid)
  end

  defp remove_pid(state, pid) do
    state.pids
    |> Map.get(pid, MapSet.new())
    |> Enum.reduce(state, &remove_editor(&2, pid, &1))
  end

  defp delete_set_member(map, key, value) do
    case Map.fetch(map, key) do
      {:ok, set} ->
        set = MapSet.delete(set, value)

        if MapSet.size(set) == 0 do
          Map.delete(map, key)
        else
          Map.put(map, key, set)
        end

      :error ->
        map
    end
  end

  defp maybe_demonitor(state, pid) do
    if Map.has_key?(state.pids, pid) do
      state
    else
      case Map.fetch(state.monitors, pid) do
        {:ok, ref} ->
          Process.demonitor(ref, [:flush])

          state
          |> update_in([:monitors], &Map.delete(&1, pid))
          |> update_in([:monitor_refs], &Map.delete(&1, ref))

        :error ->
          state
      end
    end
  end

  defp request_failure_reason(%{failed: failed}) do
    failed
    |> MapSet.to_list()
    |> List.first()
    |> case do
      {_pid, reason} -> reason
      nil -> :all_editors_failed
    end
  end
end
