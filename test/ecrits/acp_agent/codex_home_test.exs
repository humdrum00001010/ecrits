defmodule Ecrits.AcpAgent.CodexHomeTest do
  use ExUnit.Case, async: true

  alias Ecrits.AcpAgent.CodexHome
  alias ExMCP.ACP.AdapterBridge
  alias ExMCP.ACP.Adapters.Codex

  setup do
    root =
      Path.join(System.tmp_dir!(), "ecrits-codex-home-test-#{System.unique_integer([:positive])}")

    auth_source = Path.join(root, "source-auth.json")
    :ok = File.mkdir_p(root)
    :ok = File.write(auth_source, ~s({"auth_mode":"test"}))

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, auth_source: auth_source}
  end

  test "creates a private home with auth and a workspace profile that denies the global home", %{
    root: root,
    auth_source: auth_source
  } do
    global_home = Path.join(root, "personal-codex")

    assert {:ok, isolation} =
             CodexHome.prepare(
               root: Path.join(root, "homes"),
               auth_source: auth_source,
               global_home: global_home
             )

    assert File.read!(Path.join(isolation.home, "auth.json")) == ~s({"auth_mode":"test"})
    assert config = File.read!(Path.join(isolation.home, "config.toml"))
    assert config =~ "default_permissions = \"ecrits_workspace\""
    assert config =~ "[features]"
    assert config =~ "apps = false"
    assert config =~ "plugins = false"
    assert config =~ "remote_plugin = false"
    refute config =~ "shell_tool = false"
    assert config =~ "[permissions.ecrits_workspace]"
    assert config =~ "extends = \":workspace\""
    refute File.exists?(Path.join(isolation.home, "AGENTS.md"))
    assert config =~ ~s(\"#{Path.expand(global_home)}\" = \"deny\")
    assert {"CODEX_HOME", isolation.home} in isolation.env
    assert {"PATH", agent_path} = Enum.find(isolation.env, &(elem(&1, 0) == "PATH"))
    refute agent_path =~ "/bun-node-"
    assert isolation.permission_profile == "ecrits_workspace"

    opts = CodexHome.adapter_opts(isolation)
    assert opts[:env] == isolation.env
    assert opts[:use_permission_profile]
    assert opts[:expected_permission_profile] == "ecrits_workspace"
    assert is_function(opts[:on_terminate], 0)

    assert :ok = CodexHome.cleanup(isolation)
    refute File.exists?(isolation.home)
  end

  # Codex persists thread rollouts inside CODEX_HOME. A conversation-keyed
  # home therefore has to be deterministic AND survive adapter teardown —
  # per-session random homes were exactly why thread/resume silently lost the
  # agent's memory after a session restart (2026-07-19 "session's gone").
  test "a conversation-keyed home is stable across prepares and survives teardown", %{
    root: root,
    auth_source: auth_source
  } do
    opts = [
      root: Path.join(root, "homes"),
      auth_source: auth_source,
      workspace_root: Path.join(root, "ws"),
      document_lane?: true,
      path: "/opt/toolchain/bin",
      user_home: "/Users/someone",
      conversation_id: "rail-conv-1"
    ]

    assert {:ok, first} = CodexHome.prepare(opts)
    refute first.ephemeral?

    # Simulate a surviving thread rollout, then a session restart re-preparing
    # the same conversation: same home, rollout intact, config rewritten.
    rollout = Path.join(first.home, "sessions/rollout-1.jsonl")
    :ok = File.mkdir_p(Path.dirname(rollout))
    :ok = File.write(rollout, "thread history")

    assert {:ok, second} = CodexHome.prepare(opts)
    assert second.home == first.home
    assert File.read!(rollout) == "thread history"
    assert File.read!(Path.join(second.home, "config.toml")) =~ "/Library/Ruby/**"

    # Adapter teardown must NOT delete a conversation home...
    on_terminate = CodexHome.adapter_opts(second)[:on_terminate]
    _ = on_terminate.()
    assert File.exists?(rollout)

    # ...while a different conversation gets its own home and an ephemeral
    # prepare still cleans up on teardown.
    assert {:ok, other} = CodexHome.prepare(Keyword.put(opts, :conversation_id, "rail-conv-2"))
    refute other.home == first.home

    assert {:ok, ephemeral} = CodexHome.prepare(Keyword.delete(opts, :conversation_id))
    assert ephemeral.ephemeral?
    _ = CodexHome.adapter_opts(ephemeral)[:on_terminate].()
    refute File.exists?(ephemeral.home)
  end

  test "removes the Bun node compatibility shim from ACP PATH", %{
    root: root,
    auth_source: auth_source
  } do
    assert {:ok, isolation} =
             CodexHome.prepare(
               root: Path.join(root, "homes"),
               auth_source: auth_source,
               path:
                 "/opt/tools/bun-node-legitimate:/usr/bin:/private/tmp/bun-node-probe:/private/var/folders/zz/T/bun-node-darwin:/opt/homebrew/bin",
               node: "/private/tmp/bun-node-probe/node"
             )

    assert {"PATH", "/opt/tools/bun-node-legitimate:/usr/bin:/opt/homebrew/bin"} in isolation.env
    assert {"NODE", false} in isolation.env
  end

  test "the ACP adapter child receives the safe PATH and observes failed node renames", %{
    root: root,
    auth_source: auth_source
  } do
    if node = non_bun_node() do
      shim = "/private/tmp/bun-node-false-success"
      safe_segments = Enum.uniq([Path.dirname(node), "/usr/bin", "/bin"])
      source = Path.join(root, "missing-source")
      target = Path.join(root, "missing-target")
      proof = Path.join(root, "adapter-child-proof.json")
      script = Path.join(root, "adapter-child-proof.js")

      File.write!(script, """
      const fs = require("fs");
      const {spawnSync} = require("child_process");
      const [proof, source, target] = process.argv.slice(2);
      const code = `require("fs").renameSync(${JSON.stringify(source)}, ${JSON.stringify(target)})`;
      const result = spawnSync("node", ["-e", code], {encoding: "utf8"});
      fs.writeFileSync(proof, JSON.stringify({path: process.env.PATH, node: process.env.NODE || null, status: result.status, stderr: result.stderr}));
      """)

      assert {:ok, isolation} =
               CodexHome.prepare(
                 root: Path.join(root, "homes"),
                 auth_source: auth_source,
                 path: Enum.join([shim | safe_segments], ":"),
                 node: Path.join(shim, "node")
               )

      bridge =
        start_supervised!({
          AdapterBridge,
          adapter: Codex,
          adapter_opts:
            CodexHome.adapter_opts(isolation) ++
              [command_wrapper: {node, [script, proof, source, target]}]
        })

      assert {:error, reason} = AdapterBridge.receive_message(bridge, 5_000)
      assert reason in [:port_exited, :port_closed]

      assert %{"path" => child_path, "node" => nil, "status" => 1, "stderr" => stderr} =
               proof |> File.read!() |> Jason.decode!()

      assert child_path == Enum.join(safe_segments, ":")
      refute child_path =~ "bun-node-"
      assert stderr =~ "ENOENT"
    else
      IO.puts("\n[skip] system Node unavailable; skipping ACP adapter PATH integration")
    end
  end

  test "selects the read-only native permission profile", %{
    root: root,
    auth_source: auth_source
  } do
    assert {:ok, isolation} =
             CodexHome.prepare(
               root: Path.join(root, "homes"),
               auth_source: auth_source,
               sandbox: "read-only"
             )

    assert isolation.permission_profile == "ecrits_read_only"

    assert File.read!(Path.join(isolation.home, "config.toml")) =~
             "default_permissions = \"ecrits_read_only\""

    assert :ok = CodexHome.cleanup(isolation)
  end

  test "document mode gives shell read-only workspace search while ACP owns writes", %{
    root: root,
    auth_source: auth_source
  } do
    workspace_root = Path.join(root, "contract-workspace")
    global_home = Path.join(root, "personal-codex")

    assert {:ok, isolation} =
             CodexHome.prepare(
               root: Path.join(root, "homes"),
               auth_source: auth_source,
               global_home: global_home,
               workspace_root: workspace_root,
               document_lane?: true,
               path: "/opt/toolchain/bin",
               user_home: "/Users/someone"
             )

    config = File.read!(Path.join(isolation.home, "config.toml"))

    assert isolation.permission_profile == "ecrits_document_workspace"
    assert config =~ "default_permissions = \"ecrits_document_workspace\""
    assert config =~ "shell_tool = true"
    refute config =~ "shell_tool = false"

    assert config =~ """
           [permissions.ecrits_document_workspace.filesystem]
           ":minimal" = "read"
           "/opt/toolchain/**" = "read"
           "/Library/Ruby/**" = "read"
           "/Library/Perl/**" = "read"
           "/Library/Python/**" = "read"
           "/Library/Java/**" = "read"
           "/Library/Frameworks/**" = "read"
           "/Users/someone/.gem/**" = "read"
           "/Users/someone/Library/Python/**" = "read"
           "#{Path.expand(workspace_root)}" = "read"
           "#{Path.expand(workspace_root)}/**" = "read"
           "#{Path.expand(isolation.home)}/**" = "deny"
           "#{Path.expand(global_home)}/**" = "deny"
           """

    refute config =~
             ~s([permissions.ecrits_document_workspace]\nextends = ":read-only")

    # Standing familiarity: the isolated home carries the document playbook so
    # the model does not re-derive the surface's shape every turn.
    playbook = File.read!(Path.join(isolation.home, "AGENTS.md"))
    assert playbook =~ "one paragraph group per line"
    assert playbook =~ "compare-and-swap"
    assert playbook =~ "one read, one write"
    assert playbook =~ "occurrence"

    # New paragraphs are an ordinary mounted-file write (a new line holding one
    # bare paragraph node) — the playbook must teach that shape and must not
    # route paragraphs through the doc.edit fallback (2026-07-19 direction:
    # "inserting para is done simply with ACP not mcp tools").
    assert playbook =~ ~s([{"type":"paragraph","text":"..."}])
    assert playbook =~ "Never tell the user a"
    refute playbook =~ ~s(doc.edit {op: "insert_paragraph")
  end

  test "read-only document mode selects its document-specific profile", %{
    root: root,
    auth_source: auth_source
  } do
    assert {:ok, isolation} =
             CodexHome.prepare(
               root: Path.join(root, "homes"),
               auth_source: auth_source,
               workspace_root: Path.join(root, "contract-workspace"),
               document_lane?: true,
               sandbox: "read-only",
               path: "/opt/toolchain/bin",
               user_home: "/Users/someone"
             )

    assert isolation.permission_profile == "ecrits_document_read_only"

    config = File.read!(Path.join(isolation.home, "config.toml"))
    assert config =~ "shell_tool = true"

    assert config =~ """
           [permissions.ecrits_document_read_only.filesystem]
           ":minimal" = "read"
           "/opt/toolchain/**" = "read"
           "/Library/Ruby/**" = "read"
           "/Library/Perl/**" = "read"
           "/Library/Python/**" = "read"
           "/Library/Java/**" = "read"
           "/Library/Frameworks/**" = "read"
           "/Users/someone/.gem/**" = "read"
           "/Users/someone/Library/Python/**" = "read"
           "#{Path.expand(Path.join(root, "contract-workspace"))}" = "read"
           "#{Path.expand(Path.join(root, "contract-workspace"))}/**" = "read"
           "#{Path.expand(isolation.home)}/**" = "deny"
           """

    refute config =~
             ~s([permissions.ecrits_document_read_only]\nextends = ":read-only")
  end

  test "document shell can search only its workspace and cannot mutate or read secrets", %{
    auth_source: auth_source
  } do
    codex = System.find_executable("codex") || flunk("Codex CLI is required for sandbox proof")

    root =
      Path.join([
        File.cwd!(),
        "tmp",
        "codex-shell-policy-test-#{System.unique_integer([:positive])}"
      ])

    workspace_root = Path.join(root, "contract-workspace")
    host_home = Path.join(root, "host-home")
    global_home = Path.join(host_home, ".codex")
    marker = Path.join(workspace_root, "contract.jsonl")

    :ok = File.mkdir_p(Path.join(host_home, ".ssh"))
    :ok = File.mkdir_p(workspace_root)
    :ok = File.write(marker, ~s({"text":"계약금액"}))
    :ok = File.write(Path.join(host_home, ".ssh/config"), "host secret\n")
    :ok = File.write(Path.join(host_home, ".zsh_history"), "history secret\n")

    # A user gem dir must EXIST for rubygems to glob it at boot: a missing
    # ~/.gem is skipped silently (which masked the 2026-07-19 field failure on
    # a HOME without gems), while an ungranted one aborts ruby with EPERM.
    :ok = File.mkdir_p(Path.join(host_home, ".gem/ruby/2.6.0/specifications"))
    :ok = File.write(Path.join(host_home, ".gem/ruby/2.6.0/specifications/.keep"), "")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, isolation} =
             CodexHome.prepare(
               root: Path.join(root, "homes"),
               auth_source: auth_source,
               global_home: global_home,
               workspace_root: workspace_root,
               document_lane?: true,
               user_home: host_home
             )

    env =
      isolation.env
      |> Enum.reject(fn {_name, value} -> value == false end)
      |> Kernel.++([{"HOME", host_home}])

    assert {output, 0} =
             sandbox_cmd(codex, isolation, workspace_root, env, [
               "rg",
               "-n",
               "계약금액",
               "contract.jsonl"
             ])

    assert output =~ "계약금액"

    # 2026-07-19 field report: system Ruby booted but rubygems died on EPERM
    # globbing /Library/Ruby/Gems at startup, killing a read-only one-liner
    # before it touched its input. The exact failing shape must work.
    assert {output, 0} =
             sandbox_cmd(codex, isolation, workspace_root, env, [
               "/usr/bin/ruby",
               "-rjson",
               "-e",
               "puts JSON.parse(File.read(\"contract.jsonl\"))[\"text\"]"
             ])

    assert output =~ "계약금액"

    assert {output, status} =
             sandbox_cmd(codex, isolation, workspace_root, env, [
               "cat",
               Path.join(isolation.home, "auth.json")
             ])

    assert status != 0
    assert output =~ "Operation not permitted"

    for secret <- [Path.join(host_home, ".ssh/config"), Path.join(host_home, ".zsh_history")] do
      assert {output, status} =
               sandbox_cmd(codex, isolation, workspace_root, env, ["cat", secret])

      assert status != 0
      assert output =~ "Operation not permitted"
    end

    assert {output, status} =
             sandbox_cmd(codex, isolation, workspace_root, env, [
               "touch",
               Path.join(workspace_root, "shell-mutation")
             ])

    assert status != 0
    assert output =~ "Operation not permitted"
    refute File.exists?(Path.join(workspace_root, "shell-mutation"))
  end

  defp non_bun_node do
    System.get_env("PATH", "")
    |> String.split(":", trim: true)
    |> Enum.reject(&(Path.basename(&1) |> String.starts_with?("bun-node-")))
    |> Enum.map(&Path.join(&1, "node"))
    |> Enum.find(fn path ->
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, mode: mode}} -> Bitwise.band(mode, 0o111) != 0
        _other -> false
      end
    end)
  end

  defp sandbox_cmd(codex, isolation, workspace_root, env, command) do
    System.cmd(
      codex,
      [
        "sandbox",
        "-C",
        workspace_root,
        "-P",
        isolation.permission_profile
        | command
      ],
      cd: workspace_root,
      env: env,
      stderr_to_stdout: true
    )
  end
end
