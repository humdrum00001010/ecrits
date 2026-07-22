defmodule Ecrits.Agent.Dialog do
  @moduledoc """
  Durable display transcript for one completed agent turn.

  `items` remains a polymorphic map array at the durable wire boundary. Each
  map is validated and dumped by its bounded `Ecrits.Agent.Item` schema before
  storage, while list position stays the canonical chat-rail execution order.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  embedded_schema do
    field :turn_id, :string
    field :user, :string, default: ""
    field :agent, :string, default: ""
    field :items, {:array, :map}, default: []
  end

  @type item :: map()
  @type t :: %__MODULE__{
          turn_id: String.t(),
          user: String.t(),
          agent: String.t(),
          items: [item()]
        }

  @fields [:turn_id, :user, :agent, :items]

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = dialog, attrs) when is_map(attrs) do
    dialog
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required([:turn_id])
    |> validate_change(:items, fn :items, items ->
      if Enum.all?(items, &is_map/1), do: [], else: [items: "must contain maps"]
    end)
  end
end
