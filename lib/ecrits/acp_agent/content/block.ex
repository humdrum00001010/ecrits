defmodule Ecrits.AcpAgent.Content.Block do
  @moduledoc "Typed discriminator for multimodal ACP input blocks."

  alias Ecrits.AcpAgent.Content.{DocumentRef, File, Media, Text}

  @types %{
    "text" => :text,
    "image" => :image,
    "audio" => :audio,
    "file" => :file,
    "doc_ref" => :doc_ref
  }

  @schemas [Text, Media, File, DocumentRef]

  @spec cast(term()) ::
          {:ok, struct()}
          | {:error, atom(), Ecto.Changeset.t()}
          | {:error, {:unknown_block_type, term()} | {:invalid_block, term()}}
  def cast(attrs) when is_map(attrs) do
    case fetch_type(attrs) do
      :text -> cast_with(Text, :text, attrs)
      type when type in [:image, :audio] -> cast_with(Media, type, attrs)
      :file -> cast_with(File, :file, attrs)
      :doc_ref -> cast_with(DocumentRef, :doc_ref, attrs)
      nil -> {:error, {:invalid_block, attrs}}
      type -> {:error, {:unknown_block_type, type}}
    end
  end

  def cast(other), do: {:error, {:invalid_block, other}}

  @spec dump(struct()) :: map()
  def dump(%module{} = block) when module in @schemas, do: module.dump(block)

  @doc false
  @spec params(map(), [atom()]) :: map()
  def params(attrs, fields) do
    Enum.reduce(fields, %{}, fn field, params ->
      case fetch(attrs, field) do
        {:ok, value} -> Map.put(params, field, value)
        :error -> params
      end
    end)
  end

  @doc false
  @spec dump_fields(struct(), [atom()]) :: map()
  def dump_fields(block, fields) do
    Enum.reduce(fields, %{}, fn field, dumped ->
      case Map.fetch!(block, field) do
        nil -> dumped
        "" -> dumped
        value -> Map.put(dumped, field, value)
      end
    end)
  end

  defp cast_with(module, type, attrs) do
    case module.cast(attrs) do
      {:ok, block} -> {:ok, block}
      {:error, changeset} -> {:error, type, changeset}
    end
  end

  defp fetch_type(attrs) do
    case fetch(attrs, :type) do
      {:ok, type} when is_atom(type) -> type
      {:ok, type} when is_binary(type) -> Map.get(@types, type, type)
      {:ok, type} -> type
      :error -> nil
    end
  end

  defp fetch(attrs, key) do
    keys = [key, Atom.to_string(key) | aliases(key)]

    Enum.find_value(keys, :error, fn candidate ->
      case Map.fetch(attrs, candidate) do
        {:ok, value} -> {:ok, value}
        :error -> false
      end
    end)
  end

  defp aliases(:mime_type), do: ["mimeType"]
  defp aliases(:document_id), do: ["documentId"]
  defp aliases(_key), do: []
end
