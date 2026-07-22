defmodule Ecrits.AcpAgent.SessionMemoryTest do
  @moduledoc """
  Regression test for cross-turn conversation memory.

  The bug: every turn created a brand-new ACP client/provider connection and then
  a brand-new provider session (`session/new` -> codex `thread/start` with no
  `threadId`), so the rail paid app-server/MCP startup every turn and risked
  losing conversation memory. The fix keeps the ACP client/session alive across
  compatible turns; when launch options change, it starts a fresh client and
  resumes the remembered provider session id (`session/load`).

  Driven through the real `ExMCP.ACP` stack via `EcritsWeb.FakeAcpAdapter`,
  which reports each `session/new` / `session/load` to `:test_pid` so we can
  assert the resume happened with the SAME provider session id rather than a
  fresh one being minted.
  """

  use ExUnit.Case, async: false

  alias Ecrits.AcpAgent.Session

  setup do
    id = "mem-test-" <> Ecto.UUID.generate()

    start_supervised!(
      {Session,
       id: id,
       ctx: nil,
       provider: %{id: "codex"},
       exmcp_adapter: EcritsWeb.FakeAcpAdapter,
       adapter_opts: [
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         test_pid: self(),
         report_session_lifecycle: true,
         report_prompts: true,
         script: [{:text_delta, "ok"}]
       ],
       workspace_root: File.cwd!(),
       mcp_servers: []}
    )

    :ok = Ecrits.AcpAgent.subscribe(id)
    {:ok, id: id}
  end

  test "compatible turn 2 reuses the live provider session instead of opening ACP again", %{
    id: id
  } do
    pid = Session.whereis(id)
    assert is_pid(pid)

    # ── Turn 1: a brand-new provider session is created ──────────────
    {:ok, %{id: turn1}} = Session.send_turn(pid, nil, "favorite color is teal")
    assert_receive {:fake_acp_session, :new, provider_id_1}, 2_000
    assert is_binary(provider_id_1) and provider_id_1 != ""
    assert_receive {:fake_acp_prompt, ^provider_id_1, _prompt1}, 2_000

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000

    # ── Turn 2: same launch options → no session/new or session/load at all ──
    {:ok, %{id: turn2}} = Session.send_turn(pid, nil, "what is my favorite color?")

    assert_receive {:fake_acp_prompt, ^provider_id_1, _prompt2}, 2_000
    refute_received {:fake_acp_session, _method, _provider_id}

    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn2}}, 2_000
  end

  test "launch option changes reopen ACP but resume the remembered provider session", %{id: id} do
    pid = Session.whereis(id)
    assert is_pid(pid)

    {:ok, %{id: turn1}} = Session.send_turn(pid, nil, "favorite color is teal")
    assert_receive {:fake_acp_session, :new, provider_id_1}, 2_000
    assert_receive {:fake_acp_prompt, ^provider_id_1, _prompt1}, 2_000
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn1}}, 2_000

    :ok = Session.update_options(pid, model: "changed-model")

    {:ok, %{id: turn2}} = Session.send_turn(pid, nil, "what is my favorite color?")

    assert_receive {:fake_acp_session, :load, provider_id_2}, 2_000
    assert provider_id_2 == provider_id_1
    assert_receive {:fake_acp_prompt, ^provider_id_1, _prompt2}, 2_000
    assert_receive {:agent_event, %{type: :turn_completed, turn_id: ^turn2}}, 2_000

    refute_received {:fake_acp_session, :new, _}
  end

  test "invalid persisted adapter options are not restored" do
    id = "invalid-restore-" <> Ecto.UUID.generate()

    pid =
      start_supervised!(
        {Session,
         id: id,
         ctx: nil,
         provider: %{id: "codex"},
         exmcp_adapter: EcritsWeb.FakeAcpAdapter,
         adapter_opts: [test_pid: self()],
         durable_restore: %{
           id: id,
           transcript: [],
           adapter_opts: %{"model" => %{"unexpected" => true}}
         },
         workspace_root: File.cwd!(),
         mcp_servers: []}
      )

    refute Keyword.has_key?(Session.agent_snapshot(pid).adapter_opts, :model)
  end
end
