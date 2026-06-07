defmodule EcritsWeb.Plugs.WorkspaceSession do
  @moduledoc """
  Ensures a stable per-browser `ws_id` lives in the (server-signed) Phoenix
  session — the single durable handle the workspace records.

  It keys two long-running, server-side things so a browser refresh resumes the
  same shell instead of starting fresh:

    * the supervised `Ecrits.Local.AcpAgent.Session` GenServer (which survives the
      LiveView dying) — so the chat conversation re-attaches, and
    * the in-memory `Ecrits.Local.Workspace.ShellStore` (open tabs + last path).

  Written once on the first request and re-presented by the browser on every
  later request (including the LiveView socket connect), so it survives F5. It is
  NOT the agent conversation id — that stays the provider's (codex thread). This
  is purely the stable browser handle. Cleared only when the cookie is cleared.
  """
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, "ws_id") do
      nil -> put_session(conn, "ws_id", Ecto.UUID.generate())
      _id -> conn
    end
  end
end
