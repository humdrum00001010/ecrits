defmodule Contract.Local.Agent.Provider do
  @moduledoc """
  Compatibility facade for the registered local ACP provider registry.
  """

  alias Contract.Local.ACP

  def all, do: ACP.provider_metadata()
  def supported_ids, do: ACP.supported_provider_ids()
  def fetch(id), do: ACP.fetch_provider(id)
  def default_id, do: ACP.default_provider_id()
  def public_metadata(provider), do: ACP.public_provider_metadata(provider)
end
