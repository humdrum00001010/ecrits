defmodule ContractWeb.Locale do
  @moduledoc """
  Tiny Gettext-locale setter used in both the browser plug pipeline and
  every authenticated LiveView's `on_mount` chain.

  The active locale is read from `Application.get_env(:contract, :ui_locale, "en")`.

  * In `:prod` and `:dev` (i.e. the sprite), `config/config.exs` sets it
    to `"ko"` so Korean lawyers see Korean-primary chrome.
  * In `:test`, `config/test.exs` overrides it back to `"en"` so the
    Phoenix-generated gen.auth tests + the dashboard / settings_hub
    LiveViewTests continue to match the English `msgid` strings that
    serve as the source-of-truth for translation.

  English `msgid`s are the canonical strings. Each `priv/gettext/ko/LC_MESSAGES/*.po`
  fills the `msgstr` with a Korean rendering; Gettext falls back to the
  `msgid` when a `msgstr` is empty, so partially translated files render
  gracefully.

  Brand wordmarks ("Contract Studio"), regulator names ("법제처"), and
  developer-facing technical labels are intentionally left untranslated
  per the Wave 3C0-E / Wave 3C2 brief.
  """

  import Plug.Conn, only: [put_session: 3]

  @doc """
  Plug entrypoint for the `:browser` pipeline. Sets Gettext locale for
  any dead-view (controller) render path. LiveViews use `on_mount/4`.
  """
  def init(opts), do: opts

  def call(conn, _opts) do
    Gettext.put_locale(ContractWeb.Gettext, ui_locale())
    conn
  end

  @doc """
  LiveView `on_mount` callback. Wired in `:browser`-served live_sessions
  so Korean renders inside LV mounts as well as dead-view controllers.
  """
  def on_mount(:default, _params, _session, socket) do
    Gettext.put_locale(ContractWeb.Gettext, ui_locale())
    {:cont, socket}
  end

  @doc """
  Reads the configured UI locale. Defaults to `"en"` if unset.
  """
  def ui_locale do
    Application.get_env(:contract, :ui_locale, "en")
  end

  # Re-export so future call sites that want to write the locale to the
  # session (for explicit per-user overrides) have a single helper.
  @doc false
  def put_session_locale(conn, locale) when is_binary(locale) do
    put_session(conn, :ui_locale, locale)
  end
end
