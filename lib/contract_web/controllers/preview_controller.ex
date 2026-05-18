defmodule ContractWeb.PreviewController do
  use ContractWeb, :controller

  def index(conn, _params) do
    Gettext.put_locale(ContractWeb.Gettext, "ko")
    render(conn, :index, layout: false)
  end
end
