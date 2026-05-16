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

  alias Contract.Action
  alias Contract.Agent.Run
  alias Contract.Agent.RunServer
  alias Contract.Agent.RunSupervisor
  alias Contract.Studio.ContextReservoir
  alias Contract.Types, as: T

  # Hard cap so a fat reservoir can never blow up the prompt. SPEC.md §20
  # says "Agent SHOULD include … Context Reservoir projection" — bounded.
  @reservoir_max_items 8
  @reservoir_max_chars 4000

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

  @spec start(T.ctx(), Action.t()) :: {:ok, Run.t()} | {:error, term()}
  def start(ctx, %Action{kind: kind} = action)
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

  def start(_ctx, %Action{kind: kind}), do: {:error, {:unsupported_action, kind}}

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

  When the Action carries a Context Reservoir (via `payload["context_reservoir"]`
  or `payload[:context_reservoir]`), it is folded into the agent's input
  frame as a bounded read-only summary — see `include_context_reservoir/2`
  and SPEC.md §10a / §20.
  """
  @spec build_context(T.ctx(), Action.t()) :: {:ok, map()}
  def build_context(_ctx, %Action{} = action) do
    snapshot = fetch_snapshot(action.document_id)
    history = fetch_history(action.document_id)

    input =
      Enum.map(history, fn msg -> %{role: msg.role, content: msg.content} end) ++
        [%{role: "user", content: action.message || ""}]

    tools = [Contract.IO.OpenAI.law_mcp_tool()]

    frame = %{
      system: @grill_system_prompt <> "\n\nCURRENT_DOCUMENT_SNAPSHOT:\n" <> Jason.encode!(snapshot),
      input: input,
      tools: tools,
      previous_response_id: action.payload["previous_response_id"]
    }

    case extract_reservoir(action) do
      nil ->
        {:ok, frame}

      %ContextReservoir{} = reservoir ->
        include_context_reservoir(frame, reservoir)
    end
  end

  @doc """
  Folds the Context Reservoir into the agent's `input` as a bounded
  read-only summary appended to the last user message.

  Per SPEC.md §20: "Agent context SHOULD include … Context Reservoir
  projection". Per SPEC.md §10a: "The agent observes the reservoir as a
  read-only projection. Agent mutations to context still flow through
  Actions; the reservoir is never written to directly."

  The summary is bounded by `@reservoir_max_items` per section and
  `@reservoir_max_chars` overall. An empty reservoir leaves the frame
  untouched (no header noise).
  """
  @spec include_context_reservoir(map(), ContextReservoir.t()) :: {:ok, map()}
  def include_context_reservoir(frame, %ContextReservoir{} = reservoir) do
    case summarize_reservoir(reservoir) do
      "" ->
        {:ok, frame}

      summary ->
        appended = "\n\n## Context Reservoir\n" <> summary
        {:ok, Map.update(frame, :input, [], &append_to_input(&1, appended))}
    end
  end

  # --- reservoir helpers ----------------------------------------------------

  defp extract_reservoir(%Action{payload: payload}) when is_map(payload) do
    case Map.get(payload, "context_reservoir") || Map.get(payload, :context_reservoir) do
      %ContextReservoir{} = r -> r
      _ -> nil
    end
  end

  defp extract_reservoir(_), do: nil

  @doc false
  @spec summarize_reservoir(ContextReservoir.t()) :: String.t()
  def summarize_reservoir(%ContextReservoir{} = r) do
    parts =
      [
        format_brief_section(r.brief),
        format_shared_fields_section(r.shared_fields),
        format_open_questions_section(r.open_questions),
        format_related_documents_section(r.related_documents),
        format_sources_section(r.sources),
        format_evidence_section(r.evidence),
        format_readiness_section(r.readiness)
      ]
      |> Enum.reject(&(&1 == "" or is_nil(&1)))

    parts
    |> Enum.join("\n")
    |> truncate_chars(@reservoir_max_chars)
  end

  defp format_brief_section(brief) when is_map(brief) and map_size(brief) > 0 do
    pieces =
      brief
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.reject(fn {_k, v} -> blank?(v) end)
      |> Enum.take(@reservoir_max_items)
      |> Enum.map(fn {k, v} -> "#{k}: #{stringify(v)}" end)

    case pieces do
      [] -> ""
      list -> "**Brief:** " <> Enum.join(list, " · ")
    end
  end

  defp format_brief_section(_), do: ""

  defp format_shared_fields_section(fields) when is_list(fields) and fields != [] do
    pieces =
      fields
      |> Enum.take(@reservoir_max_items)
      |> Enum.map(fn f ->
        label = read_string(f, [:label, "label", :field_id, "field_id"]) || "field"
        value = read_string(f, [:value, "value"]) || "—"
        "#{label}: #{value}"
      end)

    suffix = trailing_more(length(fields))
    "**Shared fields:** " <> Enum.join(pieces, " · ") <> suffix
  end

  defp format_shared_fields_section(_), do: ""

  defp format_open_questions_section(qs) when is_list(qs) and qs != [] do
    pieces =
      qs
      |> Enum.take(@reservoir_max_items)
      |> Enum.map(fn q ->
        text = read_string(q, [:text, "text"]) || "(no text)"
        "- " <> text
      end)

    header = "**Open questions:** (#{length(qs)})"
    header <> "\n" <> Enum.join(pieces, "\n") <> trailing_more(length(qs))
  end

  defp format_open_questions_section(_), do: ""

  defp format_related_documents_section(docs) when is_list(docs) and docs != [] do
    "**Related documents:** #{length(docs)} related"
  end

  defp format_related_documents_section(_), do: ""

  defp format_sources_section(sources) when is_list(sources) and sources != [] do
    "**Sources:** #{length(sources)} item(s)"
  end

  defp format_sources_section(_), do: ""

  defp format_evidence_section(ev) when is_list(ev) and ev != [] do
    "**Evidence:** #{length(ev)} item(s)"
  end

  defp format_evidence_section(_), do: ""

  defp format_readiness_section(readiness) when is_map(readiness) and map_size(readiness) > 0 do
    unresolved = Map.get(readiness, :unresolved_questions) || Map.get(readiness, "unresolved_questions")
    warnings = Map.get(readiness, :export_warnings) || Map.get(readiness, "export_warnings")
    bits = []
    bits = if is_integer(unresolved), do: bits ++ ["unresolved=#{unresolved}"], else: bits
    bits = if is_integer(warnings), do: bits ++ ["warnings=#{warnings}"], else: bits

    case bits do
      [] -> ""
      list -> "**Readiness:** " <> Enum.join(list, " · ")
    end
  end

  defp format_readiness_section(_), do: ""

  defp trailing_more(n) when n > @reservoir_max_items, do: " …(+#{n - @reservoir_max_items})"
  defp trailing_more(_), do: ""

  defp read_string(map, keys) when is_map(map) do
    Enum.find_value(keys, fn k ->
      case Map.get(map, k) do
        v when is_binary(v) and v != "" -> v
        _ -> nil
      end
    end)
  end

  defp read_string(_, _), do: nil

  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v), do: inspect(v)

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(%{} = m), do: map_size(m) == 0
  defp blank?([]), do: true
  defp blank?(_), do: false

  defp truncate_chars(s, max) when is_binary(s) do
    if byte_size(s) > max, do: binary_part(s, 0, max) <> "…", else: s
  end

  defp append_to_input(input, suffix) when is_binary(input), do: input <> suffix

  defp append_to_input(input, suffix) when is_list(input) do
    case Enum.reverse(input) do
      [%{role: "user", content: content} = last | rest] when is_binary(content) ->
        Enum.reverse([%{last | content: content <> suffix} | rest])

      _ ->
        # No trailing user message — append a system-style user message so the
        # reservoir still reaches the model.
        input ++ [%{role: "user", content: String.trim_leading(suffix)}]
    end
  end

  defp append_to_input(_, suffix), do: [%{role: "user", content: String.trim_leading(suffix)}]

  @doc """
  Parses the model's JSON envelope and returns an `Action(:agent_change)`.

  Accepts either the raw response string or a final OpenAI Response map
  with an `output_text` field.
  """
  @spec decode_action(String.t() | map(), keyword()) ::
          {:ok, Action.t()} | {:error, term()}
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
     %Action{
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
     %Action{
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
        text |> String.replace_prefix("```json", "") |> String.replace_suffix("```", "") |> String.trim()

      String.starts_with?(text, "```") ->
        text |> String.replace_prefix("```", "") |> String.replace_suffix("```", "") |> String.trim()

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
  defp fetch_history(_document_id), do: []

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
