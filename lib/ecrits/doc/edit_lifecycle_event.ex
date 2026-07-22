defmodule Ecrits.Doc.EditLifecycleEvent do
  @moduledoc "Typed PubSub contract for candidate through snapshot-ready document edits."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields [
    :phase,
    :turn_id,
    :edit_id,
    :document_id,
    :revision,
    :legacy_lifecycle,
    :ops,
    :sets,
    :highlights,
    :preview_snapshot,
    :preview_snapshot_error,
    :agent_id,
    :instance_id
  ]

  embedded_schema do
    field :phase, Ecto.Enum, values: [:candidate, :committed, :rejected, :snapshot_ready]
    field :turn_id, :string
    field :edit_id, :string
    field :document_id, :string
    field :revision, :any, virtual: true
    field :legacy_lifecycle, :any, virtual: true
    field :ops, :any, virtual: true, default: []
    field :sets, :any, virtual: true, default: []
    field :highlights, :any, virtual: true, default: []
    field :preview_snapshot, :any, virtual: true
    field :preview_snapshot_error, :any, virtual: true
    field :agent_id, :string
    field :instance_id, :string
    field :extensions, :map, virtual: true, default: %{}
    field :present_fields, :any, virtual: true, default: []
  end

  @type t :: %__MODULE__{}

  @spec cast(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(attrs) when is_map(attrs) do
    known_atoms = MapSet.new(@fields)
    known_strings = MapSet.new(@fields, &Atom.to_string/1)

    {params, present_fields} =
      Enum.reduce(@fields, {%{}, []}, fn field, {params, present} ->
        case fetch(attrs, field) do
          {:ok, value} ->
            value =
              if field in [:ops, :sets, :highlights] and not is_list(value),
                do: [],
                else: value

            {Map.put(params, field, value), [field | present]}

          :error ->
            value = if field in [:ops, :sets, :highlights], do: [], else: nil
            {Map.put(params, field, value), present}
        end
      end)

    extensions =
      attrs
      |> Enum.reject(fn {key, _value} ->
        MapSet.member?(known_atoms, key) or MapSet.member?(known_strings, key)
      end)
      |> Map.new()

    params =
      params
      |> Map.put(:extensions, extensions)
      |> Map.put(:present_fields, present_fields)

    %__MODULE__{}
    |> Ecto.Changeset.cast(params, @fields ++ [:extensions, :present_fields], empty_values: [])
    |> validate_required([:phase])
    |> apply_action(:insert)
  end

  def cast(_attrs), do: cast(%{})

  @spec cast!(map()) :: t()
  def cast!(attrs) do
    case cast(attrs) do
      {:ok, event} -> event
      {:error, changeset} -> raise ArgumentError, inspect(changeset.errors)
    end
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = event) do
    present = MapSet.new(event.present_fields)

    known =
      Enum.reduce(@fields, %{}, fn field, dumped ->
        value = Map.fetch!(event, field)

        if is_nil(value) and not MapSet.member?(present, field),
          do: dumped,
          else: Map.put(dumped, field, value)
      end)

    Map.merge(event.extensions, known)
  end

  defp fetch(attrs, field) do
    case Map.fetch(attrs, field) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(field))
    end
  end
end
