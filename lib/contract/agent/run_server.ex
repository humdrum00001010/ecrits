defmodule Contract.Agent.RunServer do
  @moduledoc """
  One agent run, one GenServer.

  Holds in-memory `Contract.Agent.Run` state, drives the OpenAI Responses
  stream through `handle_event/2`, broadcasts SSE events to LiveView via
  PubSub, and emits a final `{:agent_completed, run_id, action}` message
  once the model returns its JSON envelope.
  """

  use GenServer
  require Logger

  alias Contract.Agent

  @registry Contract.Agent.Registry
  @pubsub Contract.PubSub

  defstruct [
    :run,
    :ctx,
    :action,
    :openai,
    :json_buffer,
    :final_response,
    :task_ref,
    :stream_task_pid,
    :test_pid,
    stream_retries_left: 1
  ]

  # --- public API -------------------------------------------------------

  def child_spec(args) do
    %{
      id: {__MODULE__, args[:run_id]},
      start: {__MODULE__, :start_link, [args]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(args) do
    run_id = Keyword.fetch!(args, :run_id)
    GenServer.start_link(__MODULE__, args, name: via(run_id))
  end

  @spec via(Ecto.UUID.t()) :: {:via, Registry, {atom(), Ecto.UUID.t()}}
  def via(run_id), do: {:via, Registry, {@registry, run_id}}

  def whereis(run_id) do
    case Registry.lookup(@registry, run_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def get_run(run_id) do
    case whereis(run_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :get_run)
    end
  end

  def cancel(run_id) do
    case whereis(run_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.call(pid, :cancel)
    end
  end

  def observe_change(run_id, change) do
    case whereis(run_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, {:observe_change, change})
    end
  end

  def observe_revoke(run_id, revoke_change) do
    case whereis(run_id) do
      nil -> {:error, :not_found}
      pid -> GenServer.cast(pid, {:observe_revoke, revoke_change})
    end
  end

  # --- GenServer callbacks ---------------------------------------------

  @impl true
  def init(args) do
    run = Keyword.fetch!(args, :run)
    ctx = Keyword.get(args, :ctx)
    action = Keyword.fetch!(args, :action)
    test_pid = Keyword.get(args, :test_pid)

    state = %__MODULE__{
      run: run,
      ctx: ctx,
      action: action,
      openai: Application.fetch_env!(:contract, :io_drivers)[:openai],
      json_buffer: [],
      test_pid: test_pid
    }

    {:ok, state, {:continue, :start_stream}}
  end

  @impl true
  def handle_continue(:start_stream, state) do
    {:ok, context} = Agent.build_context(state.ctx, state.action)

    base_params = %{
      input: context.input,
      instructions: context.system,
      tools: context.tools
    }

    # Grill-intro responses are plain Korean text, not the JSON envelope
    # the regular grill protocol uses — drop the json_object format
    # constraint so the model is free to emit prose.
    params =
      if Map.get(context, :grill_seed?) do
        base_params
      else
        Map.put(base_params, :text, %{format: %{type: "json_object"}})
      end
      |> maybe_put(:previous_response_id, Map.get(context, :previous_response_id))

    case start_stream_with_retry(state.openai, params, _attempts_left = 2) do
      {:ok, %{stream: stream, task_pid: task_pid}} ->
        ref = consume_stream(stream)
        {:noreply, %{state | task_ref: ref, stream_task_pid: task_pid}}

      {:error, reason} ->
        fail(state, reason)
    end
  end

  # Single retry on transient OpenAI connection errors (the request body
  # never reached the model, so it's safe to replay). Anything else —
  # auth failure, validation error, rate limit envelope — fails fast.
  # Backoff is 400ms, then 1.2s; total cap stays well under the 60s
  # receive timeout we configure on the OpenaiEx client.
  defp start_stream_with_retry(openai, params, attempts_left)
       when attempts_left > 0 do
    case openai.stream_chat(params, []) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        if transient_openai_error?(reason) and attempts_left > 1 do
          Logger.warning(
            "Agent stream_chat transient failure; retrying. reason=#{inspect(reason)}"
          )

          Process.sleep(if(attempts_left == 2, do: 400, else: 1_200))
          start_stream_with_retry(openai, params, attempts_left - 1)
        else
          {:error, reason}
        end
    end
  end

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

  @impl true
  def handle_call(:get_run, _from, state) do
    {:reply, {:ok, state.run}, state}
  end

  def handle_call(:cancel, _from, state) do
    new_run = %{state.run | status: :cancelled}
    broadcast(state, {:agent_failed, state.run.id, :cancelled})
    {:stop, :normal, {:ok, new_run}, %{state | run: new_run}}
  end

  @impl true
  def handle_cast({:observe_change, _change}, state), do: {:noreply, state}
  def handle_cast({:observe_revoke, _change}, state), do: {:noreply, state}

  @impl true
  def handle_info({:stream_event, event}, state) do
    broadcast(state, {:agent_stream, state.run.id, event})
    {:noreply, accumulate(state, event)}
  end

  def handle_info({:stream_done, final_text}, state) do
    decoder =
      if Agent.grill_seed?(state.action) do
        &Agent.decode_grill_intro/2
      else
        &Agent.decode_action/2
      end

    case decoder.(final_text, run_id: state.run.id, turn_index: state.run.turn_index) do
      {:ok, action} ->
        new_run = %{state.run | status: :completed}
        _ = Contract.ChatThreads.append_assistant_message(state.ctx, state.action, action.message)
        broadcast(state, {:agent_completed, state.run.id, action})
        {:stop, :normal, %{state | run: new_run}}

      {:error, reason} ->
        fail(state, {:decode_failed, reason})
    end
  end

  def handle_info({:stream_error, reason}, state) do
    cond do
      transient_openai_error?(reason) and state.stream_retries_left > 0 ->
        Logger.warning("Agent stream mid-flight failure; retrying. reason=#{inspect(reason)}")

        Process.sleep(800)

        new_state = %{
          state
          | json_buffer: [],
            task_ref: nil,
            stream_task_pid: nil,
            stream_retries_left: state.stream_retries_left - 1
        }

        {:noreply, new_state, {:continue, :start_stream}}

      true ->
        fail(state, reason)
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- helpers ----------------------------------------------------------

  defp consume_stream(stream) do
    me = self()

    Task.async(fn ->
      try do
        Enum.reduce(stream, "", fn event, acc ->
          send(me, {:stream_event, event})

          case extract_text_delta(event) do
            nil -> acc
            piece -> acc <> piece
          end
        end)
        |> then(&send(me, {:stream_done, &1}))
      rescue
        e -> send(me, {:stream_error, e})
      end
    end)
  end

  defp accumulate(state, _event), do: state

  defp extract_text_delta(%{type: "response.output_text.delta", data: %{"delta" => delta}})
       when is_binary(delta),
       do: delta

  defp extract_text_delta(%{type: "response.completed", data: %{"response" => resp}})
       when is_map(resp) do
    # The final response payload often carries the full output text.
    case Map.get(resp, "output_text") do
      text when is_binary(text) -> text
      _ -> nil
    end
  end

  defp extract_text_delta(_), do: nil

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(@pubsub, "agent:#{state.run.id}", message)

    if state.test_pid do
      send(state.test_pid, message)
    end
  end

  defp fail(state, reason) do
    new_run = %{state.run | status: :failed}
    broadcast(state, {:agent_failed, state.run.id, summarize_reason(reason)})
    {:stop, :normal, %{state | run: new_run}}
  end

  # Strip the giant request body / API key out of OpenaiEx.Error before
  # broadcasting — the LV renders the reason verbatim and we do NOT want
  # the user's Bearer token landing in flash/toast text or browser
  # devtools logs.
  defp summarize_reason(%OpenaiEx.Error{} = err) do
    {:openai_error,
     %{message: err.message, status: err.status_code, code: err.code, type: err.type}}
  end

  defp summarize_reason(%{__exception__: true} = e), do: {:exception, Exception.message(e)}
  defp summarize_reason(other), do: other

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
