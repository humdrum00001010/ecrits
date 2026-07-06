defmodule Ecrits.Workspace.Session.Agent do
  @moduledoc """
  Session-owned agent state.

  The canonical workspace session persists this shape for an agent. The ACP
  runner can be restarted or resumed from it, but does not own this state.
  """

  @type id :: String.t()
  @type role :: :foreground | :background
  @type provider_id :: String.t()
  @type adapter_opts :: keyword()
  @type transcript_item :: map()
  @type queued_turn :: map()
  @type current_turn :: %{id: String.t(), status: atom()} | map()
  @type mcp_server :: %{required(String.t()) => String.t()}

  @type ref :: %{
          pid: pid(),
          role: role()
        }

  @type t :: %__MODULE__{
          id: id(),
          role: role(),
          pid: pid() | nil,
          provider: provider_id() | nil,
          provider_session_id: String.t() | nil,
          title: String.t() | nil,
          title_user_edited?: boolean(),
          transcript: [transcript_item()],
          queue: [queued_turn()],
          current_turn: current_turn() | nil,
          adapter_opts: adapter_opts(),
          mcp_servers: [mcp_server()]
        }

  defstruct id: nil,
            role: :foreground,
            pid: nil,
            provider: nil,
            provider_session_id: nil,
            title: nil,
            title_user_edited?: false,
            transcript: [],
            queue: [],
            current_turn: nil,
            adapter_opts: [],
            mcp_servers: []
end
