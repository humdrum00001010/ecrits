defmodule Ecrits.AgentConfigTest do
  use ExUnit.Case, async: true

  alias Ecrits.AgentConfig
  alias Ecrits.AgentConfig.Access
  alias Ecrits.AgentConfig.ModelCatalog

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

  test "session opts carry the validated rail access mode end-to-end" do
    base = %{provider: %{key: "codex", label: "Codex", favicon_src: "/codex.svg"}}

    full = AgentConfig.new(Map.put(base, :access, Access.resolve("full-workspace")))
    opts = AgentConfig.session_opts(full)

    assert opts[:sandbox] == "workspace-write"
    assert opts[:approval_policy] == "never"
    assert opts[:permission_mode] == "dontAsk"
    assert opts[:access_control] == "full-workspace"

    adapter_opts = AgentConfig.adapter_opts(full, "/workspace")
    assert adapter_opts[:access_control] == "full-workspace"
    assert adapter_opts[:sandbox] == "workspace-write"

    ask = AgentConfig.new(Map.put(base, :access, Access.resolve("ask")))
    assert AgentConfig.session_opts(ask)[:access_control] == "ask"

    read_only = AgentConfig.new(Map.put(base, :access, Access.resolve("read-only")))
    assert AgentConfig.session_opts(read_only)[:access_control] == "read-only"
  end

  test "Codex catalog matches the visible 0.144.6 runtime catalog" do
    assert Enum.map(ModelCatalog.for_provider("codex"), &{&1.id, &1.label}) == [
             {"gpt-5.6-sol", "GPT-5.6-Sol"},
             {"gpt-5.6-terra", "GPT-5.6-Terra"},
             {"gpt-5.6-luna", "GPT-5.6-Luna"},
             {"gpt-5.5", "GPT-5.5"},
             {"gpt-5.3-codex-spark", "GPT-5.3-Codex-Spark"}
           ]
  end

  test "Claude catalog matches the control protocol model options" do
    assert Enum.map(ModelCatalog.for_provider("claude"), &{&1.id, &1.label}) == [
             {"default", "Default"},
             {"sonnet", "Sonnet"},
             {"opus", "Opus"}
           ]
  end
end
