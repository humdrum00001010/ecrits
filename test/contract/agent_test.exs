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
    test "free-form text produces Action(:agent_change) with no ops" do
      assert {:ok, %Command{} = action} =
               Agent.decode_action("I need more detail before editing.", run_id: "RUN")

      assert action.kind == :agent_change
      assert action.actor_type == :agent
      assert action.idempotency_key == "agent:RUN:0"
      assert action.message == "I need more detail before editing."

      assert action.payload["mode"] == "edit"
      assert action.payload["ops"] == []
      assert action.payload["marks"] == []
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

    test "decode_action accepted shapes (plain text, JSON, OpenAI response variants)" do
      assert {:ok, %Command{message: "not-json", payload: %{"ops" => []}}} =
               Agent.decode_action("not-json", run_id: "RUN")

      assert {:ok, %Command{message: "[1,2,3]"}} =
               Agent.decode_action(Jason.encode!([1, 2, 3]), run_id: "RUN")

      assert {:ok, %Command{message: json_object}} =
               Agent.decode_action(
                 Jason.encode!(%{"questions" => [], "ops" => [], "marks" => []}),
                 run_id: "RUN"
               )

      assert json_object =~ "questions"
      assert {:error, {:decode_failed, _}} = Agent.decode_action(123, run_id: "R")

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
                    "mode" => "edit",
                    "ops" => [],
                    "marks" => [],
                    "message" => "ok"
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
      assert ctx.system =~ "계약기계의 법률 문서 에이전트"
      assert ctx.system =~ "verify_citations"
      assert is_list(ctx.input)
      [user_msg] = ctx.input
      assert user_msg.role == "user"
      assert user_msg.content == "hello"

      assert ctx.tools == []
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

    # Task #143 — the full document IR no longer ships in the
    # instructions string. The agent must call `doc.get` to read it.
    test "instructions no longer inline CURRENT_DOCUMENT_IR" do
      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        message: "hi",
        document_id: Ecto.UUID.generate()
      }

      assert {:ok, frame} = Agent.build_context(nil, action)
      refute frame.system =~ "CURRENT_DOCUMENT_IR"
      assert frame.system =~ "doc.get"
      assert frame.system =~ "현재 문서 ID"
      assert frame.system =~ "응답 본문"
      refute frame.system =~ "ir_url"
      refute frame.system =~ "GET"
    end

    test "instructions prefer fields for slot edits and full-value text replacement" do
      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        message: "change the contract period",
        document_id: Ecto.UUID.generate()
      }

      assert {:ok, frame} = Agent.build_context(nil, action)

      assert frame.system =~ "slot-like date/period edit"
      assert frame.system =~ "prefer `doc.set_field_value`"
      assert frame.system =~ "replace the full exact existing value or paragraph"
      assert frame.system =~ "not only a label prefix"
      assert frame.system =~ "Use `doc.get` for metadata, outline, fields, and revision"
      assert frame.system =~ "Use `doc.find` when you already know target text"
    end

    test "instructions omit the document-context note for nil document_id" do
      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        message: "hi",
        document_id: nil
      }

      assert {:ok, frame} = Agent.build_context(nil, action)
      refute frame.system =~ "현재 문서 ID"
    end
  end

  describe "system_prompt/0" do
    test "is a string with the free-form agent and citation clauses" do
      prompt = Agent.system_prompt()
      assert is_binary(prompt)
      assert prompt =~ "계약기계의 법률 문서 에이전트"
      assert prompt =~ "명시적으로 편집을 요청"
      assert prompt =~ "JSON 으로 감싸지 마세요"
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

      # The intro response must be plain text.
      assert prompt =~ "도구 호출 없이"
      assert prompt =~ "순수 한국어 텍스트"
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

  describe "runtime facade compatibility" do
    test "rejects non-supported action kinds" do
      action = %Command{kind: :rename_document, actor_type: :user, message: "x"}
      assert {:error, {:unsupported_action, :rename_document}} = Agent.start(nil, action)
    end

    test "start/2 is a stale runtime entrypoint for chat messages" do
      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        message: "make this stricter"
      }

      assert {:error, {:stale_runtime_entrypoint, Contract.Agent, Contract.Agent.Document}} =
               Agent.start(nil, action)
    end

    test "cancel/2 is a stale runtime entrypoint" do
      assert {:error, {:stale_runtime_entrypoint, Contract.Agent, Contract.Agent.Document}} =
               Agent.cancel(nil, Ecto.UUID.generate())
    end

    test "RunServer cannot be started directly as a GenServer" do
      Process.flag(:trap_exit, true)
      run = %Contract.Agent.Run{id: Ecto.UUID.generate()}

      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        message: "stale direct start",
        document_id: Ecto.UUID.generate()
      }

      assert {:error,
              {:stale_runtime_entrypoint, Contract.Agent.RunServer, Contract.Agent.Document}} =
               GenServer.start_link(Contract.Agent.RunServer,
                 run_id: run.id,
                 run: run,
                 action: action,
                 ctx: nil
               )
    end
  end
end
