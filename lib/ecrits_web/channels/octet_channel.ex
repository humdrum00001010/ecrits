defmodule EcritsWeb.OctetChannel do
  @moduledoc """
  Binary ingress for browser document engines. The transfer itself (one
  length-prefixed binary frame per upload, size enforcement, reply-as-ack)
  is `PhoenixOctet.Channel`; this module only says where uploads go: the
  owning LiveView's sink topic on our PubSub.
  """

  use PhoenixOctet.Channel, max_upload_bytes: 256 * 1024 * 1024

  @impl PhoenixOctet.Channel
  def handle_octet(sink_id, id, bytes, _socket) do
    PhoenixOctet.Sink.deliver(Ecrits.PubSub, sink_id, id, bytes)
  end

  # Ordered after any upload pushed before the cancel on the same channel, so
  # the LiveView can drop an upload whose delivery overtook the client's
  # `octet:cancel` cleanup.
  @impl PhoenixOctet.Channel
  def handle_octet_cancelled(sink_id, id, _socket) do
    PhoenixOctet.Sink.deliver_cancel(Ecrits.PubSub, sink_id, id)
  end
end
