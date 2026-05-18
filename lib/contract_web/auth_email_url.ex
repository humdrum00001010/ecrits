defmodule ContractWeb.AuthEmailURL do
  @moduledoc """
  URL builders for auth emails.

  In local development and mailbox-preview flows we keep links relative so
  they work on the current host (including /dev/mailbox).
  In production we keep full URLs so outbound links are fully qualified.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: ContractWeb.Endpoint,
    router: ContractWeb.Router,
    statics: ContractWeb.static_paths()

  @doc "Build login magic-link URL for email deliveries."
  def login_url(token) when is_binary(token) do
    login_path = ~p"/users/log-in/#{token}"
    auth_email_url(login_path)
  end

  @doc "Build email-confirmation URL for email update instructions."
  def confirm_email_url(token) when is_binary(token) do
    confirm_path = ~p"/users/settings/confirm-email/#{token}"
    auth_email_url(confirm_path)
  end

  @doc "Whether we can show the local mailbox helper in auth views."
  def mailbox_visible? do
    Application.get_env(:contract, :dev_routes) == true or local_mail_adapter?()
  end

  defp auth_email_url(path) do
    if mailbox_visible?() do
      path
    else
      ContractWeb.Endpoint.url() <> path
    end
  end

  defp local_mail_adapter? do
    Application.get_env(:contract, Contract.Mailer, [])[:adapter] == Swoosh.Adapters.Local
  end
end
