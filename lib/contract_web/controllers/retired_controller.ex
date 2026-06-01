defmodule ContractWeb.RetiredController do
  @moduledoc """
  410 responses for hosted SaaS routes retired by the localize migration.
  """

  use ContractWeb, :controller

  def gone(conn, _params) do
    conn
    |> put_status(:gone)
    |> put_resp_content_type("text/plain")
    |> text("This hosted route has been retired. Open / to mount a local workspace.")
  end
end
