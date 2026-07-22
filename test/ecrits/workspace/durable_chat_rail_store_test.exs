defmodule Ecrits.Workspace.DurableChatRailStoreTest do
  use ExUnit.Case, async: false

  alias Ecrits.AcpAgent
  alias Ecrits.Workspace.Session
  alias Ecrits.WorkspaceHandoff

  @tag :edit_failure
  test "full owner restart restores two rails and an intentional deletion stays deleted" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-durable-chat-rails-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    store_path = Path.join(root, "handoff.json")
    File.mkdir_p!(workspace)
    previous_store = Application.fetch_env(:ecrits, :workspace_handoff_store_path)

    switch_handoff_store(store_path)

    on_exit(fn ->
      stop_workspace_owners(workspace)
      restore_handoff_store(previous_store)
      File.rm_rf(root)
    end)

    settings = [
      live_session_id: "durable-browser-session",
      chat_rail_id: "durable-browser-tab",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        test_pid: self(),
        model: "test-model",
        reasoning_effort: "high",
        sandbox: "read-only",
        permission_mode: "ask",
        approval_policy: "on-request",
        access_control: "read-only",
        script: [{:text_delta, "durable reply"}]
      ],
      workspace_root: workspace
    ]

    {:ok, first_ws} = Session.attach(workspace, settings)
    :ok = Session.subscribe_file_events(workspace)
    :ok = Session.subscribe_agent(first_ws.agent_id)

    {:ok, %{id: first_turn_id}} =
      AcpAgent.send_turn(nil, first_ws.agent_id, "first persisted prompt")

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^first_turn_id}}, 2_000
    assert_receive {:workspace_turn_finalized, %{turn_id: ^first_turn_id}}, 2_000
    assert :ok = AcpAgent.rename(first_ws.agent_id, "First persisted title")

    {:ok, second_ws} = Session.new_foreground(workspace, settings)
    :ok = Session.subscribe_agent(second_ws.agent_id)

    {:ok, %{id: second_turn_id}} =
      AcpAgent.send_turn(nil, second_ws.agent_id, "second persisted prompt")

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^second_turn_id}}, 2_000
    assert_receive {:workspace_turn_finalized, %{turn_id: ^second_turn_id}}, 2_000
    assert :ok = AcpAgent.rename(second_ws.agent_id, "Second persisted title")

    {:ok, selected_ws} = Session.select_foreground(workspace, first_ws.rail_key, settings)
    assert selected_ws.agent_id == first_ws.agent_id

    first_before = AcpAgent.durable_snapshot(first_ws.agent_id)
    second_before = AcpAgent.durable_snapshot(second_ws.agent_id)

    assert is_binary(first_before.provider_session_id)
    assert is_binary(second_before.provider_session_id)

    persisted_json = File.read!(store_path)
    assert store_path |> File.stat!() |> Map.fetch!(:mode) |> Bitwise.band(0o777) == 0o600
    refute persisted_json =~ ~s("exmcp_adapter":)
    refute persisted_json =~ ~s("test_pid":)
    refute persisted_json =~ ~s("script":)
    refute persisted_json =~ ~s("current_turn":)
    refute persisted_json =~ ~s("queue":)
    refute persisted_json =~ "#PID<"
    refute persisted_json =~ "#Reference<"
    refute persisted_json =~ ~s("__struct__":)

    stop_workspace_owners(workspace)
    restart_handoff_store()

    restored_settings =
      Keyword.update!(settings, :adapter_opts, fn opts ->
        opts
        |> Keyword.drop([:model, :reasoning_effort])
        |> Keyword.merge(
          sandbox: "workspace-write",
          permission_mode: "dontAsk",
          approval_policy: "never",
          access_control: "full-workspace"
        )
      end)

    {:ok, restored_ws} = Session.attach(workspace, restored_settings)
    assert restored_ws.rail_key == first_ws.rail_key
    assert restored_ws.agent_id == first_ws.agent_id

    assert [second_recent, first_recent] = Session.recent_foregrounds(restored_ws)
    assert second_recent.rail_key == second_ws.rail_key
    assert first_recent.rail_key == first_ws.rail_key
    assert first_recent.active?

    first_after = AcpAgent.durable_snapshot(first_ws.agent_id)
    second_after = AcpAgent.durable_snapshot(second_ws.agent_id)

    assert first_after.title == "First persisted title"
    assert second_after.title == "Second persisted title"
    assert first_after.title_user_edited?
    assert second_after.title_user_edited?
    assert [%{"user" => "first persisted prompt"}] = simplify_transcript(first_after.transcript)
    assert [%{"user" => "second persisted prompt"}] = simplify_transcript(second_after.transcript)
    assert first_after.provider_session_id == first_before.provider_session_id
    assert second_after.provider_session_id == second_before.provider_session_id
    refute first_after.instance_id == first_before.instance_id
    refute second_after.instance_id == second_before.instance_id
    assert first_after.adapter_opts["model"] == "test-model"
    assert first_after.adapter_opts["reasoning_effort"] == "high"
    assert first_after.adapter_opts["sandbox"] == "workspace-write"
    assert first_after.adapter_opts["permission_mode"] == "dontAsk"
    assert first_after.adapter_opts["approval_policy"] == "never"
    assert first_after.adapter_opts["access_control"] == "full-workspace"

    assert {:error, :stale_agent_instance} =
             WorkspaceHandoff.put_agent_state(workspace, first_ws.agent_id, first_before)

    assert {:error, :agent_id_mismatch} =
             WorkspaceHandoff.put_agent_state(
               workspace,
               first_ws.agent_id,
               Map.put(first_after, :id, "another-agent")
             )

    assert {:ok, rail_state} = WorkspaceHandoff.fetch_chat_rail_state(workspace)

    assert rail_state.foregrounds[first_ws.rail_key].agent_state.instance_id ==
             first_after.instance_id

    stop_workspace_owners(workspace)
    assert :ok = WorkspaceHandoff.delete_chat_rail(workspace, second_ws.rail_key)

    # A late write from the deleted agent is ignored instead of recreating it.
    assert :ok = WorkspaceHandoff.put_agent_state(workspace, second_ws.agent_id, second_after)
    restart_handoff_store()

    {:ok, final_ws} = Session.attach(workspace, settings)
    assert final_ws.rail_key == first_ws.rail_key
    assert Enum.map(Session.recent_foregrounds(final_ws), & &1.rail_key) == [first_ws.rail_key]
    assert AcpAgent.whereis(second_ws.agent_id) == nil

    final_json = File.read!(store_path)
    assert store_path |> File.stat!() |> Map.fetch!(:mode) |> Bitwise.band(0o777) == 0o600
    refute final_json =~ second_ws.rail_key
    refute final_json =~ second_ws.agent_id
  end

  # 2026-07-19 field bug (#464): a freshly revived instance snapshotted only
  # the rows it had seen and last-writer-wins erased the conversation history
  # ("he can't find the ruby shell cmd"). Durable transcripts must never
  # shrink through EITHER write path; an intentional new conversation resets
  # explicitly.
  test "durable transcripts merge instead of shrinking, and reset is explicit" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-durable-merge-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    store_path = Path.join(root, "handoff.json")
    File.mkdir_p!(workspace)
    previous_store = Application.fetch_env(:ecrits, :workspace_handoff_store_path)
    switch_handoff_store(store_path)

    on_exit(fn ->
      restore_handoff_store(previous_store)
      File.rm_rf(root)
    end)

    dialog = fn turn_id, user ->
      %{"turn_id" => turn_id, "user" => user, "agent" => "ok", "items" => []}
    end

    agent_state = fn instance, transcript ->
      %{
        id: "agent-merge",
        instance_id: instance,
        provider_session_id: "thread-1",
        title: "merge test",
        title_user_edited?: false,
        transcript: transcript,
        adapter_opts: %{}
      }
    end

    rail_state = fn meta ->
      %{
        foregrounds: %{"rail-merge" => meta},
        active_foregrounds: %{},
        foreground_order: ["rail-merge"]
      }
    end

    meta = fn agent ->
      %{agent_id: "agent-merge", provider: "codex", owner_session_id: "s1", agent_state: agent}
    end

    row_user = fn row ->
      cond do
        is_struct(row) -> row.user
        is_map(row) -> Map.get(row, "user") || Map.get(row, :user)
      end
    end

    full =
      agent_state.("i1", [dialog.("t1", "one"), dialog.("t2", "two"), dialog.("t3", "three")])

    assert :ok = WorkspaceHandoff.put_chat_rail_state(workspace, rail_state.(meta.(full)))

    # Same-instance snapshot with one (updated) row: rows t1/t2 survive.
    assert :ok =
             WorkspaceHandoff.put_agent_state(
               workspace,
               "agent-merge",
               agent_state.("i1", [dialog.("t3", "three-updated")])
             )

    assert {:ok, stored} = WorkspaceHandoff.fetch_chat_rail_state(workspace)
    transcript = stored.foregrounds["rail-merge"].agent_state.transcript
    assert Enum.map(transcript, row_user) == ["one", "two", "three-updated"]

    # Wholesale rail write from a NEW instance carrying one new row: nothing
    # shrinks, the new instance binds, the new row appends.
    successor = agent_state.("i2", [dialog.("t4", "four")])
    assert :ok = WorkspaceHandoff.put_chat_rail_state(workspace, rail_state.(meta.(successor)))

    assert {:ok, stored} = WorkspaceHandoff.fetch_chat_rail_state(workspace)
    transcript = stored.foregrounds["rail-merge"].agent_state.transcript
    assert Enum.map(transcript, row_user) == ["one", "two", "three-updated", "four"]
    assert stored.foregrounds["rail-merge"].agent_state.instance_id == "i2"

    # Explicit reset: the old conversation must NOT resurrect into the next write.
    assert :ok = WorkspaceHandoff.reset_agent_state(workspace, "agent-merge")
    assert {:ok, stored} = WorkspaceHandoff.fetch_chat_rail_state(workspace)
    assert stored.foregrounds["rail-merge"].agent_state == nil

    fresh = agent_state.("i3", [dialog.("t5", "fresh conversation")])
    assert :ok = WorkspaceHandoff.put_chat_rail_state(workspace, rail_state.(meta.(fresh)))
    assert {:ok, stored} = WorkspaceHandoff.fetch_chat_rail_state(workspace)
    transcript = stored.foregrounds["rail-merge"].agent_state.transcript
    assert Enum.map(transcript, row_user) == ["fresh conversation"]
  end

  test "durable tool payloads retain bounded head and tail context" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-durable-tool-payload-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    store_path = Path.join(root, "handoff.json")
    File.mkdir_p!(workspace)
    previous_store = Application.fetch_env(:ecrits, :workspace_handoff_store_path)
    switch_handoff_store(store_path)

    on_exit(fn ->
      restore_handoff_store(previous_store)
      File.rm_rf(root)
    end)

    input = "input-start\n" <> String.duplicate("i", 1_000_000) <> "\ninput-end"
    output = "output-start\n" <> String.duplicate("o", 1_000_000) <> "\noutput-end"

    agent_state = %{
      id: "agent-large-tool",
      instance_id: "instance-large-tool",
      provider_session_id: "thread-large-tool",
      title: "large tool payload",
      title_user_edited?: false,
      transcript: [
        %{
          turn_id: "turn-large-tool",
          user: "run it",
          agent: "done",
          items: [
            %{
              role: :tool,
              tool_call_id: "tool-large",
              name: "Bash",
              status: :completed,
              input: input,
              output: output,
              body: "Input:\n#{input}\n\nOutput:\n#{output}"
            }
          ]
        }
      ],
      adapter_opts: %{}
    }

    rail_state = %{
      foregrounds: %{
        "rail-large" => %{
          agent_id: agent_state.id,
          provider: "codex",
          owner_session_id: "session-large",
          agent_state: agent_state
        }
      },
      active_foregrounds: %{},
      foreground_order: ["rail-large"]
    }

    assert :ok = WorkspaceHandoff.put_chat_rail_state(workspace, rail_state)

    assert {:ok, live_state} = WorkspaceHandoff.fetch_chat_rail_state(workspace)
    [live_dialog] = live_state.foregrounds["rail-large"].agent_state.transcript
    [live_tool] = live_dialog.items
    assert live_tool.input =~ "input-start"
    assert live_tool.input =~ "input-end"
    assert live_tool.input =~ "bytes omitted from durable history"
    assert live_tool.output =~ "output-start"
    assert live_tool.output =~ "output-end"
    assert live_tool.output =~ "bytes omitted from durable history"
    assert live_tool.body == nil

    assert File.stat!(store_path).size < 100_000

    restart_handoff_store()
    assert {:ok, restored_state} = WorkspaceHandoff.fetch_chat_rail_state(workspace)

    [restored_dialog] = restored_state.foregrounds["rail-large"].agent_state.transcript

    [restored_tool] = restored_dialog.items
    assert restored_tool.input =~ "input-start"
    assert restored_tool.input =~ "input-end"
    assert restored_tool.input =~ "bytes omitted from durable history"
    assert restored_tool.output =~ "output-start"
    assert restored_tool.output =~ "output-end"
    assert restored_tool.output =~ "bytes omitted from durable history"
    assert restored_tool.body == nil
  end

  @tag :edit_failure
  test "failed provider replacement preserves the durable rail for a later retry" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-durable-restart-failure-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    store_path = Path.join(root, "handoff.json")
    File.mkdir_p!(workspace)
    previous_store = Application.fetch_env(:ecrits, :workspace_handoff_store_path)
    switch_handoff_store(store_path)

    on_exit(fn ->
      stop_workspace_owners(workspace)
      restore_handoff_store(previous_store)
      File.rm_rf(root)
    end)

    settings = [
      live_session_id: "restart-failure-browser-session",
      chat_rail_id: "restart-failure-browser-tab",
      provider: "codex",
      adapter_opts: [
        exmcp_adapter: EcritsWeb.FakeAcpAdapter,
        test_pid: self(),
        script: [{:text_delta, "kept reply"}]
      ],
      workspace_root: workspace
    ]

    {:ok, ws} = Session.attach(workspace, settings)
    :ok = Session.subscribe_file_events(workspace)
    :ok = Session.subscribe_agent(ws.agent_id)
    {:ok, %{id: turn_id}} = AcpAgent.send_turn(nil, ws.agent_id, "keep this history")
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn_id}}, 2_000
    assert_receive {:workspace_turn_finalized, %{turn_id: ^turn_id}}, 2_000
    assert :ok = AcpAgent.rename(ws.agent_id, "History that must survive")

    before_failure = File.read!(store_path)
    assert before_failure =~ "History that must survive"

    bad_settings = Keyword.put(settings, :provider, "missing-provider")

    assert {:error, {:unsupported_provider, "missing-provider", ["codex", "claude"]}} =
             Session.restart_foreground(workspace, bad_settings)

    assert File.read!(store_path) == before_failure

    stop_workspace_owners(workspace)
    restart_handoff_store()

    {:ok, restored_ws} = Session.attach(workspace, settings)
    assert restored_ws.rail_key == ws.rail_key
    assert restored_ws.agent_id == ws.agent_id
    assert AcpAgent.durable_snapshot(ws.agent_id).title == "History that must survive"

    assert [%{"user" => "keep this history"}] =
             ws.agent_id
             |> AcpAgent.durable_snapshot()
             |> Map.fetch!(:transcript)
             |> simplify_transcript()
  end

  @tag :edit_failure
  test "a hot-reloaded callback migrates the legacy handoff map without crashing" do
    root =
      Path.join(
        System.tmp_dir!(),
        "ecrits-handoff-hot-reload-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    store_path = Path.join(root, "handoff.json")
    File.mkdir_p!(workspace)
    previous_store = Application.fetch_env(:ecrits, :workspace_handoff_store_path)
    Application.put_env(:ecrits, :workspace_handoff_store_path, store_path)

    on_exit(fn ->
      case previous_store do
        {:ok, path} -> Application.put_env(:ecrits, :workspace_handoff_store_path, path)
        :error -> Application.delete_env(:ecrits, :workspace_handoff_store_path)
      end

      File.rm_rf(root)
    end)

    pid = start_supervised!({WorkspaceHandoff, name: nil, store_path: store_path})
    live_session_id = "legacy-live-session"
    rail_key = "tab-legacy"
    agent_id = "fg-legacy"

    legacy = %{
      live_session_id => workspace,
      {:chat_rails, workspace} => %{
        foregrounds: %{
          rail_key => %{
            agent_id: agent_id,
            provider: "codex",
            owner_session_id: live_session_id
          }
        },
        active_foregrounds: %{rail_key => rail_key},
        foreground_order: [rail_key]
      }
    }

    :sys.replace_state(pid, fn _current -> legacy end)

    assert {:ok, ^workspace} =
             GenServer.call(pid, {:fetch_workspace_path, live_session_id})

    assert {:ok, rail_state} =
             GenServer.call(pid, {:fetch_chat_rail_state, Path.expand(workspace)})

    assert rail_state.foregrounds[rail_key].agent_id == agent_id
    assert Process.alive?(pid)
    assert Jason.decode!(File.read!(store_path))["version"] == 1
  end

  defp simplify_transcript(transcript) do
    Enum.map(transcript, fn dialog ->
      %{"user" => Map.get(dialog, :user, Map.get(dialog, "user"))}
    end)
  end

  defp stop_workspace_owners(workspace) do
    agent_ids =
      case Session.whereis(workspace) do
        pid when is_pid(pid) ->
          state = :sys.get_state(pid)
          ids = Enum.map(state.foregrounds, fn {_rail, meta} -> meta.agent_id end)
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)
          assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
          ids

        nil ->
          []
      end

    agent_ids
    |> Enum.uniq()
    |> Enum.each(fn id ->
      case AcpAgent.whereis(id) do
        pid when is_pid(pid) ->
          ref = Process.monitor(pid)
          assert :ok = AcpAgent.close(id)
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
          await_agent_unregistered(id)

        nil ->
          :ok
      end
    end)
  end

  defp await_agent_unregistered(id, attempts \\ 100)

  defp await_agent_unregistered(id, attempts) when attempts > 0 do
    case AcpAgent.whereis(id) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          flunk("agent #{id} restarted unexpectedly as #{inspect(pid)}")
        else
          receive do
          after
            1 -> await_agent_unregistered(id, attempts - 1)
          end
        end
    end
  end

  defp await_agent_unregistered(id, 0), do: flunk("agent #{id} stayed registered after stop")

  defp switch_handoff_store(store_path) do
    Application.put_env(:ecrits, :workspace_handoff_store_path, store_path)
    restart_handoff_store()
  end

  defp restore_handoff_store({:ok, store_path}) do
    Application.put_env(:ecrits, :workspace_handoff_store_path, store_path)
    restart_handoff_store()
  end

  defp restore_handoff_store(:error) do
    Application.delete_env(:ecrits, :workspace_handoff_store_path)
    restart_handoff_store()
  end

  defp restart_handoff_store do
    assert :ok = Supervisor.terminate_child(Ecrits.Supervisor, Ecrits.WorkspaceHandoff)

    case Supervisor.restart_child(Ecrits.Supervisor, Ecrits.WorkspaceHandoff) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      other -> flunk("could not restart workspace handoff: #{inspect(other)}")
    end

    case Application.get_env(:ecrits, :workspace_handoff_store_path) do
      path when is_binary(path) -> assert WorkspaceHandoff.store_path() == path
      nil -> assert is_binary(WorkspaceHandoff.store_path())
    end
  end
end
