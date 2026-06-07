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

  alias Ecrits.Doc.Pool
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
  A READ-ONLY workspace handle (`t:ws/0`) for `path`'s already-bound foreground
  agent, or `nil` when none is bound yet. Unlike `attach/2`, this NEVER starts a
  Session or a foreground agent — it only reads the existing roster. Used by an
  OBSERVER LiveView (the extracted chat-rail child) that must NOT race the
  document shell into starting a default-provider agent: it polls this until the
  shell (which owns the provider/model/doc seed) has started + seeded the agent,
  then `subscribe/1`s + `snapshot/1`s through the returned handle.
  """
  @spec foreground_ws(String.t()) :: ws() | nil
  def foreground_ws(path) when is_binary(path) do
    case whereis(canonical_path(path)) do
      pid when is_pid(pid) ->
        case GenServer.call(pid, :foreground_agent) do
          %{id: agent_id} when is_binary(agent_id) ->
            %{
              path: canonical_path(path),
              agent_id: agent_id,
              agent_topic: AcpAgent.topic(agent_id)
            }

          _ ->
            nil
        end

      nil ->
        nil
    end
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

  @doc """
  Delegate a chat turn to the foreground agent. `input` is a bare **string**
  (sugar — the common case) OR a list of multi-modal **content blocks**
  (`%{type: :text | :image | :audio | :file | :doc_ref, …}`, Phase 5). The
  foreground agent normalizes + maps it onto the ACP prompt content shape.
  """
  @spec send_turn(ws(), String.t() | [map()]) :: {:ok, map()} | {:error, term()}
  def send_turn(%{agent_id: agent_id}, input) when is_binary(agent_id) do
    AcpAgent.send_turn(nil, agent_id, input)
  end

  def send_turn(_ws, _input), do: {:error, :no_agent}

  @doc """
  Re-Enter on a queued message: flush the foreground agent's FIFO queue head NOW
  (cancel the in-flight turn + run the head immediately).
  """
  @spec flush_queue(ws()) :: {:ok, map()} | {:error, term()}
  def flush_queue(%{agent_id: agent_id}) when is_binary(agent_id) do
    AcpAgent.flush_queue(agent_id)
  end

  def flush_queue(_ws), do: {:error, :no_agent}

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

  # ── doc ownership + viewers + wasm/NIF routing (Phase 3) ────────────
  #
  # The per-doc `owners` (one agent per doc — invariant 2) and `viewers` (a human
  # LiveView rendering a doc → its browser WASM model is the authority) maps live
  # HERE, in the per-workspace Session, not in the global `Ecrits.Doc.Pool`
  # (Phase 2 parked ownership in the Pool; this is its real home). The Session is
  # also where the wasm/NIF routing decision is made: a doc with a live registered
  # viewer routes to that viewer's browser WASM; otherwise to the server NIF
  # Editor (resolved from the Pool's doc-runtime registry).

  @doc """
  Resolve where a document's authoritative model lives for `path`'s workspace:

    * `{:browser, lv}` — a human viewer is rendering it (its WASM model is
      authority); agent edits route to that LiveView.
    * `{:server, editor}` — no viewer; the server NIF Editor is authority.
    * `{:error, :not_found}` — the doc is not open in this workspace's runtime.

  This is the single wasm/NIF routing decision (design invariant 4): `viewers`
  decides browser-vs-server, the Pool supplies the live server Editor pid.
  """
  @spec route(String.t(), String.t()) ::
          {:browser, pid()} | {:server, pid()} | {:error, :not_found}
  def route(path, document_id) when is_binary(path) and is_binary(document_id) do
    case viewer(path, document_id) do
      lv when is_pid(lv) -> {:browser, lv}
      nil -> Pool.route(document_id)
    end
  end

  @doc """
  The live human viewer (browser WASM authority) for `document_id` in `path`'s
  workspace, or nil. Returns a pid ONLY while the viewer is alive — a dead viewer
  (navigate/close race before its `:DOWN`) reads as nil so the doc falls back to
  its server NIF. The wasm/NIF routing decision is `viewer present? → browser :
  server`; callers that hold their own Pool (tests) compose this with their pool.
  """
  @spec viewer(String.t(), String.t()) :: pid() | nil
  def viewer(path, document_id) when is_binary(path) and is_binary(document_id) do
    case call_if_alive(path, {:viewer, document_id}, nil) do
      lv when is_pid(lv) -> if Process.alive?(lv), do: lv, else: nil
      _ -> nil
    end
  end

  @doc """
  Register `lv` as the human viewer (browser WASM authority) for `document_id` in
  `path`'s workspace. A viewer is the authority for AT MOST ONE doc — attaching
  it to a new doc detaches it from any other it was viewing — so navigating
  between docs in one viewer never leaves a stale browser claim behind. The
  browser becomes authoritative, so subsequent agent edits to this doc route to
  `lv` (its WASM model), not the server NIF copy.
  """
  @spec attach_viewer(String.t(), String.t(), pid()) :: :ok
  def attach_viewer(path, document_id, lv)
      when is_binary(path) and is_binary(document_id) and is_pid(lv) do
    with {:ok, _pid} <- ensure_started(canonical_path(path)) do
      GenServer.call(via(canonical_path(path)), {:attach_viewer, document_id, lv})
    else
      _ -> :ok
    end
  end

  @doc "Relinquish `lv`'s viewer authority over `document_id` (the doc falls back to its server NIF)."
  @spec detach_viewer(String.t(), String.t(), pid()) :: :ok
  def detach_viewer(path, document_id, lv)
      when is_binary(path) and is_binary(document_id) and is_pid(lv) do
    call_if_alive(path, {:detach_viewer, document_id, lv}, :ok)
  end

  @doc """
  Claim `agent_id` as the unique owner of `document_id` (invariant 2). Idempotent
  for the current owner; `{:error, {:owned, other}}` when a DIFFERENT agent owns
  it (so `doc.edit` can refuse and `doc.open` can report `held_by`).
  """
  @spec claim_owner(String.t(), String.t(), String.t()) :: :ok | {:error, {:owned, String.t()}}
  def claim_owner(path, document_id, agent_id)
      when is_binary(path) and is_binary(document_id) and is_binary(agent_id) do
    with {:ok, _pid} <- ensure_started(canonical_path(path)) do
      GenServer.call(via(canonical_path(path)), {:claim_owner, document_id, agent_id})
    else
      _ -> :ok
    end
  end

  @doc "The agent id that owns `document_id` in `path`'s workspace, or nil."
  @spec owner(String.t(), String.t()) :: String.t() | nil
  def owner(path, document_id) when is_binary(path) and is_binary(document_id) do
    call_if_alive(path, {:owner, document_id}, nil)
  end

  @doc "Release `agent_id`'s ownership of `document_id` (no-op if it isn't the owner)."
  @spec release_owner(String.t(), String.t(), String.t()) :: :ok
  def release_owner(path, document_id, agent_id)
      when is_binary(path) and is_binary(document_id) and is_binary(agent_id) do
    call_if_alive(path, {:release_owner, document_id, agent_id}, :ok)
  end

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
       foreground_id: nil,
       # Per-doc ownership (invariant 2): %{document_id => agent_id}. The real home
       # of what Phase 2 temporarily parked in `Ecrits.Doc.Pool`.
       owners: %{},
       # Per-doc human viewers (browser WASM authority): %{document_id => lv_pid}.
       # A viewer here makes `route/2` return `{:browser, lv}` for that doc.
       viewers: %{}
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

  # ── routing + viewers + ownership ──────────────────────────────────
  #
  # Each handler normalises the state first so a HOT-RELOADED Session started
  # before Phase 3 (its state had no `:owners`/`:viewers` keys) gains them on
  # first use instead of crashing the live process — important because the running
  # :4000 server is recompiled in place, not restarted.

  def handle_call({:viewer, document_id}, _from, state) do
    state = ensure_maps(state)
    {:reply, Map.get(state.viewers, document_id), state}
  end

  def handle_call({:attach_viewer, document_id, lv}, _from, state) do
    state = ensure_maps(state)
    Process.monitor(lv)
    # A viewer is the browser authority for AT MOST ONE doc; drop any other doc it
    # was viewing before claiming this one (so navigating between docs in one
    # viewer never leaves a stale browser claim that would misroute an unrelated
    # doc's edits to the currently-open one).
    viewers =
      state.viewers
      |> drop_viewer_everywhere(lv)
      |> Map.put(document_id, lv)

    {:reply, :ok, %{state | viewers: viewers}}
  end

  def handle_call({:detach_viewer, document_id, lv}, _from, state) do
    state = ensure_maps(state)

    viewers =
      case Map.get(state.viewers, document_id) do
        ^lv -> Map.delete(state.viewers, document_id)
        _ -> state.viewers
      end

    {:reply, :ok, %{state | viewers: viewers}}
  end

  def handle_call({:claim_owner, document_id, agent_id}, _from, state) do
    state = ensure_maps(state)

    case Map.get(state.owners, document_id) do
      nil -> {:reply, :ok, %{state | owners: Map.put(state.owners, document_id, agent_id)}}
      ^agent_id -> {:reply, :ok, state}
      other -> {:reply, {:error, {:owned, other}}, state}
    end
  end

  def handle_call({:owner, document_id}, _from, state) do
    state = ensure_maps(state)
    {:reply, Map.get(state.owners, document_id), state}
  end

  def handle_call({:release_owner, document_id, agent_id}, _from, state) do
    state = ensure_maps(state)

    owners =
      case Map.get(state.owners, document_id) do
        ^agent_id -> Map.delete(state.owners, document_id)
        _ -> state.owners
      end

    {:reply, :ok, %{state | owners: owners}}
  end

  @impl true
  # A crashed viewer relinquishes its browser claim on every doc it backed, so
  # those docs fall back to their server Editors.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = ensure_maps(state)
    {:noreply, %{state | viewers: drop_viewer_everywhere(state.viewers, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Backfill the Phase 3 maps onto a state that predates them (a Session GenServer
  # hot-reloaded across the upgrade), so the live process never crashes on a
  # missing key. A no-op once the keys exist.
  defp ensure_maps(state) do
    state
    |> Map.put_new(:owners, %{})
    |> Map.put_new(:viewers, %{})
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

  # Remove `lv`'s viewer claim from EVERY doc it currently backs (a previously-
  # viewed doc it navigated away from, or a crashed viewer's claims).
  defp drop_viewer_everywhere(viewers, lv) do
    viewers
    |> Enum.reject(fn {_doc, viewer} -> viewer == lv end)
    |> Map.new()
  end

  # Stable, cookieless foreground-agent id for a workspace path. Deterministic so
  # a refresh re-derives the SAME id and re-attaches to the SAME agent. Namespaced
  # so it can never collide with a UUID-keyed agent from elsewhere.
  defp foreground_agent_id(path) do
    "fg-" <>
      (:crypto.hash(:sha256, path) |> Base.url_encode64(padding: false) |> binary_part(0, 32))
  end
end
