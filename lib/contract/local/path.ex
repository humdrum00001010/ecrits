defmodule Contract.Local.Path do
  @moduledoc """
  Path boundary for local workspaces.

  User-facing paths are always relative to the workspace root, cannot enter
  `.contract`, and cannot traverse symlinks inside the workspace.
  """

  @metadata_dir ".contract"

  @type reason ::
          :absolute_path
          | :empty_path
          | :invalid_path
          | :metadata_path
          | :path_traversal
          | {:outside_workspace, String.t()}
          | {:symlink, String.t()}

  @doc """
  Name of the hidden metadata directory.
  """
  @spec metadata_dir() :: String.t()
  def metadata_dir, do: @metadata_dir

  @doc """
  Normalize a user-visible relative path.
  """
  @spec normalize(String.t()) :: {:ok, String.t()} | {:error, reason()}
  def normalize("."), do: {:ok, "."}

  def normalize(path) when is_binary(path) do
    with :ok <- reject_empty(path),
         :ok <- reject_null(path),
         :ok <- reject_absolute(path),
         {:ok, components} <- split_components(path),
         :ok <- reject_traversal(components),
         :ok <- reject_metadata(components) do
      {:ok, Path.join(components)}
    end
  end

  def normalize(_path), do: {:error, :invalid_path}

  @doc """
  Resolve a user-visible relative path inside `root`.
  """
  @spec join(String.t(), String.t()) :: {:ok, String.t()} | {:error, reason() | File.posix()}
  def join(root, path) when is_binary(root) do
    with {:ok, relative} <- normalize(path) do
      do_join(root, relative)
    end
  end

  @doc """
  Resolve a path inside `.contract`.
  """
  @spec metadata_join(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, reason() | File.posix()}
  def metadata_join(root, path \\ ".") when is_binary(root) do
    with {:ok, relative} <- normalize_metadata_path(path) do
      do_join(root, Path.join(@metadata_dir, relative))
    end
  end

  @doc """
  Return true when `path` is inside `root` after expansion.
  """
  @spec inside?(String.t(), String.t()) :: boolean()
  def inside?(root, path) when is_binary(root) and is_binary(path) do
    root = Path.expand(root)
    path = Path.expand(path)
    path == root or String.starts_with?(path, root <> "/")
  end

  defp do_join(root, relative) do
    root = Path.expand(root)
    target = Path.expand(relative, root)

    with :ok <- contain(root, target),
         :ok <- reject_symlink(root, target) do
      {:ok, target}
    end
  end

  defp normalize_metadata_path("."), do: {:ok, "."}

  defp normalize_metadata_path(path) when is_binary(path) do
    with :ok <- reject_empty(path),
         :ok <- reject_null(path),
         :ok <- reject_absolute(path),
         {:ok, components} <- split_components(path),
         :ok <- reject_traversal(components) do
      {:ok, Path.join(components)}
    end
  end

  defp normalize_metadata_path(_path), do: {:error, :invalid_path}

  defp reject_empty(""), do: {:error, :empty_path}
  defp reject_empty(_path), do: :ok

  defp reject_null(path) do
    if String.contains?(path, <<0>>) do
      {:error, :invalid_path}
    else
      :ok
    end
  end

  defp reject_absolute(path) do
    if Path.type(path) == :absolute do
      {:error, :absolute_path}
    else
      :ok
    end
  end

  defp split_components(path) do
    components =
      path
      |> Path.split()
      |> Enum.reject(&(&1 in ["", "."]))

    case components do
      [] -> {:error, :empty_path}
      _ -> {:ok, components}
    end
  end

  defp reject_traversal(components) do
    if ".." in components do
      {:error, :path_traversal}
    else
      :ok
    end
  end

  defp reject_metadata([@metadata_dir | _rest]), do: {:error, :metadata_path}
  defp reject_metadata(_components), do: :ok

  defp contain(root, target) do
    if inside?(root, target) do
      :ok
    else
      {:error, {:outside_workspace, target}}
    end
  end

  defp reject_symlink(root, target) do
    relative = Path.relative_to(target, root)

    components =
      if relative == "." do
        []
      else
        Path.split(relative)
      end

    root
    |> symlink_prefixes(components)
    |> Enum.find_value(:ok, fn path ->
      case File.lstat(path) do
        {:ok, %{type: :symlink}} -> {:error, {:symlink, path}}
        {:ok, _stat} -> false
        {:error, :enoent} -> false
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp symlink_prefixes(root, components) do
    {_path, prefixes} =
      Enum.reduce(components, {root, []}, fn component, {path, acc} ->
        path = Path.join(path, component)
        {path, [path | acc]}
      end)

    Enum.reverse(prefixes)
  end
end
