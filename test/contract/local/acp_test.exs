defmodule Contract.Local.ACPTest do
  use ExUnit.Case, async: false

  alias Contract.Context
  alias Contract.Local.ACP

  @ctx %Context{
    user: %Contract.Accounts.User{
      id: "00000000-0000-0000-0000-000000000295",
      email: "local-acp@example.test"
    }
  }

  test "application supervision starts the registered ACP GenServer" do
    assert Process.whereis(ACP) |> is_pid()
  end

  test "provider registry exposes real providers only" do
    providers = ACP.provider_metadata()

    assert Enum.map(providers, & &1.id) == ["codex", "claude", "external"]
    refute Enum.any?(providers, &(&1.id == "fake"))
  end

  test "provider public API recovers when registered ACP GenServer is stopped" do
    stop_registered_acp!()

    assert Process.whereis(ACP) == nil
    assert Enum.map(ACP.providers(), & &1.id) == ["codex", "claude", "external"]
    assert ACP.supported_provider_ids() == ["codex", "claude", "external"]
    assert ACP.default_provider_id() == "codex"

    assert {:error, {:unsupported_provider, "fake", ["codex", "claude", "external"]}} =
             ACP.fetch_provider("fake")

    assert {:error, {:unsupported_provider, "fake", ["codex", "claude", "external"]}} =
             ACP.start_session(@ctx, provider: "fake")
  end

  test "fake provider cannot start a public session" do
    assert {:error, {:unsupported_provider, "fake", ["codex", "claude", "external"]}} =
             ACP.start_session(@ctx, provider: "fake")
  end

  test "external provider fails turns with explicit unavailable error" do
    {:ok, session} = start_acp_session(provider: :external)

    :ok = ACP.subscribe(session.id)

    assert {:ok, %{id: turn_id}} = ACP.send_turn(@ctx, session.id, "hello")

    assert_receive {:local_agent_event,
                    %{
                      type: :turn_failed,
                      turn_id: ^turn_id,
                      reason: reason
                    }},
                   1_000

    assert reason =~ "provider_unavailable"
    assert reason =~ "external"
  end

  defp start_acp_session(opts) do
    id = Keyword.get(opts, :id, Ecto.UUID.generate())
    opts = Keyword.put_new(opts, :id, id)

    on_exit(fn ->
      case ACP.whereis(id) do
        pid when is_pid(pid) -> GenServer.stop(pid)
        nil -> :ok
      end
    end)

    ACP.start_session(@ctx, opts)
  end

  defp stop_registered_acp! do
    on_exit(&restart_registered_acp/0)

    case Process.whereis(ACP) do
      pid when is_pid(pid) ->
        assert :ok = Supervisor.terminate_child(Contract.Supervisor, ACP)

      nil ->
        :ok
    end
  end

  defp restart_registered_acp do
    case Process.whereis(ACP) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case Supervisor.restart_child(Contract.Supervisor, ACP) do
          {:ok, _pid} -> :ok
          {:ok, _pid, _info} -> :ok
          {:error, :running} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, _reason} -> :ok
        end
    end
  end
end
