defmodule Ecrits.DocumentElementPicker.Transition do
  @moduledoc false

  import Ecto.Changeset

  alias Ecrits.DocumentElementPicker
  alias Ecrits.DocumentElementPicker.Pick

  @max_picks 32

  def toggle(%DocumentElementPicker{} = picker), do: put_enabled(picker, not picker.enabled?)

  def put_enabled(%DocumentElementPicker{} = picker, enabled?) do
    transition(picker, %{enabled?: enabled? == true, picks: picker.picks})
  end

  def toggle_pick(%DocumentElementPicker{} = picker, attrs) when is_map(attrs) do
    with {:ok, pick} <- DocumentElementPicker.build_pick(attrs) do
      key = pick_key(pick)

      picks =
        if Enum.any?(picker.picks, &(pick_key(&1) == key)),
          do: Enum.reject(picker.picks, &(pick_key(&1) == key)),
          else: Enum.take(picker.picks ++ [pick], @max_picks)

      transition(picker, %{enabled?: picker.enabled?, picks: Enum.map(picks, &Map.from_struct/1)})
    else
      :error -> picker
    end
  end

  def toggle_pick(%DocumentElementPicker{} = picker, _attrs), do: picker

  def remove_pick(%DocumentElementPicker{} = picker, key) when is_binary(key) do
    picks = Enum.reject(picker.picks, &(pick_key(&1) == key))
    transition(picker, %{enabled?: picker.enabled?, picks: Enum.map(picks, &Map.from_struct/1)})
  end

  def remove_pick(%DocumentElementPicker{} = picker, _key), do: picker

  def clear(%DocumentElementPicker{} = picker),
    do: transition(picker, %{enabled?: picker.enabled?, picks: []})

  def compact_picks(picks) when is_list(picks) do
    picks
    |> Enum.filter(&is_map/1)
    |> Enum.take(@max_picks)
    |> Enum.flat_map(fn attrs ->
      case DocumentElementPicker.build_pick(attrs) do
        {:ok, pick} -> [Map.take(Map.from_struct(pick), [:document, :type, :ref, :text, :hint])]
        :error -> []
      end
    end)
    |> dedupe()
    |> Enum.map(&string_keys/1)
  end

  def compact_picks(_picks), do: []

  def compact_picks(%DocumentElementPicker{} = picker, implicit_picks) do
    explicit = Enum.map(picker.picks, &Map.from_struct/1)
    compact_picks(explicit ++ List.wrap(implicit_picks))
  end

  def pick_key(%Pick{} = pick), do: pick_key(Map.from_struct(pick))

  def pick_key(pick) when is_map(pick) do
    document = Map.get(pick, :document, Map.get(pick, "document", ""))
    ref = Map.get(pick, :ref, Map.get(pick, "ref", ""))
    text = Map.get(pick, :text, Map.get(pick, "text", ""))
    "#{document}|#{if(ref == "", do: text, else: ref)}"
  end

  defp transition(picker, attrs) do
    changeset = DocumentElementPicker.changeset(picker, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: picker
  end

  defp dedupe(picks) do
    {picks, _keys} =
      Enum.reduce(picks, {[], MapSet.new()}, fn pick, {acc, keys} ->
        key = pick_key(pick)

        if MapSet.member?(keys, key),
          do: {acc, keys},
          else: {acc ++ [pick], MapSet.put(keys, key)}
      end)

    picks
  end

  defp string_keys(pick), do: Map.new(pick, fn {key, value} -> {Atom.to_string(key), value} end)
end
