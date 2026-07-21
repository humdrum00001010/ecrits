defmodule Ecrits.AgentConfig.ModelCatalog do
  @moduledoc false

  @models [
    %{
      id: "gpt-5.6-sol",
      provider: "codex",
      label: "GPT-5.6-Sol",
      description: "Latest frontier agentic coding model"
    },
    %{
      id: "gpt-5.6-terra",
      provider: "codex",
      label: "GPT-5.6-Terra",
      description: "Balanced agentic coding model for everyday work"
    },
    %{
      id: "gpt-5.6-luna",
      provider: "codex",
      label: "GPT-5.6-Luna",
      description: "Fast and affordable agentic coding model"
    },
    %{
      id: "gpt-5.5",
      provider: "codex",
      label: "GPT-5.5",
      description: "Frontier model for complex coding, research, and real-world work"
    },
    %{
      id: "gpt-5.3-codex-spark",
      provider: "codex",
      label: "GPT-5.3-Codex-Spark",
      description: "Ultra-fast coding model"
    },
    %{
      id: "default",
      provider: "claude",
      label: "Default",
      description: "Recommended — latest Claude"
    },
    %{
      id: "sonnet",
      provider: "claude",
      label: "Sonnet",
      description: "Balanced speed and capability"
    },
    %{id: "opus", provider: "claude", label: "Opus", description: "Most capable — latest Opus"}
  ]

  def all, do: @models
  def get(id), do: Enum.find(@models, &(&1.id == id))
  def for_provider(provider), do: Enum.filter(@models, &(&1.provider == provider))
end
