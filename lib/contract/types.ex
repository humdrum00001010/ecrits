defmodule Contract.Types do
  @moduledoc """
  Coarse type aliases used in `@spec` annotations across `Contract.*`.

  These are NOT a substitute for Ecto schemas — they only thin out the noise
  in module specs. See SPEC.md §3.
  """

  @type id :: Ecto.UUID.t()
  @type ctx :: Contract.Context.t()
  @type result(value) :: {:ok, value} | {:error, term()}

  @type user_id :: id()
  @type owner_id :: id()
  @type tenant_id :: id()
  @type document_id :: id()
  @type change_id :: id()
  @type mark_id :: id()
  @type field_id :: id()
  @type agent_run_id :: id()
  @type chat_thread_id :: id()

  @type revision :: non_neg_integer()
  @type contract_type_key :: String.t()
  @type idempotency_key :: String.t()

  @type params :: %{optional(String.t()) => term()}
  @type attrs :: %{optional(atom() | String.t()) => term()}
  @type opts :: keyword()
  @type upload :: Phoenix.LiveView.UploadEntry.t()
  @type socket :: Phoenix.LiveView.Socket.t()
end
