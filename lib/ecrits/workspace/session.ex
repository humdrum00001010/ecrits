defmodule Ecrits.Workspace.Session do
  @moduledoc """
  Per-workspace MODEL + directory, keyed by the canonical workspace **path**.
  This is the durable facade the workspace LiveView talks to. Foreground chat
  rails are keyed by the caller LiveView process pid, while the Phoenix browser
  session id only scopes the recent-conversation list.

  ## Responsibilities (Phase 1)

    * **agents roster** — records the foreground agents bound to this workspace
      (`%{agent_id => %{role: :foreground, pid: pid}}`). Each LiveView process
      gets its own active foreground rail; completed rails remain selectable in
      the same browser session's recent list.
    * **facade** — `attach/2`, `subscribe/1`, `foreground_agent/1`, `title/1`,
      `send_turn/2`, `cancel/2`, `rename/2`. The turn verbs delegate to the
      foreground agent.

  The Session holds **no live doc handles** and supervises **no agents** — the
  foreground agent is a `Ecrits.AcpAgent.Session` GenServer held under
  `Ecrits.AcpAgent.SessionSupervisor` (durable in its own right). The
  Session is the directory that binds path + LiveView pid → foreground agent and
  the single entry point the LiveView uses.

  Later phases extend the roster (background/worker agents), add the
  `viewers`/`owners` maps + the wasm/NIF routing decision, and the doc topic.
  For Phase 1 the doc topic is a stable no-op stub.
  """

  use GenServer

  alias Ecrits.Doc.Pool
  alias Ecrits.AcpAgent
  alias Ecrits.Workspace.Session.{Agent, Document}

  @registry Ecrits.Workspace.SessionRegistry
  @supervisor Ecrits.Workspace.SessionSupervisor
  @pubsub Ecrits.PubSub
  @default_live_session_id "__default__"
  @max_recent_foregrounds 12

  @type agent :: Agent.t()
  @type agent_ref :: Agent.ref()
  @type document :: Document.t()

  @typedoc "Internal persisted workspace-session state."
  @type t :: %{
          required(:path) => String.t(),
          optional(:agents) => %{optional(Agent.id()) => agent_ref() | agent()},
          optional(:foregrounds) => %{
            optional(String.t()) => %{
              agent_id: Agent.id(),
              provider: Agent.provider_id() | nil,
              owner_session_id: String.t()
            }
          },
          optional(:active_foregrounds) => %{optional(String.t()) => String.t()},
          optional(:foreground_order) => [String.t()],
          optional(:foreground_id) => Agent.id() | nil,
          optional(:foreground_provider) => Agent.provider_id() | nil,
          optional(:documents) => %{optional(Document.path()) => document()},
          optional(:open_document_paths) => [Document.path()],
          optional(:active_document_path) => Document.path() | nil,
          optional(:document_element_picker_enabled?) => boolean(),
          optional(:owners) => %{optional(String.t()) => Agent.id()},
          optional(:viewers) => %{optional(String.t()) => pid()},
          optional(:fs_watcher_pid) => pid() | nil
        }

  @typedoc "Opaque handle the LiveView holds for a workspace Session."
  @type ws :: %{
          path: String.t(),
          live_session_id: String.t(),
          rail_key: String.t(),
          agent_id: String.t() | nil,
          agent_topic: String.t() | nil
        }

  # ── public API ────────────────────────────────────────────────────

  @doc """
  Get-or-start the per-path Session and ensure its foreground agent exists.

  Returns the workspace handle (`t:ws/0`) carrying the canonical path and the
  resolved foreground agent id + topic, so the caller can `subscribe/1` and
  delegate turn verbs. `settings` seed the foreground agent on FIRST attach
  (provider/adapter_opts/workspace_root/document_path/pool_document_id).
  Later attaches from the same LiveView pid re-use its active rail; attaches
  from a new pid start a fresh active rail and leave older rails in recents.
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
  def foreground_agent(%{agent_id: agent_id}) when is_binary(agent_id) do
    case AcpAgent.whereis(agent_id) do
      pid when is_pid(pid) -> %{id: agent_id, pid: pid}
      nil -> nil
    end
  end

  def foreground_agent(%{path: path}) do
    call_if_alive(path, :foreground_agent, nil)
  end

  # ── orchestration: background worker agents (Phase 5) ───────────────
  #
  # An orchestrator (the foreground AgentLive, or any caller) can spawn WORKER
  # AgentLives in the same workspace. A worker is tagged `role: :background` in
  # the roster with its `parent` — per the plan's lifecycle table: a foreground
  # agent's lifecycle is owned by its Session, a worker's by its parent. A worker
  # is NEVER returned as the workspace's foreground agent (`foreground_agent/1` /
  # `foreground_ws/1` read only the foreground binding), so an observer chat-rail
  # never accidentally fronts a background worker. It IS observable on its own
  # PubSub topic so an orchestrator/dashboard can watch it.

  @doc """
  Spawn a BACKGROUND worker AgentLive in `path`'s workspace, owned (lifecycle) by
  `parent_agent_id`. The worker is a full `Ecrits.AcpAgent.Session` started
  through the same `SessionSupervisor` as the foreground agent (so it has its own
  per-agent MCP url + doc context — invariant 3), tagged `:background` in the
  roster. Returns `{:ok, %{id, pid, topic}}`; the caller `subscribe_agent/1`s the
  returned topic to observe the worker's stream.

  `opts` seed the worker exactly like the foreground agent
  (provider / adapter_opts / workspace_root / document_path / pool_document_id);
  a fresh agent id is minted unless one is passed via `:id`.
  """
  @spec spawn_worker(String.t(), String.t(), keyword()) ::
          {:ok, %{id: String.t(), pid: pid(), topic: String.t()}} | {:error, term()}
  def spawn_worker(path, parent_agent_id, opts \\ [])
      when is_binary(path) and is_binary(parent_agent_id) and is_list(opts) do
    with {:ok, _pid} <- ensure_started(canonical_path(path)) do
      GenServer.call(via(canonical_path(path)), {:spawn_worker, parent_agent_id, opts})
    end
  end

  @doc """
  The background worker agents in `path`'s workspace as a list of
  `%{id, pid, parent}` (foreground excluded). Drops any whose pid has died so a
  crashed worker is not reported as live.
  """
  @spec workers(String.t()) :: [%{id: String.t(), pid: pid(), parent: String.t() | nil}]
  def workers(path) when is_binary(path) do
    call_if_alive(path, :workers, [])
  end

  @doc "The roster role of `agent_id` in `path`'s workspace (`:foreground` / `:background` / nil)."
  @spec agent_role(String.t(), String.t()) :: :foreground | :background | nil
  def agent_role(path, agent_id) when is_binary(path) and is_binary(agent_id) do
    call_if_alive(path, {:agent_role, agent_id}, nil)
  end

  @doc """
  Subscribe the CALLER to a worker (or any agent's) PubSub topic so it observes
  that agent's streamed events (`{:local_agent_event, ev}`). Client-side: runs in
  the caller process, like `subscribe/1`.
  """
  @spec subscribe_agent(String.t()) :: :ok | {:error, term()}
  def subscribe_agent(agent_id) when is_binary(agent_id) do
    AcpAgent.subscribe(agent_id)
  end

  # [deprecated] dead code — no callers in lib or test (dead-code audit 2026-07-13: xref + repo grep + runtime trace)
  @doc "The PubSub topic an agent (worker or foreground) publishes its stream on."
  @spec agent_topic(String.t()) :: String.t()
  def agent_topic(agent_id) when is_binary(agent_id), do: AcpAgent.topic(agent_id)

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
            ws(canonical_path(path), @default_live_session_id, agent_id)

          _ ->
            nil
        end

      nil ->
        nil
    end
  end

  @doc """
  Start a fresh foreground chat rail for the caller's Phoenix browser session and
  make it the active rail. Existing rails for that browser remain available via
  `recent_foregrounds/1`.
  """
  @spec new_foreground(String.t(), keyword()) :: {:ok, ws()} | {:error, term()}
  def new_foreground(path, settings \\ []) when is_binary(path) and is_list(settings) do
    canonical = canonical_path(path)

    with {:ok, _pid} <- ensure_started(canonical) do
      GenServer.call(via(canonical), {:new_foreground, settings})
    end
  end

  @doc """
  Switch the caller's Phoenix browser session to an existing recent foreground
  rail owned by that browser session.
  """
  @spec select_foreground(String.t(), String.t(), keyword()) :: {:ok, ws()} | {:error, term()}
  def select_foreground(path, rail_key, settings \\ [])
      when is_binary(path) and is_binary(rail_key) and is_list(settings) do
    canonical = canonical_path(path)

    with {:ok, _pid} <- ensure_started(canonical) do
      GenServer.call(via(canonical), {:select_foreground, rail_key, settings})
    end
  end

  @doc "Recent foreground chat rails for the caller's Phoenix browser session."
  @spec recent_foregrounds(ws()) :: [map()]
  def recent_foregrounds(%{path: path, live_session_id: live_session_id} = ws)
      when is_binary(path) and is_binary(live_session_id) do
    call_if_alive(
      path,
      {:recent_foregrounds, live_session_id, Map.get(ws, :rail_key)},
      []
    )
  end

  def recent_foregrounds(_ws), do: []

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

  # [deprecated] dead code — no callers in lib or test (the live `Session.title` calls are AcpAgent.Session's) (dead-code audit 2026-07-13)
  @doc "The foreground agent's current chat title (derived from the first prompt)."
  @spec title(ws()) :: String.t() | nil
  def title(%{agent_id: agent_id}) when is_binary(agent_id) do
    AcpAgent.title(agent_id)
  end

  def title(_ws), do: nil

  @doc """
  Display-only snapshot of the foreground agent: `%{transcript, status, title}`.
  Used by the LiveView to repaint the active or selected recent rail.
  """
  @spec snapshot(ws()) :: %{
          required(:transcript) => list(),
          required(:status) => atom(),
          required(:title) => String.t() | nil,
          optional(:title_user_edited?) => boolean()
        }
  def snapshot(%{agent_id: agent_id}) when is_binary(agent_id) do
    AcpAgent.agent_snapshot(agent_id)
  end

  def snapshot(_ws),
    do: %{transcript: [], status: :offline, title: nil, title_user_edited?: false}

  @doc """
  Delegate a chat turn to the foreground agent. `input` is a bare **string**
  (sugar — the common case) OR a list of multi-modal **content blocks**
  (`%{type: :text | :image | :audio | :file | :doc_ref, …}`, Phase 5). The
  foreground agent normalizes + maps it onto the ACP prompt content shape.

  `opts` may carry `adapter_opts:` — the composer's CURRENT per-turn options
  (access/approval, reasoning, model), merged into the agent before the turn
  starts so the turn runs with what the UI showed at send time.
  """
  @spec send_turn(ws(), String.t() | [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def send_turn(ws, input, opts \\ [])

  def send_turn(%{agent_id: agent_id}, input, opts) when is_binary(agent_id) do
    AcpAgent.send_turn(nil, agent_id, input, opts)
  end

  def send_turn(_ws, _input, _opts), do: {:error, :no_agent}

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
  Apply per-turn option changes (provider model / reasoning / access) to the
  foreground agent live, preserving the conversation.
  """
  @spec update_options(ws(), keyword()) :: :ok | {:error, term()}
  def update_options(%{agent_id: agent_id}, adapter_opts)
      when is_binary(agent_id) and is_list(adapter_opts) do
    AcpAgent.update_session_options(agent_id, adapter_opts)
  end

  def update_options(_ws, _opts), do: {:error, :no_agent}

  @doc "Session-owned document UI snapshot used to restore tabs, active document, and scroll."
  @spec document_snapshot(ws()) :: %{
          documents: [Document.t()],
          active_document_path: Document.path() | nil,
          document_element_picker_enabled?: boolean()
        }
  def document_snapshot(%{path: path}) when is_binary(path) do
    call_if_alive(path, :document_snapshot, %{
      documents: [],
      active_document_path: nil,
      document_element_picker_enabled?: false
    })
  end

  def document_snapshot(_ws),
    do: %{documents: [], active_document_path: nil, document_element_picker_enabled?: false}

  @doc "Persist whether the document element picker is enabled for this workspace session."
  @spec set_document_element_picker_enabled(ws(), boolean()) :: :ok | {:error, term()}
  def set_document_element_picker_enabled(%{path: path}, enabled?) when is_binary(path) do
    call_if_alive(path, {:set_document_element_picker_enabled, enabled?}, {:error, :no_session})
  end

  def set_document_element_picker_enabled(_ws, _enabled?), do: {:error, :no_session}

  @doc "Record or update an opened document and make it active unless `:active?` is false."
  @spec open_document(ws(), map() | keyword()) :: {:ok, Document.t()} | {:error, term()}
  def open_document(%{path: path}, attrs) when is_binary(path) do
    call_if_alive(path, {:open_document, attrs}, {:error, :no_session})
  end

  def open_document(_ws, _attrs), do: {:error, :no_session}

  @doc "Activate an already-open document by path."
  @spec activate_document(ws(), Document.path()) :: :ok | {:error, term()}
  def activate_document(%{path: path}, document_path)
      when is_binary(path) and is_binary(document_path) do
    call_if_alive(path, {:activate_document, document_path}, {:error, :no_session})
  end

  def activate_document(_ws, _document_path), do: {:error, :no_session}

  @doc "Remove an opened document from the session-owned document UI state."
  @spec close_document(ws(), Document.path()) :: :ok | {:error, term()}
  def close_document(%{path: path}, document_path)
      when is_binary(path) and is_binary(document_path) do
    call_if_alive(path, {:close_document, document_path}, {:error, :no_session})
  end

  def close_document(_ws, _document_path), do: {:error, :no_session}

  @doc "Persist browser-measured scroll for an opened document."
  @spec update_document_scroll(ws(), Document.path(), map() | keyword()) :: :ok | {:error, term()}
  def update_document_scroll(%{path: path}, document_path, attrs)
      when is_binary(path) and is_binary(document_path) do
    call_if_alive(path, {:update_document_scroll, document_path, attrs}, {:error, :no_session})
  end

  def update_document_scroll(_ws, _document_path, _attrs), do: {:error, :no_session}

  @doc """
  GENUINE restart of the foreground agent for a PROVIDER change (codex<->claude,
  or a cross-provider model selection). The ACP adapter (`exmcp_adapter`) is bound
  at `start_session` and CANNOT be swapped on a running session, so a provider
  switch must TERMINATE the current foreground agent and START a fresh one with
  the new provider/adapter + `settings`. The new agent reuses the stable
  path-keyed id ONLY after the old process is fully dead, and starts with an EMPTY
  transcript + the default "New Chat" title — a genuinely new conversation, NOT a
  replay across providers.

  Returns the rebound `t:ws/0` so the caller can re-subscribe + re-snapshot the
  fresh (empty) transcript. Same-provider option changes must NOT call this — they
  use `update_options/2` (live-apply, conversation preserved).
  """
  @spec restart_foreground(String.t(), keyword()) :: {:ok, ws()} | {:error, term()}
  def restart_foreground(path, settings \\ []) when is_binary(path) and is_list(settings) do
    canonical = canonical_path(path)

    with {:ok, _pid} <- ensure_started(canonical) do
      GenServer.call(via(canonical), {:restart_foreground, settings})
    end
  end

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

  # [deprecated] dead code — no callers in lib or test; the {:release_owner, ...} handle_call is only reachable through this fn (dead-code audit 2026-07-13)
  @doc "Release `agent_id`'s ownership of `document_id` (no-op if it isn't the owner)."
  @spec release_owner(String.t(), String.t(), String.t()) :: :ok
  def release_owner(path, document_id, agent_id)
      when is_binary(path) and is_binary(document_id) and is_binary(agent_id) do
    call_if_alive(path, {:release_owner, document_id, agent_id}, :ok)
  end

  # [deprecated] dead code — no callers in lib or test; nothing publishes or subscribes on this topic (dead-code audit 2026-07-13)
  @doc "Stable doc-topic for this workspace (Phase 1 stub — nothing publishes on it yet)."
  @spec doc_topic(String.t()) :: String.t()
  def doc_topic(path) when is_binary(path), do: "workspace_doc:" <> canonical_path(path)

  @doc """
  Subscribe the caller to file-system changes for `path` and ensure the shared
  per-workspace watcher is running.

  The watcher is owned by the durable `Workspace.Session`, not by any particular
  LiveView socket, so multiple tabs/reloads of the same workspace do not spawn
  duplicate macOS watcher processes.
  """
  @spec subscribe_file_events(ws() | String.t()) :: :ok
  def subscribe_file_events(%{path: path}) when is_binary(path), do: subscribe_file_events(path)

  def subscribe_file_events(path) when is_binary(path) do
    canonical = canonical_path(path)
    :ok = Phoenix.PubSub.subscribe(@pubsub, file_events_topic(canonical))

    with {:ok, _pid} <- ensure_started(canonical) do
      GenServer.call(via(canonical), :ensure_file_watcher)
    end

    :ok
  end

  @doc "Canonicalize a workspace path so the key is stable regardless of trailing slash etc."
  @spec canonical_path(String.t()) :: String.t()
  def canonical_path(path) when is_binary(path), do: Ecrits.Fuse.DocMount.canonical_root(path)

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

  defp ws(path, live_session_id, rail_key, agent_id) do
    %{
      path: path,
      live_session_id: live_session_id,
      rail_key: rail_key,
      agent_id: agent_id,
      agent_topic: if(is_binary(agent_id), do: AcpAgent.topic(agent_id), else: nil)
    }
  end

  defp ws(path, live_session_id, agent_id),
    do: ws(path, live_session_id, live_session_id, agent_id)

  # ── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok,
     %{
       path: Keyword.fetch!(opts, :path),
       # agents roster: %{agent_id => %{role: :foreground, pid: pid}}
       agents: %{},
       # Browser-session scoped foreground bindings:
       # %{rail_key => %{agent_id: id, provider: "codex" | "claude" | nil, owner_session_id: id}}
       foregrounds: %{},
       # Active rail per LiveView process key: %{live_view_key => rail_key}
       active_foregrounds: %{},
       # Most-recently-used rail keys, newest first.
       foreground_order: [],
       foreground_id: nil,
       # Provider id the foreground agent was started under. The ACP adapter is
       # bound at start and cannot be swapped live, so a re-attach requesting a
       # DIFFERENT provider must restart the agent rather than reuse it.
       foreground_provider: nil,
       # Per-doc ownership (invariant 2): %{document_id => agent_id}. The real home
       # of what Phase 2 temporarily parked in `Ecrits.Doc.Pool`.
       owners: %{},
       # Per-doc human viewers (browser WASM authority): %{document_id => lv_pid}.
       # A viewer here makes `route/2` return `{:browser, lv}` for that doc.
       viewers: %{},
       # Session-owned document UI state: open tabs, active document, and browser
       # scroll positions keyed by workspace-relative document path.
       documents: %{},
       open_document_paths: [],
       active_document_path: nil,
       document_element_picker_enabled?: false,
       # Shared file-system watcher for this workspace root. LiveViews subscribe to
       # this Session's PubSub topic instead of each starting their own watcher.
       fs_watcher_pid: nil
     }}
  end

  @impl true
  def handle_call({:attach, settings}, {live_view_pid, _tag}, state) do
    case ensure_foreground_agent(state, settings, live_view_pid) do
      {:ok, state, %{id: agent_id, rail_key: rail_key, live_session_id: live_session_id}} ->
        ws = ws(state.path, live_session_id, rail_key, agent_id)
        {:reply, {:ok, ws}, state}

      {:error, reason} ->
        ws = ws(state.path, foreground_session_key(settings), nil)
        {:reply, {:error, reason, ws}, state}
    end
  end

  def handle_call(:foreground_agent, _from, state) do
    {:reply, first_foreground(state), state}
  end

  def handle_call({:restart_foreground, settings}, {live_view_pid, _tag}, state) do
    case restart_foreground_agent(state, settings, live_view_pid) do
      {:ok, state, %{id: agent_id, rail_key: rail_key, live_session_id: live_session_id}} ->
        ws = ws(state.path, live_session_id, rail_key, agent_id)
        {:reply, {:ok, ws}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:new_foreground, settings}, {live_view_pid, _tag}, state) do
    live_session_id = foreground_session_key(settings)
    live_view_key = foreground_live_view_key(live_view_pid)
    state = ensure_foregrounds(state)
    state = monitor_foreground_live_view(state, live_view_pid)
    active_rail_key = active_foreground_key(state, live_view_key)

    if empty_foreground?(state, active_rail_key) do
      case restart_foreground_agent(state, settings, active_rail_key, live_view_key) do
        {:ok, state, %{id: agent_id, rail_key: rail_key}} ->
          ws = ws(state.path, live_session_id, rail_key, agent_id)
          {:reply, {:ok, ws}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      rail_key = new_foreground_key(live_view_key)

      case start_foreground_agent(state, settings, rail_key, live_view_key) do
        {:ok, state, %{id: agent_id, rail_key: rail_key}} ->
          ws = ws(state.path, live_session_id, rail_key, agent_id)
          {:reply, {:ok, ws}, state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  def handle_call({:select_foreground, rail_key, settings}, {live_view_pid, _tag}, state) do
    live_session_id = foreground_session_key(settings)
    live_view_key = foreground_live_view_key(live_view_pid)
    state = ensure_foregrounds(state)
    state = monitor_foreground_live_view(state, live_view_pid)

    with %{owner_session_id: ^live_session_id, agent_id: agent_id} = meta <-
           Map.get(state.foregrounds, rail_key),
         true <- is_binary(agent_id) do
      cond do
        provider_switch?(meta.provider, Keyword.get(settings, :provider)) ->
          case restart_foreground_agent(state, settings, rail_key, live_view_key) do
            {:ok, state, %{id: agent_id}} ->
              {:reply, {:ok, ws(state.path, live_session_id, rail_key, agent_id)}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        current_agent(agent_id) ->
          _ = maybe_apply_settings(agent_id, settings)

          state =
            state
            |> activate_foreground(live_view_key, rail_key)
            |> bump_foreground_order(rail_key)

          {:reply, {:ok, ws(state.path, live_session_id, rail_key, agent_id)}, state}

        true ->
          case start_foreground_agent(state, settings, rail_key, live_view_key) do
            {:ok, state, %{id: agent_id}} ->
              {:reply, {:ok, ws(state.path, live_session_id, rail_key, agent_id)}, state}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      _ -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:recent_foregrounds, live_session_id, active_rail_key}, _from, state) do
    state = ensure_foregrounds(state)
    {:reply, recent_foregrounds_for(state, live_session_id, active_rail_key), state}
  end

  # ── orchestration: background workers ──────────────────────────────

  def handle_call({:spawn_worker, parent_agent_id, opts}, _from, state) do
    worker_id = Keyword.get(opts, :id, Ecto.UUID.generate())
    opts = Keyword.put(opts, :id, worker_id)

    case AcpAgent.start_session(nil, opts) do
      {:ok, %{id: ^worker_id}} ->
        pid = AcpAgent.whereis(worker_id)

        state = %{
          state
          | agents:
              Map.put(state.agents, worker_id, %{
                role: :background,
                pid: pid,
                parent: parent_agent_id
              })
        }

        {:reply, {:ok, %{id: worker_id, pid: pid, topic: AcpAgent.topic(worker_id)}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:workers, _from, state) do
    workers =
      state.agents
      |> Enum.filter(fn {_id, meta} -> meta[:role] == :background end)
      |> Enum.flat_map(fn {id, meta} ->
        case AcpAgent.whereis(id) do
          pid when is_pid(pid) -> [%{id: id, pid: pid, parent: meta[:parent]}]
          _ -> []
        end
      end)

    {:reply, workers, state}
  end

  def handle_call({:agent_role, agent_id}, _from, state) do
    role =
      cond do
        agent_id == state.foreground_id -> :foreground
        match?(%{role: _}, Map.get(state.agents, agent_id)) -> state.agents[agent_id].role
        true -> nil
      end

    {:reply, role, state}
  end

  # ── document UI state ─────────────────────────────────────────────────

  def handle_call(:document_snapshot, _from, state) do
    state = ensure_document_state(state)
    {:reply, document_snapshot_payload(state), state}
  end

  def handle_call({:set_document_element_picker_enabled, enabled?}, _from, state) do
    state =
      state
      |> ensure_document_state()
      |> Map.put(:document_element_picker_enabled?, enabled? == true)

    {:reply, :ok, state}
  end

  def handle_call({:open_document, attrs}, _from, state) do
    state = ensure_document_state(state)

    case session_document(attrs, Map.get(state, :documents, %{})) do
      {:ok, %Document{} = document} ->
        active? = attr_value(attrs, :active?) != false

        state =
          state
          |> put_session_document(document)
          |> maybe_activate_session_document(document.path, active?)

        {:reply, {:ok, document}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:activate_document, document_path}, _from, state) do
    state = ensure_document_state(state)

    case normalize_document_path(document_path) do
      {:ok, path} ->
        if Map.has_key?(state.documents, path) do
          {:reply, :ok, %{state | active_document_path: path}}
        else
          {:reply, {:error, :not_open}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close_document, document_path}, _from, state) do
    state = ensure_document_state(state)

    case normalize_document_path(document_path) do
      {:ok, path} ->
        documents = Map.delete(state.documents, path)
        open_document_paths = Enum.reject(state.open_document_paths, &(&1 == path))

        active_document_path =
          if state.active_document_path == path do
            List.first(open_document_paths)
          else
            state.active_document_path
          end

        {:reply, :ok,
         %{
           state
           | documents: documents,
             open_document_paths: open_document_paths,
             active_document_path: active_document_path
         }}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update_document_scroll, document_path, attrs}, _from, state) do
    state = ensure_document_state(state)

    with {:ok, path} <- normalize_document_path(document_path),
         %Document{} = document <- Map.get(state.documents, path) do
      document = %{
        document
        | scroll_top:
            scroll_coordinate(attr_value(attrs, :top) || attr_value(attrs, :scroll_top)),
          scroll_left:
            scroll_coordinate(attr_value(attrs, :left) || attr_value(attrs, :scroll_left))
      }

      {:reply, :ok, %{state | documents: Map.put(state.documents, path, document)}}
    else
      nil -> {:reply, {:error, :not_open}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
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

  def handle_call(:ensure_file_watcher, _from, state) do
    {:reply, :ok, ensure_file_watcher(state)}
  end

  @impl true
  def handle_info({:file_event, pid, :stop}, %{fs_watcher_pid: pid} = state) do
    {:noreply, %{state | fs_watcher_pid: nil}}
  end

  def handle_info({:file_event, pid, {path, _events}}, %{fs_watcher_pid: pid} = state)
      when is_binary(path) do
    # Ignore churn from the document VFS mount itself (<root>/.ecrits); it
    # is never user content and would otherwise trigger pointless tree refreshes.
    unless String.contains?(path, "/.ecrits/") do
      Phoenix.PubSub.broadcast(
        @pubsub,
        file_events_topic(state.path),
        {:workspace_fs_event, path}
      )
    end

    {:noreply, state}
  end

  def handle_info({:file_event, _pid, _payload}, state), do: {:noreply, state}

  # A crashed viewer relinquishes its browser claim on every doc it backed, so
  # those docs fall back to their server Editors.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    state = ensure_maps(state)
    state = ensure_foregrounds(state)

    state =
      state
      |> Map.put(:viewers, drop_viewer_everywhere(state.viewers, pid))
      |> drop_live_view_foreground(pid)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = stop_file_watcher(state)
    # Tear down the document VFS mount when the workspace session truly ends
    # (best-effort; no-op if it was never mounted / already gone).
    _ = if is_binary(state.path), do: Ecrits.Fuse.DocMount.teardown(state.path)

    state
    |> Map.get(:agents, %{})
    |> Map.keys()
    |> Enum.each(&AcpAgent.close/1)

    :ok
  end

  # Backfill the Phase 3 maps onto a state that predates them (a Session GenServer
  # hot-reloaded across the upgrade), so the live process never crashes on a
  # missing key. A no-op once the keys exist.
  defp ensure_maps(state) do
    state
    |> Map.put_new(:owners, %{})
    |> Map.put_new(:viewers, %{})
    |> Map.put_new(:fs_watcher_pid, nil)
    |> ensure_document_state()
  end

  defp ensure_document_state(state) do
    documents =
      state
      |> Map.get(:documents, %{})
      |> normalize_session_documents()

    open_document_paths =
      state
      |> Map.get(:open_document_paths, Map.keys(documents))
      |> Enum.filter(&Map.has_key?(documents, &1))

    active_document_path =
      case Map.get(state, :active_document_path) do
        path when is_binary(path) and is_map_key(documents, path) -> path
        _ -> List.first(open_document_paths)
      end

    state
    |> Map.put(:documents, documents)
    |> Map.put(:open_document_paths, open_document_paths)
    |> Map.put(:active_document_path, active_document_path)
    |> Map.put_new(:document_element_picker_enabled?, false)
  end

  defp normalize_session_documents(documents) when is_map(documents) do
    documents
    |> Enum.flat_map(fn
      {path, %Document{} = document} ->
        case normalize_document_path(document.path || path) do
          {:ok, normalized} -> [{normalized, %{document | path: normalized}}]
          {:error, _} -> []
        end

      {path, document} when is_map(document) ->
        attrs = Map.put_new(document, :path, path)

        case session_document(attrs, %{}) do
          {:ok, %Document{} = normalized} -> [{normalized.path, normalized}]
          {:error, _} -> []
        end

      _other ->
        []
    end)
    |> Map.new()
  end

  defp normalize_session_documents(_documents), do: %{}

  defp document_snapshot_payload(state) do
    %{
      documents:
        state.open_document_paths
        |> Enum.flat_map(fn path ->
          case Map.get(state.documents, path) do
            %Document{} = document -> [document]
            _ -> []
          end
        end),
      active_document_path: state.active_document_path,
      document_element_picker_enabled?: Map.get(state, :document_element_picker_enabled?, false)
    }
  end

  defp session_document(attrs, existing_documents) do
    with {:ok, path} <- normalize_document_path(attr_value(attrs, :path)) do
      existing = Map.get(existing_documents, path, %Document{path: path})

      {:ok,
       %{
         existing
         | path: path,
           id: attr_value(attrs, :id) || existing.id,
           pool_document_id: attr_value(attrs, :pool_document_id) || existing.pool_document_id,
           scroll_top:
             scroll_coordinate(
               attr_value(attrs, :top) || attr_value(attrs, :scroll_top) || existing.scroll_top
             ),
           scroll_left:
             scroll_coordinate(
               attr_value(attrs, :left) || attr_value(attrs, :scroll_left) || existing.scroll_left
             )
       }}
    end
  end

  defp put_session_document(state, %Document{} = document) do
    documents = Map.put(state.documents, document.path, document)

    open_document_paths =
      Enum.reject(state.open_document_paths, &(&1 == document.path)) ++ [document.path]

    %{state | documents: documents, open_document_paths: open_document_paths}
  end

  defp maybe_activate_session_document(state, path, true),
    do: %{state | active_document_path: path}

  defp maybe_activate_session_document(state, _path, _active?), do: state

  defp normalize_document_path(path) when is_binary(path) do
    path = String.trim(path)
    segments = Path.split(path)

    if path == "" or Path.type(path) == :absolute or Enum.any?(segments, &(&1 in [".", ".."])) do
      {:error, :invalid_path}
    else
      {:ok, Path.join(segments)}
    end
  end

  defp normalize_document_path(_path), do: {:error, :invalid_path}

  defp attr_value(attrs, key) when is_list(attrs), do: Keyword.get(attrs, key)

  defp attr_value(attrs, key) when is_map(attrs) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(attrs, key) -> Map.get(attrs, key)
      Map.has_key?(attrs, string_key) -> Map.get(attrs, string_key)
      true -> nil
    end
  end

  defp attr_value(_attrs, _key), do: nil

  defp scroll_coordinate(value) when is_integer(value) and value >= 0, do: value

  defp scroll_coordinate(value) when is_float(value) and value >= 0 do
    value
    |> Float.round()
    |> trunc()
  end

  defp scroll_coordinate(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} when integer >= 0 -> integer
      _ -> 0
    end
  end

  defp scroll_coordinate(_value), do: 0

  defp ensure_file_watcher(state) do
    state = ensure_maps(state)

    case state.fs_watcher_pid do
      pid when is_pid(pid) ->
        if Process.alive?(pid),
          do: state,
          else: start_file_watcher(%{state | fs_watcher_pid: nil})

      _ ->
        start_file_watcher(state)
    end
  end

  defp start_file_watcher(state) do
    if is_binary(state.path) and state.path != "" do
      case FileSystem.start_link(dirs: [state.path]) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          %{state | fs_watcher_pid: pid}

        _other ->
          state
      end
    else
      state
    end
  end

  defp stop_file_watcher(%{fs_watcher_pid: pid}) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
    :ok
  end

  defp stop_file_watcher(_state), do: :ok

  defp file_events_topic(path), do: "workspace_files:" <> canonical_path(path)

  # ── foreground-agent binding ───────────────────────────────────────

  # Get-or-start the foreground agent for this workspace + LiveView process. The
  # workspace Session remains path-keyed for document routing; the active chat
  # agent is keyed by a stable id derived from path + caller pid. The Phoenix
  # browser session id only scopes the recent-conversation list.
  defp ensure_foreground_agent(state, settings, live_view_pid) do
    live_session_id = foreground_session_key(settings)
    live_view_key = foreground_live_view_key(live_view_pid)
    state = ensure_foregrounds(state)
    state = monitor_foreground_live_view(state, live_view_pid)
    rail_key = active_foreground_key(state, live_view_key)

    case current_foreground(state, rail_key) do
      %{id: agent_id} = fg ->
        if provider_switch?(
             foreground_provider(state, rail_key),
             Keyword.get(settings, :provider)
           ) do
          # The bound ACP adapter cannot be swapped live, so a re-attach (e.g. a
          # page reload whose URL provider differs from the durable agent's) that
          # requests a DIFFERENT provider must do a genuine restart — otherwise the
          # stale adapter keeps serving turns under the new provider's model and the
          # provider rejects them (observed: "'sonnet' not supported with Codex").
          restart_foreground_agent(state, settings, rail_key, live_view_key)
        else
          _ = maybe_apply_settings(agent_id, settings)

          state =
            state
            |> activate_foreground(live_view_key, rail_key)
            |> bump_foreground_order(rail_key)

          {:ok, state, Map.merge(fg, %{rail_key: rail_key, live_session_id: live_session_id})}
        end

      nil ->
        start_foreground_agent(state, settings, rail_key, live_view_key)
    end
  end

  defp start_foreground_agent(state, settings, rail_key, live_view_key) do
    live_session_id = foreground_session_key(settings)
    agent_id = foreground_agent_id(state.path, rail_key)
    opts = Keyword.put(settings, :id, agent_id)

    case AcpAgent.start_session(nil, opts) do
      {:ok, %{id: ^agent_id}} ->
        pid = AcpAgent.whereis(agent_id)

        state =
          state
          |> put_foreground(
            live_session_id,
            live_view_key,
            rail_key,
            agent_id,
            Keyword.get(settings, :provider)
          )
          |> Map.update!(:agents, &Map.put(&1, agent_id, %{role: :foreground, pid: pid}))

        {:ok, state,
         %{id: agent_id, pid: pid, rail_key: rail_key, live_session_id: live_session_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A provider SWITCH only when both the bound and requested providers are known
  # and differ. A same-pid re-attach that doesn't pin a provider (nil) — or pins
  # the same one — reuses the active LiveView rail.
  defp provider_switch?(bound, requested)
       when is_binary(bound) and is_binary(requested),
       do: bound != requested

  defp provider_switch?(_bound, _requested), do: false

  defp empty_foreground?(state, rail_key) do
    case current_foreground(state, rail_key) do
      %{id: agent_id} when is_binary(agent_id) ->
        empty_agent?(agent_id)

      _ ->
        false
    end
  end

  defp empty_agent?(agent_id) do
    case AcpAgent.agent_snapshot(agent_id) do
      %{transcript: [], current_turn: nil, pending: pending, queued: queued}
      when pending in [nil, 0] and queued in [nil, []] ->
        true

      _ ->
        false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  # GENUINE restart for a provider change: terminate the current foreground agent
  # (its ACP adapter is bound at start and cannot be swapped), wait for the
  # path-keyed id to be fully released from the registry, then start a fresh agent
  # with the new provider/adapter + settings. The new agent reuses the same stable
  # id but begins with an EMPTY transcript + default title.
  defp restart_foreground_agent(state, settings, live_view_pid) do
    live_view_key = foreground_live_view_key(live_view_pid)
    state = ensure_foregrounds(state)
    state = monitor_foreground_live_view(state, live_view_pid)
    rail_key = active_foreground_key(state, live_view_key)

    restart_foreground_agent(state, settings, rail_key, live_view_key)
  end

  defp restart_foreground_agent(state, settings, rail_key, live_view_key) do
    live_session_id = foreground_session_key(settings)
    agent_id = foreground_agent_id(state.path, rail_key)

    # Terminate any live agent under this path+session id and ensure the registry
    # slot is free before respawning — otherwise start_session re-attaches via
    # {:already_started, pid}.
    _ = AcpAgent.close(agent_id)
    :ok = await_agent_dead(agent_id)

    # Drop the old foreground binding so a respawn failure leaves no dangling id.
    state = drop_foreground(state, rail_key, agent_id)

    opts = Keyword.put(settings, :id, agent_id)

    case AcpAgent.start_session(nil, opts) do
      {:ok, %{id: ^agent_id}} ->
        pid = AcpAgent.whereis(agent_id)

        state =
          state
          |> put_foreground(
            live_session_id,
            live_view_key,
            rail_key,
            agent_id,
            Keyword.get(settings, :provider)
          )
          |> Map.update!(:agents, &Map.put(&1, agent_id, %{role: :foreground, pid: pid}))

        {:ok, state,
         %{id: agent_id, pid: pid, rail_key: rail_key, live_session_id: live_session_id}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Block (bounded) until the path-keyed agent id is no longer registered — the
  # Registry unregisters asynchronously on process DOWN, so even though
  # `terminate_child` returned after the exit, the id may briefly still resolve.
  # Reusing it before it clears would re-attach to the dying process.
  defp await_agent_dead(agent_id, attempts \\ 50) do
    cond do
      is_nil(AcpAgent.whereis(agent_id)) ->
        :ok

      attempts <= 0 ->
        :ok

      true ->
        Process.sleep(10)
        await_agent_dead(agent_id, attempts - 1)
    end
  end

  # Resolve the foreground agent freshly from the registry each time so a roster
  # entry whose pid died (agent crash) is treated as absent and re-started.
  defp current_foreground(state, rail_key) do
    state = ensure_foregrounds(state)

    with %{agent_id: agent_id} <- Map.get(state.foregrounds, rail_key),
         true <- is_binary(agent_id) do
      current_agent(agent_id)
    else
      _ -> nil
    end
  end

  defp first_foreground(state) do
    state = ensure_foregrounds(state)

    state.foregrounds
    |> Enum.find_value(fn {_live_session_id, %{agent_id: agent_id}} ->
      current_agent(agent_id)
    end)
  end

  defp current_agent(agent_id) do
    case AcpAgent.whereis(agent_id) do
      pid when is_pid(pid) -> %{id: agent_id, pid: pid}
      nil -> nil
    end
  end

  defp maybe_apply_settings(_agent_id, []), do: :ok

  # Keys owned by the durable session (set via select_local_agent_reasoning/access
  # and persisted in adapter_opts). A re-attach on page refresh must NOT push the
  # LiveView's default assigns over the user's last-chosen values.
  @session_owned_opts [
    :reasoning_effort,
    :sandbox,
    :permission_mode,
    :approval_policy,
    :access_control
  ]

  defp maybe_apply_settings(agent_id, settings) do
    case Keyword.get(settings, :adapter_opts) do
      opts when is_list(opts) and opts != [] ->
        live_opts = Keyword.drop(opts, @session_owned_opts)

        if live_opts != [], do: AcpAgent.update_session_options(agent_id, live_opts)
        :ok

      _ ->
        :ok
    end
  end

  defp foreground_session_key(settings) when is_list(settings) do
    case Keyword.get(settings, :live_session_id) do
      id when is_binary(id) and id != "" -> id
      _ -> @default_live_session_id
    end
  end

  defp foreground_session_key(_settings), do: @default_live_session_id

  defp foreground_live_view_key(pid) when is_pid(pid) do
    "lv-" <>
      (:crypto.hash(:sha256, :erlang.term_to_binary(pid))
       |> Base.url_encode64(padding: false)
       |> binary_part(0, 16))
  end

  defp monitor_foreground_live_view(state, pid) when is_pid(pid) do
    Process.monitor(pid)
    state
  end

  defp drop_live_view_foreground(state, pid) when is_pid(pid) do
    state = ensure_foregrounds(state)
    live_view_key = foreground_live_view_key(pid)

    case Map.pop(state.active_foregrounds, live_view_key) do
      {nil, _active_foregrounds} ->
        state

      {rail_key, active_foregrounds} ->
        state = %{state | active_foregrounds: active_foregrounds}

        if empty_foreground?(state, rail_key) and not foreground_active?(state, rail_key) do
          case Map.get(state.foregrounds, rail_key) do
            %{agent_id: agent_id} when is_binary(agent_id) ->
              _ = AcpAgent.close(agent_id)
              drop_foreground(state, rail_key, agent_id)

            _ ->
              state
          end
        else
          state
        end
    end
  end

  defp foreground_active?(state, rail_key) do
    state.active_foregrounds
    |> Map.values()
    |> Enum.any?(&(&1 == rail_key))
  end

  defp foreground_provider(state, rail_key) do
    state = ensure_foregrounds(state)

    case Map.get(state.foregrounds, rail_key) do
      %{provider: provider} -> provider
      _ -> nil
    end
  end

  defp ensure_foregrounds(state) do
    foregrounds =
      case Map.get(state, :foregrounds) do
        foregrounds when is_map(foregrounds) and map_size(foregrounds) > 0 ->
          foregrounds

        _ ->
          legacy_foregrounds(state)
      end
      |> normalize_foregrounds()

    active_foregrounds =
      state
      |> Map.get(:active_foregrounds, %{})
      |> normalize_active_foregrounds(foregrounds)

    foreground_order =
      state
      |> Map.get(:foreground_order, Map.keys(foregrounds))
      |> Enum.filter(&Map.has_key?(foregrounds, &1))
      |> then(&Enum.uniq(&1 ++ Map.keys(foregrounds)))

    state
    |> Map.put(:foregrounds, foregrounds)
    |> Map.put(:active_foregrounds, active_foregrounds)
    |> Map.put(:foreground_order, foreground_order)
  end

  defp legacy_foregrounds(state) do
    case Map.get(state, :foreground_id) do
      id when is_binary(id) ->
        %{
          @default_live_session_id => %{
            agent_id: id,
            provider: Map.get(state, :foreground_provider),
            owner_session_id: @default_live_session_id
          }
        }

      _ ->
        %{}
    end
  end

  defp normalize_foregrounds(foregrounds) do
    Map.new(foregrounds, fn {rail_key, meta} when is_map(meta) ->
      owner_session_id = Map.get(meta, :owner_session_id) || rail_key

      {rail_key,
       %{
         agent_id: meta[:agent_id],
         provider: Map.get(meta, :provider),
         owner_session_id: owner_session_id
       }}
    end)
  end

  defp normalize_active_foregrounds(active_foregrounds, foregrounds)
       when is_map(active_foregrounds) do
    active_foregrounds
    |> Enum.filter(fn {_live_view_key, rail_key} ->
      is_binary(rail_key) and Map.has_key?(foregrounds, rail_key)
    end)
    |> Map.new()
  end

  defp normalize_active_foregrounds(_active_foregrounds, _foregrounds) do
    %{}
  end

  defp active_foreground_key(state, live_view_key) do
    state = ensure_foregrounds(state)

    case Map.get(state.active_foregrounds, live_view_key) do
      rail_key when is_binary(rail_key) and is_map_key(state.foregrounds, rail_key) -> rail_key
      _ -> live_view_key
    end
  end

  defp put_foreground(state, live_session_id, live_view_key, rail_key, agent_id, provider) do
    state = ensure_foregrounds(state)

    foregrounds =
      Map.put(state.foregrounds, rail_key, %{
        agent_id: agent_id,
        provider: provider,
        owner_session_id: live_session_id
      })

    state =
      %{state | foregrounds: foregrounds}
      |> activate_foreground(live_view_key, rail_key)
      |> bump_foreground_order(rail_key)

    if rail_key == @default_live_session_id or is_nil(Map.get(state, :foreground_id)) do
      %{state | foreground_id: agent_id, foreground_provider: provider}
    else
      state
    end
  end

  defp activate_foreground(state, live_view_key, rail_key) do
    state = ensure_foregrounds(state)
    %{state | active_foregrounds: Map.put(state.active_foregrounds, live_view_key, rail_key)}
  end

  defp bump_foreground_order(state, rail_key) do
    state = ensure_foregrounds(state)

    foreground_order =
      [rail_key | Enum.reject(state.foreground_order, &(&1 == rail_key))]
      |> Enum.take(@max_recent_foregrounds)

    %{state | foreground_order: foreground_order}
  end

  defp drop_foreground(state, rail_key, agent_id) do
    state = ensure_foregrounds(state)

    state = %{
      state
      | agents: Map.delete(state.agents, agent_id),
        foregrounds: Map.delete(state.foregrounds, rail_key),
        foreground_order: Enum.reject(state.foreground_order, &(&1 == rail_key))
    }

    state = %{
      state
      | active_foregrounds: drop_active_foreground(state.active_foregrounds, rail_key)
    }

    if Map.get(state, :foreground_id) == agent_id do
      %{state | foreground_id: nil, foreground_provider: nil}
    else
      state
    end
  end

  defp drop_active_foreground(active_foregrounds, rail_key) do
    active_foregrounds
    |> Enum.reject(fn {_live_view_key, active_rail_key} -> active_rail_key == rail_key end)
    |> Map.new()
  end

  defp recent_foregrounds_for(state, live_session_id, active_rail_key) do
    state = ensure_foregrounds(state)
    active_rail_key = active_rail_key

    state.foreground_order
    |> Enum.flat_map(fn rail_key ->
      with %{agent_id: agent_id, owner_session_id: ^live_session_id} = meta <-
             Map.get(state.foregrounds, rail_key),
           %{pid: pid} <- current_agent(agent_id) do
        snapshot = AcpAgent.agent_snapshot(agent_id)

        [
          %{
            rail_key: rail_key,
            agent_id: agent_id,
            pid: pid,
            provider: meta.provider,
            title: Map.get(snapshot, :title),
            status: Map.get(snapshot, :status, :idle),
            active?: rail_key == active_rail_key
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp new_foreground_key(live_view_key) do
    live_view_key <> ":rail:" <> Ecto.UUID.generate()
  end

  # Remove `lv`'s viewer claim from EVERY doc it currently backs (a previously-
  # viewed doc it navigated away from, or a crashed viewer's claims).
  defp drop_viewer_everywhere(viewers, lv) do
    viewers
    |> Enum.reject(fn {_doc, viewer} -> viewer == lv end)
    |> Map.new()
  end

  # Stable foreground-agent id for a workspace path + rail key. Same LiveView pid
  # re-derives the same rail key; a refreshed LiveView gets a different key. The
  # default key preserves the older path-only id for legacy callers.
  defp foreground_agent_id(path, @default_live_session_id) do
    "fg-" <>
      (:crypto.hash(:sha256, path) |> Base.url_encode64(padding: false) |> binary_part(0, 32))
  end

  defp foreground_agent_id(path, rail_key) do
    "fg-" <>
      (:crypto.hash(:sha256, path <> <<0>> <> rail_key)
       |> Base.url_encode64(padding: false)
       |> binary_part(0, 32))
  end
end
