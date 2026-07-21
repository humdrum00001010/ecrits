defmodule EcritsWeb.EnvProbeAcpAdapter do
  @moduledoc false

  @behaviour ExMCP.ACP.Adapter

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def command(opts), do: Keyword.fetch!(opts, :command)

  @impl true
  def translate_outbound(_message, state), do: {:ok, :skip, state}

  @impl true
  def translate_inbound(_line, state), do: {:skip, state}
end
