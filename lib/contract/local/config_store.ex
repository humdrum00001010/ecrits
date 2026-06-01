defmodule Contract.Local.ConfigStore do
  @moduledoc """
  File-backed local config stored in `.contract/config.json`.
  """

  alias Contract.Local.Metadata

  @config_file "config.json"

  @doc """
  Load local config, returning defaults when no config exists yet.
  """
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(root) do
    case Metadata.read_json(root, @config_file) do
      {:ok, config} -> {:ok, config}
      {:error, :not_found} -> {:ok, default_config()}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Save local config atomically.
  """
  @spec save(String.t(), map()) :: :ok | {:error, term()}
  def save(root, config) when is_map(config) do
    Metadata.write_json(root, @config_file, config)
  end

  @doc """
  Get a config value.
  """
  @spec get(String.t(), atom() | String.t(), term()) :: {:ok, term()} | {:error, term()}
  def get(root, key, default \\ nil) do
    with {:ok, config} <- load(root) do
      {:ok, Map.get(config, to_string(key), default)}
    end
  end

  @doc """
  Put a config value.
  """
  @spec put(String.t(), atom() | String.t(), term()) :: :ok | {:error, term()}
  def put(root, key, value) do
    with {:ok, config} <- load(root) do
      save(root, Map.put(config, to_string(key), value))
    end
  end

  @doc """
  Default local config.
  """
  @spec default_config() :: map()
  def default_config do
    %{
      "schema_version" => Metadata.schema_version(),
      "workspaces" => []
    }
  end
end
