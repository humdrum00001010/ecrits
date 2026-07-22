defmodule Ecrits.Agent.AdapterOptions do
  @moduledoc "Persisted, provider-neutral Agent adapter options."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields [
    :model,
    :reasoning_effort,
    :sandbox,
    :permission_mode,
    :approval_policy,
    :access_control
  ]

  embedded_schema do
    field :model, :any, virtual: true
    field :reasoning_effort, :any, virtual: true
    field :sandbox, :any, virtual: true
    field :permission_mode, :any, virtual: true
    field :approval_policy, :any, virtual: true
    field :access_control, :any, virtual: true
  end

  @type t :: %__MODULE__{}

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = options, attrs) do
    options
    |> cast(normalize_attrs(attrs), @fields, empty_values: [])
    |> validate_change(:model, &validate_scalar/2)
    |> validate_change(:reasoning_effort, &validate_scalar/2)
    |> validate_change(:sandbox, &validate_scalar/2)
    |> validate_change(:permission_mode, &validate_scalar/2)
    |> validate_change(:approval_policy, &validate_scalar/2)
    |> validate_change(:access_control, &validate_scalar/2)
  end

  @spec cast(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> apply_action(:insert)
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = options) do
    Enum.reduce(@fields, %{}, fn field, dumped ->
      case Map.fetch!(options, field) do
        nil -> dumped
        value -> Map.put(dumped, Atom.to_string(field), value)
      end
    end)
  end

  defp normalize_attrs(attrs) do
    Enum.reduce(@fields, %{}, fn field, normalized ->
      value = Map.get(attrs, field, Map.get(attrs, Atom.to_string(field)))

      if is_nil(value) do
        normalized
      else
        Map.put(normalized, field, if(is_atom(value), do: Atom.to_string(value), else: value))
      end
    end)
  end

  defp validate_scalar(field, value) do
    if is_binary(value) or is_boolean(value) or is_number(value) do
      []
    else
      [{field, "must be a JSON scalar"}]
    end
  end
end
