defmodule Ecrits.Workspace.Session do
  @moduledoc """
  Per-workspace MODEL + directory, keyed by the canonical workspace **path**
  (cookieless — the path is in the URL). This is the durable facade the
  workspace LiveView talks to; it survives the LiveView dying / a browser
  refresh, so re-attaching after a refresh returns the SAME foreground agent
  (same pid, same provider thread, same transcript + title).

  ## Responsibilities (Phase 1)

    * **agents roster** — records the **foreground agent** bound to this
      workspace (`%{agent_id => %{role: :foreground, pid: pid}}`). The foreground
      agent is get-or-started ONCE per path on the first `attach/2`; later
      attaches re-use it.
    * **facade** — `attach/2`, `subscribe/1`, `foreground_agent/1`, `title/1`,
      `send_turn/2`, `cancel/2`, `rename/2`. The turn verbs delegate to the
      foreground agent.

  The Session holds **no live doc handles** and supervises **no agents** — the
  foreground agent is a `Ecrits.Local.AcpAgent.Session` GenServer held under
  `Ecrits.Local.AcpAgent.SessionSupervisor` (durable in its own right), keyed by
  a stable per-workspace agent id derived from the path. The Session is the
  directory that binds path → foreground agent and the single entry point the
  LiveView uses, so a refresh re-attaches rather than recreating anything.

  Later phases extend the roster (background/worker agents), add the
  `viewers`/`owners` maps + the wasm/NIF routing decision, and the doc topic.
  For Phase 1 the doc topic is a stable no-op stub.
  """

  use GenServer

  alias Ecrits.Local.AcpAgent

  @registry Ecrits.Workspace.SessionRegistry
  @supervisor Ecrits.Workspace.SessionSupervisor

  @typedoc "Opaque handle the LiveView holds for a workspace Session."
  @type ws :: %{
          path: String.t(),
          agent_id: String.t() | nil,
          agent_topic: String.t() | nil
        }

  # ── public API ────────────────────────────────────────────────────

  @doc """
  Get-or-start the per-path Session and ensure its foreground agent exists.

  Returns the workspace handle (`t:ws/0`) carrying the canonical path and the
  resolved foreground agent id + topic, so the caller can `subscribe/1` and
  delegate turn verbs. `settings` seed the foreground agent on FIRST attach
  (provider/adapter_opts/workspace_root/document_id); on a later attach (browser
  refresh) the existing agent is re-used and the settings are applied live (next
  turn picks them up) — never recreated.
  """
  @spec attach(String.t(), keyword()) :: {:ok, ws()} | {:error, term()}
  def attach(path, settings \\ []) when is_binary(path) do
    canonical = canonical_path(path)

    with {:ok, _pid} <- ensure_started(canonical) do
      GenServer.call(via(canonical), {:attach, settings})
    end
  end

  @doc """
  CLIENT-side subscribe helper: run in the CALLER (the LiveView process) so the
  caller — not the Session — receives the foreground agent's events. Subscribes
  the caller to the foreground agent's PubSub topic. The doc topic is a no-op
  stub this phase.
  """
  @spec subscribe(ws()) :: :ok
  def subscribe(%{agent_id: agent_id}) when is_binary(agent_id) do
    AcpAgent.subscribe(agent_id)
  end

  def subscribe(_ws), do: :ok

  @doc "The foreground agent handle (`%{id, pid}`) bound to this workspace, or nil."
  @spec foreground_agent(ws()) :: %{id: String.t(), pid: pid()} | nil
  def foreground_agent(%{path: path}) do
    call_if_alive(path, :foreground_agent, nil)
  end

  @doc """
  Resolve a per-agent id (from a `/mcp/doc-tools/<agent_id>` URL) to the live
  AgentLive pid — the MCP-isolation seam (design invariant 3). A `doc.*` tool
  call carries its calling agent's id in the URL; the MCP server resolves it
  here, then dispatches the tool in THAT agent's context.

  Returns `{:ok, pid}` when the agent is registered and alive, `:error`
  otherwise (unknown / dead id → the tool call is rejected, never silently run
  against a global default). The `AcpAgent` registry is the authoritative roster
  of live agents (only started agents are registered), so registry-liveness IS
  the in-roster check this phase.
  """
  @spec fetch_agent(String.t()) :: {:ok, pid()} | :error
  def fetch_agent(agent_id) when is_binary(agent_id) and agent_id != "" do
    case AcpAgent.whereis(agent_id) do
      pid when is_pid(pid) -> {:ok, pid}
      _ -> :error
    end
  end

  def fetch_agent(_agent_id), do: :error

  @doc "The foreground agent's current chat title (derived from the first prompt)."
  @spec title(ws()) :: String.t() | nil
  def title(%{agent_id: agent_id}) when is_binary(agent_id) do
    AcpAgent.title(agent_id)
  end

  def title(_ws), do: nil

  @doc """
  Display-only snapshot of the foreground agent: `%{transcript, status, title}`.
  Used by the LiveView to repaint the chat pane after a browser refresh.
  """
  @spec snapshot(ws()) :: %{transcript: list(), status: atom(), title: String.t() | nil}
  def snapshot(%{agent_id: agent_id}) when is_binary(agent_id) do
    AcpAgent.agent_snapshot(agent_id)
  end

  def snapshot(_ws), do: %{transcript: [], status: :offline, title: nil}

  @doc "Delegate a chat turn to the foreground agent."
  @spec send_turn(ws(), String.t()) :: {:ok, map()} | {:error, term()}
  def send_turn(%{agent_id: agent_id}, message) when is_binary(agent_id) do
    AcpAgent.send_turn(nil, agent_id, message)
  end

  def send_turn(_ws, _message), do: {:error, :no_agent}

  @doc "Cancel the foreground agent's in-flight turn."
  @spec cancel(ws(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def cancel(%{agent_id: agent_id}, turn_id \\ nil) when is_binary(agent_id) do
    AcpAgent.cancel(nil, agent_id, turn_id)
  end

  @doc """
  Rename the foreground agent's chat thread. Marks the title user-edited so the
  first-prompt auto-title never overrides it afterwards.
  """
  @spec rename(ws(), String.t()) :: :ok | {:error, term()}
  def rename(%{agent_id: agent_id}, title) when is_binary(agent_id) do
    AcpAgent.rename(agent_id, title)
  end

  def rename(_ws, _title), do: {:error, :no_agent}

  @doc """
  Apply per-turn option changes (provider model / reasoning / access / active
  document) to the foreground agent live, preserving the conversation.
  """
  @spec update_options(ws(), keyword()) :: :ok | {:error, term()}
  def update_options(%{agent_id: agent_id}, adapter_opts)
      when is_binary(agent_id) and is_list(adapter_opts) do
    AcpAgent.update_session_options(agent_id, adapter_opts)
  end

  def update_options(_ws, _opts), do: {:error, :no_agent}

  @doc "Stable doc-topic for this workspace (Phase 1 stub — nothing publishes on it yet)."
  @spec doc_topic(String.t()) :: String.t()
  def doc_topic(path) when is_binary(path), do: "workspace_doc:" <> canonical_path(path)

  @doc "Canonicalize a workspace path so the key is stable regardless of trailing slash etc."
  @spec canonical_path(String.t()) :: String.t()
  def canonical_path(path) when is_binary(path), do: Path.expand(path)

  @doc "Whereis the per-path Session GenServer (nil when none)."
  def whereis(path) when is_binary(path) do
    case Registry.lookup(@registry, canonical_path(path)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # ── lifecycle ──────────────────────────────────────────────────────

  def start_link(opts) do
    path = Keyword.fetch!(opts, :path)
    GenServer.start_link(__MODULE__, opts, name: via(path))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :path)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    }
  end

  defp via(path), do: {:via, Registry, {@registry, path}}

  defp ensure_started(path) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, path: path}) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_if_alive(path, msg, default) do
    case whereis(path) do
      pid when is_pid(pid) -> GenServer.call(pid, msg)
      nil -> default
    end
  end

  # ── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %{
       path: Keyword.fetch!(opts, :path),
       # agents roster: %{agent_id => %{role: :foreground, pid: pid}}
       agents: %{},
       foreground_id: nil
     }}
  end

  @impl true
  def handle_call({:attach, settings}, _from, state) do
    case ensure_foreground_agent(state, settings) do
      {:ok, state, %{id: agent_id}} ->
        ws = %{path: state.path, agent_id: agent_id, agent_topic: AcpAgent.topic(agent_id)}
        {:reply, {:ok, ws}, state}

      {:error, reason} ->
        ws = %{path: state.path, agent_id: nil, agent_topic: nil}
        {:reply, {:error, reason, ws}, state}
    end
  end

  def handle_call(:foreground_agent, _from, state) do
    {:reply, current_foreground(state), state}
  end

  # ── foreground-agent binding ───────────────────────────────────────

  # Get-or-start the foreground agent for this workspace. The agent is keyed by a
  # stable per-workspace id derived from the path, so a re-attach (browser
  # refresh) returns the SAME `Ecrits.Local.AcpAgent.Session` pid — preserving its
  # provider thread, transcript, and title. Only the first attach starts it; a
  # later attach re-uses the existing pid and applies the live settings.
  defp ensure_foreground_agent(state, settings) do
    case current_foreground(state) do
      %{id: agent_id} = fg ->
        _ = maybe_apply_settings(agent_id, settings)
        {:ok, state, fg}

      nil ->
        agent_id = foreground_agent_id(state.path)
        opts = Keyword.put(settings, :id, agent_id)

        case AcpAgent.start_session(nil, opts) do
          {:ok, %{id: ^agent_id}} ->
            pid = AcpAgent.whereis(agent_id)

            state = %{
              state
              | foreground_id: agent_id,
                agents: Map.put(state.agents, agent_id, %{role: :foreground, pid: pid})
            }

            {:ok, state, %{id: agent_id, pid: pid}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Resolve the foreground agent freshly from the registry each time so a roster
  # entry whose pid died (agent crash) is treated as absent and re-started.
  defp current_foreground(%{foreground_id: nil}), do: nil

  defp current_foreground(%{foreground_id: agent_id}) do
    case AcpAgent.whereis(agent_id) do
      pid when is_pid(pid) -> %{id: agent_id, pid: pid}
      nil -> nil
    end
  end

  defp maybe_apply_settings(_agent_id, []), do: :ok

  defp maybe_apply_settings(agent_id, settings) do
    case Keyword.get(settings, :adapter_opts) do
      opts when is_list(opts) and opts != [] ->
        live_opts =
          opts
          |> maybe_put_setting(settings, :document_id)
          |> maybe_put_setting(settings, :pool_document_id)

        AcpAgent.update_session_options(agent_id, live_opts)

      _ ->
        :ok
    end
  end

  # Forward a non-empty seed setting (document_id / pool_document_id) onto the
  # live-update opts so a re-attach follows the doc the workspace is now viewing.
  defp maybe_put_setting(opts, settings, key) do
    case Keyword.get(settings, key) do
      value when is_binary(value) and value != "" -> Keyword.put(opts, key, value)
      _ -> opts
    end
  end

  # Stable, cookieless foreground-agent id for a workspace path. Deterministic so
  # a refresh re-derives the SAME id and re-attaches to the SAME agent. Namespaced
  # so it can never collide with a UUID-keyed agent from elsewhere.
  defp foreground_agent_id(path) do
    "fg-" <>
      (:crypto.hash(:sha256, path) |> Base.url_encode64(padding: false) |> binary_part(0, 32))
  end
end
