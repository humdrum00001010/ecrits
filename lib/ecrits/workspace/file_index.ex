defmodule Ecrits.Workspace.FileIndex do
  @moduledoc false

  @default_limit 200
  @max_depth 8

  @text_extensions MapSet.new(
                     ~w(.jsonl .json .md .txt .csv .tsv .yaml .yml .toml .ex .exs .heex .js .ts .css .html)
                   )
  @picture_extensions MapSet.new(~w(.png .jpg .jpeg .gif .webp .bmp .tif .tiff))
  @office_extensions MapSet.new(~w(.hwp .hwpx .doc .docx .ppt .pptx .xls .xlsx .pdf))

  alias Ecrits.FS

  @spec list(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(root, opts \\ []) when is_binary(root) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@default_limit)
    root = Path.expand(root)

    case walk(root, ".", 0, limit) do
      {:ok, files, _remaining} -> {:ok, files}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec text_path?(String.t()) :: boolean()
  def text_path?(path), do: extension_in?(path, @text_extensions)

  @spec picture_path?(String.t()) :: boolean()
  def picture_path?(path), do: extension_in?(path, @picture_extensions)

  @spec office_path?(String.t()) :: boolean()
  def office_path?(path), do: extension_in?(path, @office_extensions)

  defp walk(_root, _relative, _depth, 0), do: {:ok, [], 0}

  defp walk(_root, _relative, depth, remaining) when depth > @max_depth,
    do: {:ok, [], remaining}

  defp walk(root, relative, depth, remaining) do
    with {:ok, entries} <- FS.list(root, relative) do
      Enum.reduce_while(entries, {:ok, [], remaining}, fn entry, {:ok, files, left} ->
        cond do
          left == 0 ->
            {:halt, {:ok, files, 0}}

          hidden_entry?(entry) or entry.type in [:symlink, :other] ->
            {:cont, {:ok, files, left}}

          entry.type == :directory ->
            case walk(root, entry.path, depth + 1, left) do
              {:ok, nested, next_left} -> {:cont, {:ok, files ++ nested, next_left}}
              {:error, _reason} -> {:cont, {:ok, files, left}}
            end

          entry.type == :file ->
            case indexed_file(root, entry.path) do
              {:ok, file} -> {:cont, {:ok, files ++ [file], left - 1}}
              :skip -> {:cont, {:ok, files, left}}
            end
        end
      end)
    end
  end

  defp indexed_file(root, relative) do
    absolute = Path.join(root, relative)

    kind =
      cond do
        text_path?(relative) -> "text"
        picture_path?(relative) -> "picture"
        true -> nil
      end

    case {kind, File.stat(absolute)} do
      {kind, {:ok, %File.Stat{type: :regular, links: 1}}} when is_binary(kind) ->
        {:ok, %{"path" => relative, "absolute_path" => absolute, "kind" => kind}}

      _other ->
        :skip
    end
  end

  defp hidden_entry?(%{path: path}) do
    not String.valid?(path) or
      path |> Path.split() |> Enum.any?(&String.starts_with?(&1, "."))
  end

  defp extension_in?(path, extensions) when is_binary(path) do
    path |> Path.extname() |> String.downcase() |> then(&MapSet.member?(extensions, &1))
  end

  defp extension_in?(_path, _extensions), do: false
end
