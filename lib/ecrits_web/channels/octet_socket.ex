defmodule EcritsWeb.OctetSocket do
  @moduledoc """
  Transport socket for the general binary ingress channel (`EcritsWeb.OctetChannel`).

  Separate from the LiveView socket because `Phoenix.LiveView.Socket` routes a
  fixed set of topics; binary document uploads get their own multiplexed
  websocket. Local-only app: the join is gated by the unguessable per-LiveView
  sink id, not by socket auth.
  """

  use Phoenix.Socket

  channel "octet:*", EcritsWeb.OctetChannel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
