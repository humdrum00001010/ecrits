defmodule Ecrits.WorkspaceMount.Transition do
  @moduledoc false

  alias Ecrits.WorkspaceMount

  def start_picker(%WorkspaceMount{picker_busy?: true} = state), do: state

  def start_picker(%WorkspaceMount{} = state) do
    transition(state, %{picker_busy?: true, error: nil})
  end

  def picker_selected(%WorkspaceMount{} = state, path) do
    transition(state, %{picker_busy?: false, path: path, error: nil})
  end

  def picker_failed(%WorkspaceMount{} = state, reason) do
    transition(state, %{
      picker_busy?: false,
      error: error_message(reason)
    })
  end

  def submit(%WorkspaceMount{} = state, path) do
    transition(state, %{path: path, error: nil})
  end

  def put_error(%WorkspaceMount{} = state, reason) do
    transition(state, %{error: error_message(reason)})
  end

  defp transition(state, attrs) do
    changeset = WorkspaceMount.changeset(state, attrs)
    if changeset.valid?, do: Ecto.Changeset.apply_changes(changeset), else: state
  end

  defp error_message({:invalid_path, message}) when is_binary(message), do: message
  defp error_message({:error, message}) when is_binary(message), do: message
  defp error_message(:cancelled), do: "Folder selection canceled."

  defp error_message({:native_picker_unavailable, message}) when is_binary(message),
    do: message

  defp error_message({:substrate_unavailable, message}) when is_binary(message),
    do: message

  defp error_message(message) when is_binary(message), do: message
  defp error_message(_reason), do: "Workspace could not be mounted."
end
