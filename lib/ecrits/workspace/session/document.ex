defmodule Ecrits.Workspace.Session.Document do
  @moduledoc """
  Session-owned document UI state.

  This is distinct from `Ecrits.Document.t/0`, which describes the opened
  file/runtime document. This module describes what the durable workspace
  session needs to restore: path, handles, and scroll position.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false

  @type path :: String.t()
  @type id :: String.t()
  @type pool_document_id :: String.t()
  @type scroll_coordinate :: non_neg_integer()

  @type t :: %__MODULE__{
          path: path(),
          id: id() | nil,
          pool_document_id: pool_document_id() | nil,
          scroll_top: scroll_coordinate(),
          scroll_left: scroll_coordinate()
        }

  embedded_schema do
    field :path, :string
    field :id, :string
    field :pool_document_id, :string
    field :scroll_top, :integer, default: 0
    field :scroll_left, :integer, default: 0
  end

  @fields [:path, :id, :pool_document_id, :scroll_top, :scroll_left]

  @spec cast(map() | keyword() | t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(attrs), do: cast(attrs, %__MODULE__{})

  @spec cast(map() | keyword() | t(), t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(%__MODULE__{} = document, %__MODULE__{} = existing) do
    document
    |> Map.from_struct()
    |> cast(existing)
  end

  def cast(attrs, %__MODULE__{} = existing) when is_map(attrs) or is_list(attrs) do
    changeset = changeset(existing, attrs)

    if changeset.valid? do
      {:ok, apply_changes(changeset)}
    else
      {:error, changeset}
    end
  end

  def cast(_attrs, %__MODULE__{} = existing) do
    {:error, add_error(change(existing), :path, "is invalid")}
  end

  @spec cast!(map() | keyword() | t()) :: t()
  def cast!(attrs) do
    case cast(attrs) do
      {:ok, document} -> document
      {:error, changeset} -> raise Ecto.InvalidChangesetError, action: :cast, changeset: changeset
    end
  end

  defp changeset(document, attrs) do
    attrs = normalize_attrs(attrs)

    document
    |> Ecto.Changeset.cast(attrs, @fields)
    |> validate_required([:path])
    |> validate_number(:scroll_top, greater_than_or_equal_to: 0)
    |> validate_number(:scroll_left, greater_than_or_equal_to: 0)
    |> validate_change(:path, fn :path, path ->
      if safe_relative_path?(path), do: [], else: [path: "must be a safe relative path"]
    end)
  end

  defp normalize_attrs(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalize_attrs()

  defp normalize_attrs(attrs) do
    attrs
    |> take_known_attrs()
    |> alias_coordinate(:top, :scroll_top)
    |> alias_coordinate(:left, :scroll_left)
    |> normalize_coordinate(:scroll_top)
    |> normalize_coordinate(:scroll_left)
    |> normalize_path()
    |> drop_nil_values()
  end

  defp take_known_attrs(attrs) do
    Enum.reduce(@fields ++ [:top, :left], %{}, fn key, known ->
      case fetch_value(attrs, key) do
        {:ok, value} -> Map.put(known, key, value)
        :error -> known
      end
    end)
  end

  defp alias_coordinate(attrs, source, target) do
    source_value = value(attrs, source)

    if is_nil(value(attrs, target)) and not is_nil(source_value) do
      Map.put(attrs, target, source_value)
    else
      attrs
    end
  end

  defp normalize_coordinate(attrs, key) do
    case value(attrs, key) do
      value when is_float(value) and value >= 0 -> Map.put(attrs, key, round(value))
      _ -> attrs
    end
  end

  defp normalize_path(attrs) do
    case value(attrs, :path) do
      path when is_binary(path) -> Map.put(attrs, :path, canonical_path(path))
      _ -> attrs
    end
  end

  defp canonical_path(path) do
    path = String.trim(path)

    case Path.split(path) do
      [] -> path
      segments -> Path.join(segments)
    end
  end

  defp drop_nil_values(attrs) do
    Map.reject(attrs, fn {_key, value} -> is_nil(value) end)
  end

  defp value(attrs, key) do
    case fetch_value(attrs, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp fetch_value(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp safe_relative_path?(path) when is_binary(path) do
    segments = Path.split(path)

    path != "" and Path.type(path) != :absolute and
      not Enum.any?(segments, &(&1 in [".", ".."]))
  end

  defp safe_relative_path?(_path), do: false
end
