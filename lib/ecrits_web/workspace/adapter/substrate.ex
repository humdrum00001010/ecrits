defmodule EcritsWeb.Workspace.Adapter.Substrate do
  @moduledoc """
  Adapter for Package A local substrate modules.
  """

  @behaviour EcritsWeb.Workspace.Adapter

  @workspace Ecrits.Workspace

  @impl true
  def mount(path) when is_binary(path) do
    with :ok <- ensure_exported(@workspace, :new, 1),
         :ok <- ensure_exported(@workspace, :list, 2),
         workspace <- apply(@workspace, :new, [path]),
         {:ok, tree} <- build_tree(workspace, MapSet.new()) do
      {:ok,
       %{
         root_path: workspace_root_path(workspace, path),
         title: workspace_title(workspace, path),
         substrate: workspace,
         tree: tree
       }}
    end
  end

  @impl true
  def list_tree(%{substrate: workspace}, expanded_paths) do
    with :ok <- ensure_exported(@workspace, :list, 2) do
      build_tree(workspace, expanded_paths)
    end
  end

  def list_tree(_workspace, _expanded_paths) do
    {:error, {:substrate_unavailable, missing_api_message()}}
  end

  defp ensure_exported(module, function, arity) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, {:substrate_unavailable, missing_api_message()}}

      not function_exported?(module, function, arity) ->
        {:error, {:substrate_unavailable, missing_api_message()}}

      true ->
        :ok
    end
  end

  defp build_tree(workspace, expanded_paths) do
    build_children(workspace, ".", expanded_paths)
  end

  defp build_children(workspace, relative, expanded_paths) do
    case apply(@workspace, :list, [workspace, relative]) do
      {:ok, entries} ->
        entries
        |> Enum.reduce_while({:ok, []}, fn entry, {:ok, nodes} ->
          case entry_node(workspace, entry, expanded_paths) do
            {:ok, node} -> {:cont, {:ok, [node | nodes]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:error, {:invalid_path, "Workspace path does not exist or cannot be read."}}

      {:error, :enotdir} ->
        {:error, {:invalid_path, "Workspace path is not a directory."}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp entry_node(workspace, entry, expanded_paths) do
    node = %{
      name: Map.fetch!(entry, :name),
      path: Map.fetch!(entry, :path),
      type: Map.fetch!(entry, :type)
    }

    if node.type == :directory and MapSet.member?(expanded_paths, node.path) do
      with {:ok, children} <- build_children(workspace, node.path, expanded_paths) do
        {:ok, Map.put(node, :children, children)}
      end
    else
      {:ok, Map.put(node, :children, [])}
    end
  end

  defp workspace_root_path(%{__struct__: @workspace, root: root}, _fallback), do: root

  defp workspace_root_path(workspace, fallback) when is_map(workspace) do
    Map.get(workspace, :root_path) || Map.get(workspace, :root) || Map.get(workspace, :path) ||
      fallback
  end

  defp workspace_root_path(_workspace, fallback), do: fallback

  defp workspace_title(workspace, fallback) do
    workspace
    |> workspace_root_path(fallback)
    |> Path.basename()
    |> case do
      "" -> fallback
      "ecrits" -> "Ecrits"
      title -> title
    end
  end

  defp missing_api_message do
    "Local workspace substrate unavailable: expected Ecrits.Workspace.new/1 and Ecrits.Workspace.list/2."
  end
end
