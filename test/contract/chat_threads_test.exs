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
