defmodule Ecrits.Local.AcpAgent.ProviderStatusTest do
  use ExUnit.Case, async: false

  alias Ecrits.Local.AcpAgent

  setup do
    original_path = System.get_env("PATH")
    original_ui_config = Application.get_env(:ecrits, :local_agent_ui)

    Application.delete_env(:ecrits, :local_agent_ui)

    on_exit(fn ->
      if is_nil(original_path),
        do: System.delete_env("PATH"),
        else: System.put_env("PATH", original_path)

      if is_nil(original_ui_config) do
        Application.delete_env(:ecrits, :local_agent_ui)
      else
        Application.put_env(:ecrits, :local_agent_ui, original_ui_config)
      end
    end)
  end

  test "provider setup commands install the latest CLIs" do
    assert {:ok, codex} = AcpAgent.provider_setup("codex")
    assert codex.install_command == "curl -fsSL https://chatgpt.com/codex/install.sh | sh"

    assert {:ok, claude} = AcpAgent.provider_setup("claude")
    assert claude.install_command == "curl -fsSL https://claude.ai/install.sh | bash"
  end

  @tag :tmp_dir
  test "missing provider CLIs are marked install-required", %{tmp_dir: tmp_dir} do
    System.put_env("PATH", tmp_dir)

    assert [
             %{id: "codex", status: :missing, detail: "Install codex"},
             %{id: "claude", status: :missing, detail: "Install claude"}
           ] = AcpAgent.integration_options()
  end

  @tag :tmp_dir
  test "codex status output with an expired session is login-required", %{tmp_dir: tmp_dir} do
    put_fake_cli!(tmp_dir, "codex", """
    echo "Session expired. Please log in again."
    exit 0
    """)

    put_fake_cli!(tmp_dir, "claude", """
    printf '%s\\n' '{"loggedIn":true}'
    exit 0
    """)

    System.put_env("PATH", tmp_dir)

    assert [
             %{id: "codex", status: :login_required, detail: "Run codex login"},
             %{id: "claude", status: :ready}
           ] = AcpAgent.integration_options()
  end

  @tag :tmp_dir
  test "claude status output with an expired session is login-required", %{tmp_dir: tmp_dir} do
    put_fake_cli!(tmp_dir, "codex", """
    echo "Logged in with ChatGPT"
    exit 0
    """)

    put_fake_cli!(tmp_dir, "claude", """
    printf '%s\\n' '{"loggedIn":true,"expired":true}'
    exit 0
    """)

    System.put_env("PATH", tmp_dir)

    assert [
             %{id: "codex", status: :ready},
             %{id: "claude", status: :login_required, detail: "Run claude auth login"}
           ] = AcpAgent.integration_options()
  end

  defp put_fake_cli!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, ["#!/bin/sh\n", body])
    File.chmod!(path, 0o755)
    path
  end
end
