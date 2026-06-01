defmodule Contract.Local.Metadata do
  @moduledoc """
  Low-level `.contract` JSON and JSONL primitives.
  """

  alias Contract.Local.FS
  alias Contract.Local.Path, as: LocalPath

  @schema_version 1
  @subdirs ~w(documents threads operations snapshots checkpoints indexes)

  @doc """
  Current local metadata schema version.
  """
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Ensure `.contract` metadata directory exists.
  """
  @spec ensure(String.t()) :: :ok | {:error, term()}
  def ensure(root) do
    with {:ok, metadata_root} <- LocalPath.metadata_join(root, "."),
         :ok <- File.mkdir_p(metadata_root) do
      Enum.reduce_while(@subdirs, :ok, fn subdir, :ok ->
        case File.mkdir_p(Path.join(metadata_root, subdir)) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  @doc """
  Add schema metadata to a record.
  """
  @spec envelope(map()) :: map()
  def envelope(record) when is_map(record) do
    record
    |> stringify_keys()
    |> Map.put("schema_version", @schema_version)
  end

  @doc """
  Write JSON inside `.contract` atomically.
  """
  @spec write_json(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def write_json(root, relative, record) when is_map(record) do
    with :ok <- ensure(root),
         {:ok, path} <- LocalPath.metadata_join(root, relative),
         {:ok, json} <- Jason.encode(envelope(record), pretty: true) do
      FS.atomic_write(path, json <> "\n")
    end
  end

  @doc """
  Read JSON from `.contract`.
  """
  @spec read_json(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def read_json(root, relative) do
    with {:ok, path} <- LocalPath.metadata_join(root, relative),
         {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Append a schema-versioned JSON object to a JSONL file inside `.contract`.
  """
  @spec append_jsonl(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def append_jsonl(root, relative, record) when is_map(record) do
    with :ok <- ensure(root),
         {:ok, path} <- LocalPath.metadata_join(root, relative),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, line} <- Jason.encode(envelope(record)) do
      File.write(path, line <> "\n", [:append, :binary])
    end
  end

  @doc """
  Read schema-versioned JSONL records from `.contract`.
  """
  @spec read_jsonl(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def read_jsonl(root, relative) do
    with {:ok, path} <- LocalPath.metadata_join(root, relative) do
      if File.exists?(path) do
        path
        |> File.stream!([], :line)
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
          line = String.trim(line)

          if line == "" do
            {:cont, {:ok, acc}}
          else
            case Jason.decode(line) do
              {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end
        end)
        |> case do
          {:ok, records} -> {:ok, Enum.reverse(records)}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, []}
      end
    end
  end

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value
end
