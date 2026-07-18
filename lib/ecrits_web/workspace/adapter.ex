defmodule EcritsWeb.Workspace.Adapter do
  @moduledoc """
  Boundary between local LiveViews and the local workspace substrate.
  """

  @callback mount(String.t()) :: {:ok, map()} | {:error, term()}
  @callback list_tree(map(), MapSet.t()) :: {:ok, list(map())} | {:error, term()}

  def mount(path) when is_binary(path) do
    impl().mount(path)
  end

  def list_tree(workspace, expanded_paths) do
    impl().list_tree(workspace, expanded_paths)
  end

  defp impl do
    Application.get_env(
      :ecrits,
      :workspace_adapter,
      EcritsWeb.Workspace.Adapter.Substrate
    )
  end
end
