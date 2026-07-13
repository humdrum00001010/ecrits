# [deprecated] dead module — nothing calls Ecrits.Env anywhere (lib/test/config);
# config/config.exs re-implements the .env loading inline (dead-code audit 2026-07-13)
defmodule Ecrits.Env do
  @moduledoc """
  Minimal `.env` loader used at application boot in dev/test.

  Production reads from real environment variables. In dev/test this module
  hydrates `System` env vars from a `.env` file at the project root so config
  reads (`System.get_env/1`) work identically across environments.

  The same logic runs at the top of `config/config.exs` so that
  `System.get_env` calls inside `config/dev.exs` and `config/test.exs`
  see values during config compilation.
  """

  @spec load!(Path.t()) :: :ok
  def load!(path \\ Path.expand(".env")) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.each(&put_line/1)
    end

    :ok
  end

  @spec fetch!(String.t()) :: String.t()
  def fetch!(key) do
    case System.get_env(key) do
      nil -> raise "missing required env var: #{key}"
      "" -> raise "missing required env var: #{key}"
      value -> value
    end
  end

  @spec get(String.t(), String.t() | nil) :: String.t() | nil
  def get(key, default \\ nil), do: System.get_env(key, default)

  defp put_line(line) do
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        key = String.trim(key)

        value =
          value
          |> String.trim()
          |> String.trim_leading("\"")
          |> String.trim_trailing("\"")

        if System.get_env(key) in [nil, ""] do
          System.put_env(key, value)
        end

      _ ->
        :ok
    end
  end
end
