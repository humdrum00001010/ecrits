defmodule ContractWeb.LocalDirectoryPickerStub do
  @behaviour ContractWeb.Local.DirectoryPicker

  @valid_path "/tmp/contract-local-ui"

  def valid_path, do: @valid_path

  @impl true
  def choose_folder do
    Application.get_env(:contract, :local_directory_picker_stub, {:ok, @valid_path})
  end
end
