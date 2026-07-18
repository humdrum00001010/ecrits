defmodule Ecrits.Agent.SessionContract do
  @moduledoc """
  Core contract for a per-agent session controller.

  This is a headless GenServer contract, not a Phoenix LiveView. It owns one
  agent conversation, transcript, title, send-turn queue, and PubSub topic.
  The current implementation is `Ecrits.AcpAgent.Session`; a future provider
  can implement the same session contract without joining the web layer.

  The contract deliberately declares only the stable session boundary. The
  generic transcript/queue mechanics remain in `Ecrits.AcpAgent.Session` until
  extracting them would have a concrete second implementation to serve.
  """

  alias Ecrits.Agent.Dialog

  @typedoc "A turn input: bare text or multimodal content blocks."
  @type input :: String.t() | [map()]

  @typedoc "Display-only state used to repaint the chat rail."
  @type snapshot :: %{
          transcript: [Dialog.t()],
          status: :idle | :running | :offline,
          title: String.t() | nil,
          pending: non_neg_integer()
        }

  @callback agent_snapshot(pid()) :: snapshot()

  @callback send_turn(pid(), ctx :: term(), input(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback cancel(pid(), ctx :: term(), turn_id :: String.t() | nil) ::
              {:ok, map()} | {:error, term()}

  @callback flush_queue(pid(), ctx :: term()) :: {:ok, map()} | {:error, term()}

  @callback title(pid()) :: String.t() | nil

  @callback rename(pid(), String.t()) :: :ok

  @callback topic(id :: String.t()) :: String.t()
end
