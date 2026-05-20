if Mix.env() == :dev do
  defmodule ContractWeb.DevController do
    @moduledoc false
    use ContractWeb, :controller

    def render_ir(conn, %{"ir" => ir}) when is_map(ir) do
      rendered = Contract.Agent.Prompt.IRRenderer.render(ir)
      require Logger
      Logger.info("==RENDERED-IR-BEGIN==\n#{rendered}\n==RENDERED-IR-END==")

      conn
      |> put_resp_content_type("text/plain; charset=utf-8")
      |> send_resp(200, rendered)
    end

    def render_ir(conn, _params), do: send_resp(conn, 400, "missing :ir")
  end
end
