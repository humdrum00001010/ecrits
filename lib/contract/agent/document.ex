defmodule Contract.Agent.Document do
  @moduledoc """
  Document-scoped public boundary for agent work.

  The runtime is one process per `{user_id, document_id}` scope. It owns
  `Run` creation identity, an explicit FIFO queue, the current streaming
  attempt, cancellation, status/liveness, and PubSub emission.
  """

  use GenServer
  require Logger

  alias Contract.Agent
  alias Contract.Agent.Run
  alias Contract.Command
  alias Contract.Context
  alias Contract.Types, as: T

  @registry Contract.Agent.Document.Registry
  @run_registry Contract.Agent.Document.RunRegistry
  @pubsub Contract.PubSub

  defstruct [
    :key,
    :ctx,
    :document_id,
    :openai,
    current: nil,
    queue: []
  ]

  @type status :: %{
          document_id: T.document_id() | nil,
          alive?: boolean(),
          current_attempt: Run.t() | nil,
          queue: [Run.t()]
        }

  @type active_attempt :: %{
          run_id: T.agent_run_id(),
          run: Run.t(),
          pid: pid()
        }

  @spec start(T.ctx(), Command.t()) :: {:ok, Run.t()} | {:error, term()}
  def start(ctx, %Command{kind: :chat_message} = action) do
    with {:ok, key} <- runtime_key(ctx, action.document_id),
         {:ok, pid} <- ensure_runtime(key, ctx, action.document_id) do
      run = build_run(ctx, action)
      GenServer.call(pid, {:enqueue, run, ctx, action})
    end
  end

  def start(_ctx, %Command{kind: kind}), do: {:error, {:unsupported_action, kind}}

  @spec status(T.ctx(), T.document_id() | nil) :: {:ok, status()} | {:error, term()}
  def status(ctx, document_id) do
    with {:ok, key} <- runtime_key(ctx, document_id) do
      case whereis_key(key) do
        nil -> {:error, :not_found}
        pid -> GenServer.call(pid, :status)
      end
    end
  end

  @spec suspend(T.ctx(), T.document_id() | nil) :: {:ok, Run.t()} | {:error, term()}
  def suspend(ctx, document_id) do
    with {:ok, key} <- runtime_key(ctx, document_id) do
      case whereis_key(key) do
        nil -> {:error, :not_found}
        pid -> GenServer.call(pid, :suspend)
      end
    end
  end

  @spec cancel(T.ctx(), T.agent_run_id()) :: {:ok, Run.t()} | {:error, term()}
  def cancel(ctx, run_id) when is_binary(run_id) do
    case whereis(run_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, {:cancel, ctx, run_id})
    end
  end

  def cancel(_ctx, _run_id), do: {:error, :not_found}

  @spec whereis(T.agent_run_id()) :: pid() | nil
  def whereis(run_id) when is_binary(run_id) do
    case Registry.lookup(@run_registry, run_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def whereis(_run_id), do: nil

  @spec whereis_for_scope(binary() | nil, binary() | nil) :: {binary(), pid()} | nil
  def whereis_for_scope(user_id, document_id)
      when is_binary(user_id) and is_binary(document_id) do
    case active_attempt(user_id, document_id) do
      {:ok, %{run_id: run_id, pid: pid}} -> {run_id, pid}
      nil -> nil
    end
  end

  def whereis_for_scope(_user_id, _document_id), do: nil

  @spec active_attempt(binary() | nil, binary() | nil) :: {:ok, active_attempt()} | nil
  def active_attempt(user_id, document_id)
      when is_binary(user_id) and is_binary(document_id) do
    key = {user_id, document_id}

    case whereis_key(key) do
      nil ->
        nil

      pid ->
        case GenServer.call(pid, :active_attempt) do
          %Run{} = run -> {:ok, %{run_id: run.id, run: run, pid: pid}}
          nil -> nil
        end
    end
  end

  def active_attempt(_user_id, _document_id), do: nil

  def child_spec(args) do
    %{
      id: {__MODULE__, Keyword.fetch!(args, :key)},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(args) do
    key = Keyword.fetch!(args, :key)
    GenServer.start_link(__MODULE__, args, name: via(key))
  end

  @impl true
  def init(args) do
    {:ok,
     %__MODULE__{
       key: Keyword.fetch!(args, :key),
       ctx: Keyword.get(args, :ctx),
       document_id: Keyword.get(args, :document_id),
       openai: Application.fetch_env!(:contract, :io_drivers)[:openai]
     }}
  end

  @impl true
  def handle_call({:enqueue, %Run{} = run, ctx, %Command{} = action}, _from, state) do
    :ok = register_run(run.id)

    attempt = %{
      run: run,
      ctx: ctx,
      action: action,
      test_pid: action.payload["test_pid"],
      task_ref: nil,
      task_pid: nil,
      stream_retries_left: 1
    }

    cond do
      is_nil(state.current) ->
        {state, started_run} = start_attempt(%{state | ctx: ctx}, attempt)
        {:reply, {:ok, started_run}, state}

      true ->
        queued = put_in(attempt.run.status, :pending)
        state = %{state | queue: state.queue ++ [queued]}
        {:reply, {:ok, queued.run}, state}
    end
  end

  def handle_call(:status, _from, state) do
    status = %{
      document_id: state.document_id,
      alive?: true,
      current_attempt: current_run(state),
      queue: Enum.map(state.queue, & &1.run)
    }

    {:reply, {:ok, status}, state}
  end

  def handle_call(:current_run_id, _from, state) do
    {:reply, state.current && state.current.run.id, state}
  end

  def handle_call(:active_attempt, _from, state) do
    {:reply, current_run(state), state}
  end

  def handle_call(:suspend, _from, %{current: nil} = state) do
    {:reply, {:error, :no_current_attempt}, state}
  end

  def handle_call(:suspend, _from, state) do
    attempt = state.current

    if attempt.task_pid && Process.alive?(attempt.task_pid) do
      Process.exit(attempt.task_pid, :kill)
    end

    run = %{attempt.run | status: :cancelled, completed_at: utc_now(), updated_at: utc_now()}
    broadcast(attempt, {:agent_failed, run.id, :cancelled})
    Registry.unregister(@run_registry, run.id)

    {state, _next_run} = maybe_start_next(%{state | current: nil})
    {:reply, {:ok, run}, state}
  end

  def handle_call({:cancel, ctx, run_id}, _from, state) do
    if caller_scope_matches?(ctx, state) do
      cancel_owned_run(run_id, state)
    else
      {:reply, {:error, :forbidden}, state}
    end
  end

  defp cancel_owned_run(run_id, %{current: %{run: %{id: run_id}}} = state) do
    attempt = state.current

    if attempt.task_pid && Process.alive?(attempt.task_pid) do
      Process.exit(attempt.task_pid, :kill)
    end

    run = %{attempt.run | status: :cancelled, completed_at: utc_now(), updated_at: utc_now()}
    broadcast(attempt, {:agent_failed, run.id, :cancelled})
    Registry.unregister(@run_registry, run.id)

    {state, _next_run} = maybe_start_next(%{state | current: nil})
    {:reply, {:ok, run}, state}
  end

  defp cancel_owned_run(run_id, state) do
    {matches, rest} = Enum.split_with(state.queue, &(&1.run.id == run_id))

    case matches do
      [%{run: run}] ->
        run = %{run | status: :cancelled, completed_at: utc_now(), updated_at: utc_now()}
        Registry.unregister(@run_registry, run.id)
        {:reply, {:ok, run}, %{state | queue: rest}}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_info({:agent_text_delta, run_id, piece}, state) do
    with %{run: %{id: ^run_id}} = attempt <- state.current do
      broadcast(attempt, {:agent_text_delta, run_id, piece})
    end

    {:noreply, state}
  end

  def handle_info({:stream_event, run_id, event}, state) do
    with %{run: %{id: ^run_id}} = attempt <- state.current do
      broadcast(attempt, {:agent_stream, run_id, event})

      case classify_stream_event(event) do
        :ignore -> :ok
        {tag, payload} -> broadcast(attempt, {tag, run_id, payload})
      end
    end

    {:noreply, state}
  end

  def handle_info({:stream_done, run_id, final_text}, state) do
    with %{run: %{id: ^run_id}} = attempt <- state.current do
      state = complete_attempt(state, attempt, final_text)
      {:noreply, state}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:stream_failed, run_id, reason}, state) do
    with %{run: %{id: ^run_id}} = attempt <- state.current do
      message = format_failure(reason)
      _ = persist_failed_tool_call(attempt, reason)
      _ = Contract.ChatThreads.append_assistant_message(attempt.ctx, attempt.action, message)

      synthetic = %Command{
        kind: :agent_change,
        actor_type: :agent,
        message: message,
        payload: %{"message" => message, "ops" => [], "marks" => []}
      }

      broadcast(attempt, {:agent_completed, run_id, synthetic})
      Logger.warning("Agent stream failed (#{inspect(reason)})")

      state = finish_current(state, :failed, %{message: message})
      {:noreply, state}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:stream_error, run_id, reason}, state) do
    with %{run: %{id: ^run_id}} = attempt <- state.current do
      cond do
        transient_openai_error?(reason) and attempt.stream_retries_left > 0 ->
          Logger.warning("Agent stream mid-flight failure; retrying. reason=#{inspect(reason)}")

          retry =
            %{
              attempt
              | task_ref: nil,
                task_pid: nil,
                stream_retries_left: attempt.stream_retries_left - 1
            }

          {state, _run} = start_attempt(%{state | current: nil}, retry)
          {:noreply, state}

        true ->
          broadcast(attempt, {:agent_failed, run_id, summarize_reason(reason)})
          state = finish_current(state, :failed, %{reason: summarize_reason(reason)})
          {:noreply, state}
      end
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({_ref, _result}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{current: %{task_ref: ref, task_pid: pid}} = state
      )
      when reason != :normal do
    reason = summarize_reason(reason)
    attempt = state.current

    broadcast(attempt, {:agent_failed, attempt.run.id, reason})
    state = finish_current(state, :failed, %{reason: reason})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp ensure_runtime(key, ctx, document_id) do
    case whereis_key(key) do
      nil ->
        args = [key: key, ctx: ctx, document_id: document_id]

        case Contract.Agent.DocumentSupervisor.start_document(args) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  defp runtime_key(%Context{user: %{id: user_id}}, document_id)
       when is_binary(user_id) and (is_binary(document_id) or is_nil(document_id)) do
    {:ok, {user_id, document_id}}
  end

  defp runtime_key(_ctx, _document_id), do: {:error, :missing_current_scope}

  defp whereis_key(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp via(key), do: {:via, Registry, {@registry, key}}

  defp register_run(run_id) do
    case Registry.register(@run_registry, run_id, []) do
      {:ok, _} -> :ok
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp caller_scope_matches?(ctx, state) do
    case runtime_key(ctx, state.document_id) do
      {:ok, key} -> key == state.key
      {:error, _reason} -> false
    end
  end

  defp build_run(ctx, %Command{} = action) do
    now = utc_now()
    owner_id = get_in(Map.from_struct(ctx || %Context{}), [:user, Access.key(:id)])

    %Run{
      id: Ecto.UUID.generate(),
      document_id: action.document_id,
      triggered_by_action_id: action.payload["action_id"] || action.idempotency_key,
      status: :running,
      turn_index: 0,
      previous_response_id: action.payload["previous_response_id"],
      message: action.message,
      owner_id: owner_id,
      chat_thread_id: action.chat_thread_id,
      started_at: now,
      inserted_at: now,
      updated_at: now
    }
  end

  defp start_attempt(state, attempt) do
    run = %{
      attempt.run
      | status: :running,
        started_at: attempt.run.started_at || utc_now(),
        updated_at: utc_now()
    }

    attempt = %{attempt | run: run}

    action = %{attempt.action | agent_run_id: run.id}
    {:ok, context} = Agent.build_context(attempt.ctx, action)

    params =
      %{
        input: context.input,
        instructions: context.system,
        tools: context.tools
      }
      |> maybe_put(:previous_response_id, Map.get(context, :previous_response_id))

    me = self()
    openai = state.openai

    broadcast(attempt, {:agent_thinking_started, run.id})

    task =
      Task.async(fn ->
        case start_stream_with_retry(openai, params, _attempts_left = 2) do
          {:ok, %{stream: stream}} -> consume_into(stream, me, run.id)
          {:error, reason} -> send(me, {:stream_error, run.id, reason})
        end
      end)

    Process.unlink(task.pid)
    attempt = %{attempt | task_ref: task.ref, task_pid: task.pid}
    {%{state | current: attempt}, run}
  end

  defp maybe_start_next(%{queue: [next | rest]} = state) do
    start_attempt(%{state | queue: rest}, next)
  end

  defp maybe_start_next(state), do: {state, nil}

  defp complete_attempt(state, attempt, final_text) do
    decoder =
      if Agent.grill_seed?(attempt.action) do
        &Agent.decode_grill_intro/2
      else
        &Agent.decode_action/2
      end

    case decoder.(final_text, run_id: attempt.run.id, turn_index: attempt.run.turn_index) do
      {:ok, action} ->
        reply =
          case action.message do
            msg when is_binary(msg) and msg != "" -> msg
            _ -> "(완료)"
          end

        action = %{action | message: reply}
        _ = Contract.ChatThreads.append_assistant_message(attempt.ctx, attempt.action, reply)
        broadcast(attempt, {:agent_completed, attempt.run.id, action})
        finish_current(state, :completed)

      {:error, reason} ->
        placeholder = "(완료)"

        _ =
          Contract.ChatThreads.append_assistant_message(attempt.ctx, attempt.action, placeholder)

        synthetic = %Command{
          kind: :agent_change,
          actor_type: :agent,
          message: placeholder,
          payload: %{"message" => placeholder, "ops" => [], "marks" => []}
        }

        broadcast(attempt, {:agent_completed, attempt.run.id, synthetic})

        Logger.warning(
          "Agent envelope decode failed (#{inspect(reason)}); synthesized placeholder reply."
        )

        finish_current(state, :completed)
    end
  end

  defp finish_current(state, status, error \\ nil) do
    run = %{
      state.current.run
      | status: status,
        completed_at: utc_now(),
        updated_at: utc_now(),
        error: error
    }

    Registry.unregister(@run_registry, run.id)
    {state, _run} = maybe_start_next(%{state | current: nil})
    state
  end

  defp current_run(%{current: nil}), do: nil
  defp current_run(%{current: %{run: run}}), do: run

  defp start_stream_with_retry(openai, params, attempts_left) when attempts_left > 0 do
    case openai.stream_chat(params, []) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        if transient_openai_error?(reason) and attempts_left > 1 do
          Logger.warning(
            "Agent stream_chat transient failure; retrying. reason=#{inspect(reason)}"
          )

          start_stream_with_retry(openai, params, attempts_left - 1)
        else
          {:error, reason}
        end
    end
  end

  defp consume_into(stream, document_pid, run_id) do
    try do
      {final_text, failure} =
        Enum.reduce(stream, {"", nil}, fn event, {acc, failure} ->
          send(document_pid, {:stream_event, run_id, event})

          failure = failure || extract_failure(event)

          case extract_text_delta(event) do
            nil ->
              {acc, failure}

            piece ->
              send(document_pid, {:agent_text_delta, run_id, piece})
              {acc <> piece, failure}
          end
        end)

      case failure do
        nil -> send(document_pid, {:stream_done, run_id, final_text})
        reason -> send(document_pid, {:stream_failed, run_id, reason})
      end
    rescue
      e -> send(document_pid, {:stream_error, run_id, e})
    end
  end

  defp extract_failure(%{type: "response.failed", data: data}) when is_map(data) do
    case get_in(data, ["response", "error"]) do
      %{"message" => msg} = err when is_binary(msg) -> {:openai_failed, err}
      _ -> {:openai_failed, %{"message" => "response.failed"}}
    end
  end

  defp extract_failure(%{type: "error", data: %{"error" => err}}) when is_map(err),
    do: {:openai_failed, err}

  defp extract_failure(%{type: "error", data: err}) when is_map(err),
    do: {:openai_failed, err}

  defp extract_failure(_), do: nil

  defp extract_text_delta(%{type: "response.output_text.delta", data: %{"delta" => delta}})
       when is_binary(delta),
       do: delta

  defp extract_text_delta(_), do: nil

  defp classify_stream_event(%{
         type: "response.reasoning_summary_text.delta",
         data: %{"delta" => delta}
       })
       when is_binary(delta),
       do: {:agent_reasoning_delta, delta}

  defp classify_stream_event(%{
         type: "response.reasoning_summary_text.done",
         data: %{"text" => text}
       })
       when is_binary(text),
       do: {:agent_reasoning_done, text}

  defp classify_stream_event(_), do: :ignore

  defp transient_openai_error?(%OpenaiEx.Error{message: msg}) when is_binary(msg) do
    msg =~ ~r/(connection closed|timeout|econnreset|closed)/i
  end

  defp transient_openai_error?(%{__exception__: true} = e) do
    e
    |> Exception.message()
    |> to_string()
    |> String.downcase()
    |> String.contains?(["connection closed", "timeout", "econnreset", "closed"])
  end

  defp transient_openai_error?(_), do: false

  defp format_failure({:openai_failed, %{"message" => msg} = err}) when is_binary(msg) do
    code = Map.get(err, "code")
    base = "AI 응답 실패: " <> msg
    if is_binary(code) and code != "", do: base <> " [" <> code <> "]", else: base
  end

  defp format_failure(other), do: "AI 응답 실패: " <> inspect(other)

  defp persist_failed_tool_call(attempt, reason) do
    {tool, summary} = failed_tool_call_descriptor(reason)
    run_id = attempt.run.id
    thread_id = attempt.action.chat_thread_id
    tool_id = "#{tool}-#{System.unique_integer([:positive])}"

    operation = %{
      "id" => tool_id,
      "type" => "tool_call",
      "name" => tool,
      "tool_name" => tool,
      "raw_name" => tool,
      "server_label" => "contract-doc",
      "title" => tool,
      "status" => "failed",
      "summary" => summary,
      "agent_run_id" => run_id,
      "details" => %{"arguments" => %{}, "output" => %{"error" => failed_tool_call_error(reason)}}
    }

    broadcast(attempt, {:tool_call_failed, run_id, tool_id, operation})
    Contract.ChatThreads.append_tool_call_message(thread_id, operation)
  end

  defp failed_tool_call_descriptor(
         {:openai_failed, %{"type" => "external_connector_error"} = err}
       ) do
    {"mcp.tools/list", short_openai_error(err)}
  end

  defp failed_tool_call_descriptor({:openai_failed, %{"param" => "tools"} = err}) do
    {"mcp.tools/list", short_openai_error(err)}
  end

  defp failed_tool_call_descriptor({:openai_failed, err}) when is_map(err) do
    {"agent.stream", short_openai_error(err)}
  end

  defp failed_tool_call_descriptor(_), do: {"agent.stream", "stream failed"}

  defp short_openai_error(%{"code" => code, "message" => msg}) when is_binary(msg) do
    if is_binary(code) and code != "", do: "#{code}: #{msg}", else: msg
  end

  defp short_openai_error(%{"message" => msg}) when is_binary(msg), do: msg
  defp short_openai_error(_), do: "external connector error"

  defp failed_tool_call_error({:openai_failed, err}) when is_map(err), do: err
  defp failed_tool_call_error(other), do: inspect(other)

  defp broadcast(attempt, message) do
    Phoenix.PubSub.broadcast(@pubsub, "agent:#{attempt.run.id}", message)

    if attempt.test_pid do
      send(attempt.test_pid, message)
    end
  end

  defp summarize_reason(%OpenaiEx.Error{} = err) do
    {:openai_error,
     %{message: err.message, status: err.status_code, code: err.code, type: err.type}}
  end

  defp summarize_reason({%{__exception__: true} = e, _stacktrace}),
    do: {:exception, Exception.message(e)}

  defp summarize_reason(%{__exception__: true} = e), do: {:exception, Exception.message(e)}
  defp summarize_reason(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
