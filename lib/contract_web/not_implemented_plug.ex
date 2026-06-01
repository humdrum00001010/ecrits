defmodule ContractWeb.NotImplementedPlug do
  @moduledoc """
  Returns `501 Not Implemented` for routes whose handler hasn't been wired up
  yet. Used as a placeholder for `/slack/*` until that boundary lands.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: Keyword.put_new(opts, :label, "this endpoint")

  @impl true
  def call(conn, opts) do
    label = Keyword.fetch!(opts, :label)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      501,
      Jason.encode!(%{
        error: "not_implemented",
        message: "#{label} is not implemented in this build."
      })
    )
    |> halt()
  end
end
