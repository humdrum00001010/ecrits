defmodule Ecrits.Local.FS do
  @moduledoc """
  Filesystem access through `Ecrits.Local.Path`.
  """

  alias Ecrits.Local.Path, as: LocalPath

  @type entry :: %{
          name: String.t(),
          path: String.t(),
          type: :directory | :file | :symlink | :other,
          size: non_neg_integer()
        }

  @doc """
  Read a workspace file.
  """
  @spec read(String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def read(root, relative) do
    with {:ok, path} <- LocalPath.join(root, relative) do
      File.read(path)
    end
  end

  @doc """
  Write a workspace file. Atomic by default.
  """
  @spec write(String.t(), String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def write(root, relative, contents, opts \\ []) when is_binary(contents) do
    with {:ok, path} <- LocalPath.join(root, relative),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      if Keyword.get(opts, :atomic, true) do
        atomic_write(path, contents)
      else
        File.write(path, contents, [:binary])
      end
    end
  end

  @doc """
  List a workspace directory, hiding `.ecrits`.
  """
  @spec list(String.t(), String.t()) :: {:ok, [entry()]} | {:error, term()}
  def list(root, relative \\ ".") do
    with {:ok, path} <- LocalPath.join(root, relative),
         {:ok, names} <- File.ls(path) do
      entries =
        names
        |> Enum.reject(&(&1 == LocalPath.metadata_dir()))
        |> Enum.flat_map(fn name ->
          case entry(path, relative, name) do
            nil -> []
            entry -> [entry]
          end
        end)
        |> Enum.sort_by(&entry_sort_key/1)

      {:ok, entries}
    end
  end

  @doc """
  Return true when a workspace path exists and is not hidden metadata.
  """
  @spec exists?(String.t(), String.t()) :: boolean()
  def exists?(root, relative) do
    case LocalPath.join(root, relative) do
      {:ok, path} -> File.exists?(path)
      {:error, _reason} -> false
    end
  end

  @doc """
  Atomic write helper for already-resolved paths.
  """
  @spec atomic_write(String.t(), binary()) :: :ok | {:error, File.posix()}
  def atomic_write(path, contents) when is_binary(path) and is_binary(contents) do
    tmp = tmp_path(path)

    result =
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp, contents, [:binary]),
           :ok <- File.rename(tmp, path) do
        :ok
      end

    if result == :ok do
      :ok
    else
      _ = File.rm(tmp)
      result
    end
  end

  defp entry(dir, relative, name) do
    path = Path.join(dir, name)

    case File.lstat(path) do
      {:ok, stat} ->
        %{
          name: name,
          path: child_relative(relative, name),
          type: entry_type(stat.type),
          size: stat.size
        }

      {:error, _reason} ->
        nil
    end
  end

  defp child_relative(".", name), do: name
  defp child_relative(relative, name), do: Path.join(relative, name)

  defp entry_type(:directory), do: :directory
  defp entry_type(:regular), do: :file
  defp entry_type(:symlink), do: :symlink
  defp entry_type(_type), do: :other

  defp entry_sort_key(%{name: name, type: type}) do
    {entry_type_rank(type), String.downcase(name), name}
  end

  defp entry_type_rank(:directory), do: 0
  defp entry_type_rank(:file), do: 1
  defp entry_type_rank(:symlink), do: 2
  defp entry_type_rank(_type), do: 3

  defp tmp_path(path) do
    dir = Path.dirname(path)
    base = Path.basename(path)
    suffix = System.unique_integer([:positive, :monotonic])

    Path.join(dir, ".#{base}.tmp-#{suffix}")
  end
end
