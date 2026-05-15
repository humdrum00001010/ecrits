# `:browser` is the Wallaby suite (real Chromium + chromedriver). It is
# excluded from the default `mix test` run to keep the unit suite fast and
# Chromium-free. CI / sprite runs `mix test --include browser`.
#
# `:external_hwpx` shells out to a third-party `pyhwpxlib` binary to
# validate generated HWPX bytes against an external parser. Excluded by
# default; run with `mix test --include external_hwpx`.
ExUnit.start(
  exclude: [:live_smtp, :live, :live_openai, :live_law_mcp, :browser, :external_hwpx]
)

# Engine and other pure-mechanics tests run without the database. We only
# switch the sandbox into :manual mode when the Repo actually started up.
case Process.whereis(Contract.Repo) do
  nil ->
    :ok

  _pid ->
    Ecto.Adapters.SQL.Sandbox.mode(Contract.Repo, :manual)
end

# Start Wallaby only when the endpoint actually booted AND the `:browser`
# tag is in the include set (i.e. the caller asked for the browser suite).
# Wallaby's start/2 callback hard-fails if chromedriver isn't on PATH, so
# we keep boot opt-in. Default `mix test` leaves Wallaby down.
browser_included? =
  ExUnit.configuration()
  |> Keyword.get(:include, [])
  |> Enum.any?(fn
    :browser -> true
    {:browser, _} -> true
    _ -> false
  end)

if browser_included? and Process.whereis(ContractWeb.Endpoint) do
  {:ok, _} = Application.ensure_all_started(:wallaby)
end

# Mox definitions for IO drivers. The test config swaps in
# `Contract.IO.OpenAIMock` for the OpenAI driver.
Mox.defmock(Contract.IO.OpenAIMock, for: Contract.IO.OpenAI.Behaviour)
Mox.set_mox_global()
