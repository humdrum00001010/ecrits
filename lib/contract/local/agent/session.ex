defmodule Contract.Local.Agent.Session do
  @moduledoc """
  One local, provider-agnostic agent session.

  Owns turn execution, streaming, local tool calls, approval gates,
  cancellation, and optional JSONL event persistence.
  """

  use GenServer

  alias Contract.Context
  alias Contract.Local.Agent.ToolRegistry
  alias Contract.Local.Document

  @registry Contract.Local.Agent.SessionRegistry
  @pubsub Contract.PubSub

  @type session_id :: binary()

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  def via(id), do: {:via, Registry, {@registry, id}}

  def whereis(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def whereis(_id), do: nil

  def snapshot(pid), do: GenServer.call(pid, :snapshot)
  def send_turn(pid, ctx, input, opts), do: GenServer.call(pid, {:send_turn, ctx, input, opts})
  def cancel(pid, ctx, turn_id \\ nil), do: GenServer.call(pid, {:cancel, ctx, turn_id})

  def approve_tool_call(pid, ctx, tool_call_id),
    do: GenServer.call(pid, {:approve_tool_call, ctx, tool_call_id})

  def reject_tool_call(pid, ctx, tool_call_id),
    do: GenServer.call(pid, {:reject_tool_call, ctx, tool_call_id})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    document_id = session_document_id(opts)
    document_session = session_document_ref(opts, document_id)
    document_session_module = Keyword.get(opts, :document_session_module)

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       owner_id: owner_id(Keyword.get(opts, :ctx)),
       document_id: document_id,
       workspace_root: Keyword.get(opts, :workspace_root),
       provider: Keyword.get(opts, :provider),
       adapter: Keyword.get(opts, :adapter, Contract.Local.Agent.Adapters.Unavailable),
       adapter_opts: Keyword.get(opts, :adapter_opts, []),
       approval_policy: Keyword.get(opts, :approval_policy, :never),
       access_control: Keyword.get(opts, :access_control, :read_only),
       document_session: document_session,
       document_session_module: document_session_module,
       document_session_timeout: Keyword.get(opts, :document_session_timeout, 5_000),
       persistence: normalize_persistence(opts),
       current: nil,
       pending_tool_calls: %{}
     }}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, public_snapshot(state)}, state}
  end

  def handle_call({:send_turn, ctx, input, opts}, _from, state) do
    cond do
      not authorized?(ctx, state) ->
        {:reply, {:error, :forbidden}, state}

      state.current != nil ->
        {:reply, {:error, :turn_in_progress}, state}

      true ->
        turn = build_turn(state, input, opts)
        adapter_opts = Keyword.merge(state.adapter_opts, Keyword.get(opts, :adapter_opts, []))
        parent = self()
        adapter = state.adapter

        task =
          Task.async(fn ->
            run_adapter(parent, adapter, turn, adapter_opts)
          end)

        Process.unlink(task.pid)

        current = %{
          turn: turn,
          task_ref: task.ref,
          task_pid: task.pid,
          text: ""
        }

        state = %{state | current: current}
        state = emit(state, %{type: :turn_started, turn_id: turn.id, input: input})

        {:reply, {:ok, public_turn(turn, :running)}, state}
    end
  end

  def handle_call({:cancel, ctx, turn_id}, _from, state) do
    cond do
      not authorized?(ctx, state) ->
        {:reply, {:error, :forbidden}, state}

      state.current == nil ->
        {:reply, {:error, :no_current_turn}, state}

      not is_nil(turn_id) and state.current.turn.id != turn_id ->
        {:reply, {:error, :not_found}, state}

      true ->
        if state.current.task_pid do
          Process.exit(state.current.task_pid, :kill)
        end

        turn = state.current.turn

        state =
          state
          |> emit(%{type: :turn_cancelled, turn_id: turn.id})
          |> Map.put(:current, nil)

        {:reply, {:ok, public_turn(turn, :cancelled)}, state}
    end
  end

  def handle_call({:approve_tool_call, ctx, tool_call_id}, _from, state) do
    with :ok <- authorize_result(ctx, state),
         {:ok, tool_call, state} <- pop_pending_tool_call(state, tool_call_id) do
      {state, result} = execute_tool_call(state, tool_call)
      {:reply, result, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:reject_tool_call, ctx, tool_call_id}, _from, state) do
    with :ok <- authorize_result(ctx, state),
         {:ok, tool_call, state} <- pop_pending_tool_call(state, tool_call_id) do
      state =
        emit(state, %{
          type: :tool_call_rejected,
          turn_id: tool_call.turn_id,
          tool_call_id: tool_call.id,
          name: tool_call.name
        })

      {:reply, {:ok, %{tool_call_id: tool_call.id, status: :rejected}}, state}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:adapter_event, turn_id, event}, state) do
    with %{turn: %{id: ^turn_id}} <- state.current do
      {:noreply, handle_adapter_event(state, turn_id, event)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:adapter_done, turn_id}, state) do
    with %{turn: %{id: ^turn_id}} = current <- state.current do
      state =
        state
        |> emit(%{type: :turn_completed, turn_id: turn_id, text: current.text})
        |> Map.put(:current, nil)

      {:noreply, state}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:adapter_failed, turn_id, reason}, state) do
    with %{turn: %{id: ^turn_id}} <- state.current do
      state =
        state
        |> emit(%{type: :turn_failed, turn_id: turn_id, reason: inspect(reason)})
        |> Map.put(:current, nil)

      {:noreply, state}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({_ref, _result}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current: %{task_ref: ref}} = state)
      when reason != :normal do
    turn_id = state.current.turn.id

    state =
      state
      |> emit(%{type: :turn_failed, turn_id: turn_id, reason: inspect(reason)})
      |> Map.put(:current, nil)

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp run_adapter(parent, adapter, turn, opts) do
    case adapter.stream_turn(turn, opts) do
      {:ok, stream} ->
        Enum.each(stream, fn event -> send(parent, {:adapter_event, turn.id, event}) end)
        send(parent, {:adapter_done, turn.id})

      {:error, reason} ->
        send(parent, {:adapter_failed, turn.id, reason})
    end
  rescue
    e -> send(parent, {:adapter_failed, turn.id, {:exception, Exception.message(e)}})
  end

  defp handle_adapter_event(state, turn_id, {:text_delta, delta}) when is_binary(delta) do
    handle_text_delta(state, turn_id, delta)
  end

  defp handle_adapter_event(state, turn_id, {:tool_call, name, arguments}) do
    handle_tool_call(state, turn_id, %{name: name, arguments: arguments})
  end

  defp handle_adapter_event(state, turn_id, %{type: :text_delta, delta: delta})
       when is_binary(delta) do
    handle_text_delta(state, turn_id, delta)
  end

  defp handle_adapter_event(state, turn_id, %{"type" => "text_delta", "delta" => delta})
       when is_binary(delta) do
    handle_text_delta(state, turn_id, delta)
  end

  defp handle_adapter_event(state, turn_id, %{type: :tool_call} = event) do
    handle_tool_call(state, turn_id, event)
  end

  defp handle_adapter_event(state, turn_id, %{"type" => "tool_call"} = event) do
    handle_tool_call(state, turn_id, event)
  end

  defp handle_adapter_event(state, turn_id, %{type: type} = event)
       when type in [:tool_call_started, :tool_call_completed, :tool_call_failed] do
    emit_provider_tool_event(state, turn_id, type, event)
  end

  defp handle_adapter_event(state, turn_id, %{"type" => type} = event)
       when type in ["tool_call_started", "tool_call_completed", "tool_call_failed"] do
    emit_provider_tool_event(state, turn_id, String.to_existing_atom(type), event)
  end

  defp handle_adapter_event(state, turn_id, event) do
    emit(state, %{type: :adapter_event, turn_id: turn_id, event: inspect(event)})
  end

  defp handle_text_delta(state, turn_id, delta) do
    current = %{state.current | text: (state.current.text || "") <> delta}

    state
    |> Map.put(:current, current)
    |> emit(%{type: :text_delta, turn_id: turn_id, delta: delta})
  end

  defp handle_tool_call(state, turn_id, event) do
    name = Map.get(event, :name) || Map.get(event, "name")
    arguments = Map.get(event, :arguments) || Map.get(event, "arguments") || %{}
    tool_call_id = Map.get(event, :id) || Map.get(event, "id") || Ecto.UUID.generate()

    tool_call = %{
      id: tool_call_id,
      turn_id: turn_id,
      name: name,
      arguments: arguments
    }

    state =
      emit(state, %{
        type: :tool_call_started,
        turn_id: turn_id,
        tool_call_id: tool_call_id,
        name: name,
        arguments: arguments
      })

    if ToolRegistry.requires_approval?(state.approval_policy, name) do
      state
      |> put_in([:pending_tool_calls, tool_call_id], tool_call)
      |> emit(%{
        type: :tool_approval_required,
        turn_id: turn_id,
        tool_call_id: tool_call_id,
        name: name,
        arguments: arguments
      })
    else
      {state, _result} = execute_tool_call(state, tool_call)
      state
    end
  end

  defp emit_provider_tool_event(state, turn_id, type, event) do
    tool_call_id =
      Map.get(event, :tool_call_id) ||
        Map.get(event, "tool_call_id") ||
        Map.get(event, :id) ||
        Map.get(event, "id") ||
        Ecto.UUID.generate()

    base = %{
      type: type,
      turn_id: turn_id,
      tool_call_id: tool_call_id,
      name: Map.get(event, :name) || Map.get(event, "name")
    }

    event =
      case type do
        :tool_call_started ->
          Map.put(
            base,
            :arguments,
            Map.get(event, :arguments) || Map.get(event, "arguments") || %{}
          )

        :tool_call_completed ->
          Map.put(base, :result, Map.get(event, :result) || Map.get(event, "result") || %{})

        :tool_call_failed ->
          Map.put(base, :reason, Map.get(event, :reason) || Map.get(event, "reason") || "")
      end

    emit(state, event)
  end

  defp execute_tool_call(state, tool_call) do
    session = tool_context(state)

    case ToolRegistry.call(session, tool_call.name, tool_call.arguments) do
      {:ok, result} ->
        state =
          emit(state, %{
            type: :tool_call_completed,
            turn_id: tool_call.turn_id,
            tool_call_id: tool_call.id,
            name: tool_call.name,
            result: result
          })

        {state, {:ok, result}}

      {:error, reason} ->
        state =
          emit(state, %{
            type: :tool_call_failed,
            turn_id: tool_call.turn_id,
            tool_call_id: tool_call.id,
            name: tool_call.name,
            reason: inspect(reason)
          })

        {state, {:error, reason}}
    end
  end

  defp pop_pending_tool_call(state, tool_call_id) do
    case Map.pop(state.pending_tool_calls, tool_call_id) do
      {nil, _pending} ->
        {:error, :not_found}

      {tool_call, pending} ->
        {:ok, tool_call, %{state | pending_tool_calls: pending}}
    end
  end

  defp build_turn(state, input, opts) do
    %{
      id: Keyword.get(opts, :turn_id, Ecto.UUID.generate()),
      session_id: state.id,
      document_id: state.document_id,
      workspace_root: state.workspace_root,
      input: input,
      tools: ToolRegistry.tools(),
      tool_context: tool_context(state),
      started_at: DateTime.utc_now()
    }
  end

  defp public_snapshot(state) do
    %{
      id: state.id,
      document_id: state.document_id,
      workspace_root: state.workspace_root,
      owner_id: state.owner_id,
      provider: state.provider,
      tools: ToolRegistry.tools(),
      current_turn: state.current && public_turn(state.current.turn, :running),
      pending_tool_call_ids: Map.keys(state.pending_tool_calls)
    }
  end

  defp public_turn(turn, status) do
    %{
      id: turn.id,
      session_id: turn.session_id,
      document_id: turn.document_id,
      status: status,
      tools: turn.tools
    }
  end

  defp tool_context(state) do
    %{
      document_id: state.document_id,
      document_session: state.document_session,
      document_session_module: state.document_session_module,
      document_session_timeout: state.document_session_timeout,
      access_control: state.access_control
    }
  end

  defp emit(state, event) do
    event =
      event
      |> Map.put(:session_id, state.id)
      |> Map.put(
        :at,
        DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
      )

    persist_event(state.persistence, event)
    Phoenix.PubSub.broadcast(@pubsub, topic(state.id), {:local_agent_event, event})
    state
  end

  def topic(id), do: "local_agent:" <> id

  defp persist_event(nil, _event), do: :ok

  defp persist_event({:jsonl, path}, event) when is_binary(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Jason.encode!(jsonable(event)) <> "\n", [:append])
  end

  defp persist_event(_persistence, _event), do: :ok

  defp jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp jsonable(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), jsonable(value)} end)
  end

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp jsonable(other), do: other

  defp normalize_persistence(opts) do
    case Keyword.get(opts, :persistence) do
      {:jsonl, path} when is_binary(path) -> {:jsonl, path}
      _ -> nil
    end
  end

  defp authorize_result(ctx, state) do
    if authorized?(ctx, state), do: :ok, else: {:error, :forbidden}
  end

  defp authorized?(ctx, %{owner_id: nil}), do: is_nil(owner_id(ctx))
  defp authorized?(ctx, %{owner_id: owner_id}), do: owner_id(ctx) == owner_id

  defp owner_id(%Context{user: %{id: id}}) when is_binary(id), do: id
  defp owner_id(_ctx), do: nil

  defp session_document_id(opts) do
    case Keyword.get(opts, :document_id) || Keyword.get(opts, :document_ref) do
      %Document{id: id} when is_binary(id) -> id
      id when is_binary(id) and id != "" -> id
      pid when is_pid(pid) -> document_id_for_pid(pid)
      _value -> nil
    end
  end

  defp document_id_for_pid(pid) do
    case Document.document(pid) do
      {:ok, %Document{id: id}} -> id
      _ -> nil
    end
  end

  defp session_document_ref(opts, document_id) do
    cond do
      not is_nil(Keyword.get(opts, :document_session)) ->
        Keyword.get(opts, :document_session)

      not is_nil(Keyword.get(opts, :document_ref)) ->
        Keyword.get(opts, :document_ref)

      is_binary(document_id) ->
        {:document_id, document_id}

      true ->
        nil
    end
  end
end
