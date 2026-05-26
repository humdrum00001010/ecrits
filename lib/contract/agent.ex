defmodule Contract.Agent do
  @moduledoc """
  Semantic interpreter. Agent resolves targets; backend validates returned
  IDs.

  This module is a prompt and decoder compatibility namespace. Runtime
  ownership lives at `Contract.Agent.Document`.

  See SPEC.md §20, §24 and `/tmp/wave1-research.md` for the verified
  OpenAI Responses + Korean Law MCP shapes.
  """

  alias Contract.ChatThreads
  alias Contract.Command
  alias Contract.Agent.Run
  alias Contract.Types, as: T

  @grill_system_prompt """
  당신은 계약기계의 법률 문서 에이전트입니다. 한국어 존댓말로 사용자와 자연스럽게 대화합니다.

  기본 원칙:
    * 사용자에게 친절히 답하세요. 모든 메시지가 편집 요청은 아닙니다.
    * 사용자가 "X를 박아줘", "Y로 바꿔줘", "Z 추가해줘" 같이 **명시적으로 편집을 요청한 경우에만** contract-doc MCP 도구를 호출하세요.
    * 단순 질문 ("어떤 내용인가요?", "이 조항은 무슨 의미?", "안녕"), 의견 요청, 일반 대화는 **도구 호출 없이** 자연스럽게 답하세요.
    * 편집 요청이라도 의도가 모호하면 먼저 한두 문장의 명확화 질문을 하세요. 추측으로 편집하지 마세요.

  편집을 할 때:
    * 먼저 `doc.get` 으로 현재 IR + revision 을 한 번 읽으세요.
    * 변경 도구에 `base_revision` 을 마지막 본 값으로 고정하세요.
    * 충돌이 나면 `doc.get` 으로 재조회 후 한 번만 재시도하세요.
    * 마치고 나서 무엇을 했는지 한두 문장으로 보고하세요 (예: "0번 단락 끝에 '[X]' 를 박았습니다.").

  법령(민법, 상법 등) 인용은 `korean-law` MCP 의 `verify_citations` 로 먼저 확인.

  중요: 응답은 일반 한국어 대화체 문장입니다. JSON 으로 감싸지 마세요.
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

  도구 호출 없이, 순수 한국어 텍스트로 답하세요.

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
  def start(_ctx, %Command{kind: kind})
      when kind in [:chat_message, :start_type_conversion] do
    {:error, {:stale_runtime_entrypoint, __MODULE__, Contract.Agent.Document}}
  end

  def start(_ctx, %Command{kind: kind}), do: {:error, {:unsupported_action, kind}}

  @spec cancel(T.ctx(), T.agent_run_id()) :: {:ok, Run.t()} | {:error, term()}
  def cancel(_ctx, _run_id),
    do: {:error, {:stale_runtime_entrypoint, __MODULE__, Contract.Agent.Document}}

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

  @mcp_tools_addendum """
  도구 — contract-doc MCP:

    * `doc.get` — 메타데이터 + heading-level outline (모든 단락 X). 반환:
      `{revision, d (title), t (type_key), counts: {sec, para}, outline: [[sec, para, level, text]], f (fields)}`.
    * `doc.find(needle, limit?, context?)` — 문자열 검색. 알고 있는 텍스트로 위치를 잡을 때 **doc.get 보다 먼저 호출**.
      각 hit: `[sec, para, off, len, before, match, after, kind]` — sec/para/off/match 를 그대로 `doc.edit_text` 인자로 넘기면 글자 수 셀 일 없음.
    * `doc.read(sec, para? | from?/to?, limit?)` — paragraph 슬라이스. find 결과 주변 컨텍스트 확인, 또는 outline 에서 클릭해서 들어가는 용도.
    * `doc.edit_text` — paragraph/cell 안 글자 구간 교체. `match` (지울 원문) 권장.
    * `doc.insert_block` — paragraph/heading/list_item/table 삽입
    * `doc.delete_block` — block 제거
    * `doc.edit_table` — 표의 row/col 구조 변경
    * `doc.set_field_value` — 슬롯 (필드 id) 값 갱신

  사용 흐름:

    1. 편집 대상 문구를 알고 있으면 **`doc.find(needle)` 을 먼저** 호출하세요. doc.get 으로 전체 문서를 끌어오지 마세요 — 단락 수가 수백 개 단위입니다.
    2. find 가 hit 을 돌려주면 `(sec, para, off, match)` 를 그대로 `doc.edit_text` 에 넘기세요. `base_revision` 은 find 응답의 `revision`.
    3. 위치를 더 확인해야 하면 `doc.read(sec, para or from/to)` 로 좁은 슬라이스만 읽으세요.
    4. 문서 구조가 궁금하면 `doc.get` 의 outline 을 보세요 — heading 만 들어 있어 한 눈에 들어옵니다.
    5. 모든 편집을 마친 뒤 사용자에게 한 줄 보고 (예: "제3조 둘째 줄에서 '갑'을 '원사업자'로 바꿨습니다.").
  """

  defp build_regular_context(ctx, %Command{} = action) do
    history = fetch_history(ctx, action)

    # Plain Korean text reply. No JSON envelope coupling — the user-message
    # suffix that forced "Respond in JSON only" is gone now that
    # text.format=json_object isn't set on the request.
    input =
      Enum.map(history, fn msg -> %{role: msg.role, content: msg.content} end) ++
        [%{role: "user", content: action.message || ""}]

    # law_mcp_tool is auto-injected by Contract.IO.OpenAI.build_request, so
    # we only contribute the run-scoped contract-doc tool here. Always
    # attached — the prompt tells the model when not to call it.
    tools =
      case mint_doc_route_ref(ctx, action) do
        {:ok, bearer} ->
          case Contract.IO.OpenAI.contract_doc_mcp_tool(bearer) do
            nil -> []
            tool -> [tool]
          end

        _ ->
          []
      end

    # Task #143 — the full document IR no longer ships in the
    # instructions string. The agent fetches it on demand via
    # `doc.get`, which now returns compact IR inline in the MCP tool
    # output. The IRRenderer schema prompt stays so the agent knows how
    # to parse that payload.
    system_prompt =
      [
        @grill_system_prompt,
        @mcp_tools_addendum,
        Contract.Agent.Prompt.IRRenderer.schema_prompt(),
        document_context_note(action.document_id)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    frame = %{
      system: system_prompt,
      input: input,
      tools: tools,
      previous_response_id: action.payload["previous_response_id"],
      grill_seed?: false
    }

    {:ok, frame}
  end

  # Tiny system-note that pins the current document_id so the agent
  # knows which IR to fetch. Returns nil for non-document contexts so
  # the join doesn't leak an empty section header.
  defp document_context_note(nil), do: nil

  defp document_context_note(doc_id) when is_binary(doc_id) do
    "현재 문서 ID: #{doc_id}\n" <>
      "본문 IR이 필요하면 contract-doc MCP의 `doc.get` 도구를 호출하세요. " <>
      "응답 본문에서 직접 `revision`, `p`, `f` 등을 읽으세요."
  end

  defp mint_doc_route_ref(_ctx, %Command{document_id: nil}), do: {:error, :no_document}

  defp mint_doc_route_ref(
         ctx,
         %Command{
           document_id: doc_id,
           chat_thread_id: thread_id
         } = action
       )
       when is_binary(doc_id) do
    user_id = if ctx, do: get_in(Map.from_struct(ctx), [:user, Access.key!(:id)]), else: nil

    # Task #181 — hosted doc.* calls must carry the current semantic run
    # without asking the model to invent an `agent_run_id` argument. The
    # default route_ref mint path stays deterministic for cacheable callers,
    # but an Agent.Document attempt opts into a run-bound payload so stale
    # attempts cannot be rebound to whatever run becomes active later.
    Contract.Gateway.issue_route_ref(ctx, %{
      user_id: user_id,
      document_id: doc_id,
      chat_thread_id: thread_id,
      agent_run_id: action.agent_run_id,
      bind_agent_run_id: is_binary(action.agent_run_id),
      purpose: "agent_doc_mcp",
      scopes: ["agent_doc"],
      ttl: 24 * 60 * 60
    })
  end

  defp mint_doc_route_ref(_ctx, _action), do: {:error, :missing}

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
  Builds an `Action(:agent_change)` from the model's final output.

  Free-form text is the common case (no JSON envelope coupling). For
  backwards compatibility we still detect a JSON envelope (used by older
  tests / grill-protocol prompts) and route through `build_agent_change_action/2`.
  """
  @spec decode_action(String.t() | map(), keyword()) ::
          {:ok, Command.t()} | {:error, term()}
  def decode_action(provider_output, opts \\ [])

  def decode_action(text, opts) when is_binary(text) do
    trimmed = String.trim(text)

    case extract_json(trimmed) do
      {:ok, %{"mode" => _} = payload} ->
        build_agent_change_action(payload, opts)

      _ ->
        # Plain prose reply — wrap into an agent_change Command with
        # empty ops/marks and the text as the user-visible message.
        {:ok,
         %Command{
           kind: :agent_change,
           actor_type: :agent,
           idempotency_key: idempotency_key(opts),
           payload: %{"mode" => "edit", "ops" => [], "marks" => [], "message" => trimmed},
           message: trimmed
         }}
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
  # decode_action's mode:"grill" branch (with `mark_target_type/1`) is
  # gone — the new free-form prompt asks the model to chat naturally, so
  # JSON envelopes with `mode: "grill" | "edit"` no longer arrive from
  # production runs. The `mode: "edit"` clause below is kept as a
  # backwards-compat decoder for the legacy envelope shape (and is what
  # `agent_test.exs` still exercises).

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

  # Task #143 — `fetch_snapshot/2` is gone. The agent reads compact IR via
  # `doc.get` over MCP instead of having it spliced into every
  # `instructions` string. This still avoids paying that token cost on
  # turns that do not need the document body.

  # Wave-3 owns the chat store; until it lands, return an empty history.
  defp fetch_history(ctx, %Command{} = action), do: ChatThreads.history_for_agent(ctx, action)
end
