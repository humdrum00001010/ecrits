defmodule Contract.Local.Agent.Adapters.ClaudeCLI do
  @moduledoc """
  Claude CLI adapter for local agent sessions.

  Uses real `claude -p` execution. Missing CLI/auth/runtime failures surface as
  turn failures; no canned responses are generated.
  """

  @behaviour Contract.Local.Agent.Adapter

  @default_executable_candidates ["claude"]
  @default_timeout 120_000

  @impl true
  def stream_turn(turn, opts \\ []) do
    with {:ok, executable} <- resolve_executable(opts) do
      {:ok, turn_stream(executable, turn, opts)}
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
      nil -> {:error, {:claude_executable_missing, candidates}}
      executable -> {:ok, executable}
    end
  end

  defp turn_stream(executable, turn, opts) do
    Stream.resource(
      fn ->
        port = open_port(executable, turn, opts)

        %{
          port: port,
          deadline: deadline(Keyword.get(opts, :timeout, @default_timeout)),
          text?: false,
          exit_status: nil
        }
      end,
      &next_event/1,
      fn state -> close_port(state.port) end
    )
  end

  defp next_event(%{port: port, deadline: deadline} = state) do
    receive do
      {^port, {:data, {:eol, data}}} ->
        emit_data(data <> "\n", state)

      {^port, {:data, {:noeol, data}}} ->
        emit_data(data, state)

      {^port, {:exit_status, 0}} ->
        {:halt, %{state | exit_status: 0}}

      {^port, {:exit_status, status}} ->
        if state.text? do
          {:halt, %{state | exit_status: status}}
        else
          fail_turn(state, "claude cli exited before output: #{inspect(status)}")
        end
    after
      remaining(deadline) ->
        fail_turn(state, "claude cli timeout during turn")
    end
  end

  defp emit_data("", state), do: next_event(state)

  defp emit_data(data, state) do
    {[%{type: :text_delta, delta: data}], %{state | text?: true}}
  end

  defp fail_turn(state, message) do
    close_port(state.port)
    raise message
  end

  defp open_port(executable, turn, opts) do
    options = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:args, executable_args(turn, opts)},
      {:cd, working_dir(turn, opts)},
      {:line, 1_000_000}
    ]

    Port.open({:spawn_executable, executable.path}, options)
  end

  defp executable_args(turn, opts) do
    args = [
      "-p",
      input_text(turn.input),
      "--output-format",
      "text",
      "--permission-mode",
      Keyword.get(opts, :permission_mode, "dontAsk"),
      "--effort",
      Keyword.get(opts, :reasoning_effort, "medium")
    ]

    case Keyword.get(opts, :model) do
      nil -> args
      model -> args ++ ["--model", to_string(model)]
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

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

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
