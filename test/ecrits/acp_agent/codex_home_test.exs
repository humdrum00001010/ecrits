defmodule Ecrits.AcpAgent.CodexHomeTest do
  use ExUnit.Case, async: true

  alias Ecrits.AcpAgent.CodexHome
  alias ExMCP.ACP.AdapterBridge
  alias EcritsWeb.EnvProbeAcpAdapter

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
    assert opts == [env: isolation.env]

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

    # Official ex_mcp receives only the isolated environment. Ecrits owns the
    # lifecycle policy, so a conversation home survives session teardown.
    assert CodexHome.adapter_opts(second) == [env: second.env]
    assert File.exists?(rollout)

    # ...while a different conversation gets its own home and an ephemeral
    # prepare still cleans up on teardown.
    assert {:ok, other} = CodexHome.prepare(Keyword.put(opts, :conversation_id, "rail-conv-2"))
    refute other.home == first.home

    assert {:ok, ephemeral} = CodexHome.prepare(Keyword.delete(opts, :conversation_id))
    assert ephemeral.ephemeral?
    assert :ok = CodexHome.cleanup(ephemeral)
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
    assert {"NODE", ""} in isolation.env
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
          adapter: EnvProbeAcpAdapter,
          adapter_opts:
            CodexHome.adapter_opts(isolation) ++
              [command: {node, [script, proof, source, target]}]
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

  test "document mode creates its isolated profile and provider-native playbook", %{
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
           "#{Path.expand(workspace_root)}" = "write"
           "#{Path.expand(workspace_root)}/**" = "write"
           "#{Path.expand(isolation.home)}/**" = "deny"
           "#{Path.expand(global_home)}/**" = "deny"
           """

    refute config =~
             ~s([permissions.ecrits_document_workspace]\nextends = ":read-only")

    # Standing familiarity: the isolated home carries the document playbook so
    # the model does not re-derive the surface's shape every turn.
    playbook = File.read!(Path.join(isolation.home, "AGENTS.md"))
    assert playbook =~ "one paragraph group per line"
    assert playbook =~ "two opening `[` wrapper lines and two closing `]` wrapper lines"
    assert playbook =~ "comma after every inner group line except the last"
    assert playbook =~ "Do not serialize the whole root as one line"
    assert playbook =~ "native search/read plus `apply_patch` or Python/Ruby"
    assert playbook =~ "apply that line-sized patch"
    assert playbook =~ "occurrence"

    # New paragraphs are an ordinary mounted-file write (a new line holding one
    # bare paragraph node) — the playbook must teach that shape and must not
    # route paragraphs through the doc.edit fallback (2026-07-19 direction:
    # "inserting para is done through the projection, not MCP tools").
    assert playbook =~ ~s([{"type":"paragraph","text":"..."}])
    assert playbook =~ "Never tell the user a"
    refute playbook =~ ~s(doc.edit {op: "insert_paragraph")
  end

  test "document playbook teaches Codex native bounded projection edits", %{
    root: root,
    auth_source: auth_source
  } do
    assert {:ok, isolation} =
             CodexHome.prepare(
               root: Path.join(root, "homes"),
               auth_source: auth_source,
               workspace_root: Path.join(root, "contract-workspace"),
               document_lane?: true,
               path: "/opt/toolchain/bin",
               user_home: "/Users/someone"
             )

    playbook = File.read!(Path.join(isolation.home, "AGENTS.md"))

    assert playbook =~ "Call `doc.open_doc` once and use the returned mount path"
    assert playbook =~ "Use native search/read plus `apply_patch` or Python/Ruby"
    assert playbook =~ ~r/Python\/Ruby\s+writes are allowed/
    assert playbook =~ "Never truncate the mounted target in place"
    assert playbook =~ "sibling `.tmp` file"
    assert playbook =~ ~r/atomically rename it over\s+the target once/
    assert playbook =~ ~r/one writer and one rename per\s+batch/
    assert playbook =~ ~r/discard\s+every saved line number/
    assert playbook =~ ~r/Never delete or rename a rejected projection temp\s+file/
    assert playbook =~ ~r/For a small edit, patch the required JSONL group lines/
    assert playbook =~ "append only the `table` payload"
    assert playbook =~ "append it to the Article 51 group's payload array"

    assert playbook =~
             ~r/Never append a paragraph\s+or title payload to that existing group/i

    assert playbook =~
             ~r/Never put embedded newlines inside\s+an existing paragraph or text node/

    assert playbook =~ "separate ref-less paragraph groups"
    assert playbook =~ "`acp_commit_required` does not consume the marker lookup"

    assert playbook =~ "wait for the VFS write-back to settle"
    assert playbook =~ "valid UTF-8 JSONL"
    assert playbook =~ "do not repair or rewrite transient bytes"

    assert playbook =~
             ~r/Use `doc\.edit` only for an IR-inexpressible native operation such as image\s+or signature insertion/

    assert playbook =~ "Boundedly"
    assert playbook =~ ~r/verify the durable document and preview/i

    refute playbook =~ "FileLane"
    refute playbook =~ "search_text_file"
    refute playbook =~ "edit_text_file"
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

  test "document shell can search and patch its workspace without reaching secrets", %{
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

    assert {_output, 0} =
             sandbox_cmd(codex, isolation, workspace_root, env, [
               "touch",
               Path.join(workspace_root, "shell-mutation")
             ])

    assert File.exists?(Path.join(workspace_root, "shell-mutation"))

    assert {output, status} =
             sandbox_cmd(codex, isolation, workspace_root, env, [
               "touch",
               Path.join(host_home, "outside-mutation")
             ])

    assert status != 0
    assert output =~ "Operation not permitted"
    refute File.exists?(Path.join(host_home, "outside-mutation"))
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
