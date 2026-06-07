defmodule Ecrits.Local.Workspace.ShellStore do
  @moduledoc """
  In-memory per-browser workspace shell state, keyed by the `ws_id` planted in
  the Phoenix session (see `EcritsWeb.Plugs.WorkspaceSession`).

  Holds the parts of the workspace shell that are genuinely OURS and that the
  LiveView would otherwise lose when it terminates (navigation / reconnect /
  browser refresh):

    * `:path`        — the mounted workspace root,
    * `:tabs`        — the list of open editor tabs (`%{id, name, path}`),
    * `:active_id`   — the focused tab,
    * `:active_path` — its path.

  A browser refresh rehydrates these from here on mount. Intentionally NOT
  persisted to disk — a server restart clears it (that is the product rule:
  in-memory only).

  The agent CHAT is deliberately NOT stored here. The conversation is owned by
  the provider (codex thread) and reached through the long-running
  `Ecrits.Local.AcpAgent.Session`, which is itself keyed by the same `ws_id` and
  survives the LiveView — so a refresh re-attaches to it via the existing
  `{:already_started, pid}` path. This store is only the surrounding shell.
  """
  use Agent

  def start_link(_opts) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @doc "The saved shell state for a browser key (empty map when none)."
  def get(ws_id) when is_binary(ws_id) and ws_id != "" do
    # Defensive: tolerate the store not being started yet (e.g. a dev hot-reload
    # of the calling LiveView before the supervisor child boots) — never crash a
    # mount over missing persistence.
    if Process.whereis(__MODULE__),
      do: Agent.get(__MODULE__, &Map.get(&1, ws_id, %{})),
      else: %{}
  end

  def get(_ws_id), do: %{}

  @doc "Merge `attrs` into the saved shell state for `ws_id` (no-op for a bad key)."
  def merge(ws_id, attrs) when is_binary(ws_id) and ws_id != "" and is_map(attrs) do
    if Process.whereis(__MODULE__) do
      Agent.update(__MODULE__, fn state ->
        Map.update(state, ws_id, attrs, &Map.merge(&1, attrs))
      end)
    end

    :ok
  end

  def merge(_ws_id, _attrs), do: :ok
end
