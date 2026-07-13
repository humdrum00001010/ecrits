defmodule Ecrits.WorkspaceMount do
  @moduledoc "Embedded state model for choosing and validating a workspace path."

  use Ecto.Schema

  import Ecto.Changeset

  alias __MODULE__.Transition

  @primary_key false

  embedded_schema do
    field :path, :string, default: ""
    field :picker_busy?, :boolean, default: false
    field :error, :string
  end

  @type t :: %__MODULE__{}

  def new(attrs \\ %{}), do: apply_attrs(%__MODULE__{}, attrs)

  def changeset(%__MODULE__{} = state, attrs) when is_map(attrs) do
    state
    |> cast(attrs, [:path, :picker_busy?, :error])
    |> update_change(:path, &String.trim/1)
    |> update_change(:error, &trim_error/1)
    |> validate_length(:path, max: 4_096)
    |> validate_length(:error, max: 500)
  end

  def validate_path(%__MODULE__{path: ""}),
    do: {:error, {:invalid_path, "Choose a workspace folder."}}

  def validate_path(%__MODULE__{path: path}) do
    path = Path.expand(path)

    cond do
      not File.exists?(path) -> {:error, {:invalid_path, "Workspace path does not exist."}}
      not File.dir?(path) -> {:error, {:invalid_path, "Workspace path is not a directory."}}
      true -> {:ok, path}
    end
  end

  defdelegate start_picker(state), to: Transition
  defdelegate picker_selected(state, path), to: Transition
  defdelegate picker_failed(state, reason), to: Transition
  defdelegate submit(state, path), to: Transition
  defdelegate put_error(state, reason), to: Transition

  defp apply_attrs(state, attrs) do
    changeset = changeset(state, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: state
  end

  defp trim_error(nil), do: nil
  defp trim_error(error), do: String.trim(error)
end
