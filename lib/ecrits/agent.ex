defmodule Ecrits.Agent do
  @moduledoc """
  Context boundary for durable agent dialogs.

  The ACP runner owns live turn execution; this context owns the display model
  that survives LiveView re-attachment. It accepts legacy map dialogs during a
  hot code reload, returns typed `Ecrits.Agent.Dialog` values, and provides the
  JSON dump/load seam used by persisted session state.
  """

  alias Ecrits.Agent.{Dialog, Item}

  @dialog_keys ~w(turn_id user agent items)a

  @doc "Builds and validates one typed dialog aggregate."
  @spec new_dialog(map() | Dialog.t()) :: {:ok, Dialog.t()} | {:error, Ecto.Changeset.t()}
  def new_dialog(%Dialog{} = dialog), do: new_dialog(Map.from_struct(dialog))

  def new_dialog(attrs) when is_map(attrs) do
    %Dialog{}
    |> Dialog.changeset(dialog_params(attrs))
    |> Ecto.Changeset.apply_action(:insert)
  end

  @doc "Builds one typed dialog and raises when its aggregate is invalid."
  @spec new_dialog!(map() | Dialog.t()) :: Dialog.t()
  def new_dialog!(attrs) do
    case new_dialog(attrs) do
      {:ok, dialog} -> dialog
      {:error, changeset} -> raise ArgumentError, inspect(changeset.errors)
    end
  end

  @doc "Appends a display item without changing the aggregate's execution order."
  @spec append_dialog_item(Dialog.t() | map(), map()) :: Dialog.t()
  def append_dialog_item(dialog, item) when is_map(item) do
    dialog = new_dialog!(dialog)
    new_dialog!(%{dialog | items: upsert_dialog_item(dialog.items, item, dialog.turn_id)})
  end

  @doc "Appends a display item, replacing an existing edit preview with the same stable identity."
  @spec upsert_dialog_item([map()], map(), String.t() | nil) :: [map()]
  def upsert_dialog_item(items, item, fallback_turn_id \\ nil)
      when is_list(items) and is_map(item) do
    item = item |> Item.cast!() |> Item.dump()

    case edit_preview_identity(item, fallback_turn_id) do
      nil ->
        items ++ [item]

      identity ->
        case Enum.split_while(
               items,
               &(edit_preview_identity(&1, fallback_turn_id) != identity)
             ) do
          {_before, []} ->
            items ++ [item]

          {before, [_first_match | after_first]} ->
            remaining =
              Enum.reject(
                after_first,
                &(edit_preview_identity(&1, fallback_turn_id) == identity)
              )

            before ++ [item | remaining]
        end
    end
  end

  @doc "Stable semantic identity for one persisted edit-preview descriptor."
  @spec edit_preview_identity(map(), String.t() | nil) :: tuple() | nil
  def edit_preview_identity(item, fallback_turn_id \\ nil)

  def edit_preview_identity(item, fallback_turn_id) when is_map(item) do
    if field(item, :role) |> to_string() == "edit_preview" do
      snapshot = field(item, :preview_snapshot)
      stored = field(item, :preview_identity)

      turn_id = identity_field(stored, :turn_id) || field(item, :turn_id) || fallback_turn_id

      edit_id =
        identity_field(stored, :edit_id) || field(item, :edit_id) || field(item, :hash) ||
          "legacy"

      document_id =
        identity_field(stored, :document_id) || field(item, :document_id) ||
          field(snapshot, :document_id) || field(item, :document_path) || field(item, :document)

      # A snapshot identifies one byte capture of the preview, not a distinct
      # edit. Repeated terminal broadcasts and delivery retries can recapture
      # the same committed edit under a new snapshot id. Keep that id in the
      # descriptor payload, but upsert by the semantic edit identity so the
      # latest snapshot replaces the prior row at its original position.
      if Enum.all?([turn_id, edit_id, document_id], &present_identity_field?/1) do
        {to_string(turn_id), to_string(edit_id), to_string(document_id)}
      end
    end
  end

  def edit_preview_identity(_item, _fallback_turn_id), do: nil

  @doc "Normalizes dialogs and compacts repeated preview identities at their first position."
  @spec normalize_dialogs!([Dialog.t() | map()]) :: [Dialog.t()]
  def normalize_dialogs!(dialogs) when is_list(dialogs) do
    Enum.map(dialogs, fn attrs ->
      dialog = new_dialog!(attrs)

      items =
        Enum.reduce(dialog.items, [], fn item, normalized ->
          upsert_dialog_item(normalized, item, dialog.turn_id)
        end)

      new_dialog!(%{dialog | items: items})
    end)
  end

  @doc "Returns a JSON-ready embedded representation of a dialog."
  @spec dump_dialog(Dialog.t() | map()) :: map()
  def dump_dialog(dialog) do
    dialog
    |> new_dialog!()
    |> Ecto.embedded_dump(:json)
  end

  @doc "Restores a typed dialog from its embedded JSON representation."
  @spec load_dialog(map() | Dialog.t()) :: {:ok, Dialog.t()} | {:error, Ecto.Changeset.t()}
  def load_dialog(%Dialog{} = dialog), do: new_dialog(dialog)
  def load_dialog(attrs) when is_map(attrs), do: new_dialog(attrs)

  @doc "Restores a typed dialog and raises when the representation is invalid."
  @spec load_dialog!(map() | Dialog.t()) :: Dialog.t()
  def load_dialog!(attrs), do: new_dialog!(attrs)

  defp dialog_params(attrs) do
    Map.new(@dialog_keys, fn key ->
      value = Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
      {key, normalize_dialog_value(key, value)}
    end)
  end

  defp normalize_dialog_value(:user, nil), do: ""
  defp normalize_dialog_value(:agent, nil), do: ""
  defp normalize_dialog_value(:items, nil), do: []

  defp normalize_dialog_value(:items, items) when is_list(items),
    do: Enum.map(items, fn item -> item |> Item.cast!() |> Item.dump() end)

  defp normalize_dialog_value(_key, value), do: value

  defp identity_field(map, key) when is_map(map), do: field(map, key)
  defp identity_field(_map, _key), do: nil

  defp field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp field(_map, _key), do: nil

  defp present_identity_field?(value), do: not is_nil(value) and value != ""
end
