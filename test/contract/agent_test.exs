defmodule Contract.AgentTest do
  use ExUnit.Case, async: false

  import Mox

  alias Contract.Action
  alias Contract.Agent

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "decode_action/2" do
    test "grill mode produces Action(:agent_change) with marks-only, no ops" do
      payload = %{
        "mode" => "grill",
        "questions" => [
          %{
            "text" => "Which clause should be stricter?",
            "rationale" => "request is ambiguous",
            "target_node_id" => nil
          },
          %{
            "text" => "What penalty amount?",
            "rationale" => "legal policy decision",
            "target_node_id" => "node:5"
          }
        ],
        "ops" => [],
        "marks" => [],
        "message" => "I need more detail before editing."
      }

      assert {:ok, %Action{} = action} =
               Agent.decode_action(Jason.encode!(payload), run_id: "RUN", turn_index: 0)

      assert action.kind == :agent_change
      assert action.actor_type == :agent
      assert action.idempotency_key == "agent:RUN:0"
      assert action.message == "I need more detail before editing."

      assert action.payload["mode"] == "grill"
      assert action.payload["ops"] == []
      assert length(action.payload["marks"]) == 2

      assert Enum.all?(action.payload["marks"], &(&1["intent"] == "ask"))
      assert Enum.all?(action.payload["marks"], &(&1["source"] == "agent"))

      [first, second] = action.payload["marks"]
      assert first["target_type"] == "document"
      assert second["target_type"] == "node"
      assert second["target_id"] == "node:5"
    end

    test "edit mode produces Action(:agent_change) with ops" do
      payload = %{
        "mode" => "edit",
        "questions" => [],
        "ops" => [
          %{"op" => "replace_content", "target_type" => "node", "target_id" => "node:3", "args" => %{"text" => "30 days"}}
        ],
        "marks" => [],
        "message" => "Changed payment deadline to 30 days."
      }

      assert {:ok, %Action{} = action} =
               Agent.decode_action(Jason.encode!(payload), run_id: "RUN", turn_index: 1)

      assert action.kind == :agent_change
      assert action.payload["mode"] == "edit"
      assert length(action.payload["ops"]) == 1
      assert action.idempotency_key == "agent:RUN:1"
    end

    test "handles malformed JSON gracefully" do
      assert {:error, {:decode_failed, _}} = Agent.decode_action("not-json", run_id: "RUN")
    end

    test "handles JSON that isn't an object" do
      assert {:error, {:decode_failed, :not_an_object}} =
               Agent.decode_action(Jason.encode!([1, 2, 3]), run_id: "RUN")
    end

    test "missing mode returns {:error, _}" do
      payload = %{"questions" => [], "ops" => [], "marks" => []}

      assert {:error, {:decode_failed, :missing_mode}} =
               Agent.decode_action(Jason.encode!(payload), run_id: "RUN")
    end

    test "strips ```json code fence" do
      payload = %{"mode" => "edit", "ops" => [], "marks" => [], "message" => "ok"}
      wrapped = "```json\n" <> Jason.encode!(payload) <> "\n```"

      assert {:ok, %Action{kind: :agent_change}} = Agent.decode_action(wrapped, run_id: "R")
    end

    test "accepts OpenAI Response map with output_text" do
      payload = %{"mode" => "edit", "ops" => [], "marks" => [], "message" => "ok"}
      response = %{"output_text" => Jason.encode!(payload)}

      assert {:ok, %Action{}} = Agent.decode_action(response, run_id: "R", turn_index: 2)
    end

    test "accepts OpenAI Response map with output[].content[].text" do
      payload = %{"mode" => "grill", "questions" => [], "ops" => [], "marks" => [], "message" => "?"}

      response = %{
        "output" => [
          %{
            "type" => "message",
            "content" => [
              %{"type" => "output_text", "text" => Jason.encode!(payload)}
            ]
          }
        ]
      }

      assert {:ok, %Action{kind: :agent_change}} = Agent.decode_action(response, run_id: "R")
    end

    test "rejects non-string non-map shape" do
      assert {:error, {:decode_failed, _}} = Agent.decode_action(123, run_id: "R")
    end
  end

  describe "build_context/2" do
    test "produces system prompt + tools + input array" do
      action = %Action{
        kind: :chat_message,
        actor_type: :user,
        message: "hello",
        document_id: nil
      }

      assert {:ok, ctx} = Agent.build_context(nil, action)
      assert is_binary(ctx.system)
      assert ctx.system =~ "GRILL-ME PROTOCOL"
      assert ctx.system =~ "CITATION POLICY"
      assert is_list(ctx.input)
      [user_msg] = ctx.input
      assert user_msg.role == "user"
      assert user_msg.content == "hello"

      [law_tool] = ctx.tools
      assert law_tool.type == "mcp"
      assert law_tool.server_label == "korean-law"
    end

    test "uses previous_response_id from action payload when present" do
      action = %Action{
        kind: :chat_message,
        actor_type: :user,
        message: "hi",
        payload: %{"previous_response_id" => "resp_xyz"}
      }

      assert {:ok, ctx} = Agent.build_context(nil, action)
      assert ctx.previous_response_id == "resp_xyz"
    end

    test "folds a populated Context Reservoir into the agent's input (SPEC.md §10a, §20)" do
      reservoir = %Contract.Studio.ContextReservoir{
        brief: %{purpose: "draft NDA", status: :drafting, user_role: "discloser"},
        shared_fields: [
          %{field_id: "party_a", label: "Party A", value: "Acme"},
          %{field_id: "party_b", label: "Party B", value: "Beta"}
        ],
        open_questions: [
          %{question_id: "q1", text: "Mutual or one-way?", asked_by: :agent}
        ],
        related_documents: [
          %{document_id: "d1", label_ko: "초안", label_en: "draft", role: :current_draft}
        ],
        evidence: [
          %{evidence_id: "e1", source: :law_mcp, summary: "민법 §391"}
        ]
      }

      action = %Action{
        kind: :chat_message,
        actor_type: :user,
        message: "tighten this",
        payload: %{"context_reservoir" => reservoir}
      }

      assert {:ok, ctx} = Agent.build_context(nil, action)
      [user_msg] = ctx.input
      assert user_msg.role == "user"
      assert user_msg.content =~ "tighten this"
      assert user_msg.content =~ "## Context Reservoir"
      assert user_msg.content =~ "Brief:"
      assert user_msg.content =~ "Open questions:"
      assert user_msg.content =~ "Mutual or one-way?"
      assert user_msg.content =~ "Related documents:"
      assert user_msg.content =~ "Evidence:"
    end

    test "empty reservoir leaves the input mostly unchanged — no header noise" do
      action = %Action{
        kind: :chat_message,
        actor_type: :user,
        message: "hi",
        payload: %{"context_reservoir" => %Contract.Studio.ContextReservoir{}}
      }

      assert {:ok, ctx} = Agent.build_context(nil, action)
      [user_msg] = ctx.input
      assert user_msg.content == "hi"
      refute user_msg.content =~ "Context Reservoir"
      refute user_msg.content =~ "Brief:"
    end

    test "no reservoir on action — frame is unchanged" do
      action = %Action{
        kind: :chat_message,
        actor_type: :user,
        message: "hello",
        payload: %{}
      }

      assert {:ok, ctx} = Agent.build_context(nil, action)
      [user_msg] = ctx.input
      assert user_msg.content == "hello"
      refute user_msg.content =~ "Context Reservoir"
    end
  end

  describe "include_context_reservoir/2" do
    test "appends the summary to a trailing user message" do
      frame = %{input: [%{role: "user", content: "do thing"}], system: "sys", tools: []}
      reservoir = %Contract.Studio.ContextReservoir{
        brief: %{purpose: "NDA"},
        open_questions: [%{question_id: "q1", text: "mutual?"}]
      }

      assert {:ok, new_frame} = Agent.include_context_reservoir(frame, reservoir)
      [%{content: content}] = new_frame.input
      assert content =~ "do thing"
      assert content =~ "## Context Reservoir"
      assert content =~ "Brief:"
      assert content =~ "mutual?"
    end

    test "empty reservoir is a no-op (no header)" do
      frame = %{input: [%{role: "user", content: "ok"}], system: "sys", tools: []}
      empty = %Contract.Studio.ContextReservoir{}

      assert {:ok, ^frame} = Agent.include_context_reservoir(frame, empty)
    end

    test "long lists are truncated to N items + '…(+more)' marker" do
      qs =
        for i <- 1..20 do
          %{question_id: "q#{i}", text: "question #{i}"}
        end

      reservoir = %Contract.Studio.ContextReservoir{open_questions: qs}
      summary = Agent.summarize_reservoir(reservoir)

      # Header reports the total count
      assert summary =~ "Open questions:"
      assert summary =~ "(20)"

      # Only the first N items are rendered verbatim — late ones become "…(+N)".
      assert summary =~ "question 1"
      refute summary =~ "question 20"
      assert summary =~ "…(+"
    end

    test "summary is bounded to ≤ 4000 chars even for a fat reservoir" do
      big_brief = for k <- 1..200, into: %{}, do: {"k#{k}", String.duplicate("v", 200)}
      reservoir = %Contract.Studio.ContextReservoir{brief: big_brief}
      summary = Agent.summarize_reservoir(reservoir)

      assert byte_size(summary) <= 4000 + String.length("…")
    end
  end

  describe "system_prompt/0" do
    test "is a string with the grill-me + citation-policy clauses" do
      prompt = Agent.system_prompt()
      assert is_binary(prompt)
      assert prompt =~ "GRILL-ME PROTOCOL"
      assert prompt =~ "grill"
      assert prompt =~ "mode=edit"
      assert prompt =~ "CITATION POLICY"
      assert prompt =~ "verify_citations"
    end
  end

  describe "start/2 + RunServer streaming" do
    test "rejects non-supported action kinds" do
      action = %Action{kind: :rename_document, actor_type: :user, message: "x"}
      assert {:error, {:unsupported_action, :rename_document}} = Agent.start(nil, action)
    end

    test "grill-mode on ambiguous input streams marks-only Action(:agent_change)" do
      stream =
        build_stream([
          {"response.output_text.delta", %{"delta" => "{\"mode\":\"grill\","}},
          {"response.output_text.delta",
           %{
             "delta" =>
               "\"questions\":[{\"text\":\"Which clause?\",\"rationale\":\"ambiguous\",\"target_node_id\":null}],"
           }},
          {"response.output_text.delta",
           %{"delta" => "\"ops\":[],\"marks\":[],\"message\":\"Which clause?\"}"}}
        ])

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts ->
        {:ok, %{stream: stream, task_pid: self()}}
      end)

      action = %Action{
        kind: :chat_message,
        actor_type: :user,
        message: "make this stricter",
        document_id: nil,
        payload: %{"test_pid" => self()}
      }

      assert {:ok, run} = Agent.start(nil, action)
      assert run.status == :running

      assert_receive {:agent_stream, run_id, %{type: "response.output_text.delta"}}, 1500
      assert run_id == run.id

      assert_receive {:agent_completed, ^run_id, %Action{} = final}, 2000
      assert final.kind == :agent_change
      assert final.payload["mode"] == "grill"
      assert final.payload["ops"] == []
      assert length(final.payload["marks"]) == 1
      assert hd(final.payload["marks"])["intent"] == "ask"
    end

    test "edit-mode on specific input streams Action(:agent_change) with ops" do
      payload =
        Jason.encode!(%{
          "mode" => "edit",
          "questions" => [],
          "ops" => [
            %{
              "op" => "replace_content",
              "target_type" => "node",
              "target_id" => "node:3",
              "args" => %{"text" => "30 days"}
            }
          ],
          "marks" => [],
          "message" => "Updated payment deadline."
        })

      stream =
        build_stream([
          {"response.output_text.delta", %{"delta" => payload}}
        ])

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts -> {:ok, %{stream: stream, task_pid: self()}} end)

      action = %Action{
        kind: :chat_message,
        actor_type: :user,
        message: "change the payment deadline to 30 days",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, run} = Agent.start(nil, action)
      assert_receive {:agent_completed, run_id, %Action{} = final}, 2000
      assert run_id == run.id
      assert final.payload["mode"] == "edit"
      assert length(final.payload["ops"]) == 1
      assert hd(final.payload["ops"])["op"] == "replace_content"
    end

    test "broadcasts stream events on PubSub topic agent:<run_id>" do
      stream =
        build_stream([
          {"response.output_text.delta",
           %{
             "delta" =>
               Jason.encode!(%{
                 "mode" => "edit",
                 "ops" => [],
                 "marks" => [],
                 "message" => "ok"
               })
           }}
        ])

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts -> {:ok, %{stream: stream, task_pid: self()}} end)

      action = %Action{kind: :chat_message, actor_type: :user, message: "ok", payload: %{}}

      assert {:ok, run} = Agent.start(nil, action)
      Phoenix.PubSub.subscribe(Contract.PubSub, "agent:#{run.id}")

      assert_receive {:agent_stream, _, %{type: "response.output_text.delta"}}, 2000
      assert_receive {:agent_completed, _, %Action{}}, 2000
    end

    test "failed decode emits {:agent_failed, _, {:decode_failed, _}}" do
      stream = build_stream([{"response.output_text.delta", %{"delta" => "not-json"}}])

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts -> {:ok, %{stream: stream, task_pid: self()}} end)

      action = %Action{
        kind: :chat_message,
        actor_type: :user,
        message: "x",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, _run} = Agent.start(nil, action)
      assert_receive {:agent_failed, _, {:decode_failed, _}}, 2000
    end

    test "OpenAI driver error fails the run" do
      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts -> {:error, :upstream_down} end)

      action = %Action{
        kind: :chat_message,
        actor_type: :user,
        message: "x",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, _run} = Agent.start(nil, action)
      assert_receive {:agent_failed, _, :upstream_down}, 2000
    end

    test "cancel/2 stops the run server" do
      stream =
        Stream.unfold(0, fn _i ->
          Process.sleep(50)
          {%{type: "response.output_text.delta", data: %{"delta" => "x"}}, 0}
        end)

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts -> {:ok, %{stream: stream, task_pid: self()}} end)

      action = %Action{
        kind: :chat_message,
        actor_type: :user,
        message: "long",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, run} = Agent.start(nil, action)
      :timer.sleep(50)
      assert {:ok, %{status: :cancelled}} = Agent.cancel(nil, run.id)
    end

    test "observe_change/2 is a no-op when no run exists" do
      assert :ok = Agent.observe_change("nonexistent-run-id", %Contract.Change{id: "c"})
    end

    test "observe_revoke/2 is a no-op when no run exists" do
      assert :ok = Agent.observe_revoke("nonexistent-run-id", %Contract.Change{id: "c"})
    end
  end

  defp build_stream(events) do
    events
    |> Enum.map(fn {type, data} ->
      %{type: type, data: Map.put(data, "type", type)}
    end)
  end
end
