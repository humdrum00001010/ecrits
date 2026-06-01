defmodule Contract.Local.Agent.Adapters.CodexAppServer do
  @moduledoc """
  Codex app-server / ACP adapter for local agent sessions.

  This adapter speaks Codex app-server JSON-RPC over stdio. It never fabricates
  success: missing executables, protocol errors, failed turns, and timeouts all
  return explicit errors to `Contract.Local.Agent.Session`.
  """

  @behaviour Contract.Local.Agent.Adapter

  alias Contract.Local.Agent.ToolRegistry

  @default_executable_candidates ["codex-acp", "codex"]
  @default_timeout 120_000
  @turn_start_request_id 3

  @impl true
  def stream_turn(turn, opts \\ []) do
    with {:ok, executable} <- resolve_executable(opts),
         {:ok, stream} <- start_turn_stream(executable, turn, opts) do
      {:ok, stream}
    end
  end

  def resolve_executable(opts \\ []) do
    candidates = executable_candidates(opts)

    found =
      Enum.find_value(candidates, fn candidate ->
        case resolve_candidate(candidate) do
          {:ok, path} -> %{path: path, command: candidate}
          :error -> nil
        end
      end)

    case found do
      nil -> {:error, {:codex_executable_missing, candidates}}
      executable -> {:ok, executable}
    end
  end

  defp start_turn_stream(executable, turn, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cwd = working_dir(turn, opts)
    port = open_port(executable, cwd, opts)

    try do
      result =
        with {:ok, _init} <- request(port, 1, "initialize", initialize_params(), timeout),
             {:ok, thread} <-
               request(port, 2, "thread/start", thread_params(cwd, turn, opts), timeout),
             {:ok, thread_id} <- thread_id(thread),
             :ok <-
               send_json(port, %{
                 id: @turn_start_request_id,
                 method: "turn/start",
                 params: turn_params(thread_id, turn, cwd, opts)
               }) do
          {:ok, turn_stream(port, thread_id, timeout, turn)}
        end

      case result do
        {:ok, _stream} = ok ->
          ok

        {:error, _reason} = error ->
          close_port(port)
          error
      end
    rescue
      e ->
        close_port(port)
        {:error, {:codex_app_server_exception, Exception.message(e)}}
    end
  end

  defp request(port, id, method, params, timeout) do
    case send_json(port, %{id: id, method: method, params: params}) do
      :ok -> await_response(port, id, method, deadline(timeout))
      {:error, _reason} = error -> error
    end
  end

  defp await_response(port, id, method, deadline) do
    receive do
      {^port, {:data, data}} ->
        case decode_data(data) do
          %{"id" => ^id, "result" => result} ->
            {:ok, result}

          %{"id" => ^id, "error" => error} ->
            {:error, {:codex_app_server_request_failed, method, error}}

          _other ->
            await_response(port, id, method, deadline)
        end

      {^port, {:exit_status, status}} ->
        {:error, {:codex_app_server_exit, status, method}}
    after
      remaining(deadline) ->
        {:error, {:codex_app_server_timeout, method}}
    end
  end

  defp turn_stream(port, thread_id, timeout, turn) do
    Stream.resource(
      fn ->
        %{
          port: port,
          thread_id: thread_id,
          turn_id: nil,
          deadline: deadline(timeout),
          saw_delta?: false,
          last_error: nil,
          turn: turn
        }
      end,
      &next_turn_event/1,
      fn state -> close_port(state.port) end
    )
  end

  defp next_turn_event(state) do
    %{port: port, thread_id: thread_id, deadline: deadline} = state

    receive do
      {^port, {:data, data}} ->
        message = decode_data(data)

        case handle_turn_start_response(message, state) do
          {:handled, state} ->
            next_turn_event(state)

          {:error, reason, state} ->
            fail_turn(state, "codex turn failed: #{inspect(reason)}")

          :not_server_request ->
            case handle_server_request(message, state) do
              {:handled, state} ->
                next_turn_event(state)

              {:error, reason, state} ->
                fail_turn(state, "codex request handling failed: #{inspect(reason)}")

              :not_server_request ->
                with {:ok, state} <- bind_turn_id(message, state) do
                  message
                  |> codex_event(thread_id, state.turn_id, state)
                  |> case do
                    {:event, event, state} ->
                      {[event], state}

                    {:skip, state} ->
                      next_turn_event(state)

                    {:halt, state} ->
                      {:halt, state}

                    {:error, reason, state} ->
                      fail_turn(
                        state,
                        "codex turn failed: #{inspect(reason || state.last_error)}"
                      )
                  end
                else
                  {:error, reason, state} ->
                    fail_turn(state, "codex turn failed: #{inspect(reason)}")
                end
            end
        end

      {^port, {:exit_status, status}} ->
        fail_turn(state, "codex app-server exited during turn: #{inspect(status)}")
    after
      remaining(deadline) ->
        fail_turn(state, "codex app-server timeout during turn")
    end
  end

  defp fail_turn(state, message) do
    close_port(state.port)
    raise message
  end

  defp handle_turn_start_response(%{"id" => @turn_start_request_id, "result" => result}, state) do
    with {:ok, turn_id} <- turn_id(result),
         {:ok, state} <- put_turn_id(state, turn_id) do
      {:handled, state}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_turn_start_response(%{"id" => @turn_start_request_id, "error" => error}, state) do
    {:error, {:codex_app_server_request_failed, "turn/start", error}, state}
  end

  defp handle_turn_start_response(_message, _state), do: :not_server_request

  defp bind_turn_id(message, state) do
    case event_turn_id(message, state.thread_id) do
      nil -> {:ok, state}
      turn_id -> put_turn_id(state, turn_id)
    end
  end

  defp put_turn_id(%{turn_id: nil} = state, turn_id) when is_binary(turn_id),
    do: {:ok, %{state | turn_id: turn_id}}

  defp put_turn_id(%{turn_id: turn_id} = state, turn_id) when is_binary(turn_id),
    do: {:ok, state}

  defp put_turn_id(state, other_turn_id),
    do: {:error, {:codex_app_server_unexpected_turn_id, other_turn_id, state.turn_id}}

  defp event_turn_id(
         %{"params" => %{"threadId" => thread_id, "turnId" => turn_id}},
         thread_id
       )
       when is_binary(turn_id),
       do: turn_id

  defp event_turn_id(
         %{"params" => %{"threadId" => thread_id, "turn" => %{"id" => turn_id}}},
         thread_id
       )
       when is_binary(turn_id),
       do: turn_id

  defp event_turn_id(_message, _thread_id), do: nil

  defp codex_event(
         %{
           "method" => "item/agentMessage/delta",
           "params" => %{"threadId" => thread_id, "turnId" => turn_id, "delta" => delta}
         },
         thread_id,
         turn_id,
         state
       )
       when is_binary(delta) and delta != "" do
    {:event, %{type: :text_delta, delta: delta}, %{state | saw_delta?: true}}
  end

  defp codex_event(
         %{
           "method" => "item/started",
           "params" => %{"threadId" => thread_id, "turnId" => turn_id, "item" => item}
         },
         thread_id,
         turn_id,
         state
       )
       when is_map(item) do
    case provider_tool_started(item) do
      nil -> {:skip, state}
      event -> {:event, event, state}
    end
  end

  defp codex_event(
         %{
           "method" => "item/completed",
           "params" => %{
             "threadId" => thread_id,
             "turnId" => turn_id,
             "item" => %{"type" => "agentMessage", "text" => text}
           }
         },
         thread_id,
         turn_id,
         %{saw_delta?: false} = state
       )
       when is_binary(text) and text != "" do
    {:event, %{type: :text_delta, delta: text}, state}
  end

  defp codex_event(
         %{
           "method" => "item/completed",
           "params" => %{"threadId" => thread_id, "turnId" => turn_id, "item" => item}
         },
         thread_id,
         turn_id,
         state
       )
       when is_map(item) do
    case provider_tool_completed(item) do
      nil -> {:skip, state}
      event -> {:event, event, state}
    end
  end

  defp codex_event(
         %{
           "method" => "error",
           "params" => %{"error" => error, "threadId" => thread_id, "turnId" => turn_id}
         },
         thread_id,
         turn_id,
         state
       ) do
    {:skip, %{state | last_error: error}}
  end

  defp codex_event(
         %{
           "method" => "error",
           "params" => %{"error" => error, "threadId" => thread_id}
         },
         thread_id,
         _turn_id,
         state
       ) do
    {:skip, %{state | last_error: error}}
  end

  defp codex_event(
         %{
           "method" => "turn/completed",
           "params" => %{
             "threadId" => thread_id,
             "turn" => %{"id" => turn_id, "status" => "completed"}
           }
         },
         thread_id,
         turn_id,
         state
       ) do
    {:halt, state}
  end

  defp codex_event(
         %{
           "method" => "turn/completed",
           "params" => %{"threadId" => thread_id, "turn" => %{"id" => turn_id} = turn}
         },
         thread_id,
         turn_id,
         state
       ) do
    {:error, state.last_error || Map.get(turn, "error") || turn, state}
  end

  defp codex_event(_message, _thread_id, _turn_id, state), do: {:skip, state}

  defp handle_server_request(
         %{"id" => request_id, "method" => "item/tool/call", "params" => params},
         state
       )
       when is_map(params) do
    response = dynamic_tool_response(state.turn, params)

    case send_json(state.port, %{id: request_id, result: response}) do
      :ok -> {:handled, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp handle_server_request(_message, _state), do: :not_server_request

  defp dynamic_tool_response(turn, params) do
    name = join_tool_name(Map.get(params, "namespace"), Map.get(params, "tool"))
    arguments = Map.get(params, "arguments") || %{}

    case ToolRegistry.call(Map.get(turn, :tool_context, %{}), name, arguments) do
      {:ok, result} ->
        %{
          success: true,
          contentItems: [%{type: "inputText", text: tool_result_text(result)}]
        }

      {:error, reason} ->
        %{
          success: false,
          contentItems: [%{type: "inputText", text: inspect(reason)}]
        }
    end
  end

  defp provider_tool_started(%{"type" => "commandExecution", "id" => id} = item) do
    %{
      type: :tool_call_started,
      tool_call_id: id,
      name: "command.exec",
      arguments: %{
        "command" => Map.get(item, "command"),
        "cwd" => Map.get(item, "cwd")
      }
    }
  end

  defp provider_tool_started(%{"type" => "mcpToolCall", "id" => id} = item) do
    server = Map.get(item, "server")
    tool = Map.get(item, "tool")

    %{
      type: :tool_call_started,
      tool_call_id: id,
      name: join_tool_name(server, tool),
      arguments: Map.get(item, "arguments") || %{}
    }
  end

  defp provider_tool_started(%{"type" => "dynamicToolCall", "id" => id} = item) do
    namespace = Map.get(item, "namespace")
    tool = Map.get(item, "tool")

    %{
      type: :tool_call_started,
      tool_call_id: id,
      name: join_tool_name(namespace, tool),
      arguments: Map.get(item, "arguments") || %{}
    }
  end

  defp provider_tool_started(_item), do: nil

  defp provider_tool_completed(%{"type" => "commandExecution", "id" => id} = item) do
    name = "command.exec"

    if Map.get(item, "status") == "completed" and Map.get(item, "exitCode") in [0, nil] do
      %{
        type: :tool_call_completed,
        tool_call_id: id,
        name: name,
        result: %{
          "exit_code" => Map.get(item, "exitCode"),
          "output" => Map.get(item, "aggregatedOutput")
        }
      }
    else
      %{
        type: :tool_call_failed,
        tool_call_id: id,
        name: name,
        reason:
          inspect(%{
            "status" => Map.get(item, "status"),
            "exit_code" => Map.get(item, "exitCode"),
            "output" => Map.get(item, "aggregatedOutput")
          })
      }
    end
  end

  defp provider_tool_completed(%{"type" => "mcpToolCall", "id" => id} = item) do
    name = join_tool_name(Map.get(item, "server"), Map.get(item, "tool"))

    if Map.get(item, "error") do
      %{
        type: :tool_call_failed,
        tool_call_id: id,
        name: name,
        reason: inspect(Map.get(item, "error"))
      }
    else
      %{
        type: :tool_call_completed,
        tool_call_id: id,
        name: name,
        result: Map.get(item, "result") || %{}
      }
    end
  end

  defp provider_tool_completed(%{"type" => "dynamicToolCall", "id" => id} = item) do
    name = join_tool_name(Map.get(item, "namespace"), Map.get(item, "tool"))

    if Map.get(item, "success") == false do
      %{
        type: :tool_call_failed,
        tool_call_id: id,
        name: name,
        reason: inspect(Map.get(item, "contentItems") || Map.get(item, "status"))
      }
    else
      %{
        type: :tool_call_completed,
        tool_call_id: id,
        name: name,
        result: Map.get(item, "contentItems") || %{}
      }
    end
  end

  defp provider_tool_completed(_item), do: nil

  defp join_tool_name(nil, tool) when is_binary(tool), do: tool
  defp join_tool_name("", tool) when is_binary(tool), do: tool

  defp join_tool_name(prefix, tool) when is_binary(prefix) and is_binary(tool),
    do: prefix <> "." <> tool

  defp join_tool_name(_prefix, tool) when is_binary(tool), do: tool
  defp join_tool_name(prefix, _tool) when is_binary(prefix), do: prefix
  defp join_tool_name(_prefix, _tool), do: "tool"

  defp send_json(port, payload) do
    Port.command(port, Jason.encode!(payload) <> "\n")
    :ok
  rescue
    ArgumentError -> {:error, :codex_app_server_port_closed}
  end

  defp open_port(executable, cwd, opts) do
    options = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, executable_args(executable, opts)},
      {:cd, cwd},
      {:line, 1_000_000}
    ]

    env = Keyword.get(opts, :env, [])

    options =
      if env == [] do
        options
      else
        [{:env, normalize_env(env)} | options]
      end

    Port.open({:spawn_executable, executable.path}, options)
  end

  defp executable_args(executable, opts) do
    case Keyword.get(opts, :args) do
      args when is_list(args) ->
        Enum.map(args, &to_string/1)

      _ ->
        case Path.basename(executable.path) do
          "codex" -> codex_app_server_args(opts)
          _other -> []
        end
    end
  end

  defp codex_app_server_args(opts) do
    config_args =
      []
      |> maybe_config_arg("model_reasoning_effort", Keyword.get(opts, :reasoning_effort))
      |> maybe_config_arg("model", Keyword.get(opts, :model))

    config_args ++ ["app-server", "--listen", "stdio://"]
  end

  defp maybe_config_arg(args, _key, nil), do: args

  defp maybe_config_arg(args, key, value) do
    args ++ ["-c", "#{key}=#{inspect(to_string(value))}"]
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp decode_data({:eol, data}), do: decode_line(data)
  defp decode_data({:noeol, data}), do: decode_line(data)
  defp decode_data(data), do: decode_line(data)

  defp decode_line(line) when is_binary(line) do
    line
    |> String.trim()
    |> Jason.decode()
    |> case do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp initialize_params do
    %{
      clientInfo: %{
        name: "contract-local-agent",
        title: nil,
        version: Application.spec(:contract, :vsn) |> to_string()
      },
      capabilities: %{experimentalApi: true, requestAttestation: false}
    }
  end

  defp thread_params(cwd, turn, opts) do
    %{
      cwd: cwd,
      approvalPolicy: codex_approval_policy(Keyword.get(opts, :approval_policy)),
      sandbox: Keyword.get(opts, :sandbox, "read-only"),
      reasoningEffort: Keyword.get(opts, :reasoning_effort, "medium"),
      ephemeral: Keyword.get(opts, :ephemeral, true),
      developerInstructions:
        Keyword.get(
          opts,
          :developer_instructions,
          "Answer the user's local Contract workspace request. Do not edit files unless explicitly asked."
        )
    }
    |> maybe_put(:model, Keyword.get(opts, :model))
    |> maybe_put(:dynamicTools, dynamic_tool_specs(Map.get(turn, :tools)))
  end

  defp turn_params(thread_id, turn, cwd, opts) do
    %{
      threadId: thread_id,
      cwd: cwd,
      approvalPolicy: codex_approval_policy(Keyword.get(opts, :approval_policy)),
      input: [%{type: "text", text: input_text(turn.input), text_elements: []}]
    }
  end

  defp codex_approval_policy(nil), do: "never"
  defp codex_approval_policy(:never), do: "never"
  defp codex_approval_policy(:on_write), do: "on-request"
  defp codex_approval_policy(:always), do: "on-request"
  defp codex_approval_policy(:on_request), do: "on-request"
  defp codex_approval_policy(:on_failure), do: "on-failure"

  defp codex_approval_policy(policy) when is_atom(policy) do
    policy
    |> Atom.to_string()
    |> codex_approval_policy()
  end

  defp codex_approval_policy("on_write"), do: "on-request"
  defp codex_approval_policy("always"), do: "on-request"
  defp codex_approval_policy("on_request"), do: "on-request"
  defp codex_approval_policy("on-request"), do: "on-request"
  defp codex_approval_policy("on_failure"), do: "on-failure"
  defp codex_approval_policy("on-failure"), do: "on-failure"
  defp codex_approval_policy("untrusted"), do: "untrusted"
  defp codex_approval_policy("never"), do: "never"
  defp codex_approval_policy(policy), do: policy

  defp thread_id(%{"thread" => %{"id" => id}}) when is_binary(id), do: {:ok, id}
  defp thread_id(other), do: {:error, {:codex_app_server_missing_thread_id, other}}

  defp turn_id(%{"turn" => %{"id" => id}}) when is_binary(id), do: {:ok, id}
  defp turn_id(other), do: {:error, {:codex_app_server_missing_turn_id, other}}

  defp executable_candidates(opts) do
    cond do
      is_binary(Keyword.get(opts, :executable)) ->
        [Keyword.fetch!(opts, :executable)]

      is_list(Keyword.get(opts, :executable_candidates)) ->
        Keyword.fetch!(opts, :executable_candidates)

      true ->
        @default_executable_candidates
    end
  end

  defp resolve_candidate(candidate) when is_binary(candidate) and candidate != "" do
    if String.contains?(candidate, "/") do
      path = Path.expand(candidate)
      if File.regular?(path), do: {:ok, path}, else: :error
    else
      case System.find_executable(candidate) do
        nil -> :error
        path -> {:ok, path}
      end
    end
  end

  defp resolve_candidate(_candidate), do: :error

  defp working_dir(turn, opts) do
    cond do
      is_binary(Keyword.get(opts, :cwd)) ->
        Keyword.fetch!(opts, :cwd)

      is_binary(turn.workspace_root) and Path.type(turn.workspace_root) == :absolute and
          File.dir?(turn.workspace_root) ->
        turn.workspace_root

      is_binary(turn.document_id) and Path.type(turn.document_id) == :absolute and
          File.dir?(turn.document_id) ->
        turn.document_id

      true ->
        File.cwd!()
    end
  end

  defp input_text(input) when is_binary(input), do: input
  defp input_text(%{content: content}) when is_binary(content), do: content
  defp input_text(%{"content" => content}) when is_binary(content), do: content
  defp input_text(input), do: inspect(input)

  defp dynamic_tool_specs(tools) when is_list(tools) and tools != [] do
    Enum.map(tools, fn tool ->
      {namespace, name} =
        codex_dynamic_tool_identity(Map.get(tool, "namespace"), Map.fetch!(tool, "name"))

      %{
        name: name,
        description: Map.get(tool, "description") || "",
        inputSchema: Map.get(tool, "inputSchema") || %{}
      }
      |> maybe_put(:namespace, namespace)
    end)
  end

  defp dynamic_tool_specs(_tools), do: nil

  defp codex_dynamic_tool_identity(namespace, name)
       when is_binary(namespace) and namespace != "" do
    {namespace, name}
  end

  defp codex_dynamic_tool_identity(_namespace, name) when is_binary(name) do
    case String.split(name, ".", parts: 2) do
      [namespace, tool_name] when namespace != "" and tool_name != "" -> {namespace, tool_name}
      _other -> {nil, name}
    end
  end

  defp tool_result_text(result) do
    Jason.encode!(result)
  rescue
    _ -> inspect(result)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_env(env) do
    Enum.map(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
