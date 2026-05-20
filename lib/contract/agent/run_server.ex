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
      test_pid: test_pid
    }

    {:ok, state, {:continue, :start_stream}}
  end

  @impl true
  def handle_continue(:start_stream, state) do
    # Stamp the agent_run_id onto the triggering Command so the agent
    # context can mint a route_ref scoped to this run for the contract-doc
    # MCP tool. The original action is preserved elsewhere; we only mutate
    # the in-memory copy used to build the OpenAI request.
    action = %{state.action | agent_run_id: state.run.id}
    {:ok, context} = Agent.build_context(state.ctx, action)

    # Free-form Korean text response. We used to require a JSON envelope
    # (`text.format=json_object`) because ops/marks lived in the envelope,
    # but MCP tools are the side channel for edits now — the model only
    # needs to emit a normal chat reply. Removing the JSON constraint lets
    # the agent actually converse + ask clarifying questions.
    params =
      %{
        input: context.input,
        instructions: context.system,
        tools: context.tools
      }
      |> maybe_put(:previous_response_id, Map.get(context, :previous_response_id))

    # IMPORTANT: stream creation AND consumption must both happen in the
    # Task process. OpenaiEx's `stream_chat` calls Finch.stream with the
    # caller's pid as the chunk-receiver, so `:chunk` messages land in
    # whichever process invoked the function. If we create the stream in
    # the GenServer and then iterate it in a Task, the Task's mailbox is
    # empty and Stream.resource waits forever. By moving start_stream into
    # the Task, chunks land in the Task's mailbox, the stream iterator
    # consumes them, and parsed events flow back to the GenServer via send.
    me = self()
    openai = state.openai

    task =
      Task.async(fn ->
        case start_stream_with_retry(openai, params, _attempts_left = 2) do
          {:ok, %{stream: stream}} ->
            consume_into(stream, me)

          {:error, reason} ->
            send(me, {:stream_error, reason})
        end
      end)

    {:noreply, %{state | task_ref: task.ref, stream_task_pid: task.pid}}
  end

  # Single retry on transient OpenAI connection errors. The request body
  # never reached the model on a conn-reuse failure (Finch returns the
  # error before any bytes leave the socket), so retry is safe AND can
  # fire immediately — no backoff. Anything else — auth failure,
  # validation error, rate-limit envelope — fails fast.
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

  # Build a short Korean error string from an OpenAI failure payload.
  # Keeps the model's `code` for ops debugging but stays one line so it
  # fits a chat bubble.
  defp format_failure({:openai_failed, %{"message" => msg} = err}) when is_binary(msg) do
    code = Map.get(err, "code")
    base = "AI 응답 실패: " <> msg

    if is_binary(code) and code != "" do
      base <> " [" <> code <> "]"
    else
      base
    end
  end

  defp format_failure(other), do: "AI 응답 실패: " <> inspect(other)

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
  def handle_info({:agent_text_delta, piece}, state) do
    broadcast(state, {:agent_text_delta, state.run.id, piece})
    {:noreply, state}
  end

  def handle_info({:stream_event, event}, state) do
    # The raw event broadcast is kept for tests + future text-streaming UI.
    # tool_call/reasoning bubbles do NOT come from this broadcast — tool
    # calls are emitted by `Contract.MCP.instrumented/4` (truthful, single
    # source) and reasoning summary deltas by `classify_stream_event/1`.
    broadcast(state, {:agent_stream, state.run.id, event})

    case classify_stream_event(event) do
      :ignore -> :ok
      {tag, payload} -> broadcast(state, {tag, state.run.id, payload})
    end

    {:noreply, state}
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

        # If the model returned an envelope with an empty message field,
        # synthesize a fallback so the chat rail still has something to
        # render after the run. Better than a blank bubble.
        reply =
          case action.message do
            msg when is_binary(msg) and msg != "" -> msg
            _ -> "(완료)"
          end

        action = %{action | message: reply}
        _ = Contract.ChatThreads.append_assistant_message(state.ctx, state.action, reply)
        broadcast(state, {:agent_completed, state.run.id, action})
        {:stop, :normal, %{state | run: new_run}}

      {:error, reason} ->
        # Even when envelope decoding fails (model returned non-JSON or
        # nothing after MCP work), surface a placeholder reply in the
        # chat so the user isn't left wondering — they can still see the
        # tool_call cards persisted by `Contract.MCP.instrumented/4`.
        placeholder = "(완료)"
        _ = Contract.ChatThreads.append_assistant_message(state.ctx, state.action, placeholder)

        synthetic =
          %Contract.Command{
            kind: :agent_change,
            actor_type: :agent,
            message: placeholder,
            payload: %{"message" => placeholder, "ops" => [], "marks" => []}
          }

        broadcast(state, {:agent_completed, state.run.id, synthetic})
        new_run = %{state.run | status: :completed}

        Logger.warning(
          "Agent envelope decode failed (#{inspect(reason)}); synthesized placeholder reply."
        )

        {:stop, :normal, %{state | run: new_run}}
    end
  end

  def handle_info({:stream_failed, reason}, state) do
    # Surface OpenAI-side failures truthfully instead of letting them be
    # masked as a silent `(완료)` reply. Persists a visible error bubble
    # in the chat so the user knows what happened.
    message = format_failure(reason)
    _ = Contract.ChatThreads.append_assistant_message(state.ctx, state.action, message)

    synthetic = %Contract.Command{
      kind: :agent_change,
      actor_type: :agent,
      message: message,
      payload: %{"message" => message, "ops" => [], "marks" => []}
    }

    broadcast(state, {:agent_completed, state.run.id, synthetic})

    Logger.warning("Agent stream failed (#{inspect(reason)})")

    new_run = %{state.run | status: :failed}
    {:stop, :normal, %{state | run: new_run}}
  end

  def handle_info({:stream_error, reason}, state) do
    cond do
      transient_openai_error?(reason) and state.stream_retries_left > 0 ->
        Logger.warning("Agent stream mid-flight failure; retrying. reason=#{inspect(reason)}")

        Process.sleep(800)

        new_state = %{
          state
          | task_ref: nil,
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

  # Runs in the Task process that just created the stream. For each text
  # delta we (a) forward as `:agent_text_delta` so the LV streams chars
  # into the chat bubble in real time, and (b) accumulate the full text.
  # We also watch for `response.failed` / `error` events — if the upstream
  # reports a failure (e.g. our `/mcp` returned 5xx and the MCP tools/list
  # discovery aborted the run) we surface it as `:stream_failed` instead
  # of letting an empty `:stream_done` get masked by the `(완료)` fallback.
  defp consume_into(stream, run_server_pid) do
    try do
      {final_text, failure} =
        Enum.reduce(stream, {"", nil}, fn event, {acc, failure} ->
          send(run_server_pid, {:stream_event, event})

          failure = failure || extract_failure(event)

          case extract_text_delta(event) do
            nil ->
              {acc, failure}

            piece ->
              send(run_server_pid, {:agent_text_delta, piece})
              {acc <> piece, failure}
          end
        end)

      case failure do
        nil -> send(run_server_pid, {:stream_done, final_text})
        reason -> send(run_server_pid, {:stream_failed, reason})
      end
    rescue
      e -> send(run_server_pid, {:stream_error, e})
    end
  end

  # response.failed: top-level failure with a nested error object.
  defp extract_failure(%{type: "response.failed", data: data}) when is_map(data) do
    case get_in(data, ["response", "error"]) do
      %{"message" => msg} = err when is_binary(msg) -> {:openai_failed, err}
      _ -> {:openai_failed, %{"message" => "response.failed"}}
    end
  end

  # Standalone `error` event (e.g. MCP server unreachable).
  defp extract_failure(%{type: "error", data: %{"error" => err}}) when is_map(err),
    do: {:openai_failed, err}

  defp extract_failure(%{type: "error", data: err}) when is_map(err),
    do: {:openai_failed, err}

  defp extract_failure(_), do: nil

  # Reasoning summary delta/done are the only OpenAI stream events we
  # classify here. Tool calls are broadcast by `Contract.MCP.instrumented/4`
  # (the actual server-side handler, single source of truth). Final assistant
  # text comes from the {:stream_done, text} accumulator in `consume_stream`.
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

  defp extract_text_delta(%{type: "response.output_text.delta", data: %{"delta" => delta}})
       when is_binary(delta),
       do: delta

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
