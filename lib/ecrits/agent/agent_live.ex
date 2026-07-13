defmodule Ecrits.Agent.AgentLive do
  @moduledoc """
  The extraction-boundary contract for an **AgentLive** — a per-agent CONTROLLER
  (a headless LiveView-idiom GenServer: assigns + handle-event-for-MCP +
  handle-info-for-PubSub) that owns one agent's conversation, transcript, title,
  send-turn FIFO queue, and per-agent topic.

  ## Status (Phase 5): a boundary + note, not a forced refactor

  The concrete AgentLive today is `Ecrits.AcpAgent.Session`. Factoring its
  GENERIC mechanics (transcript append/snapshot, the send-turn FIFO queue, title
  derivation, the `emit/topic` PubSub contract, `agent_snapshot`) into a
  `use Ecrits.Agent.AgentLive` behaviour with overridable callbacks would mean
  restructuring its whole `handle_call`/`handle_info` surface — which is tightly
  coupled to the ACP provider thread (`AcpStream`), the multi-modal `Prompt`
  seam, and the chat-rail event shapes. Per the migration guardrails ("if
  invasive, SKIP it and leave a clear module boundary + a note — don't refactor
  the world"), the full `use`-behaviour extraction is **deliberately deferred**:
  doing it now would put the LIVE chat at risk for a mechanical win.

  This module is that clear boundary. It declares the STABLE public contract a
  generic AgentLive exposes as `@callback`s, so a future repo extraction is
  mechanical: the concrete module already implements every function below with
  the listed arity (`Ecrits.AcpAgent.Session`), and the generic core
  (transcript / queue / title / emit) can later be lifted behind a `__using__/1`
  that provides default implementations of these callbacks, with the
  provider-specific turn driver (`run_turn`/`AcpStream`) as the single override
  point.

  ## The generic ⇄ provider-specific split (the extraction map)

    * GENERIC (lift into `use`): the `transcript`, `queue`, `title`/`title_*`,
      `current` turn bookkeeping, `emit/2` + `topic/1` PubSub contract,
      `agent_snapshot/1`, `record_transcript_turn`, `drain_queue`, the FIFO
      enqueue/flush, and the `Prompt` normalization at the `send_turn` boundary.
    * PROVIDER-SPECIFIC (the override point): `run_turn/4` → `AcpStream` (which ACP
      adapter, how a turn streams), `update_options` adapter-opt merging, and the
      provider/doc seed in `init/1`.

  See `docs/plans/2026-06-07-agentlive-session-architecture.md` (Phase 5) for the
  design rationale.
  """

  @typedoc "A turn input: a bare string (sugar) OR a list of multi-modal content blocks."
  @type input :: String.t() | [map()]

  @typedoc "Display-only snapshot for a chat-rail repaint after a refresh."
  @type snapshot :: %{
          transcript: [map()],
          status: :idle | :running | :offline,
          title: String.t() | nil,
          pending: non_neg_integer()
        }

  @doc "Display-only `%{transcript, status, title, pending}` for a refresh-time repaint."
  @callback agent_snapshot(pid()) :: snapshot()

  @doc "Run a turn with `input` (string sugar OR a multi-modal block list)."
  @callback send_turn(pid(), ctx :: term(), input(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc "Cancel the in-flight turn (optionally guarded by `turn_id`)."
  @callback cancel(pid(), ctx :: term(), turn_id :: String.t() | nil) ::
              {:ok, map()} | {:error, term()}

  @doc "Flush the FIFO queue head NOW (cancel current + run the next queued message)."
  @callback flush_queue(pid(), ctx :: term()) :: {:ok, map()} | {:error, term()}

  @doc "The current chat title (nil before the first-prompt auto-title)."
  @callback title(pid()) :: String.t() | nil

  @doc "Set the chat title explicitly (a user rename)."
  @callback rename(pid(), String.t()) :: :ok

  @doc "The PubSub topic this agent publishes its streamed events on."
  @callback topic(id :: String.t()) :: String.t()
end
