defmodule Contract.Config do
  @moduledoc """
  Startup configuration guard.

  Crashes the supervisor at boot (in `:prod`) if any required runtime
  environment variable is missing. In `:dev` and `:test` it logs warnings
  but does not crash, so contributors can iterate without provisioning
  the full external-service stack.

  Called from `Contract.Application.start/2` before any other child is
  started, so the failure mode is loud and immediate.
  """

  require Logger

  @required_prod ~w(
    OPENAI_API_KEY UPSTAGE_API_KEY LAW_OC
    MAIL_HOST MAIL_PORT MAIL_USERNAME MAIL_PASSWORD
    MAIL_FROM_ADDRESS MAIL_FROM_NAME SECRET_KEY_BASE
  )

  @required_nonprod ~w(
    OPENAI_API_KEY UPSTAGE_API_KEY LAW_OC
    MAIL_HOST MAIL_PORT MAIL_USERNAME MAIL_PASSWORD
    MAIL_FROM_ADDRESS MAIL_FROM_NAME
  )

  @doc """
  Verify that required env vars are present for the given Mix env.

  In `:prod`, a missing key raises `RuntimeError` (which crashes the
  supervisor and surfaces at boot). In other envs, missing keys are
  logged at `:warning` level and execution continues.

  Returns `:ok` on success.
  """
  @spec assert_loaded!(atom()) :: :ok
  def assert_loaded!(:prod) do
    case missing(@required_prod) do
      [] ->
        :ok

      keys ->
        raise """
        Contract.Config: missing required environment variables for :prod:

            #{Enum.join(keys, ", ")}

        Populate .env or the process environment and restart.
        """
    end
  end

  def assert_loaded!(env) when env in [:dev, :test] do
    case missing(@required_nonprod) do
      [] ->
        :ok

      keys ->
        Logger.warning(
          "Contract.Config: missing env vars (#{env}): #{Enum.join(keys, ", ")} — " <>
            "some features (mailer, OpenAI, Upstage, Korean Law MCP) will not work."
        )

        :ok
    end
  end

  def assert_loaded!(_other), do: :ok

  @spec required_keys(atom()) :: [String.t()]
  def required_keys(:prod), do: @required_prod
  def required_keys(_), do: @required_nonprod

  defp missing(keys) do
    Enum.filter(keys, fn k ->
      case System.get_env(k) do
        nil -> true
        "" -> true
        _ -> false
      end
    end)
  end
end
