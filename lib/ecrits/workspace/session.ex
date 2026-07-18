defmodule Ecrits.Workspace.Session do
  @moduledoc """
  Per-workspace MODEL + directory, keyed by the canonical workspace **path**.
  This is the durable facade the workspace LiveView talks to. Foreground chat
  rails are keyed by a stable browser-tab id when supplied (and by the caller
  process as a compatibility fallback), while the Phoenix browser session id
  scopes the recent-conversation list.

  ## Responsibilities (Phase 1)

    * **agents roster** — records the foreground agents bound to this workspace
      (`%{agent_id => %{role: :foreground, pid: pid}}`). Each browser tab gets
      its own active foreground rail; a refresh reattaches it, and completed
      rails remain selectable in the same browser session's recent list.
    * **facade** — `attach/2`, `subscribe/1`, `foreground_agent/1`, `title/1`,
      `send_turn/2`, `cancel/2`, `rename/2`. The turn verbs delegate to the
      foreground agent.

  The Session holds **no live doc handles** and supervises **no agents** — the
  foreground agent is a `Ecrits.AcpAgent.Session` GenServer held under
  `Ecrits.AcpAgent.SessionSupervisor` (durable in its own right). The
  Session is the directory that binds path + browser-tab id → foreground agent
  and the single entry point the LiveView uses.

  Later phases extend the roster (background/worker agents), add the
  `viewers`/`owners` maps + the wasm/NIF routing decision, and the doc topic.
  For Phase 1 the doc topic is a stable no-op stub.
  """

  use GenServer

  alias Ecrits.Doc.Pool
  alias Ecrits.AcpAgent
  alias Ecrits.WorkspaceHandoff
  alias Ecrits.Workspace.Session.{Agent, Document}
  alias Ecrits.Workspace.TurnFinalizer

  @registry Ecrits.Workspace.SessionRegistry
  @supervisor Ecrits.Workspace.SessionSupervisor
  @pubsub Ecrits.PubSub
  @default_live_session_id "__default__"
  @max_recent_foregrounds 12
  @max_turn_finalizations 256
  @turn_finalization_retry_base_ms 25
  @turn_finalization_retry_max_ms 1_000

  @type agent :: Agent.t()
  @type agent_ref :: Agent.ref()
  @type document :: Document.t()
  @type turn_finalization_summary :: %{
          saved: non_neg_integer(),
          failed: non_neg_integer(),
          committed: non_neg_integer(),
          pending: non_neg_integer(),
          canonical: non_neg_integer(),
          canonical_pending: non_neg_integer(),
          successful?: boolean()
        }

  @type turn_finalization_key :: {String.t(), String.t(), String.t()}

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
          optional(:foreground_live_views) => %{optional(pid()) => String.t()},
          optional(:foreground_order) => [String.t()],
          optional(:foreground_id) => Agent.id() | nil,
          optional(:foreground_provider) => Agent.provider_id() | nil,
          optional(:documents) => %{optional(Document.path()) => document()},
          optional(:open_document_paths) => [Document.path()],
          optional(:active_document_path) => Document.path() | nil,
          optional(:document_element_picker_enabled?) => boolean(),
          optional(:owners) => %{optional(String.t()) => Agent.id()},
          optional(:viewers) => %{optional(String.t()) => [pid()]},
          optional(:turn_finalizations) => %{
            optional(turn_finalization_key()) =>
              %{
                optional(:retry_token) => reference(),
                optional(:retry_reason) => term(),
                status: :queued,
                attempts: non_neg_integer()
              }
              | %{status: :running, pid: pid(), ref: reference(), attempts: pos_integer()}
              | %{status: :completed, summary: turn_finalization_summary()}
          },
          optional(:turn_finalization_order) => [turn_finalization_key()],
          optional(:turn_finalization_queue) => [turn_finalization_key()],
          optional(:turn_finalization_waiters) => %{
            optional(turn_finalization_key()) => MapSet.t(pid())
          },
          optional(:turn_finalization_active) =>
            %{
              key: turn_finalization_key(),
              pid: pid(),
              ref: reference(),
              attempts: pos_integer()
            }
            | nil,
          optional(:foreground_transitions) => %{
            optional(turn_finalization_key()) => %{
              operation: :restart | :start,
              settings: keyword(),
              rail_key: String.t(),
              live_view_key: String.t(),
              live_session_id: String.t()
            }
          },
          optional(:agent_turn_owners) => %{
            optional(turn_finalization_key()) => %{
              optional(:task_ref) => reference(),
              optional(:owner_exit_reason) => term(),
              optional(:worker_pid) => pid(),
              optional(:worker_ref) => reference(),
              optional(:worker_down?) => boolean(),
              optional(:guardian_down?) => boolean(),
              optional(:shutdown_ack?) => boolean(),
              owner_pid: pid(),
              owner_ref: reference(),
              task_pid: pid(),
              status: :active | :awaiting_task_down | :crashed
            }
          },
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
  Later attaches with the same `:chat_rail_id` re-use its active rail across
  LiveView process replacement; a different tab id starts a fresh active rail
  and leaves older rails in recents. Direct callers without a tab id retain the
  process-scoped fallback.
  """
  @spec attach(String.t(), keyword()) :: {:ok, ws()} | {:pending, ws()} | {:error, term()}
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
  # An orchestrator (the foreground agent session, or any caller) can spawn WORKER
  # AgentLives in the same workspace. A worker is tagged `role: :background` in
  # the roster with its `parent` — per the plan's lifecycle table: a foreground
  # agent's lifecycle is owned by its Session, a worker's by its parent. A worker
  # is NEVER returned as the workspace's foreground agent (`foreground_agent/1` /
  # `foreground_ws/1` read only the foreground binding), so an observer chat-rail
  # never accidentally fronts a background worker. It IS observable on its own
  # PubSub topic so an orchestrator/dashboard can watch it.

  @doc """
  Spawn a BACKGROUND worker agent session in `path`'s workspace, owned (lifecycle) by
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
  that agent's streamed events (`{:agent_event, ev}`). Client-side: runs in
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
  @spec new_foreground(String.t(), keyword()) ::
          {:ok, ws()} | {:pending, ws()} | {:error, term()}
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
  @spec select_foreground(String.t(), String.t(), keyword()) ::
          {:ok, ws()} | {:pending, ws()} | {:error, term()}
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
  Agent-session pid — the MCP-isolation seam (design invariant 3). A `doc.*` tool
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
  Display-only snapshot of the foreground agent, including the canonical
  provider/model needed to repaint the active or selected recent rail.
  """
  @spec snapshot(ws()) :: %{
          required(:transcript) => list(),
          required(:status) => atom(),
          required(:title) => String.t() | nil,
          optional(:title_user_edited?) => boolean(),
          optional(:provider) => String.t() | nil,
          optional(:model) => String.t() | nil,
          optional(:adapter_opts) => keyword()
        }
  def snapshot(%{agent_id: agent_id}) when is_binary(agent_id) do
    AcpAgent.agent_snapshot(agent_id)
  end

  def snapshot(_ws),
    do: %{
      transcript: [],
      status: :offline,
      title: nil,
      title_user_edited?: false,
      provider: nil,
      model: nil
    }

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

  def send_turn(%{path: path} = ws, input, opts) when is_binary(path) do
    call_if_alive(path, {:send_foreground_turn, ws, input, opts}, {:error, :no_session})
  end

  def send_turn(_ws, _input, _opts), do: {:error, :no_agent}

  @doc """
  Ensure document-side terminal work runs once for an agent turn.

  The Session atomically starts one out-of-process finalizer for
  `{agent_id, instance_id, turn_id}`. Running it outside this GenServer is required because a
  staged JSONL write-back may route through this Session again. Completion is
  broadcast on the workspace file-events topic so every attached LiveView can
  refresh without repeating the save or flush.
  """
  @spec finalize_turn(ws(), String.t(), keyword()) ::
          {:ok, :started | :queued | :running | {:completed, turn_finalization_summary()}}
          | {:error, term()}
  def finalize_turn(ws, turn_id, opts \\ [])

  def finalize_turn(%{path: path, agent_id: agent_id}, turn_id, opts)
      when is_binary(path) and is_binary(agent_id) and is_binary(turn_id) and turn_id != "" and
             is_list(opts) do
    with instance_id when is_binary(instance_id) and instance_id != "" <-
           Keyword.get(opts, :instance_id) || current_agent_instance_id(agent_id) do
      call_if_alive(
        path,
        {:finalize_turn, agent_id, instance_id, turn_id},
        {:error, :no_session}
      )
    else
      _missing -> {:error, :no_agent_instance}
    end
  end

  def finalize_turn(_ws, _turn_id, _opts), do: {:error, :no_agent}

  @doc false
  @spec notify_turn_started(
          String.t() | nil,
          map(),
          pid(),
          pid(),
          :sync | :async
        ) :: :registered | :no_workspace
  def notify_turn_started(
        workspace_path,
        %{
          agent_id: agent_id,
          instance_id: instance_id,
          turn_id: turn_id
        },
        owner_pid,
        task_pid,
        mode
      )
      when is_binary(workspace_path) and workspace_path != "" and is_binary(agent_id) and
             agent_id != "" and is_binary(instance_id) and instance_id != "" and
             is_binary(turn_id) and turn_id != "" and is_pid(owner_pid) and is_pid(task_pid) and
             mode in [:sync, :async] do
    case whereis(workspace_path) do
      pid when is_pid(pid) ->
        message = {:agent_turn_started, {agent_id, instance_id, turn_id}, owner_pid, task_pid}

        case mode do
          :async ->
            send(pid, message)
            :registered

          :sync ->
            GenServer.call(pid, message)
        end

      nil ->
        :no_workspace
    end
  catch
    :exit, _reason -> :no_workspace
  end

  def notify_turn_started(_workspace_path, _identity, _owner_pid, _task_pid, _mode),
    do: :no_workspace

  @doc false
  @spec notify_turn_worker_started(String.t() | nil, map(), pid(), pid()) ::
          :registered | :no_workspace
  def notify_turn_worker_started(
        workspace_path,
        %{
          agent_id: agent_id,
          instance_id: instance_id,
          turn_id: turn_id
        },
        guardian_pid,
        worker_pid
      )
      when is_binary(workspace_path) and workspace_path != "" and is_binary(agent_id) and
             agent_id != "" and is_binary(instance_id) and instance_id != "" and
             is_binary(turn_id) and turn_id != "" and is_pid(guardian_pid) and
             is_pid(worker_pid) do
    case whereis(workspace_path) do
      pid when is_pid(pid) ->
        GenServer.call(
          pid,
          {:agent_turn_worker_started, {agent_id, instance_id, turn_id}, guardian_pid, worker_pid}
        )

      nil ->
        :no_workspace
    end
  catch
    :exit, _reason -> :no_workspace
  end

  def notify_turn_worker_started(_workspace_path, _identity, _guardian_pid, _worker_pid),
    do: :no_workspace

  @doc false
  @spec notify_turn_terminal(String.t() | nil, map()) :: :ok
  def notify_turn_terminal(workspace_path, identity) do
    _ = notify_turn_terminal(workspace_path, identity, nil)
    :ok
  end

  @doc false
  @spec notify_turn_terminal(String.t() | nil, map(), pid() | nil) ::
          :pending | :no_workspace
  def notify_turn_terminal(
        workspace_path,
        %{
          agent_id: agent_id,
          instance_id: instance_id,
          turn_id: turn_id
        },
        reply_to
      )
      when is_binary(workspace_path) and workspace_path != "" and is_binary(agent_id) and
             agent_id != "" and is_binary(instance_id) and instance_id != "" and
             is_binary(turn_id) and turn_id != "" and
             (is_pid(reply_to) or is_nil(reply_to)) do
    case whereis(workspace_path) do
      pid when is_pid(pid) ->
        send(pid, {:agent_turn_terminal, {agent_id, instance_id, turn_id}, reply_to})
        :pending

      nil ->
        :no_workspace
    end
  end

  def notify_turn_terminal(_workspace_path, _identity, _reply_to), do: :no_workspace

  @doc """
  Re-Enter on a queued message: cancel the in-flight turn and promote the
  foreground agent's FIFO head after the exact workspace-finalization ack.
  """
  @spec flush_queue(ws()) :: {:ok, map()} | {:error, term()}
  def flush_queue(%{path: path} = ws) when is_binary(path) do
    call_if_alive(path, {:flush_foreground_queue, ws}, {:error, :no_session})
  end

  def flush_queue(%{agent_id: agent_id}) when is_binary(agent_id) do
    AcpAgent.flush_queue(agent_id)
  end

  def flush_queue(_ws), do: {:error, :no_agent}

  @doc "Cancel the foreground agent's in-flight turn."
  @spec cancel(ws(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def cancel(ws, turn_id \\ nil)

  def cancel(%{path: path} = ws, turn_id) when is_binary(path) do
    call_if_alive(path, {:cancel_foreground_turn, ws, turn_id}, {:error, :no_session})
  end

  def cancel(%{agent_id: agent_id}, turn_id) when is_binary(agent_id) do
    AcpAgent.cancel(nil, agent_id, turn_id)
  end

  def cancel(_ws, _turn_id), do: {:error, :no_agent}

  @doc """
  Rename the foreground agent's chat thread. Marks the title user-edited so the
  first-prompt auto-title never overrides it afterwards.
  """
  @spec rename(ws(), String.t()) :: :ok | {:error, term()}
  def rename(%{path: path} = ws, title) when is_binary(path) do
    call_if_alive(path, {:rename_foreground, ws, title}, {:error, :no_session})
  end

  def rename(%{agent_id: agent_id}, title) when is_binary(agent_id) do
    AcpAgent.rename(agent_id, title)
  end

  def rename(_ws, _title), do: {:error, :no_agent}

  @doc """
  Apply per-turn option changes (provider model / reasoning / access) to the
  foreground agent live, preserving the conversation.
  """
  @spec update_options(ws(), keyword()) :: :ok | {:error, term()}
  def update_options(%{path: path} = ws, adapter_opts)
      when is_binary(path) and is_list(adapter_opts) do
    call_if_alive(
      path,
      {:update_foreground_options, ws, adapter_opts},
      {:error, :no_session}
    )
  end

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
  @spec restart_foreground(String.t(), keyword()) ::
          {:ok, ws()} | {:pending, ws()} | {:error, term()}
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
  The active human viewer (browser WASM authority) for `document_id` in `path`'s
  workspace, or nil. The most recently attached live viewer is active; older
  concurrent viewers remain eligible as fallbacks. Returns a pid ONLY while that
  viewer is alive, promoting the next live viewer before falling back to the
  server NIF. The wasm/NIF routing decision is `viewer present? → browser :
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
  Register `lv` as the newest human viewer for `document_id` in `path`'s
  workspace. A viewer is attached to AT MOST ONE doc — attaching it to a new doc
  detaches it from any other it was viewing — while multiple concurrent viewers
  of the same doc are retained. The newest live viewer is the active browser WASM
  authority; detaching or closing it promotes the next live viewer.
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

  @doc "Detach `lv` from `document_id`, promoting another live viewer or falling back to the server NIF."
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
  @spec claim_owner(String.t(), String.t(), String.t()) ::
          :ok | {:error, {:owned, String.t()}}
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

  defp current_agent_instance_id(agent_id) do
    case AcpAgent.agent_snapshot(agent_id) do
      %{instance_id: instance_id} when is_binary(instance_id) and instance_id != "" ->
        instance_id

      _missing ->
        nil
    end
  catch
    :exit, _reason -> nil
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
    path = Keyword.fetch!(opts, :path)

    {:ok,
     %{
       path: path,
       # agents roster: %{agent_id => %{role: :foreground, pid: pid}}
       agents: %{},
       # Browser-session scoped foreground bindings:
       # %{rail_key => %{agent_id: id, provider: "codex" | "claude" | nil, owner_session_id: id}}
       foregrounds: %{},
       # Durable selected rail per stable browser-tab key (or pid fallback):
       # %{live_view_key => rail_key}
       active_foregrounds: %{},
       # Live browser processes currently attached to those durable selections:
       # %{live_view_pid => live_view_key}. A stable tab selection survives DOWN,
       # while this map is cleared so liveness and document ownership do not.
       foreground_live_views: %{},
       # Durable workspace-wide rail-list order, with genuinely new rails
       # prepended once. The display cap is applied per browser session.
       foreground_order: [],
       foreground_id: nil,
       # Provider id the foreground agent was started under. The ACP adapter is
       # bound at start and cannot be swapped live, so a re-attach requesting a
       # DIFFERENT provider must restart the agent rather than reuse it.
       foreground_provider: nil,
       # Per-doc ownership (invariant 2): %{document_id => agent_id}. The real home
       # of what Phase 2 temporarily parked in `Ecrits.Doc.Pool`.
       owners: %{},
       # Per-doc human viewers (browser WASM authority), newest first:
       # %{document_id => [lv_pid]}. `route/2` uses the first live viewer and
       # retains the rest as fallbacks for overlapping/reconnecting LiveViews.
       viewers: %{},
       # Terminal document work is serialized once per workspace. Completed
       # keys remain in a bounded ledger so a late duplicate PubSub delivery
       # cannot repeat a save or staged projection flush.
       turn_finalizations: %{},
       turn_finalization_order: [],
       turn_finalization_queue: [],
       turn_finalization_waiters: %{},
       turn_finalization_active: nil,
       foreground_transitions: %{},
       # Exact in-flight turn ownership published before provider work begins.
       # Workspace monitors both the owning Session and its guarded turn task so
       # an untrappable owner kill cannot orphan edits or skip terminal work.
       agent_turn_owners: %{},
       # Session-owned document UI state: open tabs, active document, and browser
       # scroll positions keyed by workspace-relative document path.
       documents: %{},
       open_document_paths: [],
       active_document_path: nil,
       document_element_picker_enabled?: false,
       # Shared file-system watcher for this workspace root. LiveViews subscribe to
       # this Session's PubSub topic instead of each starting their own watcher.
       fs_watcher_pid: nil
     }
     |> restore_chat_rail_state()}
  end

  @impl true
  def handle_call({:attach, settings}, {live_view_pid, _tag}, state) do
    live_view_key = foreground_live_view_key(settings, live_view_pid)
    state = restore_foreground_agents(state, settings)

    case ensure_foreground_agent(state, settings, live_view_pid) do
      {:ok, state, %{id: agent_id, rail_key: rail_key, live_session_id: live_session_id}} ->
        ws = ws(state.path, live_session_id, rail_key, agent_id)
        {:reply, {:ok, ws}, notify_foreground_rebind(state, live_view_key, ws)}

      {:pending, key, state, transition} ->
        defer_foreground_transition(state, key, transition)

      {:error, reason} ->
        ws = ws(state.path, foreground_session_key(settings), nil)
        {:reply, {:error, reason, ws}, state}
    end
  end

  def handle_call(:foreground_agent, _from, state) do
    {:reply, first_foreground(state), state}
  end

  def handle_call({:restart_foreground, settings}, {live_view_pid, _tag}, state) do
    live_view_key = foreground_live_view_key(settings, live_view_pid)

    case restart_foreground_agent(state, settings, live_view_pid) do
      {:ok, state, %{id: agent_id, rail_key: rail_key, live_session_id: live_session_id}} ->
        ws = ws(state.path, live_session_id, rail_key, agent_id)
        {:reply, {:ok, ws}, notify_foreground_rebind(state, live_view_key, ws)}

      {:pending, key, state, transition} ->
        defer_foreground_transition(state, key, transition)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:new_foreground, settings}, {live_view_pid, _tag}, state) do
    live_session_id = foreground_session_key(settings)
    live_view_key = foreground_live_view_key(settings, live_view_pid)
    state = ensure_foregrounds(state)

    case monitor_foreground_live_view(state, live_view_pid, live_view_key) do
      {:ok, state} ->
        active_rail_key = active_foreground_key(state, live_view_key, live_session_id)

        if empty_foreground?(state, active_rail_key) do
          case restart_foreground_agent(state, settings, active_rail_key, live_view_key) do
            {:ok, state, %{id: agent_id, rail_key: rail_key}} ->
              ws = ws(state.path, live_session_id, rail_key, agent_id)
              {:reply, {:ok, ws}, notify_foreground_rebind(state, live_view_key, ws)}

            {:pending, key, state, transition} ->
              defer_foreground_transition(state, key, transition)

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        else
          rail_key = new_foreground_key(live_view_key)

          case start_new_foreground_agent(
                 state,
                 settings,
                 active_rail_key,
                 rail_key,
                 live_view_key
               ) do
            {:ok, state, %{id: agent_id, rail_key: rail_key}} ->
              ws = ws(state.path, live_session_id, rail_key, agent_id)
              {:reply, {:ok, ws}, notify_foreground_rebind(state, live_view_key, ws)}

            {:pending, key, state, transition} ->
              defer_foreground_transition(state, key, transition)

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:select_foreground, rail_key, settings},
        {live_view_pid, _tag},
        state
      ) do
    state = state |> ensure_foregrounds() |> ensure_turn_finalizations()

    if foreground_transition_pending_for_live_view?(state, live_view_pid) do
      {:reply, {:error, :foreground_transition_in_progress}, state}
    else
      select_foreground_reply(state, rail_key, settings, live_view_pid)
    end
  end

  def handle_call({:send_foreground_turn, _ws, input, opts}, {live_view_pid, _tag}, state) do
    state = state |> ensure_foregrounds() |> ensure_turn_finalizations()

    with {:ok, agent_id} <- current_foreground_agent_id(state, live_view_pid) do
      state = recover_crashed_agent_turns(state, agent_id)

      if foreground_transition_pending?(state, agent_id) or
           not is_nil(agent_crash_barrier_key(state, agent_id)) do
        {:reply, {:error, :foreground_transition_in_progress}, state}
      else
        {:reply, AcpAgent.send_turn(nil, agent_id, input, opts), state}
      end
    else
      _ -> {:reply, {:error, :no_agent}, state}
    end
  end

  def handle_call({:flush_foreground_queue, _ws}, {live_view_pid, _tag}, state) do
    state = state |> ensure_foregrounds() |> ensure_turn_finalizations()

    with {:ok, agent_id} <- current_foreground_agent_id(state, live_view_pid) do
      state = recover_crashed_agent_turns(state, agent_id)

      if foreground_transition_pending?(state, agent_id) or
           not is_nil(agent_crash_barrier_key(state, agent_id)) do
        {:reply, {:error, :foreground_transition_in_progress}, state}
      else
        {:reply, AcpAgent.flush_queue(agent_id), state}
      end
    else
      _ -> {:reply, {:error, :no_agent}, state}
    end
  end

  def handle_call({:cancel_foreground_turn, _ws, turn_id}, {live_view_pid, _tag}, state) do
    state = ensure_foregrounds(state)

    with {:ok, agent_id} <- current_foreground_agent_id(state, live_view_pid) do
      {:reply, AcpAgent.cancel(nil, agent_id, turn_id), state}
    else
      _ -> {:reply, {:error, :no_agent}, state}
    end
  end

  def handle_call({:rename_foreground, _ws, title}, {live_view_pid, _tag}, state) do
    state = ensure_foregrounds(state)

    with {:ok, agent_id} <- current_foreground_agent_id(state, live_view_pid) do
      {:reply, AcpAgent.rename(agent_id, title), state}
    else
      _ -> {:reply, {:error, :no_agent}, state}
    end
  end

  def handle_call(
        {:update_foreground_options, _ws, adapter_opts},
        {live_view_pid, _tag},
        state
      ) do
    state = state |> ensure_foregrounds() |> ensure_turn_finalizations()

    with {:ok, agent_id} <- current_foreground_agent_id(state, live_view_pid) do
      state = recover_crashed_agent_turns(state, agent_id)

      if foreground_transition_pending?(state, agent_id) or
           not is_nil(agent_crash_barrier_key(state, agent_id)) do
        {:reply, {:error, :foreground_transition_in_progress}, state}
      else
        {:reply, AcpAgent.update_session_options(agent_id, adapter_opts), state}
      end
    else
      _ -> {:reply, {:error, :no_agent}, state}
    end
  end

  def handle_call({:recent_foregrounds, live_session_id, active_rail_key}, _from, state) do
    state = ensure_foregrounds(state)
    {:reply, recent_foregrounds_for(state, live_session_id, active_rail_key), state}
  end

  def handle_call(
        {:agent_turn_started, key, owner_pid, task_pid},
        _from,
        state
      ) do
    {:reply, :registered, register_agent_turn_owner(state, key, owner_pid, task_pid)}
  end

  def handle_call(
        {:agent_turn_worker_started, key, guardian_pid, worker_pid},
        _from,
        state
      ) do
    {:reply, :registered, register_agent_turn_worker(state, key, guardian_pid, worker_pid)}
  end

  def handle_call({:finalize_turn, agent_id, instance_id, turn_id}, _from, state) do
    state = state |> ensure_maps() |> ensure_foregrounds() |> ensure_turn_finalizations()
    key = {agent_id, instance_id, turn_id}

    case {known_agent?(state, agent_id), Map.get(state.turn_finalizations, key)} do
      {false, _entry} ->
        {:reply, {:error, :unknown_agent}, state}

      {true, %{status: :completed, summary: summary}} ->
        {:reply, {:ok, {:completed, summary}}, state}

      {true, %{status: :running}} ->
        {:reply, {:ok, :running}, state}

      {true, %{status: :queued}} ->
        {:reply, {:ok, :queued}, state}

      {true, nil} ->
        state = enqueue_turn_finalization(state, key)
        {reply, state} = maybe_start_turn_finalization(state, key)
        {:reply, {:ok, reply}, state}
    end
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
    {:reply, state.viewers |> Map.get(document_id, []) |> List.first(), state}
  end

  def handle_call({:attach_viewer, document_id, lv}, _from, state) do
    state = ensure_maps(state)
    monitor_live_view_once(lv)

    # A viewer is the browser authority for AT MOST ONE doc; drop any other doc it
    # was viewing before claiming this one (so navigating between docs in one
    # viewer never leaves a stale browser claim that would misroute an unrelated
    # doc's edits to the currently-open one).
    viewers =
      state.viewers
      |> drop_viewer_everywhere(lv)
      |> Map.update(document_id, [lv], &[lv | &1])

    {:reply, :ok, %{state | viewers: viewers}}
  end

  def handle_call({:detach_viewer, document_id, lv}, _from, state) do
    state = ensure_maps(state)

    viewers = drop_viewer_from_document(state.viewers, document_id, lv)

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

  defp select_foreground_reply(state, rail_key, settings, live_view_pid) do
    live_session_id = foreground_session_key(settings)
    live_view_key = foreground_live_view_key(settings, live_view_pid)

    with {:ok, state} <- monitor_foreground_live_view(state, live_view_pid, live_view_key),
         %{owner_session_id: ^live_session_id, agent_id: agent_id} = meta <-
           Map.get(state.foregrounds, rail_key),
         true <- is_binary(agent_id) do
      cond do
        provider_switch?(meta.provider, Keyword.get(settings, :provider)) ->
          case restart_foreground_agent(state, settings, rail_key, live_view_key) do
            {:ok, state, %{id: agent_id}} ->
              ws = ws(state.path, live_session_id, rail_key, agent_id)
              {:reply, {:ok, ws}, notify_foreground_rebind(state, live_view_key, ws)}

            {:pending, key, state, transition} ->
              defer_foreground_transition(state, key, transition)

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end

        current_agent(agent_id) ->
          _ = maybe_apply_settings(agent_id, settings)

          state =
            state
            |> activate_foreground(live_view_key, rail_key)
            |> remember_foreground_order(rail_key)

          ws = ws(state.path, live_session_id, rail_key, agent_id)
          {:reply, {:ok, ws}, notify_foreground_rebind(state, live_view_key, ws)}

        true ->
          case start_foreground_agent(state, settings, rail_key, live_view_key) do
            {:ok, state, %{id: agent_id}} ->
              ws = ws(state.path, live_session_id, rail_key, agent_id)
              {:reply, {:ok, ws}, notify_foreground_rebind(state, live_view_key, ws)}

            {:error, reason} ->
              {:reply, {:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      _ -> {:reply, {:error, :not_found}, state}
    end
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

  def handle_info({:agent_turn_started, key, owner_pid, task_pid}, state) do
    {:noreply, register_agent_turn_owner(state, key, owner_pid, task_pid)}
  end

  def handle_info({:agent_turn_guardian_stopped, key, guardian_pid}, state)
      when is_pid(guardian_pid) do
    state = ensure_turn_finalizations(state)
    {:noreply, acknowledge_crashed_agent_turn_guardian(state, key, guardian_pid)}
  end

  def handle_info({:agent_turn_terminal, key}, state) do
    handle_info({:agent_turn_terminal, key, nil}, state)
  end

  def handle_info(
        {:agent_turn_terminal, {agent_id, instance_id, turn_id} = key, reply_to},
        state
      )
      when is_binary(agent_id) and agent_id != "" and is_binary(instance_id) and
             instance_id != "" and is_binary(turn_id) and turn_id != "" and
             (is_pid(reply_to) or is_nil(reply_to)) do
    state = state |> ensure_maps() |> ensure_foregrounds() |> ensure_turn_finalizations()

    state =
      if known_agent?(state, agent_id) do
        state = put_turn_finalization_waiter(state, key, reply_to)

        if agent_turn_waiting_for_task?(state, key) do
          # An owner crash may race a terminal message already in the mailbox.
          # The guardian's DOWN is the authority that provider/doc work is dead;
          # only then may finalization read and commit staged mutations.
          state
        else
          case Map.get(state.turn_finalizations, key) do
            %{status: :completed, summary: summary} ->
              acknowledge_turn_finalization(state, key, summary)

            nil ->
              state
              |> enqueue_turn_finalization(key)
              |> maybe_start_queued_turn_finalization()

            _queued_or_running ->
              state
          end
        end
      else
        state
      end

    {:noreply, state}
  end

  def handle_info(
        {:workspace_turn_finalization_finished, key, task_pid, result},
        state
      ) do
    state = ensure_turn_finalizations(state)

    case state.turn_finalization_active do
      %{key: ^key, pid: ^task_pid, ref: ref} ->
        Process.demonitor(ref, [:flush])
        {:noreply, retry_or_complete_turn_finalization_result(state, key, result)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_workspace_turn_finalization, key, retry_token}, state) do
    state = ensure_turn_finalizations(state)

    state =
      case Map.get(state.turn_finalizations, key) do
        %{status: :queued, retry_token: ^retry_token} = entry ->
          finalizations =
            Map.put(
              state.turn_finalizations,
              key,
              Map.drop(entry, [:retry_token, :retry_reason])
            )

          state
          |> Map.put(:turn_finalizations, finalizations)
          |> Map.put(
            :turn_finalization_queue,
            state.turn_finalization_queue ++ [key]
          )
          |> maybe_start_queued_turn_finalization()

        _stale_or_completed ->
          state
      end

    {:noreply, state}
  end

  # A crashed viewer relinquishes its browser claim on every doc it backed, so
  # those docs fall back to their server Editors.
  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    state = state |> ensure_maps() |> ensure_foregrounds() |> ensure_turn_finalizations()

    state =
      case state.turn_finalization_active do
        %{key: key, pid: ^pid, ref: ^ref} ->
          retry_or_complete_turn_finalization(state, key, reason)

        _other ->
          cond do
            match?({_key, _owner}, agent_turn_owner_by_owner_monitor(state, ref, pid)) ->
              {key, owner} = agent_turn_owner_by_owner_monitor(state, ref, pid)
              begin_crashed_agent_turn(state, key, owner, reason)

            match?({_key, _owner}, agent_turn_owner_by_task_monitor(state, ref, pid)) ->
              {key, owner} = agent_turn_owner_by_task_monitor(state, ref, pid)
              finish_crashed_agent_turn_task(state, key, owner)

            match?({_key, _owner}, agent_turn_owner_by_worker_monitor(state, ref, pid)) ->
              {key, owner} = agent_turn_owner_by_worker_monitor(state, ref, pid)
              finish_crashed_agent_turn_worker(state, key, owner)

            true ->
              state
              |> Map.put(:viewers, drop_viewer_everywhere(state.viewers, pid))
              |> drop_live_view_foreground(pid)
          end
      end

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
    |> Map.update!(:viewers, &normalize_viewers/1)
    |> Map.put_new(:fs_watcher_pid, nil)
    |> ensure_turn_finalizations()
    |> ensure_document_state()
  end

  defp ensure_turn_finalizations(state) do
    state =
      state
      |> Map.put_new(:turn_finalizations, %{})
      |> Map.put_new(:turn_finalization_order, [])
      |> Map.put_new(:turn_finalization_queue, [])
      |> Map.put_new(:turn_finalization_waiters, %{})
      |> Map.put_new(:turn_finalization_active, nil)
      |> Map.put_new(:foreground_transitions, %{})
      |> Map.put_new(:agent_turn_owners, %{})

    state
    |> normalize_turn_finalizations()
    |> normalize_agent_turn_owners()
  end

  defp normalize_agent_turn_owners(state) do
    owners =
      state.agent_turn_owners
      |> Enum.filter(fn
        {key,
         %{
           owner_pid: owner_pid,
           owner_ref: owner_ref,
           task_pid: task_pid,
           status: status
         }} ->
          turn_finalization_key?(key) and is_pid(owner_pid) and is_reference(owner_ref) and
            is_pid(task_pid) and status in [:active, :awaiting_task_down, :crashed]

        _other ->
          false
      end)
      |> Map.new()

    %{state | agent_turn_owners: owners}
  end

  defp register_agent_turn_owner(
         state,
         {agent_id, instance_id, turn_id} = key,
         owner_pid,
         task_pid
       )
       when is_binary(agent_id) and agent_id != "" and is_binary(instance_id) and
              instance_id != "" and is_binary(turn_id) and turn_id != "" and
              is_pid(owner_pid) and is_pid(task_pid) do
    state = state |> ensure_maps() |> ensure_foregrounds() |> ensure_turn_finalizations()

    cond do
      not known_agent?(state, agent_id) ->
        state

      match?(%{status: :completed}, Map.get(state.turn_finalizations, key)) ->
        state

      match?(%{owner_pid: ^owner_pid, task_pid: ^task_pid}, Map.get(state.agent_turn_owners, key)) ->
        state

      Map.has_key?(state.agent_turn_owners, key) ->
        # The first exact identity claim is authoritative. A late process using
        # a duplicated instance/turn token must not replace its monitor refs.
        state

      true ->
        owner_ref = Process.monitor(owner_pid)

        put_in(state.agent_turn_owners[key], %{
          owner_pid: owner_pid,
          owner_ref: owner_ref,
          task_pid: task_pid,
          worker_down?: false,
          guardian_down?: false,
          shutdown_ack?: false,
          status: :active
        })
    end
  end

  defp register_agent_turn_owner(state, _key, _owner_pid, _task_pid),
    do: ensure_turn_finalizations(state)

  defp register_agent_turn_worker(state, key, guardian_pid, worker_pid)
       when is_pid(guardian_pid) and is_pid(worker_pid) do
    state = ensure_turn_finalizations(state)

    case Map.get(state.agent_turn_owners, key) do
      %{task_pid: ^guardian_pid, worker_pid: ^worker_pid} ->
        state

      %{task_pid: ^guardian_pid} = owner when not is_map_key(owner, :worker_pid) ->
        worker_ref = Process.monitor(worker_pid)

        owner =
          owner
          |> Map.put(:worker_pid, worker_pid)
          |> Map.put(:worker_ref, worker_ref)
          |> Map.put(:worker_down?, false)

        state = put_in(state.agent_turn_owners[key], owner)

        if owner.status == :awaiting_task_down do
          send(guardian_pid, {:shutdown_agent_turn, key, self()})
        end

        state

      _stale_or_conflicting ->
        state
    end
  end

  defp register_agent_turn_worker(state, _key, _guardian_pid, _worker_pid),
    do: ensure_turn_finalizations(state)

  defp agent_turn_owner_by_owner_monitor(state, ref, pid) do
    Enum.find_value(state.agent_turn_owners, fn
      {key, %{owner_ref: ^ref, owner_pid: ^pid} = owner} -> {key, owner}
      _other -> nil
    end)
  end

  defp agent_turn_owner_by_task_monitor(state, ref, pid) do
    Enum.find_value(state.agent_turn_owners, fn
      {key, %{task_ref: ^ref, task_pid: ^pid} = owner} -> {key, owner}
      _other -> nil
    end)
  end

  defp agent_turn_owner_by_worker_monitor(state, ref, pid) do
    Enum.find_value(state.agent_turn_owners, fn
      {key, %{worker_ref: ^ref, worker_pid: ^pid} = owner} -> {key, owner}
      _other -> nil
    end)
  end

  defp begin_crashed_agent_turn(state, key, owner, reason) do
    case owner.status do
      :active ->
        task_ref = Process.monitor(owner.task_pid)
        send(owner.task_pid, {:shutdown_agent_turn, key, self()})

        owner =
          owner
          |> Map.put(:status, :awaiting_task_down)
          |> Map.put(:task_ref, task_ref)
          |> Map.put(:owner_exit_reason, reason)

        state
        |> put_in([:agent_turn_owners, key], owner)
        |> maybe_finish_crashed_agent_turn(key)

      _already_recovering ->
        state
    end
  end

  defp finish_crashed_agent_turn_task(state, key, owner) do
    Process.demonitor(owner.task_ref, [:flush])

    state =
      put_in(
        state.agent_turn_owners[key],
        owner |> Map.delete(:task_ref) |> Map.put(:guardian_down?, true)
      )

    maybe_finish_crashed_agent_turn(state, key)
  end

  defp finish_crashed_agent_turn_worker(state, key, owner) do
    Process.demonitor(owner.worker_ref, [:flush])

    state =
      put_in(
        state.agent_turn_owners[key],
        owner |> Map.delete(:worker_ref) |> Map.put(:worker_down?, true)
      )

    maybe_finish_crashed_agent_turn(state, key)
  end

  defp acknowledge_crashed_agent_turn_guardian(state, key, guardian_pid) do
    case Map.get(state.agent_turn_owners, key) do
      %{task_pid: ^guardian_pid, status: status} = owner
      when status in [:awaiting_task_down, :crashed] ->
        owner = owner |> Map.put(:shutdown_ack?, true) |> Map.put(:worker_down?, true)
        state |> put_in([:agent_turn_owners, key], owner) |> maybe_finish_crashed_agent_turn(key)

      _stale_or_active ->
        state
    end
  end

  defp maybe_finish_crashed_agent_turn(state, key) do
    case Map.get(state.agent_turn_owners, key) do
      %{status: :awaiting_task_down} = owner ->
        worker_registered? = is_pid(Map.get(owner, :worker_pid))

        ready? =
          Map.get(owner, :shutdown_ack?, false) or
            (worker_registered? and Map.get(owner, :worker_down?, false)) or
            (not worker_registered? and Map.get(owner, :guardian_down?, false))

        if ready? do
          state = put_in(state.agent_turn_owners[key].status, :crashed)
          enqueue_crashed_agent_turn_finalization(state, key)
        else
          state
        end

      _active_or_finished ->
        state
    end
  end

  defp enqueue_crashed_agent_turn_finalization(state, key) do
    case Map.get(state.turn_finalizations, key) do
      %{status: :completed} -> release_agent_turn_owner(state, key)
      nil -> state |> enqueue_turn_finalization(key) |> maybe_start_queued_turn_finalization()
      _queued_or_running -> state
    end
  end

  defp release_agent_turn_owner(state, key) do
    case Map.pop(state.agent_turn_owners, key) do
      {nil, _owners} ->
        state

      {owner, owners} ->
        Process.demonitor(owner.owner_ref, [:flush])

        case Map.get(owner, :task_ref) do
          ref when is_reference(ref) -> Process.demonitor(ref, [:flush])
          _other -> :ok
        end

        case Map.get(owner, :worker_ref) do
          ref when is_reference(ref) -> Process.demonitor(ref, [:flush])
          _other -> :ok
        end

        %{state | agent_turn_owners: owners}
    end
  end

  defp agent_turn_waiting_for_task?(state, key) do
    match?(%{status: :awaiting_task_down}, Map.get(state.agent_turn_owners, key))
  end

  defp enqueue_turn_finalization(state, key) do
    %{
      state
      | turn_finalizations:
          Map.put(state.turn_finalizations, key, %{status: :queued, attempts: 0}),
        turn_finalization_queue: state.turn_finalization_queue ++ [key]
    }
  end

  defp maybe_start_turn_finalization(state, requested_key) do
    {state, started_key} = start_next_turn_finalization(state)
    reply = if started_key == requested_key, do: :started, else: :queued
    {reply, state}
  end

  defp maybe_start_queued_turn_finalization(state) do
    {state, _started_key} = start_next_turn_finalization(state)
    state
  end

  defp start_next_turn_finalization(
         %{turn_finalization_active: nil, turn_finalization_queue: [key | rest]} = state
       ) do
    parent = self()
    path = state.path

    attempts =
      state.turn_finalizations
      |> Map.get(key, %{})
      |> Map.get(:attempts, 0)
      |> Kernel.+(1)

    {pid, ref} = spawn_turn_finalizer(parent, path, key)

    state = %{
      state
      | turn_finalization_active: %{key: key, pid: pid, ref: ref, attempts: attempts},
        turn_finalization_queue: rest,
        turn_finalizations:
          Map.put(state.turn_finalizations, key, %{
            status: :running,
            pid: pid,
            ref: ref,
            attempts: attempts
          })
    }

    {state, key}
  end

  defp start_next_turn_finalization(state), do: {state, nil}

  defp retry_or_complete_turn_finalization(state, key, reason) do
    attempts =
      state.turn_finalizations
      |> Map.get(key, %{})
      |> Map.get(:attempts, 1)

    schedule_turn_finalization_retry(state, key, {:task_exit, reason}, attempts)
  end

  defp retry_or_complete_turn_finalization_result(state, key, result) do
    attempts =
      state.turn_finalizations
      |> Map.get(key, %{})
      |> Map.get(:attempts, 1)

    if recoverable_turn_finalization_result?(result) do
      schedule_turn_finalization_retry(state, key, {:result, result}, attempts)
    else
      complete_turn_finalization(state, key, result)
    end
  end

  defp recoverable_turn_finalization_result?(result) do
    not turn_finalization_summary(result).successful?
  end

  defp schedule_turn_finalization_retry(state, key, reason, attempts) do
    retry_token = make_ref()

    Process.send_after(
      self(),
      {:retry_workspace_turn_finalization, key, retry_token},
      turn_finalization_retry_delay(attempts)
    )

    state = %{
      state
      | turn_finalization_active: nil,
        turn_finalization_queue: List.delete(state.turn_finalization_queue, key),
        turn_finalizations:
          Map.put(state.turn_finalizations, key, %{
            status: :queued,
            attempts: attempts,
            retry_reason: reason,
            retry_token: retry_token
          })
    }

    {state, _started_key} = start_next_turn_finalization(state)
    state
  end

  defp turn_finalization_retry_delay(attempts) do
    exponent = attempts |> Kernel.-(1) |> max(0) |> min(10)

    min(
      @turn_finalization_retry_base_ms * Integer.pow(2, exponent),
      @turn_finalization_retry_max_ms
    )
  end

  defp run_turn_finalizer(path, {agent_id, instance_id, turn_id}) do
    TurnFinalizer.run(path,
      agent_id: agent_id,
      instance_id: instance_id,
      turn_id: turn_id
    )
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp spawn_turn_finalizer(parent, path, key) do
    spawn_monitor(fn ->
      parent_ref = Process.monitor(parent)
      worker = Task.async(fn -> run_turn_finalizer(path, key) end)
      worker_ref = worker.ref
      worker_pid = worker.pid

      receive do
        {^worker_ref, result} ->
          Process.demonitor(worker_ref, [:flush])
          send(parent, {:workspace_turn_finalization_finished, key, self(), result})

        {:DOWN, ^parent_ref, :process, ^parent, _reason} ->
          _ = Task.shutdown(worker, :brutal_kill)

        {:DOWN, ^worker_ref, :process, ^worker_pid, reason} ->
          exit({:turn_finalizer_worker_exit, reason})
      end
    end)
  end

  defp complete_turn_finalization(state, key, result) do
    summary = turn_finalization_summary(result)

    order =
      [key | List.delete(state.turn_finalization_order, key)]
      |> Enum.take(@max_turn_finalizations)

    retained = MapSet.new(order)

    finalizations =
      state.turn_finalizations
      |> Map.put(key, %{status: :completed, summary: summary})
      |> Enum.reject(fn
        {entry_key, %{status: :completed}} -> not MapSet.member?(retained, entry_key)
        _entry -> false
      end)
      |> Map.new()

    state = %{
      state
      | turn_finalization_active: nil,
        turn_finalization_order: order,
        turn_finalizations: finalizations
    }

    Phoenix.PubSub.broadcast(
      @pubsub,
      file_events_topic(state.path),
      {:workspace_turn_finalized,
       %{
         workspace_path: state.path,
         agent_id: elem(key, 0),
         instance_id: elem(key, 1),
         turn_id: elem(key, 2),
         result: result,
         summary: summary
       }}
    )

    state =
      state
      |> acknowledge_turn_finalization(key, summary)
      |> release_agent_turn_owner(key)
      |> resume_foreground_transition(key)

    {state, _started_key} = start_next_turn_finalization(state)
    state
  end

  defp put_turn_finalization_waiter(state, _key, nil), do: state

  defp put_turn_finalization_waiter(state, key, reply_to) when is_pid(reply_to) do
    waiters =
      Map.update(state.turn_finalization_waiters, key, MapSet.new([reply_to]), fn existing ->
        existing
        |> waiter_pids()
        |> MapSet.put(reply_to)
      end)

    %{state | turn_finalization_waiters: waiters}
  end

  defp acknowledge_turn_finalization(state, key, summary) do
    state.turn_finalization_waiters
    |> Map.get(key, MapSet.new())
    |> waiter_pids()
    |> Enum.each(&send(&1, {:workspace_turn_finalization_ack, key, summary}))

    %{state | turn_finalization_waiters: Map.delete(state.turn_finalization_waiters, key)}
  end

  defp normalize_turn_finalizations(state) do
    finalizations =
      state.turn_finalizations
      |> Enum.filter(fn {key, _entry} -> turn_finalization_key?(key) end)
      |> Map.new()

    queue =
      state.turn_finalization_queue
      |> Enum.filter(&turn_finalization_key?/1)
      |> Enum.filter(&Map.has_key?(finalizations, &1))
      |> Enum.uniq()

    order =
      state.turn_finalization_order
      |> Enum.filter(&turn_finalization_key?/1)
      |> Enum.filter(&Map.has_key?(finalizations, &1))
      |> Enum.uniq()

    waiters =
      state.turn_finalization_waiters
      |> Enum.filter(fn {key, _waiters} -> turn_finalization_key?(key) end)
      |> Map.new(fn {key, waiters} -> {key, waiter_pids(waiters)} end)

    active = normalize_turn_finalization_active(state.turn_finalization_active)

    %{
      state
      | turn_finalizations: finalizations,
        turn_finalization_queue: queue,
        turn_finalization_order: order,
        turn_finalization_waiters: waiters,
        turn_finalization_active: active
    }
  end

  defp normalize_turn_finalization_active(%{key: key} = active) do
    if turn_finalization_key?(key) do
      active
    else
      discard_legacy_turn_finalization_active(active)
      nil
    end
  end

  defp normalize_turn_finalization_active(_active), do: nil

  defp discard_legacy_turn_finalization_active(active) do
    case Map.get(active, :ref) do
      ref when is_reference(ref) -> Process.demonitor(ref, [:flush])
      _other -> :ok
    end

    case Map.get(active, :pid) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)

      _other ->
        :ok
    end
  end

  defp turn_finalization_key?({agent_id, instance_id, turn_id}) do
    Enum.all?([agent_id, instance_id, turn_id], &(is_binary(&1) and &1 != ""))
  end

  defp turn_finalization_key?(_key), do: false

  defp waiter_pids(%MapSet{} = waiters), do: waiters
  defp waiter_pids(waiters) when is_list(waiters), do: MapSet.new(waiters)
  defp waiter_pids(waiter) when is_pid(waiter), do: MapSet.new([waiter])
  defp waiter_pids(_waiters), do: MapSet.new()

  defp turn_finalization_summary(%{
         saved: saved,
         failed: failed,
         staged: %{committed: committed, pending: pending},
         canonical: %{published: canonical, pending: canonical_pending}
       })
       when is_list(saved) and is_list(failed) and is_list(committed) and is_list(pending) and
              is_list(canonical) and is_list(canonical_pending) do
    %{
      saved: length(saved),
      failed: length(failed),
      committed: length(committed),
      pending: length(pending),
      canonical: length(canonical),
      canonical_pending: length(canonical_pending),
      successful?: failed == [] and pending == [] and canonical_pending == []
    }
  end

  defp turn_finalization_summary(_result) do
    %{
      saved: 0,
      failed: 1,
      committed: 0,
      pending: 0,
      canonical: 0,
      canonical_pending: 0,
      successful?: false
    }
  end

  defp known_agent?(state, agent_id) do
    Map.has_key?(Map.get(state, :agents, %{}), agent_id) or
      Enum.any?(Map.get(state, :foregrounds, %{}), fn {_rail_key, meta} ->
        Map.get(meta, :agent_id) == agent_id
      end)
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

  # Get-or-start the foreground agent for this workspace + browser tab. The
  # workspace Session remains path-keyed for document routing; a stable tab id
  # survives refresh while staying distinct across tabs. The Phoenix browser
  # session id scopes which recent conversations that tab may select.
  defp restore_foreground_agents(state, settings) do
    state = ensure_foregrounds(state)
    live_session_id = foreground_session_key(settings)

    Enum.reduce(state.foreground_order, state, fn rail_key, acc ->
      case Map.get(acc.foregrounds, rail_key) do
        %{
          agent_id: agent_id,
          owner_session_id: ^live_session_id,
          agent_state: agent_state
        } = meta
        when is_binary(agent_id) and is_map(agent_state) ->
          acc = recover_crashed_agent_turns(acc, agent_id)

          cond do
            current_agent(agent_id) ->
              put_live_foreground_agent(acc, agent_id)

            is_tuple(agent_crash_barrier_key(acc, agent_id)) ->
              acc

            true ->
              restore_foreground_agent(acc, settings, meta, agent_state)
          end

        _other_session_or_unpersisted ->
          acc
      end
    end)
  end

  defp restore_foreground_agent(state, settings, meta, agent_state) do
    opts =
      settings
      |> Keyword.put(:provider, meta.provider || Keyword.get(settings, :provider))
      |> Keyword.put(:workspace_root, state.path)
      |> Keyword.put(:id, meta.agent_id)
      |> Keyword.put(:durable_restore, agent_state)

    case AcpAgent.start_session(nil, opts) do
      {:ok, %{id: agent_id}} when agent_id == meta.agent_id ->
        _ = AcpAgent.reconcile_workspace(agent_id, state.path)
        put_live_foreground_agent(state, agent_id)

      _error ->
        state
    end
  catch
    :exit, _reason -> state
  end

  defp put_live_foreground_agent(state, agent_id) do
    case AcpAgent.whereis(agent_id) do
      pid when is_pid(pid) ->
        Map.update!(state, :agents, &Map.put(&1, agent_id, %{role: :foreground, pid: pid}))

      nil ->
        state
    end
  end

  defp ensure_foreground_agent(state, settings, live_view_pid) do
    live_session_id = foreground_session_key(settings)
    live_view_key = foreground_live_view_key(settings, live_view_pid)
    state = ensure_foregrounds(state)

    with {:ok, state} <- monitor_foreground_live_view(state, live_view_pid, live_view_key) do
      rail_key = active_foreground_key(state, live_view_key, live_session_id)
      {state, _agent_id, crash_barrier_key} = foreground_crash_barrier(state, rail_key)

      if is_tuple(crash_barrier_key) do
        {:pending, crash_barrier_key, state,
         %{
           operation: :start,
           settings: settings,
           rail_key: rail_key,
           live_view_key: live_view_key,
           live_session_id: live_session_id
         }}
      else
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
              _ = AcpAgent.reconcile_workspace(agent_id, state.path)
              _ = maybe_apply_settings(agent_id, settings)

              state =
                state
                |> activate_foreground(live_view_key, rail_key)
                |> remember_foreground_order(rail_key)

              {:ok, state, Map.merge(fg, %{rail_key: rail_key, live_session_id: live_session_id})}
            end

          nil ->
            start_foreground_agent(state, settings, rail_key, live_view_key)
        end
      end
    end
  end

  defp start_foreground_agent(state, settings, rail_key, live_view_key) do
    live_session_id = foreground_session_key(settings)
    agent_id = foreground_agent_id(state.path, rail_key)

    opts =
      settings
      |> Keyword.put(:workspace_root, state.path)
      |> Keyword.put(:id, agent_id)
      |> maybe_put_durable_restore(state, rail_key, agent_id)

    case AcpAgent.start_session(nil, opts) do
      {:ok, %{id: ^agent_id}} ->
        pid = AcpAgent.whereis(agent_id)
        _ = AcpAgent.reconcile_workspace(agent_id, state.path)
        requested_provider = Keyword.get(settings, :provider)
        bound_provider = live_agent_provider(agent_id) || requested_provider

        state =
          state
          |> put_foreground(
            live_session_id,
            live_view_key,
            rail_key,
            agent_id,
            bound_provider
          )
          |> Map.update!(:agents, &Map.put(&1, agent_id, %{role: :foreground, pid: pid}))

        if provider_switch?(bound_provider, requested_provider) do
          restart_foreground_agent(state, settings, rail_key, live_view_key)
        else
          {:ok, state,
           %{id: agent_id, pid: pid, rail_key: rail_key, live_session_id: live_session_id}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_durable_restore(opts, state, rail_key, agent_id) do
    case Map.get(state.foregrounds, rail_key) do
      %{agent_id: ^agent_id, agent_state: agent_state} when is_map(agent_state) ->
        Keyword.put(opts, :durable_restore, agent_state)

      _missing ->
        opts
    end
  end

  # A provider SWITCH only when both the bound and requested providers are known
  # and differ. A same-pid re-attach that doesn't pin a provider (nil) — or pins
  # the same one — reuses the active LiveView rail.
  defp provider_switch?(bound, requested)
       when is_binary(bound) and is_binary(requested),
       do: bound != requested

  defp provider_switch?(_bound, _requested), do: false

  defp live_agent_provider(agent_id) do
    case AcpAgent.agent_snapshot(agent_id) do
      %{provider: provider} when is_binary(provider) and provider != "" -> provider
      _missing -> nil
    end
  catch
    :exit, _reason -> nil
  end

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
    live_session_id = foreground_session_key(settings)
    live_view_key = foreground_live_view_key(settings, live_view_pid)
    state = ensure_foregrounds(state)

    with {:ok, state} <- monitor_foreground_live_view(state, live_view_pid, live_view_key) do
      rail_key = active_foreground_key(state, live_view_key, live_session_id)
      restart_foreground_agent(state, settings, rail_key, live_view_key)
    end
  end

  defp restart_foreground_agent(state, settings, rail_key, live_view_key) do
    live_session_id = foreground_session_key(settings)
    agent_id = foreground_agent_id(state.path, rail_key)
    state = recover_crashed_agent_turns(state, agent_id)

    case agent_crash_barrier_key(state, agent_id) do
      key when is_tuple(key) ->
        {:pending, key, state,
         %{
           operation: :restart,
           settings: settings,
           rail_key: rail_key,
           live_view_key: live_view_key,
           live_session_id: live_session_id
         }}

      nil ->
        case current_agent(agent_id) do
          nil ->
            restart_foreground_agent_now(state, settings, rail_key, live_view_key)

          %{pid: _pid} ->
            case AcpAgent.prepare_restart(agent_id, state.path) do
              :ready ->
                restart_foreground_agent_now(state, settings, rail_key, live_view_key)

              {:pending, key} ->
                {:pending, key, state,
                 %{
                   operation: :restart,
                   settings: settings,
                   rail_key: rail_key,
                   live_view_key: live_view_key,
                   live_session_id: live_session_id
                 }}

              {:error, reason} ->
                {:error, reason}
            end
        end
    end
  end

  defp restart_foreground_agent_now(state, settings, rail_key, live_view_key) do
    live_session_id = foreground_session_key(settings)
    agent_id = foreground_agent_id(state.path, rail_key)

    # Terminate any live agent under this path+session id and ensure the registry
    # slot is free before respawning — otherwise start_session re-attaches via
    # {:already_started, pid}.
    with :ok <- AcpAgent.close(agent_id),
         :ok <- await_agent_dead(agent_id) do
      opts =
        settings
        |> Keyword.put(:workspace_root, state.path)
        |> Keyword.put(:id, agent_id)

      case AcpAgent.start_session(nil, opts) do
        {:ok, %{id: ^agent_id}} ->
          pid = AcpAgent.whereis(agent_id)
          _ = AcpAgent.reconcile_workspace(agent_id, state.path)

          state =
            state
            |> release_agent_owners(agent_id)
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
          # Keep the rail metadata and its durable transcript intact. A later
          # attach can retry this same replacement without recovering a rail
          # that was prematurely deleted from disk.
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_new_foreground_agent(
         state,
         settings,
         active_rail_key,
         rail_key,
         live_view_key
       ) do
    live_session_id = foreground_session_key(settings)

    case Map.get(state.foregrounds, active_rail_key) do
      %{agent_id: old_agent_id} when is_binary(old_agent_id) ->
        state = recover_crashed_agent_turns(state, old_agent_id)

        case agent_crash_barrier_key(state, old_agent_id) do
          key when is_tuple(key) ->
            {:pending, key, state,
             %{
               operation: :start,
               settings: settings,
               rail_key: rail_key,
               live_view_key: live_view_key,
               live_session_id: live_session_id
             }}

          nil ->
            case current_agent(old_agent_id) do
              nil ->
                start_foreground_agent(state, settings, rail_key, live_view_key)

              %{pid: _pid} ->
                case AcpAgent.prepare_restart(old_agent_id, state.path) do
                  :ready ->
                    start_foreground_agent(state, settings, rail_key, live_view_key)

                  {:pending, key} ->
                    {:pending, key, state,
                     %{
                       operation: :start,
                       settings: settings,
                       rail_key: rail_key,
                       live_view_key: live_view_key,
                       live_session_id: live_session_id
                     }}

                  {:error, reason} ->
                    {:error, reason}
                end
            end
        end

      _missing ->
        start_foreground_agent(state, settings, rail_key, live_view_key)
    end
  end

  defp defer_foreground_transition(state, key, transition) do
    state = ensure_turn_finalizations(state)

    case Map.fetch(state.foreground_transitions, key) do
      {:ok, existing} ->
        if equivalent_foreground_transition?(existing, transition) do
          {:reply, {:pending, foreground_transition_ws(state, existing)}, state}
        else
          {:reply, {:error, :foreground_transition_in_progress}, state}
        end

      :error ->
        state = %{
          state
          | foreground_transitions: Map.put(state.foreground_transitions, key, transition)
        }

        {:reply, {:pending, foreground_transition_ws(state, transition)}, state}
    end
  end

  defp equivalent_foreground_transition?(left, right) do
    left.operation == right.operation and left.settings == right.settings and
      left.live_view_key == right.live_view_key and
      left.live_session_id == right.live_session_id
  end

  defp foreground_transition_ws(state, transition) do
    agent_id = foreground_agent_id(state.path, transition.rail_key)

    ws(
      state.path,
      transition.live_session_id,
      transition.rail_key,
      agent_id
    )
  end

  defp resume_foreground_transition(state, key) do
    state = ensure_turn_finalizations(state)

    case Map.pop(state.foreground_transitions, key) do
      {nil, _transitions} ->
        state

      {transition, transitions} ->
        state = %{state | foreground_transitions: transitions}
        state = recover_crashed_agent_turns(state, elem(key, 0))

        case agent_crash_barrier_key(state, elem(key, 0)) do
          next_key when is_tuple(next_key) ->
            # Multiple dead instances of the same stable agent id can race. The
            # replacement transition advances only after every exact crash key
            # has reached its own terminal acknowledgement.
            %{
              state
              | foreground_transitions:
                  Map.put(state.foreground_transitions, next_key, transition)
            }

          nil ->
            result =
              case transition.operation do
                :restart ->
                  restart_foreground_agent_now(
                    state,
                    transition.settings,
                    transition.rail_key,
                    transition.live_view_key
                  )

                :start ->
                  start_foreground_agent(
                    state,
                    transition.settings,
                    transition.rail_key,
                    transition.live_view_key
                  )
              end

            case result do
              {:ok, state, %{id: agent_id, rail_key: rail_key}} ->
                ws = ws(state.path, transition.live_session_id, rail_key, agent_id)
                notify_foreground_rebind(state, transition.live_view_key, ws)

              {:error, reason} ->
                notify_foreground_transition_failed(state, transition, reason)
                state
            end
        end
    end
  end

  defp foreground_transition_pending?(state, agent_id) do
    Enum.any?(state.foreground_transitions, fn
      {{^agent_id, _instance_id, _turn_id}, _transition} -> true
      _other -> false
    end)
  end

  defp foreground_transition_pending_for_live_view?(state, live_view_pid) do
    case current_foreground_agent_id(state, live_view_pid) do
      {:ok, agent_id} -> foreground_transition_pending?(state, agent_id)
      {:error, :no_agent} -> false
    end
  end

  defp notify_foreground_transition_failed(state, transition, reason) do
    Enum.each(state.foreground_live_views, fn
      {pid, live_view_key}
      when is_pid(pid) and live_view_key == transition.live_view_key ->
        send(pid, {:workspace_foreground_transition_failed, reason})

      _other ->
        :ok
    end)
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
        {:error, :agent_stop_timeout}

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

  defp recover_crashed_agent_turns(state, agent_id) when is_binary(agent_id) do
    state = ensure_turn_finalizations(state)
    registered_pid = AcpAgent.whereis(agent_id)

    Enum.reduce(state.agent_turn_owners, state, fn
      {{^agent_id, _instance_id, _turn_id} = key, %{status: :active} = owner}, acc ->
        if owner.owner_pid != registered_pid or not Process.alive?(owner.owner_pid) do
          begin_crashed_agent_turn(acc, key, owner, :owner_process_unavailable)
        else
          acc
        end

      _other, acc ->
        acc
    end)
  end

  defp recover_crashed_agent_turns(state, _agent_id), do: ensure_turn_finalizations(state)

  defp agent_crash_barrier_key(state, agent_id) when is_binary(agent_id) do
    Enum.find_value(state.agent_turn_owners, fn
      {{^agent_id, _instance_id, _turn_id} = key, %{status: status}}
      when status in [:awaiting_task_down, :crashed] ->
        key

      _other ->
        nil
    end)
  end

  defp agent_crash_barrier_key(_state, _agent_id), do: nil

  defp foreground_crash_barrier(state, rail_key) do
    case Map.get(state.foregrounds, rail_key) do
      %{agent_id: agent_id} when is_binary(agent_id) ->
        state = recover_crashed_agent_turns(state, agent_id)
        {state, agent_id, agent_crash_barrier_key(state, agent_id)}

      _missing ->
        {state, nil, nil}
    end
  end

  defp maybe_apply_settings(_agent_id, []), do: :ok

  # Keys owned by the durable session (set via select_agent_reasoning/access
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

  defp foreground_live_view_key(settings, pid) when is_list(settings) and is_pid(pid) do
    case Keyword.get(settings, :chat_rail_id) do
      id when is_binary(id) and id != "" ->
        "tab-" <>
          (:crypto.hash(:sha256, foreground_session_key(settings) <> <<0>> <> id)
           |> Base.url_encode64(padding: false)
           |> binary_part(0, 20))

      _ ->
        foreground_live_view_key(pid)
    end
  end

  defp current_foreground_agent_id(state, live_view_pid) when is_pid(live_view_pid) do
    with live_view_key when is_binary(live_view_key) <-
           Map.get(state.foreground_live_views, live_view_pid),
         rail_key when is_binary(rail_key) <- Map.get(state.active_foregrounds, live_view_key),
         %{agent_id: agent_id} when is_binary(agent_id) <- Map.get(state.foregrounds, rail_key) do
      {:ok, agent_id}
    else
      _ -> {:error, :no_agent}
    end
  end

  defp monitor_foreground_live_view(state, pid, live_view_key)
       when is_pid(pid) and is_binary(live_view_key) do
    state = state |> ensure_maps() |> ensure_foregrounds()

    case Map.get(state.foreground_live_views, pid) do
      current_key when is_binary(current_key) ->
        if current_key == live_view_key do
          {:ok, state}
        else
          {:error, :tab_identity_changed}
        end

      nil ->
        monitor_live_view_once(pid)

        {:ok,
         %{
           state
           | foreground_live_views: Map.put(state.foreground_live_views, pid, live_view_key)
         }}
    end
  end

  defp monitor_live_view_once(pid) when is_pid(pid) do
    monitored? =
      case Process.info(self(), :monitors) do
        {:monitors, monitors} -> {:process, pid} in monitors
        _ -> false
      end

    if monitored?, do: nil, else: Process.monitor(pid)
  end

  defp drop_live_view_foreground(state, pid) when is_pid(pid) do
    state
    |> ensure_foregrounds()
    |> drop_live_view_foreground_entry(pid)
  end

  defp drop_live_view_foreground_entry(state, pid) when is_pid(pid) do
    case Map.pop(state.foreground_live_views, pid) do
      {nil, _foreground_live_views} ->
        state

      {live_view_key, foreground_live_views} ->
        state = %{state | foreground_live_views: foreground_live_views}
        rail_key = Map.get(state.active_foregrounds, live_view_key)

        state =
          if is_binary(rail_key) and not foreground_active?(state, rail_key) do
            case Map.get(state.foregrounds, rail_key) do
              %{agent_id: agent_id} when is_binary(agent_id) ->
                release_agent_owners(state, agent_id)

              _ ->
                state
            end
          else
            state
          end

        if stable_live_view_key?(live_view_key) do
          state
        else
          {_rail_key, active_foregrounds} = Map.pop(state.active_foregrounds, live_view_key)
          state = %{state | active_foregrounds: active_foregrounds}

          state =
            if is_binary(rail_key) and empty_foreground?(state, rail_key) and
                 not foreground_active?(state, rail_key) do
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

          persist_chat_rail_state(state)
        end
    end
  end

  defp prune_dead_foreground_live_views(state) do
    state.foreground_live_views
    |> Map.keys()
    |> Enum.reject(&Process.alive?/1)
    |> Enum.reduce(state, fn pid, acc -> drop_live_view_foreground_entry(acc, pid) end)
  end

  defp foreground_active?(state, rail_key) do
    Enum.any?(state.foreground_live_views, fn {_pid, live_view_key} ->
      Map.get(state.active_foregrounds, live_view_key) == rail_key
    end)
  end

  defp stable_live_view_key?("tab-" <> _rest), do: true
  defp stable_live_view_key?(_live_view_key), do: false

  defp foreground_provider(state, rail_key) do
    state = ensure_foregrounds(state)

    case Map.get(state.foregrounds, rail_key) do
      %{provider: provider} -> provider
      _ -> nil
    end
  end

  @chat_rail_state_keys [:foregrounds, :active_foregrounds, :foreground_order]

  defp restore_chat_rail_state(%{path: path} = state) do
    case WorkspaceHandoff.fetch_chat_rail_state(path) do
      {:ok, rail_state} when is_map(rail_state) ->
        foregrounds =
          rail_state
          |> Map.get(:foregrounds, %{})
          |> Enum.filter(fn
            {rail_key, %{agent_id: agent_id}}
            when is_binary(rail_key) and is_binary(agent_id) ->
              foreground_agent_id(path, rail_key) == agent_id

            _foreground ->
              false
          end)
          |> Map.new()

        state =
          state
          |> Map.merge(
            rail_state
            |> Map.take(@chat_rail_state_keys)
            |> Map.put(:foregrounds, foregrounds)
          )
          |> ensure_foregrounds()

        agents =
          Enum.reduce(state.foregrounds, state.agents, fn
            {_rail_key, %{agent_id: agent_id}}, agents when is_binary(agent_id) ->
              case AcpAgent.whereis(agent_id) do
                pid when is_pid(pid) ->
                  Map.put(agents, agent_id, %{role: :foreground, pid: pid})

                nil ->
                  agents
              end

            _foreground, agents ->
              agents
          end)

        %{state | agents: agents}

      _missing_or_unavailable ->
        state
    end
  end

  defp persist_chat_rail_state(state) do
    state = ensure_foregrounds(state)

    foregrounds =
      Map.new(state.foregrounds, fn {rail_key, meta} ->
        try do
          agent_state =
            case AcpAgent.durable_snapshot(meta.agent_id) do
              snapshot when is_map(snapshot) -> snapshot
              _unavailable -> Map.get(meta, :agent_state)
            end

          {rail_key,
           if(is_map(agent_state), do: Map.put(meta, :agent_state, agent_state), else: meta)}
        catch
          :exit, _reason -> {rail_key, meta}
        end
      end)

    rail_state = state |> Map.take(@chat_rail_state_keys) |> Map.put(:foregrounds, foregrounds)
    _ = WorkspaceHandoff.put_chat_rail_state(state.path, rail_state)
    %{state | foregrounds: foregrounds}
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

    foreground_live_views =
      state
      |> Map.get(:foreground_live_views, %{})
      |> normalize_foreground_live_views(active_foregrounds)

    foreground_order =
      case Map.fetch(state, :foreground_order) do
        {:ok, order} when is_list(order) -> order
        _missing_or_invalid -> Map.keys(foregrounds)
      end
      |> Enum.filter(&Map.has_key?(foregrounds, &1))
      |> then(&Enum.uniq(&1 ++ Map.keys(foregrounds)))

    state
    |> Map.put(:foregrounds, foregrounds)
    |> Map.put(:active_foregrounds, active_foregrounds)
    |> Map.put(:foreground_live_views, foreground_live_views)
    |> Map.put(:foreground_order, foreground_order)
    |> Map.delete(:superseded_foreground_live_views)
    |> prune_dead_foreground_live_views()
  end

  defp notify_foreground_rebind(state, live_view_key, ws) do
    Enum.each(state.foreground_live_views, fn
      {pid, ^live_view_key} when is_pid(pid) ->
        send(pid, {:workspace_foreground_rebound, ws})

      _other ->
        :ok
    end)

    state
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

      normalized = %{
        agent_id: meta[:agent_id],
        provider: Map.get(meta, :provider),
        owner_session_id: owner_session_id
      }

      normalized =
        case Map.get(meta, :agent_state) do
          agent_state when is_map(agent_state) -> Map.put(normalized, :agent_state, agent_state)
          _missing -> normalized
        end

      {rail_key, normalized}
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

  defp normalize_foreground_live_views(foreground_live_views, _active_foregrounds)
       when is_map(foreground_live_views) do
    foreground_live_views
    |> Enum.filter(fn {pid, live_view_key} -> is_pid(pid) and is_binary(live_view_key) end)
    |> Map.new()
  end

  defp normalize_foreground_live_views(_foreground_live_views, _active_foregrounds), do: %{}

  defp active_foreground_key(state, live_view_key, live_session_id) do
    state = ensure_foregrounds(state)

    case Map.get(state.active_foregrounds, live_view_key) do
      rail_key when is_binary(rail_key) and is_map_key(state.foregrounds, rail_key) ->
        rail_key

      _ ->
        legacy_rail_for_first_stable_tab(state, live_view_key, live_session_id) || live_view_key
    end
  end

  # Hot-upgrade bridge: rails created before the browser-tab id existed used an
  # `lv-*` pid key. On the first refresh after deployment, adopt the newest
  # inactive legacy rail instead of manufacturing a blank conversation. Once a
  # stable `tab-*` binding exists for this browser session, other tabs get their
  # own rail as normal.
  defp legacy_rail_for_first_stable_tab(state, "tab-" <> _rest, live_session_id) do
    if stable_tab_bound?(state, live_session_id) do
      nil
    else
      Enum.find(state.foreground_order, fn rail_key ->
        String.starts_with?(rail_key, "lv-") and
          match?(
            %{owner_session_id: ^live_session_id},
            Map.get(state.foregrounds, rail_key)
          ) and
          not foreground_active?(state, rail_key)
      end)
    end
  end

  defp legacy_rail_for_first_stable_tab(_state, _live_view_key, _live_session_id), do: nil

  defp stable_tab_bound?(state, live_session_id) do
    Enum.any?(state.active_foregrounds, fn
      {"tab-" <> _rest, rail_key} ->
        match?(
          %{owner_session_id: ^live_session_id},
          Map.get(state.foregrounds, rail_key)
        )

      _other ->
        false
    end)
  end

  defp put_foreground(state, live_session_id, live_view_key, rail_key, agent_id, provider) do
    state = ensure_foregrounds(state)
    new_rail? = not Map.has_key?(state.foregrounds, rail_key)

    foregrounds =
      Map.put(state.foregrounds, rail_key, %{
        agent_id: agent_id,
        provider: provider,
        owner_session_id: live_session_id
      })

    state =
      %{state | foregrounds: foregrounds}
      |> activate_foreground(live_view_key, rail_key)
      |> remember_foreground_order(rail_key, new_rail?)

    if rail_key == @default_live_session_id or is_nil(Map.get(state, :foreground_id)) do
      %{state | foreground_id: agent_id, foreground_provider: provider}
    else
      state
    end
  end

  defp activate_foreground(state, live_view_key, rail_key) do
    state = state |> ensure_maps() |> ensure_foregrounds()
    previous_rail_key = Map.get(state.active_foregrounds, live_view_key)

    state = %{
      state
      | active_foregrounds: Map.put(state.active_foregrounds, live_view_key, rail_key)
    }

    release_inactive_foreground_owners(state, previous_rail_key, rail_key)
  end

  defp release_inactive_foreground_owners(state, previous_rail_key, rail_key)
       when previous_rail_key in [nil, rail_key],
       do: state

  defp release_inactive_foreground_owners(state, previous_rail_key, _rail_key) do
    previous_still_active? = foreground_active?(state, previous_rail_key)

    if previous_still_active? do
      state
    else
      case Map.get(state.foregrounds, previous_rail_key) do
        %{agent_id: agent_id} when is_binary(agent_id) -> release_agent_owners(state, agent_id)
        _ -> state
      end
    end
  end

  defp release_agent_owners(state, agent_id) do
    %{state | owners: Map.reject(state.owners, fn {_document_id, owner} -> owner == agent_id end)}
  end

  # `foreground_order` is the complete durable rail-list order, not an
  # access-time MRU. The 12-item display cap is applied only after filtering it
  # to one browser session.
  # Merely selecting an old rail or re-attaching after a browser refresh must
  # not move it to the front. A genuinely new rail is prepended once; existing
  # rails retain their stored position.
  defp remember_foreground_order(state, rail_key, new_rail? \\ false) do
    state = ensure_foregrounds(state)

    foreground_order =
      cond do
        new_rail? ->
          [rail_key | Enum.reject(state.foreground_order, &(&1 == rail_key))]

        rail_key in state.foreground_order ->
          state.foreground_order

        true ->
          state.foreground_order ++ [rail_key]
      end

    %{state | foreground_order: foreground_order}
    |> persist_chat_rail_state()
  end

  defp drop_foreground(state, rail_key, agent_id) do
    state = state |> ensure_maps() |> ensure_foregrounds() |> release_agent_owners(agent_id)

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

    state =
      if Map.get(state, :foreground_id) == agent_id do
        %{state | foreground_id: nil, foreground_provider: nil}
      else
        state
      end

    persist_chat_rail_state(state)
  end

  defp drop_active_foreground(active_foregrounds, rail_key) do
    active_foregrounds
    |> Enum.reject(fn {_live_view_key, active_rail_key} -> active_rail_key == rail_key end)
    |> Map.new()
  end

  defp recent_foregrounds_for(state, live_session_id, active_rail_key) do
    state = ensure_foregrounds(state)

    state
    |> recent_foreground_order(live_session_id, active_rail_key)
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
            active?: rail_key == active_rail_key and foreground_active?(state, rail_key)
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp recent_foreground_order(state, live_session_id, active_rail_key) do
    order =
      state.foreground_order
      |> Enum.filter(fn rail_key ->
        match?(
          %{owner_session_id: ^live_session_id},
          Map.get(state.foregrounds, rail_key)
        )
      end)
      |> Enum.take(@max_recent_foregrounds)

    cond do
      active_rail_key in order ->
        order

      match?(
        %{owner_session_id: ^live_session_id},
        Map.get(state.foregrounds, active_rail_key)
      ) ->
        Enum.take(order, @max_recent_foregrounds - 1) ++ [active_rail_key]

      true ->
        order
    end
  end

  defp new_foreground_key(live_view_key) do
    live_view_key <> ":rail:" <> Ecto.UUID.generate()
  end

  # Normalize both the current newest-first representation and legacy hot state,
  # where each document mapped directly to one pid. Dead candidates are pruned
  # here so a call racing a delayed :DOWN promotes a live fallback immediately.
  defp normalize_viewers(viewers) when is_map(viewers) do
    Enum.reduce(viewers, %{}, fn {document_id, candidates}, acc ->
      candidates =
        candidates
        |> viewer_candidates()
        |> Enum.filter(&(is_pid(&1) and Process.alive?(&1)))
        |> Enum.uniq()

      if candidates == [], do: acc, else: Map.put(acc, document_id, candidates)
    end)
  end

  defp normalize_viewers(_viewers), do: %{}

  defp viewer_candidates(pid) when is_pid(pid), do: [pid]
  defp viewer_candidates(candidates) when is_list(candidates), do: candidates
  defp viewer_candidates(_candidates), do: []

  # Remove `lv` from EVERY doc it currently views (a previously-viewed doc it
  # navigated away from, or a crashed viewer's claims), retaining other viewers.
  defp drop_viewer_everywhere(viewers, lv) do
    Enum.reduce(viewers, %{}, fn {document_id, candidates}, acc ->
      remaining = Enum.reject(viewer_candidates(candidates), &(&1 == lv))
      if remaining == [], do: acc, else: Map.put(acc, document_id, remaining)
    end)
  end

  defp drop_viewer_from_document(viewers, document_id, lv) do
    case Map.get(viewers, document_id) do
      nil ->
        viewers

      candidates ->
        case Enum.reject(viewer_candidates(candidates), &(&1 == lv)) do
          [] -> Map.delete(viewers, document_id)
          remaining -> Map.put(viewers, document_id, remaining)
        end
    end
  end

  # Stable foreground-agent id for a workspace path + rail key. Browser tabs keep
  # the same rail key across refresh; direct callers can still use a pid-derived
  # compatibility key. The default key preserves the older path-only id.
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
