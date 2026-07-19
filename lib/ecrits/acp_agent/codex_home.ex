defmodule Ecrits.AcpAgent.CodexHome do
  @moduledoc false

  @type isolation :: %{
          home: String.t(),
          env: [{String.t(), String.t() | false}],
          permission_profile: String.t()
        }

  @read_only_profile "ecrits_read_only"
  @workspace_profile "ecrits_workspace"
  @document_read_only_profile "ecrits_document_read_only"
  @document_workspace_profile "ecrits_document_workspace"

  @spec prepare(keyword()) :: {:ok, isolation()} | {:error, term()}
  def prepare(opts \\ []) do
    auth_source = Keyword.get(opts, :auth_source, default_auth_source())
    global_home = Keyword.get(opts, :global_home, default_global_home())
    root = Keyword.get(opts, :root, default_root())
    document_lane? = Keyword.get(opts, :document_lane?, false)
    workspace_root = Keyword.get(opts, :workspace_root)
    user_home = Keyword.get(opts, :user_home, System.user_home!())
    permission_profile = permission_profile(Keyword.get(opts, :sandbox), document_lane?)

    with :ok <- require_auth(auth_source),
         {:ok, home} <- make_home(root),
         :ok <- copy_auth(auth_source, home),
         :ok <-
           write_config(
             home,
             global_home,
             permission_profile,
             workspace_root,
             document_lane?,
             Keyword.get(opts, :path, System.get_env("PATH")),
             user_home
           ),
         :ok <- write_document_playbook(home, document_lane?) do
      {:ok,
       %{
         home: home,
         env:
           agent_env(
             home,
             Keyword.get(opts, :path, System.get_env("PATH")),
             Keyword.get(opts, :node, System.get_env("NODE"))
           ),
         permission_profile: permission_profile
       }}
    end
  end

  @spec adapter_opts(isolation()) :: keyword()
  def adapter_opts(%{} = isolation) do
    [
      env: isolation.env,
      use_permission_profile: true,
      expected_permission_profile: isolation.permission_profile,
      on_terminate: fn -> cleanup(isolation) end
    ]
  end

  @spec cleanup(isolation()) :: :ok
  def cleanup(%{home: home}) when is_binary(home) do
    _ = File.rm_rf(home)
    :ok
  end

  defp require_auth(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, _stat} -> {:error, :codex_auth_not_regular}
      {:error, reason} -> {:error, {:codex_auth_unavailable, reason}}
    end
  end

  defp require_auth(_path), do: {:error, :codex_auth_unavailable}

  # Tidewave's ephemeral `bun-node-*` compatibility shim currently reports
  # `fs.renameSync/2` success even when the kernel returned an errno. Let ACP
  # subprocesses inherit the ordinary system Node instead, so atomic projection
  # commits remain observable to the calling agent.
  defp agent_env(home, path, node) do
    env =
      if is_binary(path) do
        safe_path =
          path
          |> String.split(":", trim: true)
          |> Enum.reject(&bun_node_shim?/1)
          |> Enum.join(":")

        [{"CODEX_HOME", home}, {"PATH", safe_path}]
      else
        [{"CODEX_HOME", home}]
      end

    if bun_node_shim?(node), do: env ++ [{"NODE", false}], else: env
  end

  defp bun_node_shim?(path) when is_binary(path) do
    expanded = Path.expand(path)

    temporary_path?(expanded) and
      Enum.any?(Path.split(expanded), &String.starts_with?(&1, "bun-node-"))
  end

  defp bun_node_shim?(_path), do: false

  defp temporary_path?(path) do
    temporary_roots()
    |> Enum.any?(fn root -> path == root or String.starts_with?(path, root <> "/") end)
  end

  defp temporary_roots do
    [
      System.tmp_dir(),
      System.get_env("TMPDIR"),
      "/tmp",
      "/private/tmp",
      "/var/tmp",
      "/private/var/tmp",
      "/var/folders",
      "/private/var/folders"
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.map(&(&1 |> Path.expand() |> String.trim_trailing("/")))
    |> Enum.uniq()
  end

  defp make_home(root) do
    with :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700) do
      create_home(root, 0)
    end
  end

  defp create_home(_root, attempt) when attempt == 8, do: {:error, :codex_home_creation_failed}

  defp create_home(root, attempt) do
    home = Path.join(root, "codex-" <> random_suffix())

    case File.mkdir(home) do
      :ok ->
        with :ok <- File.chmod(home, 0o700) do
          {:ok, home}
        end

      {:error, :eexist} ->
        create_home(root, attempt + 1)

      {:error, reason} ->
        {:error, {:codex_home_creation_failed, reason}}
    end
  end

  defp copy_auth(source, home) do
    target = Path.join(home, "auth.json")

    with :ok <- File.cp(source, target),
         :ok <- File.chmod(target, 0o600) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm_rf(home)
        {:error, {:codex_auth_copy_failed, reason}}
    end
  end

  defp write_config(
         home,
         global_home,
         default_profile,
         workspace_root,
         document_lane?,
         path,
         user_home
       ) do
    # Keep ordinary shell search available. Document profiles are read-only so
    # the provider can inspect the workspace while every mutation remains
    # mediated by the ACP file handler.
    shell_tool = if document_lane?, do: "shell_tool = true\n", else: ""

    document_profiles =
      if document_lane? and is_binary(workspace_root) and workspace_root != "" do
        expanded_home = home |> Path.expand() |> toml_string()
        expanded_global_home = global_home |> Path.expand() |> toml_string()
        expanded_workspace_root = workspace_root |> Path.expand() |> toml_string()

        # Confinement is deliberate: document-lane reads stay within the
        # workspace subtree (the live sandbox proof below requires outside
        # reads to FAIL). The explicit /** glob spells out subtree semantics.
        # Tool directories from PATH get read grants because execvp needs to
        # READ a binary to run it: /usr/bin tools (jq) always worked while
        # /opt/homebrew tools (rg) failed as "No such file or directory" —
        # the field report "셸의 읽기 전용 검색이 샌드박스에서 막혔습니다".
        tool_grants =
          tool_path_grants(path, home, global_home) <>
            system_interpreter_grants() <> user_package_grants(user_home)

        """

        [permissions.#{@document_read_only_profile}.filesystem]
        \":minimal\" = \"read\"
        #{tool_grants}\"#{expanded_workspace_root}\" = \"read\"
        \"#{expanded_workspace_root}/**\" = \"read\"
        \"#{expanded_home}/**\" = \"deny\"
        \"#{expanded_global_home}/**\" = \"deny\"

        [permissions.#{@document_workspace_profile}.filesystem]
        \":minimal\" = \"read\"
        #{tool_grants}\"#{expanded_workspace_root}\" = \"read\"
        \"#{expanded_workspace_root}/**\" = \"read\"
        \"#{expanded_home}/**\" = \"deny\"
        \"#{expanded_global_home}/**\" = \"deny\"
        """
      else
        ""
      end

    config =
      """
      default_permissions = \"#{default_profile}\"

      [features]
      #{shell_tool}apps = false
      plugins = false
      remote_plugin = false

      [permissions.#{@read_only_profile}]
      extends = \":read-only\"

      [permissions.#{@read_only_profile}.filesystem]
      \"#{toml_string(Path.expand(global_home))}\" = \"deny\"

      [permissions.#{@workspace_profile}]
      extends = \":workspace\"

      [permissions.#{@workspace_profile}.filesystem]
      \"#{toml_string(Path.expand(global_home))}\" = \"deny\"
      """ <> document_profiles

    path = Path.join(home, "config.toml")

    with :ok <- File.write(path, config),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm_rf(home)
        {:error, {:codex_config_write_failed, reason}}
    end
  end

  # A standing AGENTS.md in the isolated Codex home, so document-lane
  # familiarity is a habit rather than something re-derived every turn: the
  # preamble carries the RULES, this carries the worked shape of a good turn.
  # Measured motive (2026-07-19): a single-field edit spent ~0.2s in ecrits
  # and ~97s in model deliberation, most of it re-learning the surface and
  # defensively re-verifying strings the CAS write already guards.
  defp write_document_playbook(_home, false), do: :ok

  defp write_document_playbook(home, true) do
    playbook = """
    # Editing the mounted document projection

    The open document is served as ONE `.jsonl` file: a single JSON value laid
    out one paragraph group per line. Line N is paragraph group N's whole
    payload array. Raw newlines are reserved record separators; newlines inside
    text stay escaped as `\\n`.

    ## The shape of a good edit turn

    1. `doc.open_doc {path: "current"}` once — it returns the mounted path.
    2. Locate with line-based search on the mounted file (it is workspace-
       scoped and read-only): the matching LINE is your edit target.
    3. Read that exact line, build the replacement line from what you just
       read (never from memory of an earlier search display — space runs in
       forms are width-exact), keep the trailing comma.
    4. Write the whole file once with your line(s) replaced. Do not pre-verify
       counts or re-check your own strings first: the write is compare-and-swap
       and fails closed — a `stale_projection` reply means reread and rewrite,
       an `EINVAL` means your base predates the last commit, so reread and
       restage. One corrected retry is normal, silent corruption is impossible.

    ### Example: change one field

    A search for `계약명` hits line 14. Read line 14, replace only the target
    text inside it, write the file with line 14 swapped. That is the entire
    edit — one read, one write.

    ## Inserts

    New content is exactly one payload node appended INSIDE an existing line's
    payload array: a `{"type":"table","cells":[[...]],"header":true}` node or a
    picture. New lines (new paragraph groups) are structural and rejected.

    ## The one native fallback

    Only an explicitly requested picture uses `doc.find` (one post-commit
    marker lookup; pass `occurrence` 1-based when the exact paragraph text
    repeats) then `doc.edit` with the returned ref verbatim.
    """

    File.write(Path.join(home, "AGENTS.md"), playbook)
  end

  defp random_suffix do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp permission_profile(sandbox, true) when sandbox in ["read-only", :read_only],
    do: @document_read_only_profile

  defp permission_profile(_sandbox, true), do: @document_workspace_profile

  defp permission_profile(sandbox, false) when sandbox in ["read-only", :read_only],
    do: @read_only_profile

  defp permission_profile(_sandbox, false), do: @workspace_profile

  # Read grants for the PATH toolchains, so shell search binaries outside
  # :minimal (homebrew, mise shims) can run in the document sandbox. A binary
  # needs more than its bin dir — dyld loads shared libraries from the
  # toolchain prefix (rg failed on /opt/homebrew/opt/pcre2/lib even after its
  # bin dir was granted) — so each <prefix>/bin|sbin entry grants the whole
  # read-only <prefix>/** subtree. Home-rooted entries stay excluded: secrets
  # confinement wins over tool convenience.
  defp tool_path_grants(path, home, global_home) do
    denied_roots = [Path.expand(home), Path.expand(global_home), System.user_home!()]

    (path || "")
    |> String.split(":", trim: true)
    |> Enum.map(&Path.expand/1)
    |> Enum.map(&toolchain_prefix/1)
    |> Enum.uniq()
    |> Enum.reject(fn dir ->
      Enum.any?(denied_roots, fn root ->
        dir == root or String.starts_with?(dir, root <> "/")
      end)
    end)
    |> Enum.map_join(fn dir -> "\"#{toml_string(dir)}/**\" = \"read\"\n" end)
  end

  defp toolchain_prefix(dir) do
    if Path.basename(dir) in ["bin", "sbin"] and Path.dirname(dir) != "/" do
      Path.dirname(dir)
    else
      dir
    end
  end

  # macOS system interpreters execute from /usr/bin or /System frameworks, but
  # their package trees live under /Library/<language>: rubygems globs
  # /Library/Ruby/Gems/*/specifications at interpreter BOOT, so without this
  # grant `ruby -e ...` dies on EPERM before reading any input (2026-07-19
  # field report). Grants stay per-language — never /Library/** wholesale,
  # which would expose /Library/Keychains and application state.
  @system_interpreter_support ~w(
    /Library/Ruby
    /Library/Perl
    /Library/Python
    /Library/Java
    /Library/Frameworks
  )

  defp system_interpreter_grants do
    Enum.map_join(@system_interpreter_support, fn dir -> "\"#{dir}/**\" = \"read\"\n" end)
  end

  # Interpreters also scan USER package trees at boot: after /Library/Ruby was
  # granted, rubygems progressed to ~/.gem and died there the same way (EPERM
  # aborts the glob; a missing dir is silently skipped, which is why a fake
  # test HOME without ~/.gem masked this). These are named package
  # directories, not a $HOME grant — secrets confinement stands.
  @user_package_dirs ~w(.gem Library/Python)

  defp user_package_grants(user_home) when is_binary(user_home) do
    Enum.map_join(@user_package_dirs, fn dir ->
      "\"#{toml_string(Path.join(Path.expand(user_home), dir))}/**\" = \"read\"\n"
    end)
  end

  defp user_package_grants(_user_home), do: ""

  defp toml_string(value),
    do: value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  defp default_auth_source, do: Path.join(default_global_home(), "auth.json")
  defp default_global_home, do: Path.join(System.user_home!(), ".codex")
  defp default_root, do: Path.join(System.tmp_dir!(), "ecrits-acp-codex")
end
