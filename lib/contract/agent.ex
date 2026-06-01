defmodule Contract.Agent do
  @moduledoc """
  Semantic interpreter. Agent resolves targets; backend validates returned
  IDs.

  This module owns prompt assembly and final-text decoding. Runtime ownership
  lives at `Contract.Agent.Document`.

  See SPEC.md §20, §24 and `/tmp/wave1-research.md` for the verified
  OpenAI Responses + Korean Law MCP shapes.
  """

  alias Contract.ChatThreads
  alias Contract.Command
  alias Contract.Types, as: T

  @grill_system_prompt """
  당신은 계약기계의 법률 문서 에이전트입니다. 한국어 존댓말로 사용자와 자연스럽게 대화합니다.

  기본 원칙:
    * 사용자에게 친절히 답하세요. 모든 메시지가 편집 요청은 아닙니다.
    * 사용자가 "X를 박아줘", "Y로 바꿔줘", "Z 추가해줘" 같이 **명시적으로 편집을 요청한 경우** 실제 반영했다고 말하지 말고 필요한 변경 위치와 문구를 확인하세요.
    * 단순 질문 ("어떤 내용인가요?", "이 조항은 무슨 의미?", "안녕"), 의견 요청, 일반 대화는 **도구 호출 없이** 자연스럽게 답하세요.
    * 편집 요청이라도 의도가 모호하면 먼저 한두 문장의 명확화 질문을 하세요. 추측으로 편집하지 마세요.

  편집 요청을 받을 때:
    * 문서 편집 도구는 서버 에이전트에 제공되지 않습니다.
    * 서버 에이전트는 문서를 직접 수정하지 않습니다. 실제 local document tools 실행은 workspace provider 경로가 담당합니다.
    * 필요한 변경 위치, 기존 문구, 새 문구를 확인한 뒤 간결하게 답하세요.

  법령(민법, 상법 등) 인용은 `korean-law` MCP 의 `verify_citations` 로 먼저 확인.

  중요: 응답은 일반 한국어 대화체 문장입니다. JSON 으로 감싸지 마세요.
  """

  @grill_intro_system_prompt """
  당신은 계약기계의 법률 문서 에이전트입니다.

  오늘은 사용자가 새 계약 문서를 열었고, 채팅 이력이 비어 있습니다. 당신이 먼저 말을 걸어야 합니다.

  다음 순서로 ONE message에 모두 담아 응답하세요:

  1. 짧은 인사 (한 줄, 격식 있는 한국어).
  2. 문서 본문을 훑고 한 단락(2-3 문장)으로 요약 — 무슨 종류의 계약/문서인지, 주요 당사자나 주제는 무엇인지.
  3. 패킷 맥락을 좁히는 1-3개의 질문을 번호 매겨 제시:
     - 이 패킷이 어떤 일/거래인지
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

  @doc """
  Assembles the system prompt, conversation history, tool list, and
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
    history = fetch_history(ctx, action)

    # Plain Korean text reply. No JSON envelope coupling — the user-message
    # suffix that forced "Respond in JSON only" is gone now that
    # text.format=json_object isn't set on the request.
    input =
      Enum.map(history, fn msg -> %{role: msg.role, content: msg.content} end) ++
        [%{role: "user", content: action.message || ""}]

    frame = %{
      system: @grill_system_prompt,
      input: input,
      tools: [],
      previous_response_id: action.payload["previous_response_id"],
      grill_seed?: false
    }

    {:ok, frame}
  end

  defp build_grill_intro_context(%Command{} = action) do
    nodes_summary = grill_seed_nodes_summary(action.payload["grill_seed_nodes"])

    user_content =
      case nodes_summary do
        "" -> "DOCUMENT_BODY: (empty)"
        text -> "DOCUMENT_BODY:\n" <> text
      end

    frame = %{
      system: @grill_intro_system_prompt,
      input: [%{role: "user", content: user_content}],
      tools: [],
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

  def decode_grill_intro(%{} = response, opts) do
    case response_text(response) do
      text when is_binary(text) -> decode_grill_intro(text, opts)
      nil -> {:error, {:decode_failed, {:bad_shape, response}}}
    end
  end

  def decode_grill_intro(other, _opts), do: {:error, {:decode_failed, {:bad_shape, other}}}

  @doc """
  Builds an `Action(:agent_change)` from the model's final output.

  Free-form text is the live path. Document writes happen during the stream via
  contract-doc MCP tools; the final assistant text is stored as chat only.
  """
  @spec decode_action(String.t() | map(), keyword()) ::
          {:ok, Command.t()} | {:error, term()}
  def decode_action(provider_output, opts \\ [])

  def decode_action(text, opts) when is_binary(text) do
    trimmed = String.trim(text)

    {:ok,
     %Command{
       kind: :agent_change,
       actor_type: :agent,
       idempotency_key: idempotency_key(opts),
       payload: %{"mode" => "edit", "ops" => [], "marks" => [], "message" => trimmed},
       message: trimmed
     }}
  end

  def decode_action(%{} = response, opts) do
    case response_text(response) do
      text when is_binary(text) -> decode_action(text, opts)
      nil -> {:error, {:decode_failed, {:bad_shape, response}}}
    end
  end

  def decode_action(other, _opts), do: {:error, {:decode_failed, {:bad_shape, other}}}

  # --- internals --------------------------------------------------------

  defp idempotency_key(opts) do
    run_id = Keyword.get(opts, :run_id, "anon")
    turn = Keyword.get(opts, :turn_index, 0)
    "agent:#{run_id}:#{turn}"
  end

  defp response_text(%{"output_text" => text}) when is_binary(text), do: text

  defp response_text(%{"output" => output}) when is_list(output) do
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

    if text == "", do: nil, else: text
  end

  defp response_text(_response), do: nil

  # Task #143/#222 — `fetch_snapshot/2` is gone. The prompt path no longer
  # splices document IR into every request; the agent gets aggregate metadata
  # from doc.get and reads content/navigation through doc.read.
  # This still avoids paying the body-token cost on turns that do not need the
  # document body.

  # Wave-3 owns the chat store; until it lands, return an empty history.
  defp fetch_history(ctx, %Command{} = action), do: ChatThreads.history_for_agent(ctx, action)
end
