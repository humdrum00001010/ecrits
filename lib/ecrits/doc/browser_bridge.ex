defmodule Ecrits.Doc.BrowserBridge do
  @moduledoc """
  Synchronous request/reply bridge to the browser model selected by a workspace session.

  The caller remains responsible for choosing browser versus server authority via
  `Ecrits.Workspace.Session.route/2`. This module only transports a request to an
  already-selected viewer and preserves the apply/save completion boundary.
  """

  require Logger

  @default_timeout 8_000

  @spec call(pid(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(lv, verb, payload, opts \\ [])
      when is_pid(lv) and is_atom(verb) and is_map(payload) and is_list(opts) do
    ref = make_ref()
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    started_at = System.monotonic_time(:millisecond)
    send(lv, {:doc_browser_request, self(), ref, verb, payload})

    result =
      receive do
        {:doc_browser_reply, ^ref, {:ok, result}} -> {:ok, result}
        {:doc_browser_reply, ^ref, {:error, reason}} -> {:error, reason}
      after
        timeout -> {:error, {:browser_timeout, "viewer did not reply in time"}}
      end

    log_timing(verb, result, started_at)
    result
  end

  defp log_timing(verb, result, started_at) do
    duration_ms = System.monotonic_time(:millisecond) - started_at

    Logger.debug(fn ->
      "[doc_browser_bridge] verb=#{verb} status=#{result_status(result)} duration_ms=#{duration_ms}"
    end)
  end

  defp result_status({:ok, _result}), do: "ok"
  defp result_status({:error, reason}) when is_atom(reason), do: "error:#{reason}"
  defp result_status({:error, _reason}), do: "error"
end
