defmodule Ecrits.AcpAgent.PermissionHandler do
  @moduledoc false

  @behaviour ExMCP.ACP.Client.Handler

  @impl true
  def init(opts) do
    with {:ok, workspace_root} <- canonical_root(Keyword.get(opts, :workspace_root)) do
      {:ok,
       %{
         access_control: normalize_access(Keyword.get(opts, :access_control)),
         workspace_root: workspace_root
       }}
    end
  end

  @impl true
  def handle_session_update(_session_id, _update, state), do: {:ok, state}

  @impl true
  def handle_permission_request(_session_id, tool_call, options, state) do
    outcome =
      cond do
        not confined_to_workspace?(tool_call, state.workspace_root) ->
          select_option(options, ["reject_once", "reject_always"])

        read_tool?(tool_call) ->
          select_option(options, ["allow_once", "allow_always"])

        state.access_control == "full-workspace" ->
          select_option(options, ["allow_once", "allow_always"])

        state.access_control == "ask" ->
          %{"outcome" => "cancelled"}

        true ->
          select_option(options, ["reject_once", "reject_always"])
      end

    {:ok, outcome, state}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  defp normalize_access(access) when access in ["read-only", "ask", "full-workspace"],
    do: access

  defp normalize_access(_access), do: "read-only"

  defp read_tool?(tool_call) do
    kind = tool_call["kind"] || tool_call[:kind]

    name =
      tool_call["toolName"] || tool_call[:tool_name] || tool_call["title"] ||
        tool_call[:title] || ""

    kind in ["read", "search"] or
      String.downcase(to_string(name)) in ["read", "grep", "glob", "search"]
  end

  defp confined_to_workspace?(tool_call, workspace_root) do
    paths = path_values(tool_call)

    case paths do
      [] -> read_tool?(tool_call) or pathless_file_change_request?(tool_call)
      paths -> Enum.all?(paths, &confined_path?(&1, workspace_root))
    end
  end

  defp pathless_file_change_request?(tool_call) do
    kind = tool_call["kind"] || tool_call[:kind]
    raw_input = tool_call["rawInput"] || tool_call[:raw_input]

    kind == "edit" and is_map(raw_input) and
      (is_binary(raw_input["itemId"] || raw_input[:item_id]) or
         is_binary(raw_input["callId"] || raw_input[:call_id]))
  end

  defp path_values(value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} ->
      key = to_string(key)

      own =
        if key in [
             "path",
             "file_path",
             "filePath",
             "cwd",
             "root",
             "workspace_root",
             "grantRoot",
             "mounted_at",
             "src"
           ] and
             is_binary(nested),
           do: [nested],
           else: []

      file_changes =
        if key == "fileChanges" and is_map(nested), do: Map.keys(nested), else: []

      own ++ file_changes ++ path_values(nested)
    end)
  end

  defp path_values(value) when is_list(value), do: Enum.flat_map(value, &path_values/1)
  defp path_values(_value), do: []

  defp confined_path?(path, workspace_root) do
    expanded =
      if Path.type(path) == :absolute,
        do: Path.expand(path),
        else: Path.expand(path, workspace_root)

    not symlink_component?(expanded) and
      case canonical_existing_ancestor(expanded) do
        {:ok, canonical} -> inside?(canonical, workspace_root)
        {:error, _reason} -> false
      end
  end

  defp canonical_existing_ancestor(path) do
    cond do
      File.exists?(path) -> canonical_root(path)
      Path.dirname(path) == path -> {:error, :no_existing_ancestor}
      true -> canonical_existing_ancestor(Path.dirname(path))
    end
  end

  defp symlink_component?(path) do
    path
    |> Path.split()
    |> Enum.reduce_while(nil, fn component, current ->
      next = if current, do: Path.join(current, component), else: component

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, true}
        _ -> {:cont, next}
      end
    end)
    |> Kernel.==(true)
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp canonical_root(path) when is_binary(path) do
    with executable when is_binary(executable) <- System.find_executable("realpath"),
         {canonical, 0} <- System.cmd(executable, [Path.expand(path)], stderr_to_stdout: true),
         canonical <- String.trim(canonical),
         true <- Path.type(canonical) == :absolute do
      {:ok, canonical}
    else
      nil -> {:error, :realpath_unavailable}
      {message, status} -> {:error, {:realpath_failed, status, String.trim(message)}}
      false -> {:error, :not_absolute}
    end
  end

  defp canonical_root(_path), do: {:error, :invalid_workspace_root}

  defp select_option(options, kinds) do
    kinds
    |> Enum.find_value(fn kind -> Enum.find(options, &(Map.get(&1, "kind") == kind)) end)
    |> case do
      nil -> %{"outcome" => "cancelled"}
      option -> %{"outcome" => "selected", "optionId" => option["optionId"]}
    end
  end
end
