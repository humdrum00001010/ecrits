# `:browser` is the Wallaby suite (real Chromium + chromedriver). It is
# excluded from the default `mix test` run to keep the unit suite fast and
# Chromium-free. CI / sprite runs `mix test --include browser`.
#
# `:live_law_mcp` hits the real legal-rag MCP endpoint; excluded by default.
ExUnit.start(
  exclude: [
    :live,
    :live_law_mcp,
    :browser
  ]
)

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

if browser_included? and Process.whereis(EcritsWeb.Endpoint) do
  {:ok, _} = Application.ensure_all_started(:wallaby)
end
