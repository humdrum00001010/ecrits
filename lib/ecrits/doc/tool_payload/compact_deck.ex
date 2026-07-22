defmodule Ecrits.Doc.ToolPayload.CompactDeck do
  @moduledoc "Typed compact summary of a `doc.create` presentation deck."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @fields [:title, :subtitle, :slides, :slide_titles]

  embedded_schema do
    field :title, :string
    field :subtitle, :string
    field :slides, :integer, default: 0
    field :slide_titles, {:array, :string}, default: []
  end

  @type t :: %__MODULE__{}

  @spec cast(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(deck) when is_map(deck) do
    slides =
      case field(deck, :slides) do
        slides when is_list(slides) -> slides
        _other -> []
      end

    params = %{
      title: field(deck, :title),
      subtitle: field(deck, :subtitle),
      slides: length(slides),
      slide_titles:
        slides
        |> Enum.map(&field(&1, :title))
        |> Enum.reject(&is_nil/1)
        |> Enum.take(8)
    }

    %__MODULE__{}
    |> Ecto.Changeset.cast(params, @fields, empty_values: [])
    |> apply_action(:insert)
  end

  @spec dump(t()) :: map()
  def dump(%__MODULE__{} = deck) do
    %{
      "title" => deck.title,
      "subtitle" => deck.subtitle,
      "slides" => deck.slides,
      "slide_titles" => deck.slide_titles
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, "", []] end)
    |> Map.new()
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_value, _key), do: nil
end
