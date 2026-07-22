defmodule Ecrits.Workspace.TurnOwner do
  @moduledoc "Runtime-only ownership record for one exact agent turn."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields [
    :owner_pid,
    :owner_ref,
    :task_pid,
    :task_ref,
    :owner_exit_reason,
    :worker_pid,
    :worker_ref,
    :worker_down?,
    :guardian_down?,
    :shutdown_ack?,
    :status
  ]

  embedded_schema do
    field :owner_pid, :any, virtual: true
    field :owner_ref, :any, virtual: true
    field :task_pid, :any, virtual: true
    field :task_ref, :any, virtual: true
    field :owner_exit_reason, :any, virtual: true
    field :worker_pid, :any, virtual: true
    field :worker_ref, :any, virtual: true
    field :worker_down?, :boolean, default: false
    field :guardian_down?, :boolean, default: false
    field :shutdown_ack?, :boolean, default: false
    field :status, Ecto.Enum, values: [:active, :awaiting_task_down, :crashed], default: :active
  end

  @type t :: %__MODULE__{}

  @spec cast(map() | t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(%__MODULE__{} = owner), do: owner |> Map.from_struct() |> cast()

  def cast(attrs) when is_map(attrs) do
    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.cast(take_fields(attrs), @fields, empty_values: [])
      |> validate_required([:owner_pid, :owner_ref, :task_pid, :status])
      |> validate_change(:owner_pid, &validate_pid/2)
      |> validate_change(:owner_ref, &validate_reference/2)
      |> validate_change(:task_pid, &validate_pid/2)
      |> validate_change(:task_ref, &validate_optional_reference/2)
      |> validate_change(:worker_pid, &validate_optional_pid/2)
      |> validate_change(:worker_ref, &validate_optional_reference/2)
      |> validate_worker_monitor_pair()

    apply_action(changeset, :insert)
  end

  def cast(_attrs), do: cast(%{})

  @spec cast!(map() | t()) :: t()
  def cast!(attrs) do
    case cast(attrs) do
      {:ok, owner} ->
        owner

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  defp take_fields(attrs) do
    Enum.reduce(@fields, %{}, fn field, params ->
      case fetch(attrs, field) do
        {:ok, value} -> Map.put(params, field, value)
        :error -> params
      end
    end)
  end

  defp validate_pid(field, value), do: if(is_pid(value), do: [], else: [{field, "must be a pid"}])

  defp validate_reference(field, value) do
    if is_reference(value), do: [], else: [{field, "must be a reference"}]
  end

  defp validate_optional_pid(_field, nil), do: []
  defp validate_optional_pid(field, value), do: validate_pid(field, value)

  defp validate_optional_reference(_field, nil), do: []
  defp validate_optional_reference(field, value), do: validate_reference(field, value)

  defp validate_worker_monitor_pair(changeset) do
    case {
      get_field(changeset, :worker_pid),
      get_field(changeset, :worker_ref),
      get_field(changeset, :worker_down?)
    } do
      {nil, nil, _down?} -> changeset
      {pid, ref, _down?} when is_pid(pid) and is_reference(ref) -> changeset
      {pid, nil, true} when is_pid(pid) -> changeset
      _incomplete -> add_error(changeset, :worker_ref, "must accompany worker_pid")
    end
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end
end
