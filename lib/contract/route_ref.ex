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
  produced by the default `Contract.Gateway.issue_route_ref/2` path. That
  bearer is deterministic across all turns of the same `(user_id,
  document_id, chat_thread_id)` triple so cacheable MCP `tools/list`
  callers can reuse the catalog instead of cold-rebuilding it.

  The per-turn `agent_run_id` is never reconstructed from whatever run
  happens to be active later. A nil-agent bearer remains nil and doc.*
  handlers reject it. If a handler receives a caller-supplied run id, it
  must prove that id is the active `Contract.Agent.Document` attempt for
  the same `(user_id, document_id)` before stamping a change.

  A current `Contract.Agent.Document` attempt may explicitly opt into a
  run-bound route_ref payload. That token is no longer the deterministic
  list-cache bearer; it exists so hosted `doc.*` calls can prove the
  semantic run identity without relying on the model to pass an
  undocumented `agent_run_id` tool argument.
  """

  @type purpose :: String.t()
  @type scope :: String.t() | atom()
  @type t :: %__MODULE__{
          document_id: binary() | nil,
          user_id: binary() | nil,
          chat_thread_id: binary() | nil,
          agent_run_id: binary() | nil,
          agent_run_id_source: atom() | nil,
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
    :agent_run_id_source,
    :base_revision,
    :purpose,
    :issued_at,
    :expires_at,
    :scopes
  ]
end
