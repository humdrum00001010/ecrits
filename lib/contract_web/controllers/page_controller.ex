defmodule ContractWeb.PageController do
  use ContractWeb, :controller

  @doc """
  Landing page (`GET /`).

  The marketing surface is Korean-primary: we pin the Gettext locale to
  `"ko"` for this action so `dgettext("landing", …)` in
  `home.html.heex` resolves through `priv/gettext/ko/LC_MESSAGES/landing.po`.
  English msgids remain the fallback for any msgstr we haven't filled.

  Chrome strings on `Layouts.app` are deliberately *not* gettext-wrapped
  (they're literal English in `layouts.ex`), so the top-nav / footer
  English copy is unaffected and the gen.auth LiveView tests that
  assert on chrome literals continue to pass.
  """
  def home(conn, _params) do
    Gettext.put_locale(ContractWeb.Gettext, "ko")
    render(conn, :home)
  end
end
