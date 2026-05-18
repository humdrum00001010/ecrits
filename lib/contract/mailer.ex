defmodule Contract.Mailer do
  use Swoosh.Mailer, otp_app: :contract

  @doc """
  Default From tuple, sourced from application env at runtime.

  Set in `config/runtime.exs` as:

      config :contract, :mail_from, {"계약기계", "ereignis@korea.ac.kr"}

  In dev/test where the env var may not be set, returns a placeholder
  so the generated `UserNotifier` keeps working under
  `Swoosh.Adapters.Local` and `Swoosh.Adapters.Test`.
  """
  @spec from() :: {String.t(), String.t()}
  def from do
    Application.get_env(:contract, :mail_from, {"계약기계", "no-reply@example.com"})
  end
end
