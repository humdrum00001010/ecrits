defmodule Ecrits.Workspace.Foreground do
  @moduledoc "Shared typed boundary for a workspace chat-rail foreground."

  use Ecto.Schema

  import Ecto.Changeset

  alias Ecrits.Agent.DurableState

  @primary_key false
  @fields [:agent_id, :provider, :owner_session_id, :settings]

  embedded_schema do
    field :agent_id, :string
    field :provider, :string
    field :owner_session_id, :string
    embeds_one :agent_state, DurableState, on_replace: :update
    field :settings, :any, virtual: true
  end

  @type t :: %__MODULE__{}

  @spec cast(map() | t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(%__MODULE__{} = foreground), do: foreground |> Map.from_struct() |> cast()

  def cast(attrs) when is_map(attrs) do
    changeset =
      %__MODULE__{}
      |> Ecto.Changeset.cast(take_fields(attrs), @fields, empty_values: [])
      |> validate_required([:agent_id, :owner_session_id])
      |> validate_change(:agent_id, &validate_non_empty/2)
      |> validate_change(:owner_session_id, &validate_non_empty/2)
      |> validate_change(:settings, &validate_settings/2)
      |> cast_agent_state(attrs)

    apply_action(changeset, :insert)
  end

  def cast(_attrs), do: cast(%{})

  @spec cast!(map() | t()) :: t()
  def cast!(attrs) do
    case cast(attrs) do
      {:ok, foreground} ->
        foreground

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = foreground) do
    %{
      agent_id: foreground.agent_id,
      provider: foreground.provider,
      owner_session_id: foreground.owner_session_id,
      agent_state: dump_agent_state(foreground.agent_state, :runtime),
      settings: foreground.settings
    }
  end

  @spec dump_durable(t()) :: map()
  def dump_durable(%__MODULE__{} = foreground) do
    %{
      "agent_id" => foreground.agent_id,
      "provider" => foreground.provider,
      "owner_session_id" => foreground.owner_session_id,
      "agent_state" => dump_agent_state(foreground.agent_state, :durable)
    }
  end

  defp take_fields(attrs) do
    Enum.reduce(@fields, %{}, fn field, params ->
      case fetch(attrs, field) do
        {:ok, value} -> Map.put(params, field, value)
        :error -> params
      end
    end)
  end

  defp cast_agent_state(changeset, attrs) do
    case fetch(attrs, :agent_state) do
      :error ->
        changeset

      {:ok, nil} ->
        changeset

      {:ok, agent_state} ->
        case DurableState.cast(agent_state) do
          {:ok, state} -> put_embed(changeset, :agent_state, state)
          {:error, _changeset} -> add_error(changeset, :agent_state, "is invalid")
        end
    end
  end

  defp validate_non_empty(field, value) do
    if String.trim(value) == "", do: [{field, "must not be empty"}], else: []
  end

  defp validate_settings(:settings, settings) do
    if Keyword.keyword?(settings), do: [], else: [settings: "must be a keyword list"]
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp dump_agent_state(nil, _mode), do: nil
  defp dump_agent_state(%DurableState{} = state, :runtime), do: DurableState.runtime_map(state)
  defp dump_agent_state(%DurableState{} = state, :durable), do: DurableState.dump(state)

  defp dump_agent_state(state, mode) when is_map(state) do
    state
    |> DurableState.cast!()
    |> dump_agent_state(mode)
  end
end
