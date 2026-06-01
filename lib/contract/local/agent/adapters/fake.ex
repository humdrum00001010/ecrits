defmodule Contract.Local.Agent.Adapters.Fake do
  @moduledoc """
  Deterministic local agent adapter for tests and offline UI wiring.
  """

  @behaviour Contract.Local.Agent.Adapter

  @impl true
  def stream_turn(turn, opts \\ []) do
    script = Keyword.get(opts, :script) || default_script(turn)

    stream =
      case Keyword.get(opts, :wait_for) do
        nil -> Stream.map(script, &normalize_event/1)
        message -> blocking_stream(script, message, opts)
      end

    {:ok, stream}
  end

  defp default_script(turn) do
    [
      {:text_delta, "Fake response: "},
      {:text_delta, input_text(turn.input)}
    ]
  end

  defp blocking_stream(script, message, opts) do
    test_pid = Keyword.get(opts, :test_pid)
    timeout = Keyword.get(opts, :timeout, 5_000)

    Stream.resource(
      fn -> :waiting end,
      fn
        :waiting ->
          if is_pid(test_pid), do: send(test_pid, {:fake_adapter_waiting, self()})

          receive do
            ^message -> {Enum.map(script, &normalize_event/1), :done}
          after
            timeout -> {[], :done}
          end

        :done ->
          {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  defp normalize_event({:text_delta, delta}) when is_binary(delta),
    do: %{type: :text_delta, delta: delta}

  defp normalize_event({:tool_call, name, arguments})
       when is_binary(name) and is_map(arguments) do
    %{type: :tool_call, name: name, arguments: arguments}
  end

  defp normalize_event(%{} = event), do: event

  defp normalize_event(other) do
    %{type: :adapter_event, event: inspect(other)}
  end

  defp input_text(input) when is_binary(input), do: input
  defp input_text(%{content: content}) when is_binary(content), do: content
  defp input_text(%{"content" => content}) when is_binary(content), do: content
  defp input_text(input), do: inspect(input)
end
