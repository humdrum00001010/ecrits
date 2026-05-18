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

  @grill_intro_system_prompt """
  당신은 계약기계의 법률 문서 에이전트입니다.

  오늘은 사용자가 새 계약 문서를 열었고, 채팅 이력이 비어 있습니다. 당신이 먼저 말을 걸어야 합니다.

  다음 순서로 ONE message에 모두 담아 응답하세요:

  1. 짧은 인사 (한 줄, 격식 있는 한국어).
  2. 문서 본문을 훑고 한 단락(2-3 문장)으로 요약 — 무슨 종류의 계약/문서인지, 주요 당사자나 주제는 무엇인지.
  3. 프로젝트 맥락을 좁히는 1-3개의 질문을 번호 매겨 제시:
     - 이 프로젝트가 어떤 일/거래인지
     - 왜 지금 이 계약서가 필요한지
     - 결정/확정해야 할 핵심 슬롯이 무엇인지 (금액·기간·당사자 등)
     질문은 한 문장씩, 한국어 존댓말, 답하기 좋게 구체적으로.

  마크나 ops는 emit하지 마세요. 이 첫 응답은 순수 텍스트 메시지여야 합니다. JSON envelope을 쓰는 다른 grill 프로토콜과 달리, 이 grill_seed 첫 응답은 그냥 한국어 일반 텍스트로.

  문서 본문 IR이 비어 있다면 요약 단계를 건너뛰고 곧장 3번의 질문만 던지세요.
  """

  @doc "Returns the system prompt used by `build_context/2`."
  @spec system_prompt() :: String.t()
  def system_prompt, do: @grill_system_prompt

  @doc """
  Returns the Korean grill-intro system prompt used when a document is
  opened cold (empty chat thread). Emitted by `build_context/2` when the
  triggering Command carries `payload["grill_seed"] == true`.
  """
  @spec grill_intro_system_prompt() :: String.t()
  def grill_intro_system_prompt, do: @grill_intro_system_prompt

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
    if grill_seed?(action) do
      build_grill_intro_context(action)
    else
      build_regular_context(ctx, action)
    end
  end

  defp build_regular_context(ctx, %Command{} = action) do
    snapshot = fetch_snapshot(action.document_id)
    history = fetch_history(ctx, action)

    input =
      Enum.map(history, fn msg -> %{role: msg.role, content: msg.content} end) ++
        [%{role: "user", content: action.message || ""}]

    tools = [Contract.IO.OpenAI.law_mcp_tool()]

    frame = %{
      system:
        @grill_system_prompt <> "\n\nCURRENT_DOCUMENT_SNAPSHOT:\n" <> Jason.encode!(snapshot),
      input: input,
      tools: tools,
      previous_response_id: action.payload["previous_response_id"],
      grill_seed?: false
    }

    {:ok, frame}
  end

  defp build_grill_intro_context(%Command{} = action) do
    nodes_summary = grill_seed_nodes_summary(action.payload["grill_seed_nodes"])
    tools = [Contract.IO.OpenAI.law_mcp_tool()]

    user_content =
      case nodes_summary do
        "" -> "DOCUMENT_BODY: (empty)"
        text -> "DOCUMENT_BODY:\n" <> text
      end

    frame = %{
      system: @grill_intro_system_prompt,
      input: [%{role: "user", content: user_content}],
      tools: tools,
      previous_response_id: nil,
      grill_seed?: true
    }

    {:ok, frame}
  end

  @doc """
  Renders the projection nodes the LV ships in the grill seed payload
  into a compact plain-text summary. Limits to the first ~25 heading/
  paragraph nodes so the user message stays within a sensible token
  budget for the cold start.
  """
  @spec grill_seed_nodes_summary(term()) :: String.t()
  def grill_seed_nodes_summary(nil), do: ""

  def grill_seed_nodes_summary(nodes) when is_list(nodes) do
    nodes
    |> Enum.take(25)
    |> Enum.map_join("\n", &render_grill_seed_node/1)
  end

  def grill_seed_nodes_summary(_other), do: ""

  defp render_grill_seed_node(%{} = node) do
    kind = node[:kind] || node["kind"]
    content = node[:content] || node["content"] || ""
    "- [#{kind}] #{content}"
  end

  defp render_grill_seed_node(_), do: ""

  @doc "Returns true when `command.payload[\"grill_seed\"]` is truthy."
  @spec grill_seed?(Command.t()) :: boolean()
  def grill_seed?(%Command{payload: payload}) when is_map(payload) do
    Map.get(payload, "grill_seed") == true or Map.get(payload, :grill_seed) == true
  end

  def grill_seed?(_), do: false

  @doc """
  Wraps a plain-text grill-intro response into an `Action(:agent_change)`
  with `mode: "edit"`, empty ops/marks, and the text as `:message`. The
  intro response is rendered as a normal agent chat message and never
  produces document mutations.
  """
  @spec decode_grill_intro(String.t() | map(), keyword()) ::
          {:ok, Command.t()} | {:error, term()}
  def decode_grill_intro(text, opts) when is_binary(text) do
    message = String.trim(text)

    {:ok,
     %Command{
       kind: :agent_change,
       actor_type: :agent,
       idempotency_key: idempotency_key(opts),
       payload: %{
         "mode" => "edit",
         "ops" => [],
         "marks" => [],
         "message" => message,
         "grill_seed" => true
       },
       message: message
     }}
  end

  def decode_grill_intro(%{"output_text" => text}, opts) when is_binary(text),
    do: decode_grill_intro(text, opts)

  def decode_grill_intro(%{"output" => output}, opts) when is_list(output) do
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

    decode_grill_intro(text, opts)
  end

  def decode_grill_intro(other, _opts), do: {:error, {:decode_failed, {:bad_shape, other}}}

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
