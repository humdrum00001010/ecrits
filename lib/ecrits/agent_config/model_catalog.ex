defmodule Ecrits.AgentConfig.ModelCatalog do
  @moduledoc false

  @models [
    %{id: "gpt-5.6", provider: "codex", label: "GPT-5.6", description: "Frontier Codex model"},
    %{id: "gpt-5.5", provider: "codex", label: "GPT-5.5", description: "Previous frontier"},
    %{id: "gpt-5.4", provider: "codex", label: "GPT-5.4", description: "Balanced Codex model"},
    %{
      id: "gpt-5.4-mini",
      provider: "codex",
      label: "GPT-5.4 mini",
      description: "Lower token spend"
    },
    %{
      id: "gpt-5.3-codex",
      provider: "codex",
      label: "GPT-5.3 Codex",
      description: "Coding-specialized"
    },
    %{
      id: "gpt-5.3-codex-spark",
      provider: "codex",
      label: "GPT-5.3 Codex Spark",
      description: "Fast coding model"
    },
    %{
      id: "default",
      provider: "claude",
      label: "Default",
      description: "Recommended — latest Claude"
    },
    %{id: "opus", provider: "claude", label: "Opus", description: "Most capable — latest Opus"},
    %{
      id: "sonnet",
      provider: "claude",
      label: "Sonnet",
      description: "Balanced speed and capability"
    },
    %{id: "haiku", provider: "claude", label: "Haiku", description: "Fastest, lowest cost"},
    %{
      id: "opusplan",
      provider: "claude",
      label: "Opus Plan",
      description: "Opus plans, Sonnet executes"
    }
  ]

  def all, do: @models
  def get(id), do: Enum.find(@models, &(&1.id == id))
  def for_provider(provider), do: Enum.filter(@models, &(&1.provider == provider))
end
