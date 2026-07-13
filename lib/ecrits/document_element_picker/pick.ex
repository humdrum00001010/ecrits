defmodule Ecrits.DocumentElementPicker.Pick do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  @max_rects 512

  embedded_schema do
    field :document, :string, default: ""
    field :backend, :string, default: ""
    field :format, :string, default: ""
    field :type, :string, default: "unknown"
    field :ref, :string, default: ""
    field :text, :string, default: ""
    field :hint, :string, default: ""
    field :ir, :map, default: %{}
    field :rects, {:array, :map}, default: []
  end

  def changeset(pick, attrs) when is_map(attrs) do
    pick
    |> cast(attrs, [:document, :backend, :format, :type, :ref, :text, :hint, :ir, :rects])
    |> validate_length(:document, max: 500)
    |> validate_length(:backend, max: 50)
    |> validate_length(:format, max: 20)
    |> validate_length(:type, max: 50)
    |> validate_length(:ref, max: 500)
    |> validate_length(:text, max: 200)
    |> validate_length(:hint, max: 300)
    |> validate_length(:rects, max: @max_rects)
    |> validate_change(:rects, &validate_rects/2)
    |> validate_useful_pick()
  end

  def build(attrs) when is_map(attrs) do
    changeset = changeset(%__MODULE__{}, attrs)
    if changeset.valid?, do: {:ok, apply_changes(changeset)}, else: :error
  end

  defp validate_useful_pick(changeset) do
    if Enum.any?([:ref, :text, :hint], &(get_field(changeset, &1, "") != "")),
      do: changeset,
      else: add_error(changeset, :ref, "pick must contain a ref, text, or hint")
  end

  defp validate_rects(:rects, rects) do
    if Enum.all?(rects, &valid_rect?/1), do: [], else: [rects: "contains an invalid rectangle"]
  end

  defp valid_rect?(rect) when is_map(rect) do
    Enum.all?(rect, fn
      {key, value}
      when key in [
             :pageIndex,
             :x,
             :y,
             :width,
             :height,
             :left,
             :top,
             :right,
             :bottom,
             "pageIndex",
             "x",
             "y",
             "width",
             "height",
             "left",
             "top",
             "right",
             "bottom"
           ] ->
        is_number(value)

      _pair ->
        false
    end)
  end

  defp valid_rect?(_rect), do: false
end
