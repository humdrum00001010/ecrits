defmodule Ecrits.Local.ConfigStore do
  @moduledoc """
  Ephemeral local config compatibility API.
  """

  alias Ecrits.Local.Metadata

  @doc """
  Load local config, returning defaults when no config exists yet.
  """
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(_root), do: {:ok, default_config()}

  @doc """
  Compatibility no-op.
  """
  @spec save(String.t(), map()) :: :ok | {:error, term()}
  def save(_root, config) when is_map(config), do: :ok

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
  def put(_root, key, _value) when is_atom(key) or is_binary(key) do
    :ok
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
