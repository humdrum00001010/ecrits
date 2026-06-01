defmodule Contract.Local.Agent.Endpoint do
  @moduledoc """
  Public compatibility facade for local ACP-backed agent sessions.
  """

  alias Contract.Local.ACP

  def start_session(ctx, opts \\ []) when is_list(opts), do: ACP.start_session(ctx, opts)

  def send_turn(ctx, session_id, input, opts \\ []),
    do: ACP.send_turn(ctx, session_id, input, opts)

  def cancel(ctx, session_id, turn_id \\ nil), do: ACP.cancel(ctx, session_id, turn_id)

  def approve_tool_call(ctx, session_id, tool_call_id) do
    ACP.approve_tool_call(ctx, session_id, tool_call_id)
  end

  def reject_tool_call(ctx, session_id, tool_call_id) do
    ACP.reject_tool_call(ctx, session_id, tool_call_id)
  end

  def status(ctx, session_id), do: ACP.status(ctx, session_id)
  def subscribe(session_id) when is_binary(session_id), do: ACP.subscribe(session_id)

  def providers, do: ACP.providers()
  def provider_metadata, do: providers()

  def topic(session_id), do: ACP.topic(session_id)
  def whereis(session_id), do: ACP.whereis(session_id)
end
