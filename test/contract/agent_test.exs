defmodule Contract.AgentTest do
  use Contract.DataCase, async: false

  import Mox

  alias Contract.ChatThread
  alias Contract.Command
  alias Contract.Agent
  alias Contract.Repo

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

      assert {:ok, %Command{} = action} =
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
          %{
            "op" => "replace_content",
            "target_type" => "node",
            "target_id" => "node:3",
            "args" => %{"text" => "30 days"}
          }
        ],
        "marks" => [],
        "message" => "Changed payment deadline to 30 days."
      }

      assert {:ok, %Command{} = action} =
               Agent.decode_action(Jason.encode!(payload), run_id: "RUN", turn_index: 1)

      assert action.kind == :agent_change
      assert action.payload["mode"] == "edit"
      assert length(action.payload["ops"]) == 1
      assert action.idempotency_key == "agent:RUN:1"
    end

    test "decode_action error / accepted shapes (JSON, OpenAI response variants)" do
      # Error shapes.
      assert {:error, {:decode_failed, _}} = Agent.decode_action("not-json", run_id: "RUN")

      assert {:error, {:decode_failed, :not_an_object}} =
               Agent.decode_action(Jason.encode!([1, 2, 3]), run_id: "RUN")

      assert {:error, {:decode_failed, :missing_mode}} =
               Agent.decode_action(
                 Jason.encode!(%{"questions" => [], "ops" => [], "marks" => []}),
                 run_id: "RUN"
               )

      assert {:error, {:decode_failed, _}} = Agent.decode_action(123, run_id: "R")

      # Accepted: code-fenced JSON.
      fenced =
        "```json\n" <>
          Jason.encode!(%{"mode" => "edit", "ops" => [], "marks" => [], "message" => "ok"}) <>
          "\n```"

      assert {:ok, %Command{kind: :agent_change}} = Agent.decode_action(fenced, run_id: "R")

      # Accepted: OpenAI Response map output_text.
      assert {:ok, %Command{}} =
               Agent.decode_action(
                 %{
                   "output_text" =>
                     Jason.encode!(%{
                       "mode" => "edit",
                       "ops" => [],
                       "marks" => [],
                       "message" => "ok"
                     })
                 },
                 run_id: "R",
                 turn_index: 2
               )

      # Accepted: OpenAI Response map output[].content[].text.
      response = %{
        "output" => [
          %{
            "type" => "message",
            "content" => [
              %{
                "type" => "output_text",
                "text" =>
                  Jason.encode!(%{
                    "mode" => "grill",
                    "questions" => [],
                    "ops" => [],
                    "marks" => [],
                    "message" => "?"
                  })
              }
            ]
          }
        ]
      }

      assert {:ok, %Command{kind: :agent_change}} = Agent.decode_action(response, run_id: "R")
    end
  end

  describe "build_context/2" do
    test "produces system prompt + tools + input array" do
      action = %Command{
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

      labels =
        ctx.tools
        |> Enum.filter(&(Map.get(&1, :type) == "mcp"))
        |> Enum.map(&Map.get(&1, :server_label))

      assert labels == Enum.uniq(labels)

      [law_tool] = ctx.tools
      assert law_tool.type == "mcp"
      assert law_tool.server_label == "korean-law"
    end

    test "uses previous_response_id from action payload when present" do
      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        message: "hi",
        payload: %{"previous_response_id" => "resp_xyz"}
      }

      assert {:ok, ctx} = Agent.build_context(nil, action)
      assert ctx.previous_response_id == "resp_xyz"
    end

    test "loads persisted ChatThread messages before the current user turn" do
      owner_id = Ecto.UUID.generate()

      thread =
        Repo.insert!(%ChatThread{
          owner_id: owner_id,
          messages: [
            %{"role" => "user", "content" => "We need a SaaS distribution agreement."},
            %{"role" => "assistant", "content" => "What territory should it cover?"}
          ],
          last_message_at: DateTime.utc_now(:second)
        })

      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        actor_id: owner_id,
        chat_thread_id: thread.id,
        message: "South Korea only."
      }

      ctx = Contract.Context.for_user(%Contract.Accounts.User{id: owner_id})

      assert {:ok, frame} = Agent.build_context(ctx, action)

      assert [
               %{role: "user", content: "We need a SaaS distribution agreement."},
               %{role: "assistant", content: "What territory should it cover?"},
               %{role: "user", content: "South Korea only."}
             ] = frame.input
    end

    test "no reservoir on action — frame is unchanged" do
      action = %Command{
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

  describe "grill_intro_system_prompt/0" do
    test "is the Korean auto-grill cold-open prompt with the three-step shape" do
      prompt = Agent.grill_intro_system_prompt()
      assert is_binary(prompt)

      # The agent must speak first in Korean and follow the three-section
      # template (greeting → one-paragraph summary → 1-3 questions).
      assert prompt =~ "계약기계의 법률 문서 에이전트"
      assert prompt =~ "당신이 먼저 말을 걸어야"
      assert prompt =~ "짧은 인사"
      assert prompt =~ "한 단락"
      assert prompt =~ "1-3개의 질문"

      # The intro response must be plain text — NOT the JSON envelope the
      # regular grill protocol uses.
      assert prompt =~ "ops는 emit하지 마"
      assert prompt =~ "순수 텍스트"
      assert prompt =~ "JSON envelope"
    end

    test "is distinct from the regular grill system prompt" do
      refute Agent.grill_intro_system_prompt() == Agent.system_prompt()
    end
  end

  describe "build_context/2 with grill_seed" do
    test "swaps in the grill_intro system prompt and the projection user message" do
      action = %Command{
        kind: :chat_message,
        actor_type: :system,
        message: "GRILL_SEED: …",
        document_id: nil,
        payload: %{
          "grill_seed" => true,
          "grill_seed_nodes" => [
            %{"kind" => "heading", "content" => "비밀유지계약서"},
            %{"kind" => "paragraph", "content" => "당사자는 다음을 약정한다."}
          ]
        }
      }

      assert {:ok, frame} = Agent.build_context(nil, action)
      assert frame.system == Agent.grill_intro_system_prompt()
      assert frame.grill_seed? == true
      assert [%{role: "user", content: content}] = frame.input
      assert content =~ "DOCUMENT_BODY"
      assert content =~ "비밀유지계약서"
      assert content =~ "당사자는 다음을 약정한다"
    end

    test "renders an empty DOCUMENT_BODY when no nodes are provided" do
      action = %Command{
        kind: :chat_message,
        actor_type: :system,
        message: "GRILL_SEED: …",
        document_id: nil,
        payload: %{"grill_seed" => true}
      }

      assert {:ok, frame} = Agent.build_context(nil, action)
      assert frame.system == Agent.grill_intro_system_prompt()
      assert [%{role: "user", content: "DOCUMENT_BODY: (empty)"}] = frame.input
    end
  end

  describe "decode_grill_intro/2" do
    test "wraps plain text as an :agent_change Command (mode=edit, no ops/marks)" do
      text = "안녕하세요. 짧은 요약…\n1) 어떤 일인가요?"

      assert {:ok, %Command{} = action} =
               Agent.decode_grill_intro(text, run_id: "RUN", turn_index: 0)

      assert action.kind == :agent_change
      assert action.actor_type == :agent
      assert action.idempotency_key == "agent:RUN:0"
      assert action.message == text
      assert action.payload["mode"] == "edit"
      assert action.payload["ops"] == []
      assert action.payload["marks"] == []
      assert action.payload["grill_seed"] == true
    end

    test "accepts OpenAI Response output_text / output[] shapes" do
      assert {:ok, %Command{}} =
               Agent.decode_grill_intro(%{"output_text" => "hi"}, run_id: "R")

      response = %{
        "output" => [
          %{
            "type" => "message",
            "content" => [%{"type" => "output_text", "text" => "안녕하세요"}]
          }
        ]
      }

      assert {:ok, %Command{message: "안녕하세요"}} =
               Agent.decode_grill_intro(response, run_id: "R")
    end
  end

  describe "start/2 + RunServer streaming" do
    test "rejects non-supported action kinds" do
      action = %Command{kind: :rename_document, actor_type: :user, message: "x"}
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

      action = %Command{
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

      assert_receive {:agent_completed, ^run_id, %Command{} = final}, 2000
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

      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        message: "change the payment deadline to 30 days",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, run} = Agent.start(nil, action)
      assert_receive {:agent_completed, run_id, %Command{} = final}, 2000
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

      action = %Command{kind: :chat_message, actor_type: :user, message: "ok", payload: %{}}

      assert {:ok, run} = Agent.start(nil, action)
      Phoenix.PubSub.subscribe(Contract.PubSub, "agent:#{run.id}")

      assert_receive {:agent_stream, _, %{type: "response.output_text.delta"}}, 2000
      assert_receive {:agent_completed, _, %Command{}}, 2000
    end

    test "failed decode emits {:agent_failed, _, {:decode_failed, _}}" do
      stream = build_stream([{"response.output_text.delta", %{"delta" => "not-json"}}])

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts -> {:ok, %{stream: stream, task_pid: self()}} end)

      action = %Command{
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

      action = %Command{
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

      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        message: "long",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, run} = Agent.start(nil, action)
      :timer.sleep(50)
      assert {:ok, %{status: :cancelled}} = Agent.cancel(nil, run.id)
    end

    test "observe_change/2 and observe_revoke/2 are no-ops when no run exists" do
      assert :ok = Agent.observe_change("nonexistent-run-id", %Contract.Change{id: "c"})
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
