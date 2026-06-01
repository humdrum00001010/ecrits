defmodule Contract.Context do
  @moduledoc """
  The request-scoped context (`T.ctx`) threaded through every Contract Studio
  module.

  Every public function in `Contract.Studio`, `Contract.Runtime`,
  `Contract.Engine`, `Contract.IO`, `Contract.Agent`, etc. takes a
  `%Contract.Context{}` as its first argument. It replaces the
  `phx.gen.auth`-generated `Contract.Accounts.Scope` while remaining
  compatible with the generated user-auth plumbing (the assign key is still
  `:current_scope`, and `for_user/1` is still the constructor used by
  `user_auth.ex`).

  Fields:

    * `:user` — the authenticated `Contract.Accounts.User` struct, or `nil`.
    * `:tenant` — tenant identifier, scoped per request (nil until populated).
    * `:request_id` — Plug request id, useful for log correlation.
    * `:now` — frozen request timestamp for deterministic time-based logic.
    * `:perms` — permission set (map or list, shape TBD).
  """

  alias Contract.Accounts.User

  @type t :: %__MODULE__{
          user: User.t() | nil,
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
  Builds a context for the given user.

  Returns `nil` if no user is given, matching the legacy auth contract used
  by older document-scoped code.
  """
  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
