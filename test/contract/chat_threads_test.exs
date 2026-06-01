defmodule Contract.ChatThreadsTest do
  use Contract.DataCase, async: false

  alias Contract.ChatThread
  alias Contract.ChatThreads
  alias Contract.Command
  alias Contract.Context
  alias Contract.Repo
  alias Contract.Studio.State

  describe "list_visible_messages/2" do
    test "excludes rows with role `system` (auto-grill seed)" do
      owner_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()

      Repo.insert!(%ChatThread{
        owner_id: owner_id,
        document_id: document_id,
        title: "Discussion",
        status: "active",
        messages: [
          %{
            "id" => Ecto.UUID.generate(),
            "role" => "system",
            "content" => "GRILL_SEED: …",
            "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
          },
          %{
            "id" => Ecto.UUID.generate(),
            "role" => "assistant",
            "content" => "안녕하세요. 어떤 계약인가요?",
            "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
          },
          %{
            "id" => Ecto.UUID.generate(),
            "role" => "user",
            "content" => "NDA 입니다.",
            "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
          }
        ],
        last_message_at: DateTime.utc_now(:second)
      })

      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})
      state = %State{selected_document_id: document_id, mode: :editing}

      messages = ChatThreads.list_visible_messages(ctx, state)
      roles = Enum.map(messages, & &1.role)

      refute Enum.any?(roles, &(&1 == :system))
      assert :agent in roles
      assert :user in roles
      assert length(messages) == 2
    end

    test "current_thread_info/2 returns visible title metadata" do
      owner_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()

      Repo.insert!(%ChatThread{
        owner_id: owner_id,
        document_id: document_id,
        title: "Discussion - Scope confirmed",
        status: "active",
        messages: [
          %{
            "id" => Ecto.UUID.generate(),
            "role" => "system",
            "content" => "GRILL_SEED",
            "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
          },
          %{
            "id" => Ecto.UUID.generate(),
            "role" => "user",
            "content" => "Please review this.",
            "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
          }
        ],
        last_message_at: DateTime.utc_now(:second)
      })

      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})
      state = %State{selected_document_id: document_id, mode: :editing}

      assert %{
               id: _,
               title: "Discussion - Scope confirmed",
               message_count: 1
             } = ChatThreads.current_thread_info(ctx, state)
    end

    test "reset_context/2 archives the active visible thread" do
      owner_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()

      thread =
        Repo.insert!(%ChatThread{
          owner_id: owner_id,
          document_id: document_id,
          title: "Discussion",
          status: "active",
          messages: [
            %{
              "id" => Ecto.UUID.generate(),
              "role" => "user",
              "content" => "old context",
              "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
            }
          ],
          last_message_at: DateTime.utc_now(:second)
        })

      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})
      state = %State{selected_document_id: document_id, mode: :editing}

      assert {:ok, :archived} = ChatThreads.reset_context(ctx, state)

      assert Repo.get!(ChatThread, thread.id).status == "archived"
      assert ChatThreads.current_thread_info(ctx, state) == nil
      assert ChatThreads.list_visible_messages(ctx, state) == []
    end

    test "rename_context/3 updates the active visible thread title" do
      owner_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()

      thread =
        Repo.insert!(%ChatThread{
          owner_id: owner_id,
          document_id: document_id,
          title: "Discussion - Scope confirmed",
          status: "active",
          messages: [
            %{
              "id" => Ecto.UUID.generate(),
              "role" => "user",
              "content" => "old context",
              "inserted_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
            }
          ],
          last_message_at: DateTime.utc_now(:second)
        })

      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})
      state = %State{selected_document_id: document_id, mode: :editing}

      assert {:ok, %ChatThread{title: "Deal setup"}} =
               ChatThreads.rename_context(ctx, state, "  Deal   setup  ")

      assert Repo.get!(ChatThread, thread.id).title == "Deal setup"
      assert %{title: "Deal setup"} = ChatThreads.current_thread_info(ctx, state)
    end

    test "rename_context/3 creates the visible thread when the context is fresh" do
      owner_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()
      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})
      state = %State{selected_document_id: document_id, mode: :editing}

      assert {:ok, %ChatThread{title: "Deal setup", messages: []}} =
               ChatThreads.rename_context(ctx, state, "Deal setup")

      assert %{title: "Deal setup", message_count: 0} =
               ChatThreads.current_thread_info(ctx, state)
    end

    test "rename_context/3 does not create empty no-document threads" do
      owner_id = Ecto.UUID.generate()
      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})
      state = %State{selected_document_id: nil, mode: :no_document}

      assert {:error, :not_found} = ChatThreads.rename_context(ctx, state, "새 대화")
      assert ChatThreads.current_thread_info(ctx, state) == nil
      assert Repo.aggregate(ChatThread, :count) == 0
    end

    test "preserves persisted operation order for a run" do
      owner_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()
      agent_run_id = Ecto.UUID.generate()

      Repo.insert!(%ChatThread{
        owner_id: owner_id,
        document_id: document_id,
        title: "Discussion",
        status: "active",
        messages: [
          %{
            "id" => "user-1",
            "role" => "user",
            "content" => "문서를 봐줘",
            "inserted_at" => "2026-05-26T00:00:00Z"
          },
          %{
            "id" => "tool-doc-get",
            "role" => "agent",
            "content" => "",
            "agent_run_id" => agent_run_id,
            "operation" => %{
              "id" => "tool-#{agent_run_id}-doc.get-1",
              "type" => "tool_call",
              "title" => "doc.get",
              "status" => "completed",
              "summary" => "Read document",
              "agent_run_id" => agent_run_id
            },
            "inserted_at" => "2026-05-26T00:00:01Z"
          },
          %{
            "id" => "reasoning-after-doc-get",
            "role" => "agent",
            "content" => "",
            "agent_run_id" => agent_run_id,
            "operation" => %{
              "id" => "reasoning-#{agent_run_id}",
              "type" => "reasoning",
              "title" => "Thinking",
              "status" => "completed",
              "summary" => "doc.get 결과를 검토함",
              "details" => %{"text" => "doc.get 결과를 검토함"},
              "agent_run_id" => agent_run_id
            },
            "inserted_at" => "2026-05-26T00:00:02Z"
          }
        ],
        last_message_at: DateTime.utc_now(:second)
      })

      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})
      state = %State{selected_document_id: document_id, mode: :editing}

      assert ["user-1", "tool-doc-get", "reasoning-after-doc-get"] =
               ChatThreads.list_visible_messages(ctx, state)
               |> Enum.map(& &1.id)
    end
  end

  describe "persist_user_message/2 grill seed" do
    test "persists with role `system` when payload[\"grill_seed\"] is true" do
      owner_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()

      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})

      command = %Command{
        kind: :chat_message,
        actor_type: :system,
        actor_id: nil,
        document_id: document_id,
        message: "GRILL_SEED: ...",
        payload: %{"grill_seed" => true}
      }

      assert {:ok, %ChatThread{} = thread, %Command{}, message} =
               ChatThreads.persist_user_message(ctx, command)

      assert message["role"] == "system"
      assert thread.messages == [message]

      # The visible rail must NOT include the system seed.
      state = %State{selected_document_id: document_id, mode: :editing}
      assert ChatThreads.list_visible_messages(ctx, state) == []
    end

    test "still persists with role `user` for normal chat commands" do
      owner_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()

      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})

      command = %Command{
        kind: :chat_message,
        actor_type: :user,
        actor_id: owner_id,
        document_id: document_id,
        message: "Hi",
        payload: %{}
      }

      assert {:ok, _thread, _command, message} = ChatThreads.persist_user_message(ctx, command)
      assert message["role"] == "user"
    end

    test "assistant reply appends a concise summary to the thread title" do
      owner_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()

      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})

      command = %Command{
        kind: :chat_message,
        actor_type: :user,
        actor_id: owner_id,
        document_id: document_id,
        message: "What changed?",
        payload: %{}
      }

      assert {:ok, %ChatThread{id: thread_id}, %Command{} = command, _message} =
               ChatThreads.persist_user_message(ctx, command)

      assert {:ok, %ChatThread{title: title}} =
               ChatThreads.append_assistant_message(
                 ctx,
                 command,
                 "검토 범위와 지급 조건을 먼저 확인해야 합니다.\n다음 질문을 드릴게요."
               )

      assert title == "Discussion - 검토 범위와 지급 조건을 먼저 확인해야 합니다."
      assert Repo.get!(ChatThread, thread_id).title == title
    end
  end

  describe "append_tool_call_message/2" do
    test "persists successful document tool calls as minimal document facts" do
      owner_id = Ecto.UUID.generate()

      {:ok, thread} =
        Repo.insert(%ChatThread{
          owner_id: owner_id,
          document_id: nil,
          title: "Discussion",
          status: "active",
          messages: [],
          last_message_at: DateTime.utc_now(:second)
        })

      assert {:ok, %ChatThread{} = updated} =
               ChatThreads.append_tool_call_message(thread.id, %{
                 "id" => "tool-doc-get-1",
                 "type" => "tool_call",
                 "name" => "doc.get",
                 "tool_name" => "doc.get",
                 "raw_name" => "doc.get",
                 "server_label" => "contract-doc",
                 "title" => "doc.get",
                 "status" => "completed",
                 "summary" => "rev 7",
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
               })

      assert [message] = updated.messages

      assert message["operation"] == %{
               "id" => "tool-doc-get-1",
               "name" => "doc.get",
               "output" => %{
                 "revision" => 7,
                 "d" => "NDA",
                 "t" => "service",
                 "counts" => %{"paragraphs" => 3}
               }
             }

      encoded = Jason.encode!(message["operation"])

      for forbidden <-
            ~w(ok change_id raw_name server_label status title summary reason tool_name type details arguments read) do
        refute encoded =~ forbidden
      end
    end

    test "persists failed tool calls as minimal name and error" do
      owner_id = Ecto.UUID.generate()

      {:ok, thread} =
        Repo.insert(%ChatThread{
          owner_id: owner_id,
          document_id: nil,
          title: "Discussion",
          status: "active",
          messages: [],
          last_message_at: DateTime.utc_now(:second)
        })

      assert {:ok, %ChatThread{} = updated} =
               ChatThreads.append_tool_call_message(thread.id, %{
                 "id" => "tool-doc-get-failed",
                 "type" => "tool_call",
                 "name" => "doc.get",
                 "tool_name" => "doc.get",
                 "raw_name" => "doc.get",
                 "server_label" => "contract-doc",
                 "title" => "doc.get",
                 "status" => "failed",
                 "summary" => "Failed Dependency",
                 "details" => %{
                   "arguments" => %{},
                   "output" => %{"error" => "projection unavailable"}
                 }
               })

      assert [message] = updated.messages

      assert message["operation"] == %{
               "id" => "tool-doc-get-failed",
               "name" => "doc.get",
               "error" => "projection unavailable"
             }

      encoded = Jason.encode!(message["operation"])

      for forbidden <-
            ~w(raw_name server_label status title summary reason tool_name type details arguments) do
        refute encoded =~ forbidden
      end
    end
  end

  describe "append_reasoning_message/2" do
    test "persists a reasoning operation row that rehydrates through the rail" do
      owner_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()

      {:ok, thread} =
        Repo.insert(%ChatThread{
          owner_id: owner_id,
          document_id: document_id,
          title: "Discussion",
          status: "active",
          messages: [],
          last_message_at: DateTime.utc_now(:second)
        })

      agent_run_id = Ecto.UUID.generate()

      assert {:ok, %ChatThread{} = updated} =
               ChatThreads.append_reasoning_message(thread.id, %{
                 agent_run_id: agent_run_id,
                 body: "First step\nSecond internal step"
               })

      assert [persisted] = updated.messages
      assert persisted["role"] == "agent"
      assert persisted["agent_run_id"] == agent_run_id
      operation = persisted["operation"]
      assert operation["type"] == "reasoning"
      assert operation["status"] == "completed"
      assert operation["id"] == "reasoning-#{agent_run_id}"
      assert operation["summary"] == "First step"
      assert operation["details"]["text"] == "First step\nSecond internal step"

      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})
      state = %State{selected_document_id: document_id, mode: :editing}

      assert [rehydrated] = ChatThreads.list_visible_messages(ctx, state)
      assert rehydrated.role == :agent
      # Rehydrated row carries the `operation` map, so the chat rail
      # renders it through `operation_block` (same path as tool_call).
      assert rehydrated.operation["type"] == "reasoning"
      assert rehydrated.operation["details"]["text"] == "First step\nSecond internal step"
    end

    test "skips empty / whitespace-only bodies" do
      owner_id = Ecto.UUID.generate()

      {:ok, thread} =
        Repo.insert(%ChatThread{
          owner_id: owner_id,
          document_id: nil,
          title: "Discussion",
          status: "active",
          messages: [],
          last_message_at: DateTime.utc_now(:second)
        })

      assert :ok =
               ChatThreads.append_reasoning_message(thread.id, %{
                 agent_run_id: Ecto.UUID.generate(),
                 body: ""
               })

      assert :ok =
               ChatThreads.append_reasoning_message(thread.id, %{
                 agent_run_id: Ecto.UUID.generate(),
                 body: "   \n  "
               })

      assert Repo.get!(ChatThread, thread.id).messages == []
    end

    test "skipped when chat_thread_id is nil (test/legacy path)" do
      assert :ok ==
               ChatThreads.append_reasoning_message(nil, %{
                 agent_run_id: Ecto.UUID.generate(),
                 body: "anything"
               })
    end
  end

  describe "concurrent append (race fix, #131)" do
    # Regression: agent stream + user submit could double-write the same
    # baseline `messages` value under read-modify-write, dropping a row.
    # The fix is a Postgres-native jsonb[] array_append at the DB level.
    # DataCase already puts the sandbox into `{:shared, self()}` because
    # this module is `async: false`, so child Tasks inherit the
    # connection without an extra checkout here.

    test "50 concurrent append_tool_call_message calls keep every payload" do
      owner_id = Ecto.UUID.generate()

      {:ok, thread} =
        Repo.insert(%ChatThread{
          owner_id: owner_id,
          document_id: nil,
          title: "race",
          status: "active",
          messages: [],
          last_message_at: DateTime.utc_now(:second)
        })

      payloads =
        for i <- 1..50 do
          %{
            "id" => Ecto.UUID.generate(),
            "type" => "tool_call",
            "name" => "tool_#{i}",
            "agent_run_id" => Ecto.UUID.generate(),
            "seq" => i
          }
        end

      payloads
      |> Task.async_stream(
        fn op -> ChatThreads.append_tool_call_message(thread.id, op) end,
        max_concurrency: 50,
        timeout: 15_000,
        ordered: false
      )
      |> Stream.run()

      reloaded = Repo.get!(ChatThread, thread.id)
      assert length(reloaded.messages) == 50

      stored_ids =
        reloaded.messages
        |> Enum.map(&(&1["operation"]["id"] || &1[:operation]["id"]))
        |> MapSet.new()

      expected_ids = payloads |> Enum.map(& &1["id"]) |> MapSet.new()
      assert MapSet.equal?(stored_ids, expected_ids)
    end

    test "persist_user_message + append_tool_call_message interleaved retain every row" do
      owner_id = Ecto.UUID.generate()
      document_id = Ecto.UUID.generate()
      ctx = Context.for_user(%Contract.Accounts.User{id: owner_id})

      # Seed the thread via a single persist_user_message so subsequent
      # append paths target the same row.
      seed_cmd = %Command{
        kind: :chat_message,
        actor_type: :user,
        actor_id: owner_id,
        document_id: document_id,
        message: "seed",
        payload: %{}
      }

      assert {:ok, %ChatThread{id: thread_id}, _, _} =
               ChatThreads.persist_user_message(ctx, seed_cmd)

      tasks =
        for i <- 1..25 do
          Task.async(fn ->
            user_cmd = %Command{
              kind: :chat_message,
              actor_type: :user,
              actor_id: owner_id,
              document_id: document_id,
              chat_thread_id: thread_id,
              message: "user_#{i}",
              payload: %{}
            }

            ChatThreads.persist_user_message(ctx, user_cmd)

            tool_op = %{
              "id" => Ecto.UUID.generate(),
              "type" => "tool_call",
              "name" => "tool_#{i}",
              "agent_run_id" => Ecto.UUID.generate()
            }

            ChatThreads.append_tool_call_message(thread_id, tool_op)
          end)
        end

      Enum.each(tasks, &Task.await(&1, 15_000))

      reloaded = Repo.get!(ChatThread, thread_id)
      # 1 seed + 25 user appends + 25 tool appends = 51
      assert length(reloaded.messages) == 51
    end
  end
end
