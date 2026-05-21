defmodule Contract.RouteRef do
  @moduledoc """
  A signed, opaque, time-bounded reference that authorizes an external client
  (Slack thread, MCP tool caller, deep link) to act on a specific document without ever seeing a BEAM pid.

  Per SPEC.md §15 invariant 2: a BEAM pid MUST NOT be exposed externally as
  routing authority. RouteRefs only carry durable binary_ids — `document_id`, plus a purpose string and a scope list. They are signed via
  `Phoenix.Token` so the server can verify them statelessly without a DB
  lookup.

  See SPEC.md §21 (Gateway).

  ## Deterministic bearer per (user, doc, thread) — task #139

  The `agent_run_id` field is **NOT** included in the signed payload
  produced by `Contract.Gateway.issue_route_ref/2`. The bearer is
  deterministic across all turns of the same `(user_id, document_id,
  chat_thread_id)` triple so OpenAI's hosted MCP `tools/list` cache
  (keyed by bearer) hits across turns instead of cold-rebuilding the
  tool catalog every first message of every turn (~700ms).

  The per-turn `agent_run_id` is reconstructed server-side at MCP
  submit_change time by looking up the active `Contract.Agent.RunServer`
  for `(user_id, document_id)` in `Contract.Agent.ScopeRegistry`. That
  avoids leaking the run id through the token *and* keeps the change
  row's `actor_type: :agent` / `agent_run_id` stamp truthful — the run
  that's actually live is the one that gets credited.

  The struct still carries `agent_run_id` for one purpose only: a tool
  handler can populate it from the server-side lookup before passing
  the (struct-shaped) RouteRef into `Contract.MCP.build_command/3` and
  related helpers — i.e. it's a runtime field, never part of what the
  client sees.
  """

  @type purpose :: String.t()
  @type scope :: String.t() | atom()
  @type t :: %__MODULE__{
          document_id: binary() | nil,
          user_id: binary() | nil,
          chat_thread_id: binary() | nil,
          agent_run_id: binary() | nil,
          base_revision: integer() | nil,
          purpose: purpose(),
          issued_at: DateTime.t(),
          expires_at: DateTime.t(),
          scopes: [scope()]
        }

  defstruct [
    :document_id,
    :user_id,
    :chat_thread_id,
    :agent_run_id,
    :base_revision,
    :purpose,
    :issued_at,
    :expires_at,
    :scopes
  ]
end
