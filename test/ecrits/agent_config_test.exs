defmodule Ecrits.AgentConfigTest do
  use ExUnit.Case, async: true

  alias Ecrits.AgentConfig
  alias Ecrits.AgentConfig.Access

  test "configuration transitions keep a validated embedded access policy" do
    config =
      AgentConfig.new(%{
        provider: %{key: "codex", label: "Codex", favicon_src: "/codex.svg"},
        model: "gpt-5.5",
        reasoning_effort: "high",
        access: Access.resolve("ask"),
        integrations: []
      })

    assert config.access.id == "ask"
    assert config.access.approval_policy == :on_write

    updated =
      AgentConfig.put(config, %{model: "gpt-5.4", access: Access.resolve("full-workspace")})

    assert updated.model == "gpt-5.4"
    assert updated.access.id == "full-workspace"
    assert updated.access.approval_policy == :never

    assert AgentConfig.put(updated, %{reasoning_effort: "invalid"}) == updated
  end

  # Board #459: the ACP write authorization reads these exact fields from the
  # turn opts. A Full-workspace config must emit BOTH redundant signals
  # (approval "never" + permission_mode "dontAsk") so losing one in transit
  # cannot silently downgrade the rail to write-refusing.
  test "session opts carry both full-workspace write signals end-to-end" do
    base = %{provider: %{key: "codex", label: "Codex", favicon_src: "/codex.svg"}}

    full = AgentConfig.new(Map.put(base, :access, Access.resolve("full-workspace")))
    opts = AgentConfig.session_opts(full)

    assert opts[:sandbox] == "workspace-write"
    assert opts[:approval_policy] == "never"
    assert opts[:permission_mode] == "dontAsk"
    assert Ecrits.AcpAgent.AcpStream.acp_write_authorized?(opts)

    ask = AgentConfig.new(Map.put(base, :access, Access.resolve("ask")))
    refute Ecrits.AcpAgent.AcpStream.acp_write_authorized?(AgentConfig.session_opts(ask))

    read_only = AgentConfig.new(Map.put(base, :access, Access.resolve("read-only")))
    refute Ecrits.AcpAgent.AcpStream.acp_write_authorized?(AgentConfig.session_opts(read_only))
  end
end
