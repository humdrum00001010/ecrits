defmodule EcritsWeb.Local.DirectoryPicker.Native do
  @moduledoc """
  macOS native folder picker for the local-only mount screen.
  """

  @behaviour EcritsWeb.Local.DirectoryPicker

  @impl true
  def choose_folder do
    with :ok <- ensure_supported_os(),
         {:ok, osascript} <- find_osascript(),
         {output, 0} <- System.cmd(osascript, ["-e", script()], stderr_to_stdout: true),
         {:ok, path} <- selected_path(output) do
      {:ok, path}
    else
      {:error, reason} -> {:error, reason}
      {output, _status} -> {:error, osascript_error(output)}
    end
  end

  defp ensure_supported_os do
    case :os.type() do
      {:unix, :darwin} ->
        :ok

      _other ->
        {:error, {:native_picker_unavailable, "Native folder picker is unavailable on this OS."}}
    end
  end

  defp find_osascript do
    case System.find_executable("osascript") do
      nil ->
        {:error,
         {:native_picker_unavailable,
          "Native folder picker is unavailable: osascript was not found."}}

      path ->
        {:ok, path}
    end
  end

  defp script do
    ~S[POSIX path of (choose folder with prompt "Choose workspace folder" default location (path to home folder))]
  end

  defp selected_path(output) do
    output
    |> String.trim()
    |> case do
      "" -> {:error, :cancelled}
      path -> {:ok, Path.expand(path)}
    end
  end

  defp osascript_error(output) do
    if output =~ "User canceled" or output =~ "-128" do
      :cancelled
    else
      {:native_picker_unavailable, "Native folder picker failed to open."}
    end
  end
end
