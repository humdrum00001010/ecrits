defmodule Ecrits.Agent.Item do
  @moduledoc """
  Typed normalization boundary for durable transcript items.

  Only the bounded role discriminator is read here. Each role family owns its
  fields and changeset validation, while unknown provider fields remain in the
  dumped map without creating atoms.
  """

  alias Ecrits.Agent.Item.{EditPreview, FileActivity, Text, Tool}

  @roles %{
    "user" => :user,
    "agent" => :agent,
    "thinking" => :thinking,
    "tool" => :tool,
    "file_activity" => :file_activity,
    "edit_preview" => :edit_preview
  }

  @schemas [Text, Tool, FileActivity, EditPreview]

  @spec cast(map()) :: {:ok, struct()} | {:error, Ecto.Changeset.t()}
  def cast(attrs) when is_map(attrs) do
    case fetch_role(attrs) do
      role when role in [:user, :agent, :thinking] -> Text.cast(attrs)
      :tool -> Tool.cast(attrs)
      :file_activity -> FileActivity.cast(attrs)
      :edit_preview -> EditPreview.cast(attrs)
      role -> {:error, invalid_role_changeset(role)}
    end
  end

  def cast(_attrs), do: {:error, invalid_role_changeset(nil)}

  @spec cast!(map()) :: struct()
  def cast!(attrs) do
    case cast(attrs) do
      {:ok, item} -> item
      {:error, changeset} -> raise ArgumentError, inspect(changeset.errors)
    end
  end

  @spec dump(struct()) :: map()
  def dump(%module{} = item) when module in @schemas, do: module.dump(item)

  @doc false
  @spec params(map(), [atom()]) :: map()
  def params(attrs, fields) when is_map(attrs) and is_list(fields) do
    known_atoms = MapSet.new(fields)
    known_strings = MapSet.new(fields, &Atom.to_string/1)

    extensions =
      attrs
      |> Enum.reject(fn {key, _value} ->
        key in [:__struct__, :__meta__, :extensions] or
          MapSet.member?(known_atoms, key) or MapSet.member?(known_strings, key)
      end)
      |> Map.new()
      |> Map.merge(Map.get(attrs, :extensions, %{}))

    {params, present_fields} =
      Enum.reduce(fields, {%{extensions: extensions}, []}, fn field, {params, present} ->
        case fetch(attrs, field) do
          {:ok, value} -> {Map.put(params, field, value), [field | present]}
          :error -> {params, present}
        end
      end)

    Map.put(params, :present_fields, present_fields)
  end

  @doc false
  @spec dump_fields(struct(), [atom()]) :: map()
  def dump_fields(item, fields) when is_struct(item) and is_list(fields) do
    present_fields = MapSet.new(item.present_fields)

    known =
      Enum.reduce(fields, %{}, fn field, dumped ->
        case Map.fetch!(item, field) do
          nil ->
            if MapSet.member?(present_fields, field),
              do: Map.put(dumped, field, nil),
              else: dumped

          value ->
            Map.put(dumped, field, value)
        end
      end)

    Map.merge(item.extensions, known)
  end

  defp fetch_role(attrs) do
    case fetch(attrs, :role) do
      {:ok, role} when is_atom(role) -> role
      {:ok, role} when is_binary(role) -> Map.get(@roles, role, role)
      {:ok, role} -> role
      :error -> nil
    end
  end

  defp fetch(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  defp invalid_role_changeset(role) do
    {%{}, %{role: :string}}
    |> Ecto.Changeset.cast(%{role: inspect(role)}, [:role])
    |> Ecto.Changeset.add_error(:role, "is invalid")
  end
end
