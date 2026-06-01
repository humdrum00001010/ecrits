defmodule Contract.Local.Agent.Adapters.Unavailable do
  @moduledoc """
  Adapter used when a real ACP provider is registered but not implemented.
  """

  @behaviour Contract.Local.Agent.Adapter

  @impl true
  def stream_turn(_turn, opts \\ []) do
    provider = Keyword.get(opts, :provider, "provider")
    reason = Keyword.get(opts, :reason, "#{provider} ACP adapter is unavailable.")

    {:error, {:provider_unavailable, provider, reason}}
  end
end
