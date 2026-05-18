defmodule Contract.ChatThreadsTest do
  use Contract.DataCase, async: true

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
end
