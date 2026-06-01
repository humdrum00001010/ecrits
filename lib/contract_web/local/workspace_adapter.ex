defmodule ContractWeb.Local.WorkspaceAdapter do
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
      :contract,
      :local_workspace_adapter,
      ContractWeb.Local.WorkspaceAdapter.Substrate
    )
  end
end
