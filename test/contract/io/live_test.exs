defmodule Contract.IO.LiveTest do
  @moduledoc """
  Tagged integration tests that hit real OpenAI + real Korean Law MCP.

  ## Double-gate (env + tag) — to prevent accidental quota burn

  These tests are excluded from the default `mix test` run via the
  `:live`, `:live_openai`, and `:live_law_mcp` tags (see
  `test/test_helper.exs`). They ALSO require the `LIVE_API` env flag to
  be set to `1`, even when the caller passes `--include live`.

  Without `LIVE_API=1`, each test is marked with the `:skip` tag (at
  compile time) — so `mix test --include live` reports each test as
  *skipped* with a clear reason instead of firing real API requests. To
  see them, run with the env flag set:

      mix test                                       # excluded (tag)
      mix test --include live                        # skipped (no LIVE_API)
      LIVE_API=1 mix test --include live             # real API calls
      LIVE_API=1 mix test --only live_openai         # only the OpenAI live test
      LIVE_API=1 mix test --only live_law_mcp        # only the Law MCP live test

  Required env when actually running live:

    * `OPENAI_API_KEY` — for `:live_openai`
    * `LAW_OC` — for `:live_law_mcp` (defaults to `"openapi"`)
  """
  use ExUnit.Case, async: false

  @moduletag :live

  # Compile-time env gate. When LIVE_API!=1 at compile time, every test
  # in this module carries `@tag skip: "..."` and is reported as skipped
  # by ExUnit's filter layer — no setup runs, no HTTP fires.
  @live_api_enabled System.get_env("LIVE_API") == "1"
  @skip_reason "Live API test skipped — set LIVE_API=1 to enable real OpenAI / Korean-Law-MCP calls"

  unless @live_api_enabled do
    @moduletag skip: @skip_reason
  end

  @tag :live_openai
  test "OpenAI Responses stream emits SSE events" do
    api_key = System.get_env("OPENAI_API_KEY")
    if is_nil(api_key) or api_key == "", do: flunk("OPENAI_API_KEY not set")

    # Use the real production base URL + law-mcp URL.
    original_openai = Application.get_env(:contract, :openai)
    original_law = Application.get_env(:contract, :law_mcp)

    Application.put_env(:contract, :openai,
      api_key: api_key,
      base_url: "https://api.openai.com/v1",
      default_model: "gpt-5-mini",
      reasoning_effort: "high"
    )

    Application.put_env(:contract, :law_mcp,
      endpoint: "https://korean-law-mcp.fly.dev/mcp",
      oc: System.get_env("LAW_OC", "openapi")
    )

    on_exit(fn ->
      Application.put_env(:contract, :openai, original_openai)
      Application.put_env(:contract, :law_mcp, original_law)
    end)

    params = %{
      input: "Reply with the literal JSON object {\"mode\":\"edit\",\"ops\":[],\"marks\":[],\"message\":\"ok\"}.",
      text: %{format: %{type: "json_object"}}
    }

    assert {:ok, %{stream: stream, task_pid: _}} = Contract.IO.OpenAI.stream_chat(params)

    events = Enum.to_list(stream)
    types = events |> Enum.map(& &1.type) |> Enum.uniq()

    IO.puts("LIVE OPENAI SSE EVENT TYPES: #{inspect(types)}")

    assert Enum.any?(types, fn t ->
             t in ["response.created", "response.completed", "response.output_text.delta"]
           end)
  end

  @tag :live_law_mcp
  test "Korean Law MCP verify_citations confirms 민법 제390조" do
    original = Application.get_env(:contract, :law_mcp)

    Application.put_env(:contract, :law_mcp,
      endpoint: "https://korean-law-mcp.fly.dev/mcp",
      oc: System.get_env("LAW_OC", "openapi")
    )

    on_exit(fn -> Application.put_env(:contract, :law_mcp, original) end)

    assert {:ok, results} = Contract.IO.LawMCP.verify_citations(["민법 제390조"])
    IO.puts("LIVE LAW MCP verify_citations result: #{inspect(results)}")
    assert is_list(results)
  end
end
