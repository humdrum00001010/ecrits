defmodule Contract.Agent do
  @moduledoc """
  Semantic interpreter. Agent resolves targets; backend validates returned
  IDs.

  This module is a thin façade — actual run state lives in
  `Contract.Agent.RunServer` (one GenServer per run, supervised by
  `Contract.Agent.RunSupervisor`). The agent ships the "grill me" skill:
  on the first turn of an ambiguous request it emits clarifying questions
  as marks instead of edits.

  See SPEC.md §20, §24 and `/tmp/wave1-research.md` for the verified
  OpenAI Responses + Korean Law MCP shapes.
  """

  alias Contract.ChatThreads
  alias Contract.Command
  alias Contract.Agent.Run
  alias Contract.Agent.RunServer
  alias Contract.Agent.RunSupervisor
  alias Contract.Types, as: T

  @grill_system_prompt """
  You are a legal-document agent for Contract Studio. You modify documents only via Actions.

  GRILL-ME PROTOCOL:
  On the FIRST turn of a conversation, you MUST emit clarifying questions as marks, NOT edits, when the user's intent is ambiguous. Output JSON in the schema:

  {
    "mode": "grill" | "edit",
    "questions": [{"text": "...", "rationale": "...", "target_node_id": null | "..."}],
    "ops": [],
    "marks": [],
    "message": "..."
  }

  Use mode=grill when ANY of:
    - the user said "make stricter"/"clean up"/"fix" without specifying which clause
    - the change implies a legal-policy decision (penalty amount, term length, jurisdiction)
    - the contract type is ambiguous
    - the user's request would affect >= 3 clauses

  Otherwise use mode=edit. ON THE SECOND TURN (after user answered grill questions), default to mode=edit.

  CITATION POLICY: When you cite Korean law (민법, 상법, etc.), you MUST call the `korean-law` MCP tool's `verify_citations` to confirm the article exists before emitting the citation. Never emit a citation that failed verification.

  OUTPUT: Always JSON. No prose outside the JSON envelope.
  """

  @doc "Returns the system prompt used by `build_context/2`."
  @spec system_prompt() :: String.t()
  def system_prompt, do: @grill_system_prompt

  # TODO(SPEC.md §18): agent auto-set type_key from marks.
  #
  # When an agent run completes for an untyped document (Document.type_key
  # == nil) and the output contains a label mark
  # (`%{intent: :label, source: :agent, data: %{suggested_type_key: key}}`),
  # this module should automatically emit an `Action(:set_contract_type)`
  # with that key so the user does not have to ratify the obvious. The
  # current fix only stops gating the create flow on type selection; the
  # auto-set is a follow-up that depends on the agent emitting
  # well-formed label marks first.

  # --- public API -------------------------------------------------------

  @spec start(T.ctx(), Command.t()) :: {:ok, Run.t()} | {:error, term()}
  def start(ctx, %Command{kind: kind} = action)
      when kind in [:chat_message, :start_type_conversion] do
    run = %Run{
      id: Ecto.UUID.generate(),
      document_id: action.document_id,
      triggered_by_action_id: action.payload["action_id"] || action.idempotency_key,
      status: :running,
      turn_index: 0,
      message: action.message,
      inserted_at: utc_now(),
      updated_at: utc_now()
    }

    args = [
      run_id: run.id,
      run: run,
      ctx: ctx,
      action: action,
      test_pid: action.payload["test_pid"]
    ]

    case RunSupervisor.start_run(args) do
      {:ok, _pid} -> {:ok, run}
      {:error, {:already_started, _}} -> {:ok, run}
      {:error, reason} -> {:error, reason}
    end
  end

  def start(_ctx, %Command{kind: kind}), do: {:error, {:unsupported_action, kind}}

  @spec cancel(T.ctx(), T.agent_run_id()) :: {:ok, Run.t()} | {:error, term()}
  def cancel(_ctx, run_id), do: RunServer.cancel(run_id)

  @spec observe_change(T.agent_run_id(), Contract.Change.t()) :: :ok
  def observe_change(run_id, change) do
    _ = RunServer.observe_change(run_id, change)
    :ok
  end

  @spec observe_revoke(T.agent_run_id(), Contract.Change.t()) :: :ok
  def observe_revoke(run_id, revoke_change) do
    _ = RunServer.observe_revoke(run_id, revoke_change)
    :ok
  end

  @doc """
  Assembles the system prompt, conversation history, MCP tool list, and
  optional `previous_response_id` for one agent run.

  v0.5: Context Reservoir is no longer in spec — the
  `include_context_reservoir/2` helper has been removed.
  """
  @spec build_context(T.ctx(), Command.t()) :: {:ok, map()}
  def build_context(ctx, %Command{} = action) do
    snapshot = fetch_snapshot(action.document_id)
    history = fetch_history(ctx, action)

    # OpenAI's Responses API requires the word "json" in input messages
    # when text.format.type is "json_object". Append a small reminder
    # to the current user message so even a fresh conversation passes.
    current_user_content =
      (action.message || "") <> "\n\n(Respond in JSON only, per the schema in instructions.)"

    input =
      Enum.map(history, fn msg -> %{role: msg.role, content: msg.content} end) ++
        [%{role: "user", content: current_user_content}]

    tools = [Contract.IO.OpenAI.law_mcp_tool()]

    frame = %{
      system:
        @grill_system_prompt <> "\n\nCURRENT_DOCUMENT_SNAPSHOT:\n" <> Jason.encode!(snapshot),
      input: input,
      tools: tools,
      previous_response_id: action.payload["previous_response_id"]
    }

    {:ok, frame}
  end

  @doc """
  Parses the model's JSON envelope and returns an `Action(:agent_change)`.

  Accepts either the raw response string or a final OpenAI Response map
  with an `output_text` field.
  """
  @spec decode_action(String.t() | map(), keyword()) ::
          {:ok, Command.t()} | {:error, term()}
  def decode_action(provider_output, opts \\ [])

  def decode_action(text, opts) when is_binary(text) do
    case extract_json(text) do
      {:ok, payload} -> build_agent_change_action(payload, opts)
      {:error, _} = err -> err
    end
  end

  def decode_action(%{"output_text" => text}, opts) when is_binary(text),
    do: decode_action(text, opts)

  def decode_action(%{"output" => output}, opts) when is_list(output) do
    text =
      output
      |> Enum.flat_map(fn
        %{"content" => content} when is_list(content) ->
          Enum.flat_map(content, fn
            %{"text" => t} when is_binary(t) -> [t]
            _ -> []
          end)

        _ ->
          []
      end)
      |> Enum.join("")

    decode_action(text, opts)
  end

  def decode_action(other, _opts), do: {:error, {:decode_failed, {:bad_shape, other}}}

  # --- internals --------------------------------------------------------

  defp build_agent_change_action(%{"mode" => "grill"} = payload, opts) do
    marks =
      Enum.map(payload["questions"] || [], fn q ->
        %{
          "intent" => "ask",
          "source" => "agent",
          "text" => q["text"],
          "target_type" => mark_target_type(q),
          "target_id" => q["target_node_id"],
          "data" => %{"rationale" => q["rationale"]}
        }
      end)

    {:ok,
     %Command{
       kind: :agent_change,
       actor_type: :agent,
       idempotency_key: idempotency_key(opts),
       payload: %{
         "mode" => "grill",
         "ops" => [],
         "marks" => marks,
         "message" => payload["message"]
       },
       message: payload["message"]
     }}
  end

  defp build_agent_change_action(%{"mode" => "edit"} = payload, opts) do
    ops = payload["ops"] || []
    marks = payload["marks"] || []

    {:ok,
     %Command{
       kind: :agent_change,
       actor_type: :agent,
       idempotency_key: idempotency_key(opts),
       payload: %{
         "mode" => "edit",
         "ops" => ops,
         "marks" => marks,
         "message" => payload["message"]
       },
       message: payload["message"]
     }}
  end

  defp build_agent_change_action(_other, _opts), do: {:error, {:decode_failed, :missing_mode}}

  defp mark_target_type(%{"target_node_id" => nil}), do: "document"
  defp mark_target_type(%{"target_node_id" => _}), do: "node"
  defp mark_target_type(_), do: "document"

  defp idempotency_key(opts) do
    run_id = Keyword.get(opts, :run_id, "anon")
    turn = Keyword.get(opts, :turn_index, 0)
    "agent:#{run_id}:#{turn}"
  end

  defp extract_json(text) do
    trimmed =
      text
      |> String.trim()
      |> strip_code_fence()

    case Jason.decode(trimmed) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      {:ok, _other} -> {:error, {:decode_failed, :not_an_object}}
      {:error, reason} -> {:error, {:decode_failed, reason}}
    end
  end

  defp strip_code_fence(text) do
    cond do
      String.starts_with?(text, "```json") ->
        text
        |> String.replace_prefix("```json", "")
        |> String.replace_suffix("```", "")
        |> String.trim()

      String.starts_with?(text, "```") ->
        text
        |> String.replace_prefix("```", "")
        |> String.replace_suffix("```", "")
        |> String.trim()

      true ->
        text
    end
  end

  # Wave-2 owns the real Store; until it lands, return an empty snapshot
  # so the agent can run end-to-end in tests.
  defp fetch_snapshot(nil), do: %{nodes: []}

  defp fetch_snapshot(_document_id) do
    %{nodes: []}
  end

  # Wave-3 owns the chat store; until it lands, return an empty history.
  defp fetch_history(ctx, %Command{} = action), do: ChatThreads.history_for_agent(ctx, action)

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
