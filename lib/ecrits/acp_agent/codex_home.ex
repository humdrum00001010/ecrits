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
             document_lane?
           ) do
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

  defp write_config(home, global_home, default_profile, workspace_root, document_lane?) do
    # Keep ordinary shell search available. Document profiles are read-only so
    # the provider can inspect the workspace while every mutation remains
    # mediated by the ACP file handler.
    shell_tool = if document_lane?, do: "shell_tool = true\n", else: ""

    document_profiles =
      if document_lane? and is_binary(workspace_root) and workspace_root != "" do
        expanded_home = home |> Path.expand() |> toml_string()
        expanded_global_home = global_home |> Path.expand() |> toml_string()
        expanded_workspace_root = workspace_root |> Path.expand() |> toml_string()

        """

        [permissions.#{@document_read_only_profile}.filesystem]
        \":minimal\" = \"read\"
        \"#{expanded_workspace_root}\" = \"read\"
        \"#{expanded_home}/**\" = \"deny\"
        \"#{expanded_global_home}/**\" = \"deny\"

        [permissions.#{@document_workspace_profile}.filesystem]
        \":minimal\" = \"read\"
        \"#{expanded_workspace_root}\" = \"read\"
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

  defp toml_string(value),
    do: value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")

  defp default_auth_source, do: Path.join(default_global_home(), "auth.json")
  defp default_global_home, do: Path.join(System.user_home!(), ".codex")
  defp default_root, do: Path.join(System.tmp_dir!(), "ecrits-acp-codex")
end
