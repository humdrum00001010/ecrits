defmodule EcritsWeb.LocalDirectoryPickerStub do
  @behaviour EcritsWeb.Local.DirectoryPicker

  @valid_path "/tmp/ecrits-local-ui"

  def valid_path, do: @valid_path

  @impl true
  def choose_folder do
    case Application.get_env(:ecrits, :local_directory_picker_stub, {:ok, @valid_path}) do
      {:await, owner, result} when is_pid(owner) ->
        send(owner, {:directory_picker_started, self()})

        receive do
          :release_directory_picker -> result
        after
          5_000 -> {:error, {:native_picker_unavailable, "Native folder picker timed out."}}
        end

      result ->
        result
    end
  end
end
