defmodule Ecrits.Agent.DurableState do
  @moduledoc "Shared typed boundary for persisted Agent session state."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.Agent
  alias Ecrits.Agent.AdapterOptions

  @primary_key false
  @fields [
    :id,
    :instance_id,
    :provider_session_id,
    :thread_covers_from,
    :title,
    :title_user_edited?,
    :transcript
  ]

  embedded_schema do
    field :id, :string
    field :instance_id, :string
    field :provider_session_id, :string
    field :thread_covers_from, :integer, default: 0
    field :title, :string
    field :title_user_edited?, :boolean, default: false
    field :transcript, {:array, :map}, default: []
    embeds_one :adapter_opts, AdapterOptions, on_replace: :update
  end

  @type t :: %__MODULE__{}

  @spec cast(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(attrs) when is_map(attrs) do
    %__MODULE__{adapter_opts: %AdapterOptions{}}
    |> Ecto.Changeset.cast(normalize_attrs(attrs), @fields, empty_values: [])
    |> cast_embed(:adapter_opts, with: &AdapterOptions.changeset/2)
    |> validate_required([:id])
    |> validate_number(:thread_covers_from, greater_than_or_equal_to: 0)
    |> validate_change(:transcript, &validate_transcript/2)
    |> apply_action(:insert)
  end

  def cast(_attrs) do
    cast(%{})
  end

  @spec cast!(map()) :: t()
  def cast!(attrs) do
    case cast(attrs) do
      {:ok, state} -> state
      {:error, changeset} -> raise ArgumentError, inspect(changeset.errors)
    end
  end

  @spec runtime_map(t()) :: map()
  def runtime_map(%__MODULE__{} = state) do
    %{
      id: state.id,
      instance_id: state.instance_id,
      provider_session_id: state.provider_session_id,
      thread_covers_from: state.thread_covers_from,
      title: state.title,
      title_user_edited?: state.title_user_edited?,
      transcript: Enum.map(state.transcript, &Agent.dump_dialog/1),
      adapter_opts: AdapterOptions.dump(state.adapter_opts)
    }
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = state) do
    state
    |> runtime_map()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp normalize_attrs(attrs) do
    params =
      Enum.reduce(@fields, %{}, fn field, normalized ->
        case fetch(attrs, field) do
          {:ok, value} -> Map.put(normalized, field, value)
          :error -> normalized
        end
      end)

    case fetch(attrs, :adapter_opts) do
      {:ok, value} -> Map.put(params, :adapter_opts, value)
      :error -> params
    end
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp validate_transcript(:transcript, transcript) do
    if Enum.all?(transcript, &valid_dialog?/1),
      do: [],
      else: [transcript: "contains an invalid dialog"]
  end

  defp valid_dialog?(dialog) do
    match?({:ok, _dialog}, Agent.load_dialog(dialog))
  rescue
    _error -> false
  end
end
