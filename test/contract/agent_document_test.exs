defmodule Contract.Agent.DocumentTest do
  use Contract.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Contract.Agent.Document
  alias Contract.Agent.Run
  alias Contract.Command
  alias Contract.Context
  alias Contract.Runtime

  setup :set_mox_from_context
  setup :verify_on_exit!

  @ctx %Context{
    user: %Contract.Accounts.User{
      id: "00000000-0000-0000-0000-000000000180",
      email: "agent-document@example.test"
    }
  }

  describe "Runtime.apply/2 -> :chat_message" do
    test "persists the user message and admits the run through the document boundary" do
      parent = self()

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts ->
        {:ok, %{stream: blocking_stream(parent, ["received"]), task_pid: self()}}
      end)

      document_id = Ecto.UUID.generate()

      action = %Command{
        kind: :chat_message,
        document_id: document_id,
        actor_type: :user,
        message: "요약해줘",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, %Run{} = run} = Runtime.apply(@ctx, action)
      assert run.document_id == document_id
      assert run.owner_id == @ctx.user.id
      assert run.chat_thread_id

      assert {:ok, status} = Document.status(@ctx, document_id)
      assert status.document_id == document_id
      assert status.alive? == true
      assert status.current_attempt.id == run.id
      assert status.queue == []

      assert_receive {:agent_stream_started, stream_pid}, 2_000
      send(stream_pid, :release_stream)
      assert_receive {:agent_completed, run_id, %Command{message: "received"}}, 2_000
      assert run_id == run.id

      assert {:ok, status} = Document.status(@ctx, document_id)
      assert status.current_attempt == nil
      assert status.queue == []
    end

    test "response.failed stream failure completes the attempt instead of stranding it as working" do
      parent = self()

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts ->
        {:ok,
         %{
           stream:
             blocking_stream(parent, [
               %{
                 type: "response.failed",
                 data: %{
                   "response" => %{
                     "error" => %{"message" => "MCP connector failed", "code" => "mcp_error"}
                   }
                 }
               }
             ]),
           task_pid: self()
         }}
      end)

      document_id = Ecto.UUID.generate()

      action = %Command{
        kind: :chat_message,
        document_id: document_id,
        actor_type: :user,
        message: "계약명을 바꿔줘",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, %Run{} = run} = Runtime.apply(@ctx, action)
      assert_receive {:agent_stream_started, stream_pid}, 2_000
      send(stream_pid, :release_stream)

      assert_receive {:tool_call_failed, run_id, _tool_id, %{"status" => "failed"}}, 2_000
      assert run_id == run.id
      assert_receive {:agent_completed, ^run_id, %Command{message: message}}, 2_000
      assert message =~ "AI 응답 실패"

      assert {:ok, status} = Document.status(@ctx, document_id)
      assert status.current_attempt == nil
      assert status.queue == []
      assert Document.whereis(run.id) == nil
    end

    test "suspend cancels the current attempt while leaving document liveness visible" do
      parent = self()

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts ->
        {:ok, %{stream: blocking_stream(parent, ["late"]), task_pid: self()}}
      end)

      document_id = Ecto.UUID.generate()

      action = %Command{
        kind: :chat_message,
        document_id: document_id,
        actor_type: :user,
        message: "기다려",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, %Run{} = run} = Runtime.apply(@ctx, action)
      assert_receive {:agent_stream_started, _stream_pid}, 2_000

      assert {:ok, suspended} = Document.suspend(@ctx, document_id)
      assert suspended.id == run.id
      assert suspended.status == :cancelled

      assert {:ok, status} = Document.status(@ctx, document_id)
      assert status.alive? == true
      assert status.current_attempt == nil
      assert status.queue == []
    end

    test "cancel rejects a run owned by a different user scope" do
      parent = self()

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts ->
        {:ok, %{stream: blocking_stream(parent, ["still running"]), task_pid: self()}}
      end)

      document_id = Ecto.UUID.generate()

      action = %Command{
        kind: :chat_message,
        document_id: document_id,
        actor_type: :user,
        message: "취소 권한 확인",
        payload: %{"test_pid" => self()}
      }

      other_ctx = %Context{
        user: %Contract.Accounts.User{
          id: "00000000-0000-0000-0000-000000000181",
          email: "other-agent-document@example.test"
        }
      }

      assert {:ok, %Run{} = run} = Runtime.apply(@ctx, action)
      assert_receive {:agent_stream_started, stream_pid}, 2_000

      assert {:error, :forbidden} = Document.cancel(other_ctx, run.id)

      assert {:ok, status} = Document.status(@ctx, document_id)
      assert status.current_attempt.id == run.id
      assert Document.whereis(run.id)

      run_id = run.id
      send(stream_pid, :release_stream)
      assert_receive {:agent_completed, ^run_id, %Command{message: "still running"}}, 2_000
    end

    test "queued attempts are status-visible and suspend promotes the next attempt" do
      parent = self()

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts ->
        {:ok, %{stream: blocking_stream(parent, ["first"]), task_pid: self()}}
      end)
      |> expect(:stream_chat, fn _params, _opts ->
        {:ok, %{stream: blocking_stream(parent, ["second"]), task_pid: self()}}
      end)

      document_id = Ecto.UUID.generate()

      first_action = %Command{
        kind: :chat_message,
        document_id: document_id,
        actor_type: :user,
        message: "첫 번째",
        payload: %{"test_pid" => self()}
      }

      second_action = %Command{
        kind: :chat_message,
        document_id: document_id,
        actor_type: :user,
        message: "두 번째",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, %Run{} = first_run} = Runtime.apply(@ctx, first_action)
      assert_receive {:agent_stream_started, first_stream_pid}, 2_000

      assert {:ok, %Run{} = second_run} = Runtime.apply(@ctx, second_action)
      assert second_run.status == :pending

      assert {:ok, status} = Document.status(@ctx, document_id)
      assert status.current_attempt.id == first_run.id
      assert [%Run{id: queued_id, status: :pending}] = status.queue
      assert queued_id == second_run.id

      pid = Document.whereis(first_run.id)
      assert is_pid(pid)
      assert Document.whereis(second_run.id) == pid
      assert Document.whereis_for_scope(@ctx.user.id, document_id) == {first_run.id, pid}

      assert {:ok, %{run_id: active_run_id, run: %Run{id: active_run_id}, pid: ^pid}} =
               Document.active_attempt(@ctx.user.id, document_id)

      assert active_run_id == first_run.id

      assert {:ok, suspended} = Document.suspend(@ctx, document_id)
      assert suspended.id == first_run.id
      assert suspended.status == :cancelled

      assert_receive {:agent_stream_started, second_stream_pid}, 2_000
      assert second_stream_pid != first_stream_pid

      assert {:ok, status} = Document.status(@ctx, document_id)
      assert status.current_attempt.id == second_run.id
      assert status.queue == []

      send(second_stream_pid, :release_stream)
      assert_receive {:agent_completed, run_id, %Command{message: "second"}}, 2_000
      assert run_id == second_run.id
    end

    test "stream task crash fails the current run and promotes the queued attempt" do
      parent = self()

      Contract.IO.OpenAIMock
      |> expect(:stream_chat, fn _params, _opts ->
        send(parent, {:stream_boot_ready, self()})

        receive do
          :crash_before_stream_error -> raise "stream boot crash"
        end
      end)
      |> expect(:stream_chat, fn _params, _opts ->
        {:ok, %{stream: blocking_stream(parent, ["second"]), task_pid: self()}}
      end)

      document_id = Ecto.UUID.generate()

      first_action = %Command{
        kind: :chat_message,
        document_id: document_id,
        actor_type: :user,
        message: "첫 번째",
        payload: %{"test_pid" => self()}
      }

      second_action = %Command{
        kind: :chat_message,
        document_id: document_id,
        actor_type: :user,
        message: "두 번째",
        payload: %{"test_pid" => self()}
      }

      assert {:ok, %Run{} = first_run} = Runtime.apply(@ctx, first_action)
      assert_receive {:stream_boot_ready, stream_task_pid}, 2_000

      assert {:ok, %Run{} = second_run} = Runtime.apply(@ctx, second_action)
      assert second_run.status == :pending

      log =
        capture_log(fn ->
          send(stream_task_pid, :crash_before_stream_error)

          assert_receive {:agent_failed, run_id, {:exception, "stream boot crash"}}, 2_000
          assert run_id == first_run.id
          assert_receive {:agent_stream_started, second_stream_pid}, 2_000
          send(parent, {:second_stream_pid, second_stream_pid})
        end)

      assert log =~ "stream boot crash"

      assert Document.whereis(first_run.id) == nil
      assert Document.whereis(second_run.id)

      assert {:ok, status} = Document.status(@ctx, document_id)
      assert status.current_attempt.id == second_run.id
      assert status.queue == []

      assert_receive {:second_stream_pid, second_stream_pid}, 2_000
      send(second_stream_pid, :release_stream)
      assert_receive {:agent_completed, run_id, %Command{message: "second"}}, 2_000
      assert run_id == second_run.id
    end
  end

  defp build_stream(chunks) do
    Enum.map(chunks, fn chunk ->
      if is_map(chunk) do
        chunk
      else
        %{
          type: "response.output_text.delta",
          data: %{"type" => "response.output_text.delta", "delta" => chunk}
        }
      end
    end)
  end

  defp blocking_stream(parent, chunks) do
    Stream.resource(
      fn -> :waiting end,
      fn
        :waiting ->
          send(parent, {:agent_stream_started, self()})

          receive do
            :release_stream -> {build_stream(chunks), :done}
          after
            5_000 -> {[], :done}
          end

        :done ->
          {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end
end
