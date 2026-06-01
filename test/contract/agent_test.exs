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

    test "decode_action accepts final text and OpenAI response variants only" do
      assert {:ok, %Command{message: "not-json", payload: %{"ops" => []}}} =
               Agent.decode_action("not-json", run_id: "RUN")

      legacy_json = Jason.encode!(%{"mode" => "edit", "ops" => [%{"op" => "stale"}]})

      assert {:ok, %Command{message: ^legacy_json, payload: %{"ops" => []}}} =
               Agent.decode_action(legacy_json, run_id: "RUN")

      assert {:ok, %Command{}} =
               Agent.decode_action(
                 %{
                   "output_text" => "done"
                 },
                 run_id: "R",
                 turn_index: 2
               )

      response = %{
        "output" => [
          %{
            "type" => "message",
            "content" => [
              %{"type" => "output_text", "text" => "ok"}
            ]
          }
        ]
      }

      assert {:ok, %Command{kind: :agent_change}} = Agent.decode_action(response, run_id: "R")
      assert {:error, {:decode_failed, _}} = Agent.decode_action(%{"output" => []}, run_id: "R")
      assert {:error, {:decode_failed, _}} = Agent.decode_action(123, run_id: "R")
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

    test "projects persisted tool-call operations to document facts only" do
      owner_id = Ecto.UUID.generate()
      agent_run_id = Ecto.UUID.generate()

      thread =
        Repo.insert!(%ChatThread{
          owner_id: owner_id,
          messages: [
            %{"role" => "user", "content" => "Read the document."},
            %{
              "id" => "tool-1",
              "role" => "agent",
              "content" => "",
              "agent_run_id" => agent_run_id,
              "operation" => %{
                "id" => "op-1",
                "type" => "tool_call",
                "tool_name" => "doc.get",
                "raw_name" => "doc.get",
                "server_label" => "contract-doc",
                "name" => "doc.get",
                "title" => "Document read",
                "summary" => "rev 7",
                "reason" => "cached",
                "status" => "completed",
                "details" => %{
                  "arguments" => %{"ignored" => true},
                  "output" => %{
                    "ok" => true,
                    "change_id" => "change-nope",
                    "revision" => 7,
                    "d" => "NDA",
                    "t" => "service",
                    "read" => %{"ignored" => true},
                    "counts" => %{"paragraphs" => 3}
                  }
                }
              },
              "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
            },
            %{
              "id" => "tool-2",
              "role" => "agent",
              "content" => "",
              "agent_run_id" => agent_run_id,
              "operation" => %{
                "id" => "op-2",
                "type" => "tool_call",
                "tool_name" => "doc.read",
                "raw_name" => "doc.read",
                "server_label" => "contract-doc",
                "name" => "doc.read",
                "title" => "Read document",
                "summary" => "read sec 0",
                "reason" => "cache",
                "status" => "completed",
                "details" => %{
                  "arguments" => %{"sec" => 0, "at" => 0},
                  "output" => %{
                    "ok" => true,
                    "change_id" => "change-nope",
                    "revision" => 7,
                    "sec" => 0,
                    "at" => 0,
                    "next_at" => 2,
                    "items" => [
                      %{
                        "kind" => "paragraph",
                        "sec" => 0,
                        "para" => 1,
                        "text" => "Alpha",
                        "chars" => 5,
                        "target" => %{"ignored" => true}
                      }
                    ],
                    "details" => %{"ignored" => true}
                  }
                }
              },
              "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
            },
            %{
              "id" => "tool-3",
              "role" => "agent",
              "content" => "",
              "agent_run_id" => agent_run_id,
              "operation" => %{
                "id" => "op-3",
                "type" => "tool_call",
                "tool_name" => "doc.write",
                "raw_name" => "doc.write",
                "server_label" => "contract-doc",
                "name" => "doc.write",
                "title" => "Write document",
                "summary" => "rev 8",
                "reason" => "committed",
                "status" => "completed",
                "details" => %{
                  "arguments" => %{"text" => "ignored"},
                  "output" => %{
                    "ok" => true,
                    "change_id" => "change-nope",
                    "revision" => 8,
                    "details" => %{"ignored" => true}
                  }
                }
              },
              "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
            }
          ],
          last_message_at: DateTime.utc_now(:second)
        })

      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        actor_id: owner_id,
        chat_thread_id: thread.id,
        message: "What did it say?"
      }

      ctx = Contract.Context.for_user(%Contract.Accounts.User{id: owner_id})

      assert {:ok, frame} = Agent.build_context(ctx, action)

      assert [
               %{role: "user", content: "Read the document."},
               %{role: "assistant", content: get_content},
               %{role: "assistant", content: read_content},
               %{role: "assistant", content: write_content},
               %{role: "user", content: "What did it say?"}
             ] = frame.input

      assert get_content =~ "doc.get facts:\n"
      get_json = String.replace_prefix(get_content, "doc.get facts:\n", "")

      assert Jason.decode!(get_json) == %{
               "revision" => 7,
               "d" => "NDA",
               "t" => "service",
               "counts" => %{"paragraphs" => 3}
             }

      assert read_content =~ "doc.read facts:\n"
      read_json = String.replace_prefix(read_content, "doc.read facts:\n", "")

      assert Jason.decode!(read_json) == %{
               "revision" => 7,
               "sec" => 0,
               "at" => 0,
               "next_at" => 2,
               "items" => [
                 %{"sec" => 0, "para" => 1, "text" => "Alpha", "chars" => 5}
               ]
             }

      assert write_content =~ "doc.write facts:\n"
      write_json = String.replace_prefix(write_content, "doc.write facts:\n", "")
      assert Jason.decode!(write_json) == %{"revision" => 8}

      joined = Enum.join([get_content, read_content, write_content], "\n")

      for forbidden <-
            ~w(ok change_id raw_name server_label status title summary reason tool_name name type details arguments) do
        refute joined =~ forbidden
      end

      refute joined =~ "Document read"
      refute joined =~ "Read document"
      refute joined =~ "Write document"
      refute joined =~ "contract-doc"
      refute joined =~ "cached"
      refute joined =~ "ignored"
    end

    test "projects new minimal persisted tool-call operation to agent history" do
      owner_id = Ecto.UUID.generate()

      thread =
        Repo.insert!(%ChatThread{
          owner_id: owner_id,
          messages: [
            %{
              "id" => "tool-minimal",
              "role" => "agent",
              "content" => "",
              "operation" => %{
                "id" => "tool-minimal",
                "name" => "doc.write",
                "output" => %{"revision" => 9}
              }
            }
          ],
          last_message_at: DateTime.utc_now(:second)
        })

      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        actor_id: owner_id,
        chat_thread_id: thread.id,
        message: "continue"
      }

      ctx = Contract.Context.for_user(%Contract.Accounts.User{id: owner_id})

      assert {:ok, frame} = Agent.build_context(ctx, action)

      assert [
               %{role: "assistant", content: "doc.write facts:\n{\"revision\":9}"},
               %{role: "user", content: "continue"}
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

    test "instructions no longer expose hosted document tool surface" do
      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        message: "hi",
        document_id: Ecto.UUID.generate()
      }

      assert {:ok, frame} = Agent.build_context(nil, action)
      refute frame.system =~ "CURRENT_DOCUMENT_IR"
      assert frame.system =~ "문서 편집 도구는 서버 에이전트에 제공되지 않습니다"
      refute frame.system =~ "현재 문서 ID"
      refute frame.system =~ "contract-doc"
      refute frame.system =~ "doc.get"
      refute frame.system =~ "doc.read"
      refute frame.system =~ "doc.write"
      refute frame.system =~ "doc.get(type:"
      refute frame.system =~ "paragraph_index"
      refute frame.system =~ "leaf_index"
      refute frame.system =~ "bounded metadata/read hints/cursors"
      refute frame.system =~ "doc.get`은 aggregate metadata/read contract"
      refute frame.system =~ "cursors.outline"
      refute frame.system =~ "ir_url"
      refute frame.system =~ "GET"
      refute frame.system =~ "본문 IR이 필요하면"
    end

    test "instructions do not promise server-side document edits" do
      action = %Command{
        kind: :chat_message,
        actor_type: :user,
        message: "change the contract period",
        document_id: Ecto.UUID.generate()
      }

      assert {:ok, frame} = Agent.build_context(nil, action)

      assert frame.system =~ "실제 반영했다고 말하지 말고"
      assert frame.system =~ "필요한 변경 위치, 기존 문구, 새 문구"
      refute frame.system =~ "`doc.write"
      refute frame.system =~ "insert_after_match"
      refute frame.system =~ "insert_before_match"
      refute frame.system =~ "insert_at_offset"
      refute frame.system =~ "insert_paragraph_after"
      refute frame.system =~ "payload:{cmd,payload}"
      refute frame.system =~ "`doc.edit`"
      refute frame.system =~ "doc.find"
      refute frame.system =~ "paragraph_index"
      refute frame.system =~ "leaf_index"
      refute frame.system =~ "target"
      refute frame.system =~ "cell_path"
      refute frame.system =~ "field_id"
      refute frame.system =~ "len"
      refute frame.system =~ "doc.edit_text"
      refute frame.system =~ "doc.insert_block"
      refute frame.system =~ "doc.delete_block"
      refute frame.system =~ "doc.edit_table"
      refute frame.system =~ "doc.set_field_value"
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
      assert frame.tools == []
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

  describe "stale runtime guards" do
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
