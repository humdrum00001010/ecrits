defmodule Ecrits.Context do
  @moduledoc """
  The request-scoped context (`T.ctx`) threaded through every ecrits
  module.

  It is the first argument threaded through the surviving local-first
  components (the studio chrome data structures still carry a context).
  The SaaS `Ecrits.Accounts` user layer is retired, so `:user` is now an
  opaque term (always `nil` in the local-first app).

  Fields:

    * `:user` — opaque user term, or `nil` (auth layer retired).
    * `:tenant` — tenant identifier, scoped per request (nil until populated).
    * `:request_id` — Plug request id, useful for log correlation.
    * `:now` — frozen request timestamp for deterministic time-based logic.
    * `:perms` — permission set (map or list, shape TBD).
  """

  @type t :: %__MODULE__{
          user: term() | nil,
          tenant: term() | nil,
          request_id: String.t() | nil,
          now: DateTime.t() | nil,
          perms: term() | nil
        }

  defstruct user: nil,
            tenant: nil,
            request_id: nil,
            now: nil,
            perms: nil

  @doc """
  Builds a context for the given user term, or `nil` when no user is given.
  """
  # [deprecated] dead code — no callers in lib or test (dead-code audit 2026-07-13: xref + repo grep + runtime trace)
  @spec for_user(term() | nil) :: t() | nil
  def for_user(nil), do: nil
  def for_user(user), do: %__MODULE__{user: user}
end
