defmodule Contract.Workers.MailerJob do
  @moduledoc """
  Retired Oban mailer worker kept as a compile stub.
  """

  def new(args) when is_map(args), do: %{worker: __MODULE__, args: args}

  def perform(%{args: %{"kind" => kind, "args" => args}}) when is_binary(kind) do
    fun = String.to_existing_atom("perform_" <> kind)
    apply(Contract.Accounts.UserNotifier, fun, [args])
  end

  def perform(_job), do: {:error, :db_retired}
end
