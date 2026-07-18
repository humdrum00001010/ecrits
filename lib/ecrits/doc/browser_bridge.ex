defmodule Ecrits.Doc.BrowserBridge do
  @moduledoc """
  Synchronous request/reply bridge to the browser model selected by a workspace session.

  The caller remains responsible for choosing browser versus server authority via
  `Ecrits.Workspace.Session.route/2`. This module only transports a request to an
  already-selected viewer and preserves the apply/save completion boundary. A
  browser reply is acknowledged back to the viewer before `call/4` returns; the
  viewer uses that ACK as the irreversible boundary for browser VFS commits.
  """

  require Logger

  @default_timeout 8_000
  @vfs_pre_upload_budget 30_000
  @octet_upload_timeout 30_000
  @vfs_reply_margin 5_000
  @vfs_write_timeout @vfs_pre_upload_budget + @octet_upload_timeout + @vfs_reply_margin

  @doc """
  Server-side deadline for browser exports used by VFS writeback.

  The server timer starts before browser-side mutation and export, while the
  browser's 30-second octet timer starts only when upload begins. The deadline
  therefore budgets both phases plus a short reply margin so a precise client
  error can make the round trip instead of becoming a generic server timeout.
  """
  @spec vfs_write_timeout() :: pos_integer()
  def vfs_write_timeout, do: @vfs_write_timeout

  @spec call(pid(), atom(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call(lv, verb, payload, opts \\ [])
      when is_pid(lv) and is_atom(verb) and is_map(payload) and is_list(opts) do
    ref = make_ref()
    monitor_ref = Process.monitor(lv)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    expected_document_id =
      Keyword.get(opts, :expected_document_id) || payload[:expected_document_id] ||
        payload["expected_document_id"] || payload[:document_id] || payload["document_id"]

    started_at = System.monotonic_time(:millisecond)

    request =
      if is_binary(expected_document_id) and expected_document_id != "" do
        {:doc_browser_request, self(), ref, verb, payload, expected_document_id}
      else
        {:doc_browser_request, self(), ref, verb, payload}
      end

    send(lv, request)

    try do
      result =
        receive do
          {:doc_browser_reply, ^ref, {:ok, result}} ->
            acknowledge_completion(lv, ref, monitor_ref, {:ok, result})

          {:doc_browser_reply, ^ref, {:error, reason}} ->
            acknowledge_completion(lv, ref, monitor_ref, {:error, reason})

          {:DOWN, ^monitor_ref, :process, ^lv, reason} ->
            {:error, {:browser_unavailable, reason}}
        after
          timeout ->
            send(lv, {:doc_browser_request_cancelled, self(), ref, :timeout})
            {:error, {:browser_timeout, "viewer did not reply in time"}}
        end

      log_timing(verb, result, started_at)
      result
    after
      Process.demonitor(monitor_ref, [:flush])
    end
  end

  defp acknowledge_completion(lv, ref, monitor_ref, result) do
    ack_ref = make_ref()
    send(lv, {:doc_browser_request_completed, self(), ref, ack_ref})

    receive do
      {:doc_browser_request_completion_ack, ^ack_ref, :ok} ->
        result

      {:doc_browser_request_completion_ack, ^ack_ref, {:error, :request_not_pending}} ->
        # Cancellation removes the pending entry immediately after sending its
        # terminal error reply. If completion crosses that removal, preserve
        # the precise cancellation error. Only a successful reply requires the
        # retained entry/ACK boundary before it may escape to the caller.
        case result do
          {:error, _reason} -> result
          {:ok, _reply} -> {:error, {:browser_completion_failed, :request_not_pending}}
        end

      {:doc_browser_request_completion_ack, ^ack_ref, {:error, reason}} ->
        {:error, {:browser_completion_failed, reason}}

      {:DOWN, ^monitor_ref, :process, ^lv, reason} ->
        {:error, {:browser_unavailable, reason}}
    end
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
