defmodule Contract.IO.OpenAI do
  @moduledoc """
  OpenAI Responses-API client with the Korean Law MCP tool attached by default.

  Reasoning model defaults to `gpt-5-mini` with `effort: "high"`. Streaming
  returns a `Stream` of `%{type: event_type, data: data}` maps; one-shot
  returns the parsed Response JSON.

  See SPEC.md §20, §24 and `/tmp/wave1-research.md` §1–3.
  """

  alias Contract.Types, as: T

  @behaviour Contract.IO.OpenAI.Behaviour

  @type params :: map()
  @type stream_event :: %{type: String.t(), data: map()}

  @doc """
  Streams a Responses-API completion. Returns an `Enumerable` of
  `%{type: event_type, data: data}` maps and (in `meta`) the underlying
  task pid so callers can cancel.
  """
  @impl true
  @spec stream_chat(params(), T.opts()) ::
          {:ok, %{stream: Enumerable.t(), task_pid: pid()}} | {:error, term()}
  def stream_chat(params, opts \\ []) do
    {client, request} = build_request(params, opts)

    case OpenaiEx.Responses.create(client, request, stream: true) do
      {:ok, %{body_stream: body_stream, task_pid: task_pid}} ->
        {:ok, %{stream: normalize_stream(body_stream), task_pid: task_pid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Issues a one-shot (non-streaming) Responses-API call. Returns the parsed
  Response JSON.
  """
  @impl true
  @spec one_shot(params(), T.opts()) :: {:ok, map()} | {:error, term()}
  def one_shot(params, opts \\ []) do
    {client, request} = build_request(params, opts)

    case OpenaiEx.Responses.create(client, request) do
      {:ok, %{} = response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Builds the canonical Korean-law MCP tool entry per `tools-connectors-mcp`.
  Exposed so the Agent can ask for the same shape when building context.
  """
  @spec law_mcp_tool(T.opts()) :: map()
  def law_mcp_tool(opts \\ []) do
    cfg = Application.fetch_env!(:contract, :law_mcp)
    oc = Keyword.get(opts, :oc) || cfg[:oc] || "openapi"
    base = Keyword.get(opts, :endpoint) || cfg[:endpoint]

    %{
      type: "mcp",
      server_label: "korean-law",
      server_url: "#{base}?oc=#{oc}",
      require_approval: "never"
    }
  end

  @doc """
  Builds the Slack-hosted MCP tool entry per Wave 6. Returns `nil` if the
  request-scoped `Contract.Context` does not have a stored Slack token
  for the user — callers should drop nils before sending the tool list.

  Write-capable tools (chat:write, reactions:write, …) are gated behind
  the Responses-API `require_approval` flag so the agent must surface an
  approval step to the user before invoking them.
  """
  @spec slack_mcp_tool(Contract.Context.t() | nil) :: map() | nil
  def slack_mcp_tool(%Contract.Context{} = ctx) do
    case Contract.Integrations.Slack.token_for(ctx) do
      {:ok, token} ->
        %{
          type: "mcp",
          server_label: "slack",
          server_url: System.get_env("SLACK_MCP_URL") || "https://mcp.slack.com/mcp",
          require_approval: %{always: %{tool_names: slack_write_tool_names()}},
          headers: %{"Authorization" => "Bearer " <> token}
        }

      {:error, _} ->
        nil
    end
  end

  def slack_mcp_tool(_), do: nil

  @contract_doc_allowed_tools ~w(
    doc.get
    doc.find
    doc.read
    doc.edit_text
    doc.insert_block
    doc.delete_block
    doc.edit_table
    doc.set_field_value
  )

  @doc """
  Agent-facing MCP tool spec for the in-house `contract-doc` server. Takes
  a signed route_ref `bearer` token (which carries document_id +
  agent_run_id) and returns the spec to splice into a Responses-API tools
  list. `allowed_tools` restricts the model's surface to the 6 doc.* tools
  even though the server advertises more.

  Returns `nil` when no bearer is supplied so callers can drop it.
  """
  @spec contract_doc_mcp_tool(bearer :: String.t() | nil) :: map() | nil
  def contract_doc_mcp_tool(nil), do: nil
  def contract_doc_mcp_tool(""), do: nil

  def contract_doc_mcp_tool(bearer) when is_binary(bearer) do
    base = Application.get_env(:contract, :mcp, []) |> Keyword.get(:public_base_url)

    case base do
      nil ->
        nil

      url ->
        %{
          type: "mcp",
          server_label: "contract-doc",
          server_url: String.trim_trailing(url, "/") <> "/mcp",
          require_approval: "never",
          allowed_tools: @contract_doc_allowed_tools,
          headers: %{"Authorization" => "Bearer " <> bearer}
        }
    end
  end

  # --- internals ---------------------------------------------------------

  # Write-capable Slack tool names that REQUIRE user approval before
  # invocation. Derived from `SLACK_MCP_WRITE_SCOPES` — Slack MCP tool
  # names follow `slack_<verb>_<resource>` shape (see Slack's hosted MCP
  # docs); we include the conservative set that maps 1:1 to the write
  # scopes in `.env`.
  defp slack_write_tool_names do
    [
      "slack_post_message",
      "slack_update_message",
      "slack_delete_message",
      "slack_add_reaction",
      "slack_remove_reaction",
      "slack_create_channel",
      "slack_archive_channel",
      "slack_invite_to_channel",
      "slack_create_canvas",
      "slack_edit_canvas"
    ]
  end

  defp build_request(params, opts) do
    cfg = Application.fetch_env!(:contract, :openai)
    api_key = Keyword.get(opts, :api_key) || cfg[:api_key] || env!("OPENAI_API_KEY")
    base_url = Keyword.get(opts, :base_url) || cfg[:base_url] || "https://api.openai.com/v1"

    client =
      OpenaiEx.new(api_key)
      |> OpenaiEx.with_base_url(base_url)
      |> OpenaiEx.with_receive_timeout(60_000)
      |> OpenaiEx.with_finch_name(Contract.Finch.OpenAI)

    extra_tools = Keyword.get(opts, :extra_tools, [])
    include_law = Keyword.get(opts, :include_law_mcp?, true)
    include_slack = Keyword.get(opts, :include_slack_mcp?, true)
    ctx = Keyword.get(opts, :ctx)

    base_tools = if include_law, do: [law_mcp_tool(opts)], else: []

    slack_tools =
      if include_slack do
        case slack_mcp_tool(ctx) do
          nil -> []
          tool -> [tool]
        end
      else
        []
      end

    tools =
      base_tools ++
        slack_tools ++ List.wrap(Map.get(params, :tools, [])) ++ List.wrap(extra_tools)

    tools = deduplicate_mcp_tools(tools)

    request =
      params
      |> Map.put_new(:model, cfg[:default_model] || "gpt-5-mini")
      |> Map.put_new(:reasoning, %{
        effort: cfg[:reasoning_effort] || "high",
        # `detailed` (rather than `auto`) forces the API to stream
        # `response.reasoning_summary_text.delta` events on every call —
        # including short replies where `auto` would skip the summary.
        # Without a summary stream the chat-rail's Thinking… disclosure
        # stays empty for the 5–15s TTFT gap on high-effort gpt-5.
        summary: "detailed"
      })
      |> Map.put(:tools, tools)

    {client, request}
  end

  defp deduplicate_mcp_tools(tools) do
    {deduped, _seen_labels} =
      Enum.reduce(tools, {[], MapSet.new()}, fn tool, {acc, seen_labels} ->
        case mcp_server_label(tool) do
          nil ->
            {[tool | acc], seen_labels}

          label ->
            if MapSet.member?(seen_labels, label) do
              {acc, seen_labels}
            else
              {[tool | acc], MapSet.put(seen_labels, label)}
            end
        end
      end)

    Enum.reverse(deduped)
  end

  defp mcp_server_label(%{} = tool) do
    type = Map.get(tool, :type) || Map.get(tool, "type")
    label = Map.get(tool, :server_label) || Map.get(tool, "server_label")

    if type == "mcp" and is_binary(label) and label != "", do: label, else: nil
  end

  defp mcp_server_label(_tool), do: nil

  defp normalize_stream(body_stream) do
    body_stream
    |> Stream.flat_map(fn
      events when is_list(events) -> events
      event -> [event]
    end)
    |> Stream.map(&normalize_event/1)
    |> Stream.reject(&is_nil/1)
  end

  defp normalize_event(%{event: type, data: data}), do: %{type: type, data: data}

  defp normalize_event(%{data: %{"type" => type} = data}), do: %{type: type, data: data}

  defp normalize_event(%{data: data}) when is_map(data), do: %{type: "data", data: data}

  defp normalize_event(_), do: nil

  defp env!(name) do
    case System.get_env(name) do
      val when is_binary(val) and val != "" -> val
      _ -> raise "missing required env var: #{name}"
    end
  end
end
