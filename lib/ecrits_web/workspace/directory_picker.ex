defmodule EcritsWeb.Workspace.DirectoryPicker do
  @moduledoc """
  Boundary for native local folder selection.
  """

  @callback choose_folder() :: {:ok, String.t()} | {:error, term()}

  def choose_folder do
    impl().choose_folder()
  end

  defp impl do
    Application.get_env(
      :ecrits,
      :local_directory_picker,
      EcritsWeb.Workspace.DirectoryPicker.Native
    )
  end
end
