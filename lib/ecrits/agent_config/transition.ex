defmodule Ecrits.AgentConfig.Transition do
  @moduledoc false

  import Ecto.Changeset

  alias Ecrits.AgentConfig

  def put(%AgentConfig{} = config, attrs) when is_map(attrs) do
    changeset = AgentConfig.changeset(config, attrs)
    if changeset.valid?, do: apply_changes(changeset), else: config
  end

  def put(%AgentConfig{} = config, _attrs), do: config
end
