defmodule Contract.Mailer do
  use Swoosh.Mailer, otp_app: :contract

  @doc """
  Default From tuple, sourced from application env at runtime.

  Set in `config/runtime.exs` as:

      config :contract, :mail_from, {"Contract", "ereignis@korea.ac.kr"}

  In dev/test where the env var may not be set, returns a placeholder
  so the generated `UserNotifier` keeps working under
  `Swoosh.Adapters.Local` and `Swoosh.Adapters.Test`.
  """
  @spec from() :: {String.t(), String.t()}
  def from do
    Application.get_env(:contract, :mail_from, {"Contract", "no-reply@example.com"})
  end

  @doc """
  Build the Swoosh SMTP adapter config from an env-var map.

  Used by `config/runtime.exs` in `:prod` only. Tests exercise this
  pure function to verify the prod-mode config without standing up
  a real release. Accepts the same key set the runtime config reads:
  MAIL_HOST, MAIL_PORT, MAIL_USERNAME, MAIL_PASSWORD.

  Returns a keyword list suitable for `config :contract, Contract.Mailer, ...`.
  Raises `KeyError` if any required key is missing — the prod boot
  must fail loudly rather than ship a half-configured mailer.
  """
  @spec smtp_config(%{optional(String.t()) => String.t()}) :: keyword()
  def smtp_config(env) do
    host = Map.fetch!(env, "MAIL_HOST")

    [
      adapter: Swoosh.Adapters.SMTP,
      relay: host,
      port: env |> Map.fetch!("MAIL_PORT") |> String.to_integer(),
      ssl: true,
      tls: :never,
      auth: :always,
      username: Map.fetch!(env, "MAIL_USERNAME"),
      password: Map.fetch!(env, "MAIL_PASSWORD"),
      retries: 2,
      no_mx_lookups: true,
      sockopts: [
        versions: [:"tlsv1.2", :"tlsv1.3"],
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ],
        server_name_indication: String.to_charlist(host)
      ]
    ]
  end
end
